#!/usr/bin/env python3
# server.py
# OpenDicomViewer
#
# SAM 3 session adapter -- the gated-download path (PLUGIN_PROTOCOL.md 1.2, 6).
#
# The session interface is identical to SAM 2's and is shared through
# `_shared.sam_session`; what differs is entirely how the weights are obtained.
# SAM 3 is distributed under Meta's SAM License, which requires accepting terms
# on Hugging Face and authenticating, so the manifest declares gate
# `gated-download` with weight source `manual` and this adapter never downloads
# anything. It checks for a checkpoint at a documented path and, when it is
# absent, returns `license_required` naming the terms URL and that path -- the
# one error code the host routes to the store's license gate rather than to a
# generic failure banner.
#
# UNVERIFIED: the inference path below has not been executed against real SAM 3
# weights, because obtaining them requires accepting Meta's terms under a named
# Hugging Face account, which is exactly the human step this gate exists to
# preserve. The checkpoint-absent path -- health reporting, the
# `license_required` envelope, and its message -- is tested and is what the
# store shows until a user satisfies the gate. Anything below `_load` should be
# treated as a first implementation to be validated against the checkpoint, not
# as a verified path.
# Licensed under the MIT License. See LICENSE for details.
"""Promptable segmentation with concept prompts, behind a manual license gate."""

from __future__ import annotations

import logging
import os
import sys
import threading
from pathlib import Path
from typing import Any, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _shared.protocol import ErrorCode, PluginError  # noqa: E402
from _shared.cli import parse_server_args  # noqa: E402
from _shared.sam_session import SamSessionAdapter, select_device  # noqa: E402
from _shared.weights import (  # noqa: E402
    install_arg_present,
    parse_install_args,
    run_install,
    verify_manual_checkpoint,
)

PLUGIN_ID = "sam3"

MODEL_REPO = "facebook/sam3"
TERMS_URL = "https://huggingface.co/facebook/sam3"

# Filename as plugins.json declares it for the manual weight source. The store
# shows the user this exact name and the directory below.
CHECKPOINT_FILENAME = "sam3.pt"

# Matches `max_sessions` in plugins.json. SAM 3 is the larger model, so it
# caches fewer sessions than SAM 2 within a comparable memory budget.
MAX_SESSIONS = 2

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(PLUGIN_ID)


def weights_dir() -> Path:
    """The documented location for the manually placed checkpoint.

    This path is shown verbatim in the store's license gate, so it must be
    stable and must not depend on how the adapter was launched.
    """
    override = os.environ.get("ODV_SAM3_WEIGHTS")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "OpenDicomViewer" / \
        "plugins" / PLUGIN_ID / "weights"


def license_message() -> str:
    """The text the store's license gate shows when the checkpoint is absent."""
    return (
        f"SAM 3 weights are distributed under Meta's SAM License and cannot be "
        f"downloaded automatically. Accept the model terms at {TERMS_URL}, then "
        f"place the checkpoint at {weights_dir() / CHECKPOINT_FILENAME}. "
        f"OpenDicomViewer verifies only that the file is present; it never "
        f"transmits your Hugging Face credentials."
    )


