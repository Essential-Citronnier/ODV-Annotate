# sam_session.py
# OpenDicomViewer
#
# The session adapter shared by SAM 2 and SAM 3.
#
# Both are promptable segmenters with the same shape: encode a slice once,
# decode a mask per click or box. Everything except which checkpoint is loaded
# and how it is obtained is identical, so the session lifecycle, prompt
# conversion, mask selection, and RLE emission live here and each adapter
# supplies only a backend. Duplicating this would let the two drift on the mask
# geometry, which is the part with no runtime signal when it goes wrong.
#
# torch is imported lazily inside the backend so that `--help`, /capabilities,
# and the license-gate error path all work in an environment where torch is
# absent or the weights were never downloaded.
# Licensed under the MIT License. See LICENSE for details.
"""Shared encode-once, prompt-many session adapter for the SAM family."""

from __future__ import annotations

import io
import threading
import time
from typing import Any, Protocol, Sequence

from .protocol import ErrorCode, PluginError, TaskRequest, TaskSpec
from .rle import mask2d_payload
from .sessions import Session, SessionStore

__all__ = ["SamBackend", "SamSessionAdapter", "select_device", "decode_png"]


def select_device() -> str:
    """Pick the best available torch device.

    MPS first on Apple Silicon, then CUDA, then CPU. The manifest marks these
    plugins as not requiring Apple Silicon, so the CPU path is a supported
    configuration and not merely a fallback -- it is slow but correct.
    """
    try:
        import torch
    except ImportError:
        return "cpu"

    if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def decode_png(data: bytes):
    """Decode PNG bytes into an RGB PIL image."""
    from PIL import Image, UnidentifiedImageError

    try:
        return Image.open(io.BytesIO(data)).convert("RGB")
    except (UnidentifiedImageError, OSError) as exc:
        raise PluginError(
            ErrorCode.BAD_INPUT, f"slice2d is not a readable image: {exc}",
            recoverable=False,
        ) from None


class SamBackend(Protocol):
    """What an adapter must supply for `SamSessionAdapter` to serve it.

    A backend owns the checkpoint and the model call. It knows nothing about
    HTTP, sessions, or the wire format.
    """

    def availability(self) -> tuple[str, str | None]:
        """Return ``(status, detail)`` for /health without loading the model.

        `status` is one of loading, ready, error. A backend whose weights are
        absent reports the reason here, so the host can distinguish a plugin
        that is warming up from one that will never become ready.
        """

    def ensure_loaded(self) -> None:
        """Load the model, or raise `PluginError` explaining why it cannot.

        A missing licence must raise `license_required` and missing weights
        `not_ready`; the host routes those to different places in the UI.
        """

    def encode(self, image: Any) -> Any:
        """Encode one image and return whatever state `decode` needs."""

    def decode(self, state: Any, points: Sequence[Any], box: Any,
               text: str | None, multimask: bool) -> Sequence[tuple[Any, float]]:
        """Decode masks from prompts, returning ``[(mask_2d, score), ...]``.

        Ordered best-first, and never empty. With `multimask` false a backend
        returns exactly one candidate; with it true it may return several,
        which protocol section 3 permits the adapter to emit as a list.
        """


class SamSessionAdapter:
    """Serves a `SamBackend` over the session contract of protocol section 3."""

    def __init__(
        self,
        plugin_id: str,
        backend: SamBackend,
        max_sessions: int,
        supports_text_prompt: bool = False,
    ) -> None:
        self.plugin_id = plugin_id
        self.backend = backend
        self.supports_text_prompt = supports_text_prompt
        self.sessions = SessionStore(max_sessions=max_sessions)
        # Inference is serialized: neither backend is safe to call concurrently
        # from the HTTP threadpool, and a session's cached state is mutated by
        # some implementations during decode.
        self._inference_lock = threading.Lock()

    # -- capabilities and health ------------------------------------------

    def tasks(self) -> list[TaskSpec]:
        inputs = ["slice2d", "points", "box"]
        if self.supports_text_prompt:
            inputs.append("text")
        return [
            TaskSpec(
                id="prompt-mask",
                label="Prompt Segmentation",
                inputs=inputs,
                outputs=["mask2d"],
                options={"multimask": {"type": "bool", "default": False,
                                       "label": "Return best of three candidate masks"}},
            )
        ]

    def health(self) -> tuple[str, str | None, float | None]:
        status, detail = self.backend.availability()
        return status, detail, self._memory_mb()

    def _memory_mb(self) -> float | None:
        try:
            import torch

            if torch.backends.mps.is_available():
                return torch.mps.current_allocated_memory() / (1024 * 1024)
        except Exception:  # noqa: BLE001 - a metrics read must never fail a request
            return None
        return None

    # -- sessions ----------------------------------------------------------

    def open_session(self, request: TaskRequest) -> tuple[str, float]:
        """Encode the slice and cache the embedding."""
        self.backend.ensure_loaded()
        image = decode_png(request.slice2d_bytes())

        started = time.perf_counter()
        with self._inference_lock:
            state = self.backend.encode(image)
        encode_ms = (time.perf_counter() - started) * 1000.0

        width, height = image.size
        session = self.sessions.open(state, width, height)
        return session.id, encode_ms

    def close_session(self, session_id: str) -> bool:
        return self.sessions.close(session_id)

    # -- tasks -------------------------------------------------------------

    def run_task(self, task_id: str, request: TaskRequest) -> dict:
        if task_id != "prompt-mask":
            raise PluginError(
                ErrorCode.BAD_INPUT, f"unknown task '{task_id}'", recoverable=False
            )
        return self.prompt_mask(request)

    def prompt_mask(self, request: TaskRequest) -> dict:
        self.backend.ensure_loaded()
        session: Session = self.sessions.get(request.session_id)

        points = request.points()
        box = request.rect("box")
        text = request.text() if self.supports_text_prompt else ""

        if not points and box is None and not text:
            raise PluginError(
                ErrorCode.BAD_INPUT,
                "prompt-mask needs at least one prompt: points, a box"
                + (", or text." if self.supports_text_prompt else "."),
                recoverable=False,
            )

        # Prompts arrive normalized 0-1 and are converted against the encoded
        # image's own size, not the slice the host happens to be displaying:
        # the two differ whenever the panel is zoomed.
        pixel_points = [
            (*point.to_pixels(session.width, session.height),
             1 if point.is_foreground else 0)
            for point in points
        ]
        pixel_box = box.to_pixels(session.width, session.height) if box else None
        multimask = request.option_bool("multimask", default=False)

        with self._inference_lock:
            candidates = self.backend.decode(
                session.state, pixel_points, pixel_box, text or None, multimask
            )

        if not candidates:
            raise PluginError(
                ErrorCode.INTERNAL, "the model returned no mask", recoverable=False
            )

        payloads = []
        for mask, score in candidates:
            payload = mask2d_payload(mask, label=text or None, confidence=score)
            if payload["width"] != session.width or payload["height"] != session.height:
                # A mask on a different grid than the slice would be silently
                # misregistered by the host, which trusts the declared dimensions.
                raise PluginError(
                    ErrorCode.INTERNAL,
                    f"mask is {payload['width']}x{payload['height']} but the session "
                    f"image is {session.width}x{session.height}",
                    recoverable=False,
                )
            payloads.append(payload)

        # Section 3 allows either shape. A single mask is emitted as a bare
        # object rather than a one-element list so the common case stays the
        # simple one on the wire and for any client reading it by hand;
        # candidates are emitted as a list, ordered best-first.
        return {"mask2d": payloads[0] if len(payloads) == 1 else payloads}
