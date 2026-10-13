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
# Two checkpoint forms are accepted in the weight directory:
#
# - the single file the store asks for, `sam3.pt` (Meta's release format). It is
#   converted once, on first load, into `hf-converted/` beside it
#   (checkpoint_convert.py), because transformers loads only the Hugging Face
#   layout and Meta's own `sam3` package cannot run on a Mac (it imports triton
#   and hardcodes CUDA);
# - the Hugging Face folder form (`config.json` + `model.safetensors`, what a
#   snapshot download of facebook/sam3 produces), loaded as is.
#
# Point and box prompts run through `Sam3TrackerModel`, the SAM-2-style
# interactive half of SAM 3. Text concept prompts need `Sam3Model` and the CLIP
# tokenizer, which only the folder form ships.
#
# VERIFICATION STATUS. Not executed against the real weights: obtaining them
# requires accepting Meta's terms under a named Hugging Face account, which is
# exactly the human step this gate exists to preserve. Verified without them:
# the checkpoint-absent path (health, the `license_required` envelope, its
# message); form detection; and, in an opt-in test, that a checkpoint with the
# names and shapes of Meta's model converts, loads into `Sam3TrackerModel` with
# no missing tensors, and decodes a point prompt to a mask of the image's size.
# The text-prompt path is UNVERIFIED.
# Licensed under the MIT License. See LICENSE for details.
"""Promptable segmentation with concept prompts, behind a manual license gate."""

from __future__ import annotations

