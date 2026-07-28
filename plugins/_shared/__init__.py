# __init__.py
# OpenDicomViewer
#
# Shared implementation of ODV Plugin Protocol v1 for the Python adapters.
#
# Each adapter ships in its own virtualenv (PLUGIN_PROTOCOL.md section 7), so
# this package cannot be a pip dependency of any one of them without four
# copies that are free to drift on the one thing they must agree on. It is
# instead imported from the parent directory -- see `_shared.bootstrap`. That
# constrains the design: nothing imported at package load may come from outside
# the standard library, and every third-party import (PIL, numpy, fastapi,
# torch) happens inside the function that needs it. An adapter therefore never
# pays for a dependency its venv does not have.
# Licensed under the MIT License. See LICENSE for details.
"""Shared protocol helpers for ODV plugin adapters."""

from .oneshot import OneShotResult, parse_oneshot_args, run_oneshot
from .progress import ProgressReporter, emit_log, emit_progress
from .protocol import (
    PROTOCOL_VERSION,
    ErrorCode,
    PluginError,
    Point,
    Rect,
    TaskRequest,
    TaskSpec,
    capabilities_payload,
    error_payload,
    health_payload,
    success_payload,
)
from .rle import decode_rle, encode_mask, encode_rle, mask2d_payload
from .sessions import Session, SessionStore

__all__ = [
    "PROTOCOL_VERSION",
    "ErrorCode",
    "OneShotResult",
    "PluginError",
    "Point",
    "ProgressReporter",
    "Rect",
    "Session",
    "SessionStore",
    "TaskRequest",
    "TaskSpec",
    "capabilities_payload",
    "decode_rle",
    "emit_log",
    "emit_progress",
    "encode_mask",
    "encode_rle",
    "error_payload",
    "health_payload",
    "mask2d_payload",
    "parse_oneshot_args",
    "run_oneshot",
    "success_payload",
]
