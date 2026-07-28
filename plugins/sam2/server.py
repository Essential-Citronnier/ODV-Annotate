#!/usr/bin/env python3
# server.py
# OpenDicomViewer
#
# SAM 2 session adapter (PLUGIN_PROTOCOL.md section 1.2 and 3).
#
# Encoding a slice costs roughly two orders of magnitude more than decoding a
# mask from a click, which is the entire reason this plugin is a `session`
# rather than a `resident-server`: the host opens a session per slice and then
# re-prompts it interactively as the user clicks.
#
# The session lifecycle, prompt conversion, and RLE emission are shared with
# SAM 3 in `_shared.sam_session`; this file supplies only the backend -- which
# checkpoint to load, and how to run it.
# Licensed under the MIT License. See LICENSE for details.
"""Promptable segmentation of one slice, served over the session contract."""

from __future__ import annotations

import logging
import os
import sys
import threading
from pathlib import Path
from typing import Any, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _shared.protocol import ErrorCode, PluginError  # noqa: E402
from _shared.sam_session import SamSessionAdapter, select_device  # noqa: E402
from _shared.serve import parse_server_args, run_adapter  # noqa: E402
from _shared.weights import (  # noqa: E402
    download_huggingface,
    install_arg_present,
    parse_install_args,
    run_install,
)

PLUGIN_ID = "sam2"

# Apache-2.0, ~180 MB. Declared in plugins.json under the same repo id, and
# downloaded by the store into the plugin's weight directory at install time.
MODEL_REPO = "facebook/sam2.1-hiera-small"

# Matches `max_sessions` in plugins.json. Duplicated rather than read from the
# manifest because the adapter must bound its own memory even when launched
# standalone for testing; a mismatch would let the host's arbiter admit work
# against a number the adapter does not honour.
MAX_SESSIONS = 4

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(PLUGIN_ID)


def weights_dir() -> Path:
    """Where the store places this plugin's weights.

    Overridable so the adapter can be exercised against a checkout of the
    weights outside an installed plugin environment.
    """
    override = os.environ.get("ODV_SAM2_WEIGHTS")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "OpenDicomViewer" / \
        "plugins" / PLUGIN_ID / "weights"