import logging
import sys
import threading
from pathlib import Path
from typing import Any, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _shared.protocol import ErrorCode, PluginError  # noqa: E402
from _shared.bench import bench_arg_present, run_sam_bench  # noqa: E402
from _shared.cli import parse_server_args  # noqa: E402
from _shared.sam_session import SamSessionAdapter, select_device  # noqa: E402
from _shared.weights import (  # noqa: E402
    install_arg_present,
    installed_weight_dir,
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

# The manual weight's id in plugins.json. The store tells the user to place the
# checkpoint at <weights root>/<this id>/sam3.pt (`manualWeightPath`), so that
# is where the adapter looks.
WEIGHT_ID = "sam3-checkpoint"

# Matches `max_sessions` in plugins.json. SAM 3 is the larger model, so it
# caches fewer sessions than SAM 2 within a comparable memory budget.
MAX_SESSIONS = 2

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(PLUGIN_ID)


# Where a single-file checkpoint is converted to the Hugging Face layout.
CONVERTED_DIRNAME = "hf-converted"


def checkpoint_form(directory: Path) -> str | None:
    """"folder" for the Hugging Face layout, "file" for a single sam3.pt, or None.

    The folder form wins when both are present: it needs no conversion and
    carries the tokenizer text prompts use.
    """
    if (directory / "config.json").is_file() and any(
            (directory / name).is_file()
            for name in ("model.safetensors", "pytorch_model.bin")):
        return "folder"
    if (directory / CHECKPOINT_FILENAME).is_file():
        return "file"
    return None


def _has_tokenizer(directory: Path | None) -> bool:
    return directory is not None and any(
        (directory / name).is_file()
        for name in ("tokenizer.json", "vocab.json", "tokenizer_config.json"))


def tracker_processor(model_dir: Path):
    """The point/box processor for a model directory.

    A folder download ships its processor configuration; a converted single
    file does not, and gets the defaults the upstream conversion uses
    (`Sam3ImageProcessor()`), which are facebook/sam3's.
    """
    from transformers import Sam3TrackerProcessor

    if (model_dir / "processor_config.json").is_file() or \
            (model_dir / "preprocessor_config.json").is_file():
        return Sam3TrackerProcessor.from_pretrained(str(model_dir), local_files_only=True)
    from transformers.models.sam3.image_processing_sam3 import Sam3ImageProcessor

    return Sam3TrackerProcessor(image_processor=Sam3ImageProcessor())


def weights_dir() -> Path:
    """The documented location for the manually placed checkpoint.

    This path is shown verbatim in the store's license gate, so it must be
    stable and must not depend on how the adapter was launched: it is the
    directory of the store's `manualWeightPath`, reported by the host through
    ODV_WEIGHTS_DIR. `ODV_SAM3_WEIGHTS` overrides it for standalone testing.
    """
    return installed_weight_dir(PLUGIN_ID, WEIGHT_ID, override_env="ODV_SAM3_WEIGHTS")


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
        self._form: str | None = None
        self._model_dir: Path | None = None
        self._text = None

    # -- the license gate --------------------------------------------------

    def checkpoint_path(self) -> Path:
        return weights_dir() / CHECKPOINT_FILENAME

    def _checkpoint_present(self) -> bool:
        """Whether the user has satisfied the gate.

        Presence of the declared file (or of the folder form) is the whole
        check. Validating contents would mean loading a multi-gigabyte
        checkpoint on every health poll, and the failure it would catch -- a
        truncated download -- surfaces clearly enough at first use.
        """
        return checkpoint_form(weights_dir()) is not None

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
        """Load SAM 3's interactive (tracker) model from either checkpoint form.

        A single `sam3.pt` is converted once into `hf-converted/` first; see
        checkpoint_convert.py and the verification status in the file header.
        """
        import torch
        from transformers import Sam3TrackerModel

        self._device = select_device()
        directory = weights_dir()
        form = checkpoint_form(directory)
        if form == "file":
            # Beside this file; the host runs the adapter from its own
            # directory, but a test or a bench may import it from elsewhere.
            adapter_dir = str(Path(__file__).resolve().parent)
            if adapter_dir not in sys.path:
                sys.path.insert(0, adapter_dir)
            from checkpoint_convert import convert_checkpoint

            model_dir = convert_checkpoint(self.checkpoint_path(),
                                           directory / CONVERTED_DIRNAME, log=logger.info)
        elif form == "folder":
            model_dir = directory
        else:
            raise PluginError(ErrorCode.LICENSE_REQUIRED, license_message(), recoverable=True)
        self._form = form
        self._model_dir = model_dir
        logger.info("Loading %s from %s (%s form) on %s", MODEL_REPO, model_dir, form,
                    self._device)
        self._processor = tracker_processor(model_dir)
        model = Sam3TrackerModel.from_pretrained(str(model_dir), local_files_only=True,
                                                 dtype=torch.float32)
        self._model = model.to(self._device).eval()

    def _text_model(self):
        """Sam3Model and its processor, for text concept prompts. Loaded on the
        first text prompt only: most sessions never send one, and it is a
        second copy of the vision encoder. UNVERIFIED (see the file header)."""
        if self._text is not None:
            return self._text
        if self._form != "folder" or not _has_tokenizer(self._model_dir):
            raise PluginError(
                ErrorCode.BAD_INPUT,
                "Text prompts need the SAM 3 tokenizer, which the single sam3.pt "
                "file does not include. Use point or box prompts, or place the full "
                f"Hugging Face download of {MODEL_REPO} (config.json, "
                "model.safetensors and the tokenizer files) in "
                f"{weights_dir()} instead.",
                recoverable=False,
            )
        import torch
        from transformers import Sam3Model, Sam3Processor

        processor = Sam3Processor.from_pretrained(str(self._model_dir), local_files_only=True)
        model = Sam3Model.from_pretrained(str(self._model_dir), local_files_only=True,
                                          dtype=torch.float32)
        self._text = (model.to(self._device).eval(), processor)
        return self._text

    def encode(self, image: Any) -> dict:
        """Encode one image once per session; prompts decode against it."""
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
        """Decode masks from geometric prompts, or from a text concept prompt.

        Geometric prompts decode against the session's cached embedding.
        A text prompt asks a different question -- every instance of the
        concept -- and runs the concept model on the image instead.
        """
        import numpy as np
        import torch

        width, height = state["size"]
        if box is not None:
            x0, y0, x1, y1 = box
            if x1 <= x0 or y1 <= y0:
                raise PluginError(
                    ErrorCode.BAD_INPUT, "the box prompt has zero width or height",
                    recoverable=False,
                )
        if text:
            return self._decode_text(state, text, box, width, height)

        input_points = input_labels = input_boxes = None
        if points:
            input_points = [[[[int(x), int(y)] for x, y, _ in points]]]
            input_labels = [[[int(label) for _, _, label in points]]]
        if box is not None:
            input_boxes = [[[float(v) for v in box]]]
        prompt = self._processor(
            images=state["image"], input_points=input_points, input_labels=input_labels,
            input_boxes=input_boxes, return_tensors="pt",
        )
        prompt_inputs = {key: value.to(self._device) for key, value in prompt.items()
                         if key in ("input_points", "input_labels", "input_boxes")}
        with torch.inference_mode():
            outputs = self._model(
                image_embeddings=state["embeddings"],
                multimask_output=bool(multimask),
                **prompt_inputs,
            )

        masks = self._processor.post_process_masks(
            outputs.pred_masks.cpu(), state["original_sizes"].cpu(), binarize=False
        )[0]
        scores = outputs.iou_scores.reshape(-1).cpu()

        # Candidates ranked by predicted IoU; section 3 permits returning them
        # as a best-first list rather than discarding the alternatives.
        flat = masks.reshape(-1, masks.shape[-2], masks.shape[-1])
        order = torch.argsort(scores, descending=True).tolist() \
            if scores.numel() > 1 else [0]
        return [(_check_mask((flat[index] > 0).numpy().astype(np.uint8), width, height),
                 float(scores[index].item()) if scores.numel() else 0.0)
                for index in order]

    def _decode_text(self, state: dict, text: str, box, width: int,
                     height: int) -> list[tuple[Any, float]]:
        """UNVERIFIED. Every instance of a text concept, best first."""
        import numpy as np
        import torch

        model, processor = self._text_model()
        kwargs: dict[str, Any] = {"images": state["image"], "text": text, "return_tensors": "pt"}
        if box is not None:
            kwargs["input_boxes"] = [[[float(v) for v in box]]]
            kwargs["input_boxes_labels"] = [[1]]
        inputs = processor(**kwargs).to(self._device)
        with torch.inference_mode():
            outputs = model(**inputs)
        result = processor.post_process_instance_segmentation(
            outputs, threshold=0.5, mask_threshold=0.5,
            target_sizes=[(height, width)],
        )[0]
        scores = result["scores"].reshape(-1).cpu()
        masks = result["masks"].cpu()
        order = torch.argsort(scores, descending=True).tolist()
        return [(_check_mask(masks[index].numpy().astype(np.uint8), width, height),
                 float(scores[index].item())) for index in order]


def _check_mask(mask: Any, width: int, height: int) -> Any:
    if mask.shape != (height, width):
        raise PluginError(
            ErrorCode.INTERNAL,
            f"decoded mask is {mask.shape[1]}x{mask.shape[0]}, expected {width}x{height}",
            recoverable=False,
        )
    return mask


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
    if bench_arg_present(argv):
        # Dispatched before the server parser, like --install-weights. On a
        # machine without the gated checkpoint this reports the
        # `license_required` envelope rather than a timing, which is the
        # correct measurement of a gated plugin.
        return run_sam_bench(PLUGIN_ID, build_adapter, argv)
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
