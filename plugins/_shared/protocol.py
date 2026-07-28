# protocol.py
# OpenDicomViewer
#
# Response shapes and the task request envelope of ODV Plugin Protocol v1.
#
# Keeping these in one module means the four adapters cannot disagree about
# what an error looks like: the host routes `license_required` to the store's
# gate UI and everything else to a failure banner, so a typo in an error code
# degrades a recoverable, actionable state into a dead end.
# Licensed under the MIT License. See LICENSE for details.
"""Protocol v1 envelopes: health, capabilities, task request, task response."""

from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Mapping, Sequence

PROTOCOL_VERSION = 1

__all__ = [
    "PROTOCOL_VERSION",
    "ErrorCode",
    "PluginError",
    "Point",
    "Rect",
    "TaskRequest",
    "TaskSpec",
    "capabilities_payload",
    "error_payload",
    "health_payload",
    "success_payload",
]


class ErrorCode(str, Enum):
    """The five codes of PLUGIN_PROTOCOL.md section 3. No others are valid."""

    NOT_READY = "not_ready"
    BAD_INPUT = "bad_input"
    LICENSE_REQUIRED = "license_required"
    OUT_OF_MEMORY = "out_of_memory"
    INTERNAL = "internal"


class PluginError(Exception):
    """An error the adapter can describe to the user in protocol terms.

    `recoverable` tells the host whether retrying could plausibly succeed. A
    missing checkpoint is recoverable (install it and retry); a malformed
    request from the host is not.
    """

    def __init__(
        self,
        code: ErrorCode,
        message: str,
        recoverable: bool = True,
        http_status: int = 200,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.recoverable = recoverable
        # The protocol accepts either a non-200 or a 200 carrying ok:false.
        # Defaulting to 200 keeps the error body readable by clients that treat
        # a non-200 as a transport failure and discard the payload.
        self.http_status = http_status

    def to_payload(self) -> dict:
        return error_payload(self.code, self.message, self.recoverable)


# ---------------------------------------------------------------------------
# Response shapes
# ---------------------------------------------------------------------------


def health_payload(
    plugin_id: str,
    status: str,
    detail: str | None = None,
    memory_mb: float | None = None,
) -> dict:
    """`GET /health` body. `status` is one of loading, ready, error."""
    if status not in ("loading", "ready", "error"):
        raise ValueError(f"invalid health status: {status}")
    payload: dict = {
        "status": status,
        "plugin_id": plugin_id,
        "protocol": PROTOCOL_VERSION,
    }
    if detail is not None:
        payload["detail"] = detail
    if memory_mb is not None:
        payload["memory_mb"] = round(float(memory_mb), 1)
    return payload


@dataclass(frozen=True)
class TaskSpec:
    """One entry of `GET /capabilities`.

    This is the runtime truth the host routes on. It is declared in adapter
    code rather than read back from plugins.json so that an adapter which
    cannot actually serve a declared task -- a missing optional dependency,
    say -- can omit it here and have the host notice.
    """

    id: str
    label: str
    inputs: Sequence[str]
    outputs: Sequence[str]
    options: Mapping[str, Any] = field(default_factory=dict)

    def to_payload(self) -> dict:
        payload: dict = {
            "id": self.id,
            "label": self.label,
            "inputs": list(self.inputs),
            "outputs": list(self.outputs),
        }
        if self.options:
            payload["options"] = dict(self.options)
        return payload


def capabilities_payload(plugin_id: str, tasks: Sequence[TaskSpec]) -> dict:
    """`GET /capabilities` body."""
    return {
        "plugin_id": plugin_id,
        "protocol": PROTOCOL_VERSION,
        "tasks": [task.to_payload() for task in tasks],
    }


def success_payload(outputs: Mapping[str, Any], elapsed_ms: float | int) -> dict:
    """`POST /task/<id>` success body."""
    return {"ok": True, "outputs": dict(outputs), "elapsed_ms": int(round(elapsed_ms))}


def error_payload(
    code: ErrorCode | str,
    message: str,
    recoverable: bool = True,
) -> dict:
    """Error body shared by the HTTP and one-shot contracts."""
    value = code.value if isinstance(code, ErrorCode) else str(code)
    return {
        "ok": False,
        "error": {"code": value, "message": message, "recoverable": bool(recoverable)},
    }


# ---------------------------------------------------------------------------
# Request envelope
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Rect:
    """Normalized rectangle, 0-1, as used by `roi` and `box` inputs."""

    x: float
    y: float
    width: float
    height: float

    def to_pixels(self, image_width: int, image_height: int) -> tuple[int, int, int, int]:
        """Convert to integer ``(x0, y0, x1, y1)`` clamped to the image."""
        x0 = max(0, min(image_width, round(self.x * image_width)))
        y0 = max(0, min(image_height, round(self.y * image_height)))
        x1 = max(x0, min(image_width, round((self.x + self.width) * image_width)))
        y1 = max(y0, min(image_height, round((self.y + self.height) * image_height)))
        return x0, y0, x1, y1


@dataclass(frozen=True)
class Point:
    """Normalized click prompt. `is_foreground` mirrors the wire `label` int."""

    x: float
    y: float
    is_foreground: bool

    def to_pixels(self, image_width: int, image_height: int) -> tuple[int, int]:
        px = max(0, min(image_width - 1, int(round(self.x * image_width))))
        py = max(0, min(image_height - 1, int(round(self.y * image_height))))
        return px, py


def _as_float(value: Any, field_name: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        raise PluginError(
            ErrorCode.BAD_INPUT, f"{field_name} must be a number, got {value!r}",
            recoverable=False,
        ) from None


class TaskRequest:
    """Parsed `POST /task/<id>` body with validating accessors.

    Accessors raise `PluginError(bad_input)` rather than returning None for a
    malformed value, so an adapter's task handler reads as a straight line and
    every rejection reaches the user with the field named.
    """

    def __init__(self, body: Mapping[str, Any] | None) -> None:
        body = body or {}
        if not isinstance(body, Mapping):
            raise PluginError(
                ErrorCode.BAD_INPUT, "request body must be a JSON object",
                recoverable=False,
            )
        self.session_id: str | None = body.get("session_id")
        inputs = body.get("inputs") or {}
        options = body.get("options") or {}
        if not isinstance(inputs, Mapping):
            raise PluginError(
                ErrorCode.BAD_INPUT, "`inputs` must be a JSON object", recoverable=False
            )
        if not isinstance(options, Mapping):
            raise PluginError(
                ErrorCode.BAD_INPUT, "`options` must be a JSON object", recoverable=False
            )
        self.inputs: Mapping[str, Any] = inputs
        self.options: Mapping[str, Any] = options

    # -- inputs ------------------------------------------------------------

    def has(self, kind: str) -> bool:
        return self.inputs.get(kind) is not None

    def slice2d_bytes(self, required: bool = True) -> bytes | None:
        """Decode the base64 PNG carried by a `slice2d` input."""
        raw = self.inputs.get("slice2d")
        if raw is None:
            if required:
                raise PluginError(
                    ErrorCode.BAD_INPUT, "this task requires a `slice2d` input",
                    recoverable=False,
                )
            return None
        if not isinstance(raw, str):
            raise PluginError(
                ErrorCode.BAD_INPUT, "`slice2d` must be a base64 string",
                recoverable=False,
            )
        # A data URL prefix is tolerated: it costs one split and removes a
        # whole class of host-side encoding bug.
        if raw.startswith("data:"):
            _, _, raw = raw.partition(",")
        try:
            return base64.b64decode(raw, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise PluginError(
                ErrorCode.BAD_INPUT, f"`slice2d` is not valid base64: {exc}",
                recoverable=False,
            ) from None

    def series3d_path(self, required: bool = True) -> str | None:
        """Filesystem path to a DICOM series directory."""
        import os

        raw = self.inputs.get("series3d")
        if raw is None:
            if required:
                raise PluginError(
                    ErrorCode.BAD_INPUT, "this task requires a `series3d` input",
                    recoverable=False,
                )
            return None
        if not isinstance(raw, str) or not raw:
            raise PluginError(
                ErrorCode.BAD_INPUT, "`series3d` must be a non-empty path string",
                recoverable=False,
            )
        if not os.path.isdir(raw):
            raise PluginError(
                ErrorCode.BAD_INPUT, f"series directory not found: {raw}"
            )
        return raw

    def rect(self, kind: str, required: bool = False) -> Rect | None:
        """Parse a `roi` or `box` input."""
        raw = self.inputs.get(kind)
        if raw is None:
            if required:
                raise PluginError(
                    ErrorCode.BAD_INPUT, f"this task requires a `{kind}` input",
                    recoverable=False,
                )
            return None
        if not isinstance(raw, Mapping):
            raise PluginError(
                ErrorCode.BAD_INPUT, f"`{kind}` must be an object with x, y, width, height",
                recoverable=False,
            )
        return Rect(
            x=_as_float(raw.get("x", 0.0), f"{kind}.x"),
            y=_as_float(raw.get("y", 0.0), f"{kind}.y"),
            width=_as_float(raw.get("width", 0.0), f"{kind}.width"),
            height=_as_float(raw.get("height", 0.0), f"{kind}.height"),
        )

    def points(self, required: bool = False) -> list[Point]:
        """Parse the `points` input. `label` is 1 foreground, 0 background."""
        raw = self.inputs.get("points")
        if raw is None:
            if required:
                raise PluginError(
                    ErrorCode.BAD_INPUT, "this task requires a `points` input",
                    recoverable=False,
                )
            return []
        if not isinstance(raw, Sequence) or isinstance(raw, (str, bytes)):
            raise PluginError(
                ErrorCode.BAD_INPUT, "`points` must be a list", recoverable=False
            )
        parsed: list[Point] = []
        for i, item in enumerate(raw):
            if not isinstance(item, Mapping):
                raise PluginError(
                    ErrorCode.BAD_INPUT, f"points[{i}] must be an object",
                    recoverable=False,
                )
            parsed.append(
                Point(
                    x=_as_float(item.get("x"), f"points[{i}].x"),
                    y=_as_float(item.get("y"), f"points[{i}].y"),
                    is_foreground=bool(item.get("label", 1)),
                )
            )
        return parsed

    def text(self, default: str = "") -> str:
        raw = self.inputs.get("text")
        if raw is None:
            return default
        if not isinstance(raw, str):
            raise PluginError(
                ErrorCode.BAD_INPUT, "`text` must be a string", recoverable=False
            )
        return raw

    # -- options -----------------------------------------------------------

    def option_enum(self, name: str, values: Sequence[str], default: str) -> str:
        """Read an enum option, falling back to the default on any unknown value.

        Deliberately lenient: the manifest and the adapter can drift by a
        release, and refusing a whole request over an unrecognized mode string
        is a worse outcome than running the default mode.
        """
        raw = self.options.get(name)
        return raw if isinstance(raw, str) and raw in values else default

    def option_bool(self, name: str, default: bool) -> bool:
        raw = self.options.get(name)
        if raw is None:
            return default
        if isinstance(raw, bool):
            return raw
        if isinstance(raw, str):
            return raw.strip().lower() in ("1", "true", "yes", "on")
        return bool(raw)

    def option_number(self, name: str, default: float) -> float:
        raw = self.options.get(name)
        if raw is None:
            return default
        try:
            return float(raw)
        except (TypeError, ValueError):
            return default
