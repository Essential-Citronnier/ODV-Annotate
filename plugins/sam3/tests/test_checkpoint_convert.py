# test_checkpoint_convert.py
# OpenDicomViewer
#
# The single-file SAM 3 checkpoint path, checked without the gated weights.
#
# The fast tests need nothing beyond the standard library. The structural test
# is opt-in (ODV_SAM3_STRUCTURAL=1) and needs torch, transformers >= 5.19 and
# Meta's `sam3` package: it builds Meta's model with random weights, saves its
# state dict as a stand-in `sam3.pt` in the public `detector.*` / `tracker.*`
# layout, and drives the adapter's real load, encode and decode on it. What it
# cannot prove is that the released file uses exactly these names.
# Licensed under the MIT License. See LICENSE for details.
"""Tests for SAM 3 checkpoint-form detection and conversion."""

from __future__ import annotations

import importlib.util
import os
import sys
import types
from pathlib import Path

import pytest

ADAPTER = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ADAPTER.parent))
sys.path.insert(0, str(ADAPTER))


def _load_server():
    spec = importlib.util.spec_from_file_location("sam3_server", ADAPTER / "server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_checkpoint_form_detection(tmp_path):
    server = _load_server()
    assert server.checkpoint_form(tmp_path) is None
    (tmp_path / "sam3.pt").write_bytes(b"x")
    assert server.checkpoint_form(tmp_path) == "file"
    (tmp_path / "config.json").write_text("{}")
    assert server.checkpoint_form(tmp_path) == "file", "config alone is not a folder checkpoint"
    (tmp_path / "model.safetensors").write_bytes(b"x")
    assert server.checkpoint_form(tmp_path) == "folder", "the folder form wins"


def test_single_file_satisfies_the_gate(tmp_path, monkeypatch):
    server = _load_server()
    monkeypatch.setenv("ODV_SAM3_WEIGHTS", str(tmp_path))
    backend = server.Sam3Backend()
    assert backend.availability()[0] == "error"
    (tmp_path / "sam3.pt").write_bytes(b"x")
    status, detail = backend.availability()
    assert status == "ready" and "not yet loaded" in detail


def test_public_prefixes_map_to_the_upstream_layout():
    import checkpoint_convert as cc

    names = cc.to_internal_names(["detector.backbone.x", "tracker.sam_mask_decoder.y",
                                  "sam3_model.z", "other"])
    assert names == {"detector.backbone.x": "sam3_model.backbone.x",
                     "tracker.sam_mask_decoder.y": "sam2_predictor.model.sam_mask_decoder.y",
                     "sam3_model.z": "sam3_model.z", "other": "other"}


def test_conversion_is_reused_until_the_source_changes(tmp_path):
    import json

    import checkpoint_convert as cc

    source = tmp_path / "sam3.pt"
    source.write_bytes(b"one")
    out = tmp_path / "hf"
    out.mkdir()
    (out / "config.json").write_text("{}")
    (out / "model.safetensors").write_bytes(b"w")
    assert not cc.is_converted(out, source), "no stamp, no reuse"
    (out / cc.SOURCE_STAMP).write_text(json.dumps(cc.source_fingerprint(source)))
    assert cc.is_converted(out, source)
    source.write_bytes(b"replaced")
    assert not cc.is_converted(out, source), "a replaced sam3.pt is converted again"


# ---------------------------------------------------------------------------
# Structural check (opt-in)
# ---------------------------------------------------------------------------


def _meta_state_dict():
    """Meta's SAM 3 image model with random weights, keyed like sam3.pt."""
    import torch
    from torch.overrides import TorchFunctionMode

    # sam3.model.edt imports triton (no macOS wheels); building the image
    # model never calls it.
    edt = types.ModuleType("sam3.model.edt")
    edt.edt_triton = lambda *a, **k: None
    sys.modules.setdefault("sam3.model.edt", edt)
    from sam3 import model_builder

    class _NoTokenizer:  # the BPE vocabulary is not in the wheel; no weights depend on it
        def __init__(self, *a, **k):
            pass

    class _CPU(TorchFunctionMode):  # Meta's code hardcodes device="cuda"
        def __torch_function__(self, func, types_, args=(), kwargs=None):
            kwargs = dict(kwargs or {})
            if str(kwargs.get("device", "")).startswith("cuda"):
                kwargs["device"] = "cpu"
            return func(*args, **kwargs)

    original_tokenizer = model_builder.SimpleTokenizer
    original_cuda = torch.Tensor.cuda
    model_builder.SimpleTokenizer = _NoTokenizer
    torch.Tensor.cuda = lambda self, *a, **k: self
    try:
        torch.manual_seed(0)
        with _CPU():
            model = model_builder.build_sam3_image_model(
                device="cpu", checkpoint_path=None, load_from_HF=False,
                enable_inst_interactivity=True)
    finally:
        model_builder.SimpleTokenizer = original_tokenizer
        torch.Tensor.cuda = original_cuda
    prefix = "inst_interactive_predictor.model."
    return {("tracker." + key[len(prefix):]) if key.startswith(prefix) else ("detector." + key):
            value for key, value in model.state_dict().items()}


@pytest.mark.skipif(os.environ.get("ODV_SAM3_STRUCTURAL") != "1",
                    reason="opt-in: needs torch, transformers and Meta's sam3 package")
def test_single_file_checkpoint_loads_and_decodes(tmp_path, monkeypatch):
    import numpy as np
    import torch
    from PIL import Image

    torch.save({"model": _meta_state_dict()}, tmp_path / "sam3.pt")
    monkeypatch.setenv("ODV_SAM3_WEIGHTS", str(tmp_path))
    server = _load_server()
    backend = server.Sam3Backend()
    backend.ensure_loaded()
    assert (tmp_path / "hf-converted" / "model.safetensors").is_file()

    from transformers import Sam3TrackerModel

    _, info = Sam3TrackerModel.from_pretrained(str(tmp_path / "hf-converted"),
                                               output_loading_info=True)
    assert info["missing_keys"] == [] or not info["missing_keys"]
    assert not info.get("mismatched_keys")

    image = Image.fromarray((np.random.default_rng(0).random((240, 320, 3)) * 255)
                            .astype(np.uint8))
    state = backend.encode(image)
    candidates = backend.decode(state, [(160, 120, 1)], None, None, multimask=True)
    assert len(candidates) == 3
    assert all(mask.shape == (240, 320) for mask, _ in candidates)
    scores = [score for _, score in candidates]
    assert scores == sorted(scores, reverse=True)
    boxed = backend.decode(state, [], (40, 30, 200, 180), None, multimask=False)
    assert boxed and boxed[0][0].shape == (240, 320)

    from _shared.protocol import PluginError

    with pytest.raises(PluginError) as raised:
        backend.decode(state, [], None, "liver", multimask=False)
    assert "tokenizer" in raised.value.message

    # A second backend reuses the conversion instead of converting again.
    stamp = (tmp_path / "hf-converted" / ".odv-converted-from.json").stat().st_mtime_ns
    server.Sam3Backend().ensure_loaded()
    assert (tmp_path / "hf-converted" / ".odv-converted-from.json").stat().st_mtime_ns == stamp
