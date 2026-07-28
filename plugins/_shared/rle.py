# rle.py
# OpenDicomViewer
#
# Run-length encoding for mask2d outputs, per PLUGIN_PROTOCOL.md section 5.
#
# The host's decoder (PluginMask2D.decodeMask in PluginTypes.swift) is already
# written and tested against that definition. It infers foreground purely from
# run parity, with no marker in the data, so an encoder that emits a different
# phase produces a perfectly well-formed payload that renders inverted. That
# failure is silent on both sides, which is why the phase convention is stated
# once here and asserted by the round-trip test rather than left to each
# adapter.
# Licensed under the MIT License. See LICENSE for details.
"""Row-major RLE over a 2D mask, starting with a background run."""

from __future__ import annotations

from typing import Any, Iterable, Sequence

__all__ = ["encode_rle", "encode_mask", "decode_rle", "mask2d_payload"]


def encode_rle(flat: Iterable[Any]) -> list[int]:
    """Encode a flat row-major sequence of truthy/falsy pixels as run lengths.

    Runs alternate background, foreground, background, ... starting with
    background. A mask whose first pixel is foreground therefore yields a
    leading zero-length run, which the protocol explicitly admits.
    """
    runs: list[int] = []
    expecting_foreground = False
    current = 0

    for pixel in flat:
        is_foreground = bool(pixel)
        if is_foreground == expecting_foreground:
            current += 1
        else:
            runs.append(current)
            expecting_foreground = is_foreground
            current = 1

    # The final run is only emitted here, so an empty input yields [] rather
    # than [0]; callers with a zero-area mask are rejected upstream.
    if current or runs:
        runs.append(current)
    return runs


def encode_mask(mask: Any) -> tuple[list[int], int, int]:
    """Encode a 2D mask, returning ``(rle, width, height)``.

    Accepts a numpy array or any nested sequence of rows. numpy is used when
    the input provides it but is never imported here, so this module stays
    usable in an adapter venv that has no numerical stack.
    """
    shape = getattr(mask, "shape", None)
    if shape is not None:
        if len(shape) != 2:
            raise ValueError(f"mask must be 2D, got shape {tuple(shape)}")
        height, width = int(shape[0]), int(shape[1])
        # ravel() on a C-ordered array is row-major, matching the protocol.
        flat = mask.astype(bool).ravel(order="C").tolist()
        return encode_rle(flat), width, height

    rows: Sequence[Sequence[Any]] = list(mask)
    height = len(rows)
    if height == 0:
        raise ValueError("mask must have at least one row")
    width = len(rows[0])
    if any(len(row) != width for row in rows):
        raise ValueError("mask rows must all be the same length")

    def pixels() -> Iterable[Any]:
        for row in rows:
            yield from row

    return encode_rle(pixels()), width, height


def decode_rle(rle: Sequence[int], width: int, height: int) -> list[bool]:
    """Decode run lengths back to a row-major boolean list.

    This mirrors the host's Swift decoder exactly and exists so adapters can
    round-trip their own output in tests. It is not on any request path.
    """
    total = width * height
    if total <= 0:
        raise ValueError("width and height must both be positive")

    out = [False] * total
    index = 0
    is_foreground = False
    for run in rle:
        if run < 0:
            raise ValueError(f"negative run length: {run}")
        if index + run > total:
            raise ValueError("runs overflow width * height")
        if is_foreground and run:
            for i in range(index, index + run):
                out[i] = True
        index += run
        is_foreground = not is_foreground

    if index != total:
        raise ValueError(f"runs sum to {index}, expected {total}")
    return out


def mask2d_payload(
    mask: Any,
    label: str | None = None,
    confidence: float | None = None,
) -> dict:
    """Build the protocol's `mask2d` output object from a 2D mask."""
    rle, width, height = encode_mask(mask)
    payload: dict = {"width": width, "height": height, "rle": rle}
    if label is not None:
        payload["label"] = label
    if confidence is not None:
        payload["confidence"] = float(confidence)
    return payload
