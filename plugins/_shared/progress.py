# progress.py
# OpenDicomViewer
#
# stdout progress lines for one-shot adapters, per PLUGIN_PROTOCOL.md section 4.
#
# The host parses each stdout line as JSON and treats anything else as a log
# line, so the only hard requirements are one object per line and a flush --
# without the flush a subprocess that buffers stdout to a pipe delivers its
# whole progress history at exit, which is exactly when it stops being useful.
# Licensed under the MIT License. See LICENSE for details.
"""Progress and log emission for one-shot adapters."""

from __future__ import annotations

import json
import sys
from typing import TextIO

__all__ = ["emit_progress", "emit_log", "ProgressReporter"]


def emit_progress(progress: float, message: str, stream: TextIO | None = None) -> None:
    """Write one `{"progress": .., "message": ..}` line and flush."""
    out = stream or sys.stdout
    clamped = max(0.0, min(1.0, float(progress)))
    out.write(json.dumps({"progress": round(clamped, 4), "message": message}) + "\n")
    out.flush()


def emit_log(message: str, stream: TextIO | None = None) -> None:
    """Write a plain log line. The host shows these in the plugin log view."""
    out = stream or sys.stdout
    out.write(str(message) + "\n")
    out.flush()


class ProgressReporter:
    """Maps stage-relative progress onto a span of the overall run.

    A one-shot run is a handful of stages whose durations differ by an order of
    magnitude, and the useful signal is a bar that advances roughly with wall
    time rather than with stage count. Each stage is therefore given an
    explicit span of the 0-1 range, and a stage that can report internal
    progress interpolates within its own span.
    """

    def __init__(self, stream: TextIO | None = None) -> None:
        self._stream = stream
        self._start = 0.0
        self._end = 1.0

    def stage(self, start: float, end: float, message: str) -> "ProgressReporter":
        """Enter a stage occupying [start, end] of the run and announce it."""
        self._start, self._end = float(start), float(end)
        emit_progress(self._start, message, self._stream)
        return self

    def within(self, fraction: float, message: str) -> None:
        """Report `fraction` (0-1) of progress through the current stage."""
        span = self._end - self._start
        emit_progress(self._start + span * max(0.0, min(1.0, fraction)),
                      message, self._stream)

    def done(self, message: str = "Done") -> None:
        emit_progress(1.0, message, self._stream)

    def log(self, message: str) -> None:
        emit_log(message, self._stream)
