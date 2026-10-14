# coerce.py
# OpenDicomViewer
#
# Turning a vision-language model's answer into boxes the viewer can draw.
#
# Shared by the built-in mlx-server and the Gemma plugin: both run the same
# checkpoint with the same prompts, so the same answer must produce the same
# overlay whichever engine served it. Standard library only (see __init__.py).
# Licensed under the MIT License. See LICENSE for details.
"""Lenient parsing of model output: JSON recovery, boxes, confidence, severity."""

from __future__ import annotations

import json
import math
import re
from typing import Any, Mapping

# Boxes thinner than this (normalized) are noise, not findings.
MIN_BOX_SIZE = 0.002

SEVERITIES = ("normal", "mild", "moderate", "severe", "critical")

__all__ = [
    "MIN_BOX_SIZE",
    "SEVERITIES",
    "as_object",
    "coerce_boxes",
    "coerce_confidence",
    "coerce_findings",
    "coerce_severity",
    "coerce_text",
    "detect_scale",
    "extract_json",
    "finite",
    "raw_corners",
]


def extract_json(text: str) -> Any:
    """Recover a JSON value (object or array) from model output, or None."""
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        pass

    match = re.search(r"```(?:json)?\s*([\[{].*?[\]}])\s*```", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(1))
        except json.JSONDecodeError:
            pass

    for pattern in (r"\{.*\}", r"\[.*\]"):
        match = re.search(pattern, text, re.DOTALL)
        if match:
            try:
                return json.loads(match.group(0))
            except json.JSONDecodeError:
                pass

    return None


def as_object(parsed: Any, list_key: str) -> dict | None:
    """Normalize parsed model output to a dict.

    A bare array is read as the response's primary list (the model sometimes
    drops the wrapper object); scalars are unusable.
    """
    if isinstance(parsed, Mapping):
        return dict(parsed)
    if isinstance(parsed, list):
        return {list_key: parsed}
    return None


def finite(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def coerce_confidence(value: Any) -> float:
    """Confidence as a float in [0, 1]; accepts "85%" and 0-100 scales."""
    if isinstance(value, str):
        value = value.strip().rstrip("%")
    number = finite(value)
    if number is None:
        return 0.0
    if 1.0 < number <= 100.0:
        number /= 100.0
    return min(max(number, 0.0), 1.0)


def coerce_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, Mapping):
        for key in ("finding", "label", "description", "text", "name"):
            if isinstance(value.get(key), str):
                return value[key].strip()
        return json.dumps(value, ensure_ascii=False)
    return str(value).strip()


def coerce_findings(value: Any) -> list[str]:
    items = value if isinstance(value, list) else [value] if value else []
    findings = [coerce_text(item) for item in items]
    return [f for f in findings if f]


def coerce_severity(value: Any) -> str:
    """Lower-cased known severity, or "unknown" -- never silently "normal".

    "unknown" renders neutral grey in the viewer, so a misspelt or invented
    severity cannot make a finding look benign, and "critical" keeps its own
    (red) value instead of falling back to "normal" (green).
    """
    severity = coerce_text(value).lower()
    return severity if severity in SEVERITIES else "unknown"


def raw_corners(item: Mapping) -> tuple[float, float, float, float] | None:
    """(x0, y0, x1, y1) in whatever unit the model used, or None."""
    box_2d = item.get("box_2d")
    if isinstance(box_2d, (list, tuple)) and len(box_2d) == 4:
        # Gemma's native grounding format: [ymin, xmin, ymax, xmax].
        values = [finite(v) for v in box_2d]
        if any(v is None for v in values):
            return None
        y0, x0, y1, x1 = values
        return x0, y0, x1, y1

    x = finite(item.get("x"))
    y = finite(item.get("y"))
    w = finite(item.get("width", item.get("w")))
    h = finite(item.get("height", item.get("h")))
    if None in (x, y, w, h):
        return None
    return x, y, x + w, y + h


def detect_scale(corners: list[tuple[float, float, float, float]],
                 image_size: tuple[int, int] | None) -> tuple[float, float] | None:
    """Divisors that map the model's units onto [0, 1].

    The prompt asks for normalized coordinates, but the model does not always
    comply. Decided once per response, from the largest coordinate:
      * <= 2        -> already normalized, overshooting the edge (clamped
                       below). A 0-1000 or pixel box this small would be
                       sub-pixel noise anyway.
      * <= 1000     -> Gemma's native 0-1000 grid. Pixel units are
                       indistinguishable here unless they exceed 1000, and the
                       model's trained convention is the likelier explanation.
      * otherwise   -> pixel units of the image the model saw, if they fit it.
    Returns None when no reading fits, so the caller drops every box rather
    than drawing them in the wrong place.
    """
    if not corners:
        return (1.0, 1.0)
    largest = max(max(abs(v) for v in c) for c in corners)
    if largest <= 2.0:
        return (1.0, 1.0)
    if largest <= 1000.0 + 1e-3:
        return (1000.0, 1000.0)
    if image_size is not None:
        width, height = image_size
        fits = all(max(c[0], c[2]) <= width * 1.02 and max(c[1], c[3]) <= height * 1.02
                   for c in corners)
        if fits:
            return (float(width), float(height))
    return None


def coerce_boxes(raw: Any, image_size: tuple[int, int] | None = None,
                 with_severity: bool = False) -> list[dict]:
    """Keep only well-formed boxes, normalized and clamped to [0, 1].

    A malformed box among several good ones is dropped rather than failing the
    request: the model is the unreliable component here, and a partial overlay
    is more useful than an error.
    """
    items = [item for item in (raw if isinstance(raw, list) else [])
             if isinstance(item, Mapping)]
    parsed = [(item, raw_corners(item)) for item in items]
    parsed = [(item, c) for item, c in parsed if c is not None]

    scale = detect_scale([c for _, c in parsed], image_size)
    if scale is None:
        return []
    sx, sy = scale

    boxes: list[dict] = []
    for item, (x0, y0, x1, y1) in parsed:
        # Order the corners (negative width/height) then clamp to the image.
        left = min(max(min(x0, x1) / sx, 0.0), 1.0)
        right = min(max(max(x0, x1) / sx, 0.0), 1.0)
        top = min(max(min(y0, y1) / sy, 0.0), 1.0)
        bottom = min(max(max(y0, y1) / sy, 0.0), 1.0)
        if right - left < MIN_BOX_SIZE or bottom - top < MIN_BOX_SIZE:
            continue
        box = {
            "x": left,
            "y": top,
            "width": right - left,
            "height": bottom - top,
            "label": coerce_text(item.get("label")),
            "confidence": coerce_confidence(item.get("confidence")),
        }
        if with_severity:
            box["severity"] = coerce_severity(item.get("severity"))
        boxes.append(box)
    return boxes
