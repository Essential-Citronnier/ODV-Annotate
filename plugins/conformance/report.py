# report.py
# OpenDicomViewer
#
# Rendering a conformance run for a human.
#
# The audience is an adapter author who has just been told their plugin does
# not conform, so the reason line matters more than the verdict: it names the
# protocol section, what the adapter did, and what the host would do about it.
# A bare "FAIL: H3" would send them back to the specification to guess.
# Licensed under the MIT License. See LICENSE for details.
"""Human-readable rendering of a ConformanceReport."""

from __future__ import annotations

import os
import sys
import textwrap
from typing import Sequence

from .kit import ConformanceReport, Status

__all__ = ["render", "render_many", "summary_line"]

_GLYPH = {Status.PASS: "PASS", Status.FAIL: "FAIL",
          Status.SKIP: "SKIP", Status.ERROR: "ERR "}

_COLOR = {Status.PASS: "\033[32m", Status.FAIL: "\033[31m",
          Status.SKIP: "\033[90m", Status.ERROR: "\033[33m"}
_RESET = "\033[0m"


def _use_colour(stream) -> bool:
    if os.environ.get("NO_COLOR") is not None:
        return False
    return bool(getattr(stream, "isatty", lambda: False)())


def render(report: ConformanceReport, width: int = 88, stream=None) -> str:
    """Render one adapter's report as plain text."""
    colour = _use_colour(stream or sys.stdout)
    lines: list[str] = []
    header = f"{report.plugin_id or '(unknown id)'}  [{report.execution or '?'}]"
    lines.append(header)
    lines.append("─" * min(width, max(len(header), 40)))
    lines.append(f"adapter   {report.adapter_dir}")
    lines.append(f"manifest  {report.manifest or '(none found)'}")
    lines.append("")

    for result in report.results:
        tag = _GLYPH[result.status]
        if colour:
            tag = f"{_COLOR[result.status]}{tag}{_RESET}"
        lines.append(f"  {tag}  {result.id}  {result.title}   [§{result.section}]")
        if result.reason:
            wrapped = textwrap.wrap(result.reason, width=width - 14) or [""]
            for line in wrapped:
                lines.append(f"            {line}")
        lines.append("")

    counts = report.counts()
    verdict = "CONFORMS" if report.passed else "DOES NOT CONFORM"
    if colour:
        verdict = ((_COLOR[Status.PASS] if report.passed else _COLOR[Status.FAIL])
                   + verdict + _RESET)
    lines.append(
        f"  {verdict} — {counts['PASS']} passed, {counts['FAIL']} failed, "
        f"{counts['SKIP']} skipped, {counts['ERROR']} inconclusive "
        f"({report.duration_s:.1f}s)")
    return "\n".join(lines)


def summary_line(report: ConformanceReport) -> str:
    counts = report.counts()
    return (f"{(report.plugin_id or '?'):<18} "
            f"{(report.execution or '?'):<15} "
            f"{counts['PASS']:>3} pass  {counts['FAIL']:>2} fail  "
            f"{counts['SKIP']:>2} skip  {counts['ERROR']:>2} inconclusive   "
            f"{'CONFORMS' if report.passed else 'DOES NOT CONFORM'}")


def render_many(reports: Sequence[ConformanceReport], width: int = 88,
                stream=None) -> str:
    """Render several adapters, each in full, followed by a summary table."""
    blocks = [render(report, width=width, stream=stream) for report in reports]
    if len(reports) > 1:
        blocks.append("")
        blocks.append("Summary")
        blocks.append("─" * 60)
        blocks.extend(summary_line(report) for report in reports)
    return "\n\n".join(blocks)