class Sam3Backend:
    """Gate check plus, once satisfied, the same encode/decode shape as SAM 2."""

    def __init__(self) -> None:
        self._model = None
        self._processor = None
        self._device = "cpu"
        self._load_error: str | None = None
        self._lock = threading.Lock()

    # -- the license gate --------------------------------------------------

    def checkpoint_path(self) -> Path:
        return weights_dir() / CHECKPOINT_FILENAME

    def _checkpoint_present(self) -> bool:
        """Whether the user has satisfied the gate.

        Presence of the declared file is the whole check. Validating its
        contents would mean loading a multi-gigabyte checkpoint on every health
        poll, and the failure it would catch -- a truncated download -- surfaces
        clearly enough at first use.
        """
        path = self.checkpoint_path()
        if path.is_file():
            return True
        # A directory-format checkpoint is accepted too: Hugging Face's own
        # snapshot download produces one, and requiring the user to repackage
        # it would be a pointless obstacle.
        directory = weights_dir()
        return (directory / "config.json").is_file() and any(
            (directory / name).is_file()
            for name in ("model.safetensors", "pytorch_model.bin")
        )

    def availability(self) -> tuple[str, str | None]:
        if self._load_error is not None:
            return "error", self._load_error
        if not self._checkpoint_present():
            # Reported as `error` with the gate message rather than `loading`:
            # this state never resolves on its own, and the host must not sit
            # polling for a checkpoint only the user can supply.
            return "error", license_message()
        if self._model is not None:
            return "ready", f"{MODEL_REPO} on {self._device}"
        return "ready", f"{MODEL_REPO} (not yet loaded)"

    def ensure_loaded(self) -> None:
        if self._model is not None:
            return
        with self._lock:
            if self._model is not None:
                return
            if not self._checkpoint_present():
                # The distinction the protocol draws in section 6: missing
                # weights are `not_ready`, a missing license is
                # `license_required`. SAM 3's weights are missing *because* the
                # license gate is unsatisfied, so this is the latter.
                raise PluginError(
                    ErrorCode.LICENSE_REQUIRED, license_message(), recoverable=True
                )
            if self._load_error is not None:
                raise PluginError(
                    ErrorCode.NOT_READY,
                    f"The model failed to load: {self._load_error}",
                    recoverable=False,
                )
            try:
                self._load()
            except PluginError:
                raise
            except BaseException as exc:  # noqa: BLE001
                self._load_error = f"{type(exc).__name__}: {exc}"
                raise PluginError(
                    ErrorCode.NOT_READY,
                    f"Could not load {MODEL_REPO}: {self._load_error}",
                    recoverable=False,
                ) from None

    # -- inference (UNVERIFIED; see the file header) -----------------------

    def _load(self) -> None:
        """Load SAM 3 from the manually placed checkpoint.

        UNVERIFIED against real weights. The transformers class names below
        follow SAM 2's pattern and must be confirmed once a checkpoint is
        available; a mismatch surfaces as a `not_ready` load error naming the
        missing symbol, which is a legible failure rather than a silent one.
        """
        import torch
        from transformers import Sam3Model, Sam3Processor

        self._device = select_device()
        directory = weights_dir()
        logger.info("Loading %s from %s on %s", MODEL_REPO, directory, self._device)
        self._processor = Sam3Processor.from_pretrained(str(directory),
                                                        local_files_only=True)
        model = Sam3Model.from_pretrained(str(directory), local_files_only=True,
                                          dtype=torch.float32)
        self._model = model.to(self._device).eval()

    def encode(self, image: Any) -> dict:
        """UNVERIFIED. Encode one image; see the file header."""
        import torch

        inputs = self._processor(images=image, return_tensors="pt").to(self._device)
        with torch.inference_mode():
            embeddings = self._model.get_image_embeddings(inputs["pixel_values"])
        return {
            "embeddings": embeddings,
            "size": image.size,
            "original_sizes": inputs["original_sizes"],
            "image": image,
        }

    def decode(self, state: dict, points: Sequence[tuple[int, int, int]],
               box: tuple[int, int, int, int] | None, text: str | None,
               multimask: bool) -> list[tuple[Any, float]]:
        """UNVERIFIED. Decode masks from geometric or concept prompts.

        SAM 3 adds text-concept prompting, which the manifest declares as a
        `text` input for this task. A concept prompt goes through the processor
        alongside any geometric prompts rather than replacing them.
        """
        import numpy as np
        import torch

        width, height = state["size"]

        input_points = input_labels = input_boxes = None
        if points:
            input_points = [[[[int(x), int(y)] for x, y, _ in points]]]
            input_labels = [[[int(label) for _, _, label in points]]]
        if box is not None:
            x0, y0, x1, y1 = box
            if x1 <= x0 or y1 <= y0:
                raise PluginError(
                    ErrorCode.BAD_INPUT, "the box prompt has zero width or height",
                    recoverable=False,
                )
            input_boxes = [[[float(x0), float(y0), float(x1), float(y1)]]]

        processor_kwargs: dict[str, Any] = {
            "input_points": input_points,
            "input_labels": input_labels,
            "input_boxes": input_boxes,
            "original_sizes": state["original_sizes"],
            "return_tensors": "pt",
        }
        if text:
            processor_kwargs["text"] = text
            processor_kwargs["images"] = state["image"]

        inputs = self._processor(**processor_kwargs).to(self._device)
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

        # Candidates ranked by predicted IoU; section 3 permits returning them
        # as a best-first list rather than discarding the alternatives.
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
        backend=Sam3Backend(),
        max_sessions=MAX_SESSIONS,
        supports_text_prompt=True,
    )


# ---------------------------------------------------------------------------
# Weight acquisition (PLUGIN_PROTOCOL.md section 4b)
# ---------------------------------------------------------------------------


def install_weights(args, dest: Path, reporter) -> list[Path]:
    """Verify the manually placed checkpoint. Never downloads.

    Section 4b requires a `manual` source to attempt no download at all. That
    is the substance of the gate rather than an implementation detail: the
    weights are released under Meta's SAM License on the condition that a human
    accepted its terms under a named account, and an adapter that fetched them
    anyway would be routing around the one check the store exists to enforce.
    """
    if args.source != "manual":
        raise PluginError(
            ErrorCode.BAD_INPUT,
            f"{PLUGIN_ID} weights are gated and only support the 'manual' "
            f"source, got '{args.source}'",
            recoverable=False,
        )

    reporter.stage(0.0, 1.0, "Checking for the SAM 3 checkpoint")
    return verify_manual_checkpoint(
        dest=dest,
        filename=CHECKPOINT_FILENAME,
        terms_url=TERMS_URL,
        message=("SAM 3 weights are distributed under Meta's SAM License and "
                 "cannot be downloaded automatically."),
    )


def main(argv: list[str] | None = None) -> int:
    if install_arg_present(argv):
        return run_install(
            parse_install_args("SAM 3 weight verifier.", argv), install_weights
        )
    args = parse_server_args("SAM 3 session adapter for OpenDicomViewer.", argv)

    # Imported here rather than at module scope: `serve` pulls in fastapi and
    # uvicorn. For this plugin the point is sharper than convenience -- the
    # gated-weight check above needs nothing but the standard library, and
    # requiring a web stack to be installed before the store can tell the user
    # where to put a checkpoint would be backwards.
    from _shared.serve import run_adapter

    run_adapter(build_adapter(), args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
