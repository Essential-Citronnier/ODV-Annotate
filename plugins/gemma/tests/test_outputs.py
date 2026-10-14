# test_outputs.py
# OpenDicomViewer
#
# The Gemma plugin must turn a model answer into the same overlay the built-in
# mlx-server would: both now parse through _shared/coerce.py.
# Licensed under the MIT License. See LICENSE for details.
"""Tests for the Gemma plugin's prompt text and output parsing (no MLX needed)."""

from __future__ import annotations

import base64
import io
import json
import sys
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import server  # noqa: E402
from _shared.protocol import TaskRequest  # noqa: E402


def test_analyze_boxes_on_the_thousand_grid_are_rescaled():
    raw = json.dumps({"description": "d", "findings": ["one"],
                      "bounding_boxes": [{"x": 100, "y": 200, "width": 300,
                                          "height": 400, "label": "a",
                                          "confidence": 85}]})
    outputs = server.build_analyze_outputs(raw, (512, 512))
    box = outputs["bbox"][0]
    assert box["x"] == pytest.approx(0.1)
    assert box["height"] == pytest.approx(0.4)
    assert box["confidence"] == pytest.approx(0.85)
    assert outputs["text"] == "d\n\n- one"


def test_box_2d_format_is_understood():
    raw = json.dumps({"bounding_boxes": [{"box_2d": [100, 200, 500, 600], "label": "a"}]})
    box = server.build_analyze_outputs(raw, (512, 512))["bbox"][0]
    assert (box["x"], box["y"]) == (pytest.approx(0.2), pytest.approx(0.1))


def test_pixel_units_beyond_the_grid_use_the_image_size():
    raw = json.dumps({"bounding_boxes": [{"x": 560, "y": 100, "width": 560,
                                          "height": 200, "label": "a"}]})
    box = server.build_analyze_outputs(raw, (1120, 800))["bbox"][0]
    assert box["x"] == pytest.approx(0.5)


def test_severity_is_case_insensitive_and_critical_is_never_normal():
    raw = json.dumps({"regions": [
        {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2, "label": "a", "severity": "CRITICAL"},
        {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2, "label": "b", "severity": "Severe"},
        {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2, "label": "c", "severity": "urgent"},
    ]})
    severities = [b["severity"] for b in server.build_abnormality_outputs(raw, (100, 100))["bbox"]]
    assert severities == ["critical", "severe", "unknown"]


def test_bare_list_and_malformed_boxes():
    raw = '[{"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2}, {"x": "bad"}]'
    outputs = server.build_abnormality_outputs(raw, (100, 100))
    assert len(outputs["bbox"]) == 1
    assert outputs["bbox"][0]["severity"] == "unknown"


def test_unparseable_answer_falls_back_to_text():
    assert server.build_analyze_outputs("plain words", (10, 10)) == {
        "text": "plain words", "bbox": []}
    assert server.build_roi_outputs('{"label": "liver", "description": "ok"}') == {
        "text": "liver: ok"}


def _png_b64() -> str:
    from PIL import Image

    buffer = io.BytesIO()
    Image.new("RGB", (64, 32)).save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode()


class _Processor:
    def __init__(self):
        self.messages = None

    def apply_chat_template(self, messages, add_generation_prompt=False):
        self.messages = messages
        return "FORMATTED"


@pytest.mark.parametrize("mode", list(server.ANALYZE_MODES))
def test_final_analyze_prompt_has_single_braces(monkeypatch, mode):
    pytest.importorskip("PIL")
    processor = _Processor()
    adapter = server.GemmaAdapter()
    adapter.model._model = object()
    adapter.model._processor = processor
    fake = types.ModuleType("mlx_vlm")
    fake.stream_generate = lambda *a, **k: iter(
        [types.SimpleNamespace(text='{"description": "ok", "bounding_boxes": []}')])
    monkeypatch.setitem(sys.modules, "mlx_vlm", fake)

    outputs = adapter.run_task("analyze", TaskRequest({
        "inputs": {"slice2d": _png_b64(), "text": "CT"}, "options": {"mode": mode}}))

    assert outputs["text"] == "ok"
    text = processor.messages[-1]["content"][1]["text"]
    assert "{{" not in text and "}}" not in text
    example = text[text.index("{"): text.rindex("}") + 1]
    assert set(json.loads(example)) == {"findings", "bounding_boxes", "description"}