class Sam2Backend:
    """Loads SAM 2.1 through transformers and runs encode/decode.

    transformers' SAM 2 implementation is used rather than Meta's `sam2`
    package because it loads from a plain checkpoint directory with no Hydra
    config resolution, which keeps the store's install step to a file download.
    """

    def __init__(self) -> None:
        self._model = None
        self._processor = None
        self._device = "cpu"
        self._load_error: str | None = None
        self._lock = threading.Lock()

    # -- availability ------------------------------------------------------

    def _checkpoint_present(self) -> bool:
        directory = weights_dir()
        return (directory / "config.json").is_file() and any(
            (directory / name).is_file()
            for name in ("model.safetensors", "pytorch_model.bin")
        )

    def availability(self) -> tuple[str, str | None]:
        if self._load_error is not None:
            return "error", self._load_error
        if self._model is not None:
            return "ready", f"{MODEL_REPO} on {self._device}"
        if not self._checkpoint_present():
            return "error", (
                f"Weights for {MODEL_REPO} are not present at {weights_dir()}. "
                "Install the plugin from the store."
            )
        # Weights are on disk but not loaded: loading is deferred to the first
        # session so that starting the plugin is instant and the memory is only
        # claimed when the user actually segments something.
        return "ready", f"{MODEL_REPO} (not yet loaded)"

    def ensure_loaded(self) -> None:
        if self._model is not None:
            return
        with self._lock:
            if self._model is not None:
                return
            if self._load_error is not None:
                raise PluginError(
                    ErrorCode.NOT_READY,
                    f"The model failed to load: {self._load_error}",
                    recoverable=False,
                )
            directory = weights_dir()
            if not self._checkpoint_present():
                raise PluginError(
                    ErrorCode.NOT_READY,
                    f"Weights for {MODEL_REPO} are not present at {directory}. "
                    "Install the plugin from the store.",
                )
            try:
                self._load(directory)
            except PluginError:
                raise
            except BaseException as exc:  # noqa: BLE001
                self._load_error = f"{type(exc).__name__}: {exc}"
                raise PluginError(
                    ErrorCode.NOT_READY,
                    f"Could not load {MODEL_REPO}: {self._load_error}",
                    recoverable=False,
                ) from None

    def _load(self, directory: Path) -> None:
        import torch
        from transformers import Sam2Processor, Sam2Model

        self._device = select_device()
        logger.info("Loading %s from %s on %s", MODEL_REPO, directory, self._device)
        # local_files_only keeps invariant 3 honest: at inference time this
        # adapter must not reach the network, whatever the cache state.
        self._processor = Sam2Processor.from_pretrained(str(directory),
                                                        local_files_only=True)
        model = Sam2Model.from_pretrained(str(directory), local_files_only=True,
                                          dtype=torch.float32)
        self._model = model.to(self._device).eval()

    # -- inference ---------------------------------------------------------

    def encode(self, image: Any) -> dict:
        """Run the image encoder once and cache what decoding needs."""
        import torch

        inputs = self._processor(images=image, return_tensors="pt").to(self._device)
        with torch.inference_mode():
            embeddings = self._model.get_image_embeddings(inputs["pixel_values"])
        return {
            "embeddings": embeddings,
            "size": image.size,               # (width, height)
            "original_sizes": inputs["original_sizes"],
        }

    def decode(self, state: dict, points: Sequence[tuple[int, int, int]],
               box: tuple[int, int, int, int] | None, text: str | None,
               multimask: bool) -> list[tuple[Any, float]]:
        import numpy as np
        import torch

        width, height = state["size"]

        # The processor expects prompts batched as [image][object][point].
        input_points = input_labels = input_boxes = None
        if points:
            input_points = [[[[int(x), int(y)] for x, y, _ in points]]]
            input_labels = [[[int(label) for _, _, label in points]]]
        if box is not None:
            x0, y0, x1, y1 = box
            if x1 <= x0 or y1 <= y0:
                raise PluginError(
                    ErrorCode.BAD_INPUT,
                    "the box prompt has zero width or height",
                    recoverable=False,
                )
            input_boxes = [[[float(x0), float(y0), float(x1), float(y1)]]]

        inputs = self._processor(
            input_points=input_points,
            input_labels=input_labels,
            input_boxes=input_boxes,
            original_sizes=state["original_sizes"],
            return_tensors="pt",
        ).to(self._device)

        with torch.inference_mode():
            outputs = self._model(
                image_embeddings=state["embeddings"],
                multimask_output=bool(multimask),
                **inputs,
            )

        masks = self._processor.post_process_masks(
            outputs.pred_masks, state["original_sizes"], binarize=False
        )[0]
        scores = outputs.iou_scores.reshape(-1)

        # With multimask the model proposes three candidates at different
        # scales. Protocol section 3 lets a task return them as a list ordered
        # best-first, so all of them are returned ranked by predicted IoU
        # rather than discarding the alternatives the user might have wanted.
        flat = masks.reshape(-1, masks.shape[-2], masks.shape[-1])
        order = torch.argsort(scores, descending=True).tolist() \
            if scores.numel() > 1 else [0]

        candidates: list[tuple[Any, float]] = []
        for index in order:
            mask = (flat[index] > 0).detach().to("cpu").numpy().astype(np.uint8)
            if mask.shape != (height, width):
                raise PluginError(
                    ErrorCode.INTERNAL,
                    f"decoded mask is {mask.shape[1]}x{mask.shape[0]}, "
                    f"expected {width}x{height}",
                    recoverable=False,
                )
            score = float(scores[index].item()) if scores.numel() else 0.0
            candidates.append((mask, score))
        return candidates


def build_adapter() -> SamSessionAdapter:
    return SamSessionAdapter(
        plugin_id=PLUGIN_ID,
        backend=Sam2Backend(),
        max_sessions=MAX_SESSIONS,
        # SAM 2 takes geometric prompts only; concept prompts are SAM 3.
        supports_text_prompt=False,
    )


# ---------------------------------------------------------------------------
# Weight acquisition (PLUGIN_PROTOCOL.md section 4b)
# ---------------------------------------------------------------------------

# The transformers loader needs the config and processor files alongside the
# weights, and pulling only these keeps the download to the ~180 MB the
# manifest declares rather than the repo's full history of formats.
WEIGHT_FILE_PATTERNS = ("config.json", "*preprocessor_config.json",
                        "processor_config.json", "model.safetensors")


def install_weights(args, dest: Path, reporter) -> list[Path]:
    """Fetch the SAM 2 checkpoint into the host-owned directory."""
    if args.source != "huggingface":
        raise PluginError(
            ErrorCode.BAD_INPUT,
            f"{PLUGIN_ID} only knows the 'huggingface' weight source, "
            f"got '{args.source}'",
            recoverable=False,
        )
    download_huggingface(args.repo or MODEL_REPO, dest, reporter,
                         allow_patterns=WEIGHT_FILE_PATTERNS)
    # Report what the adapter actually requires at load time, so that exit 0
    # means this plugin can start rather than merely that files arrived.
    return [dest / "config.json", dest / "model.safetensors"]


def main(argv: list[str] | None = None) -> int:
    if install_arg_present(argv):
        return run_install(
            parse_install_args("SAM 2 weight installer.", argv), install_weights
        )
    args = parse_server_args("SAM 2 session adapter for OpenDicomViewer.", argv)
    run_adapter(build_adapter(), args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
