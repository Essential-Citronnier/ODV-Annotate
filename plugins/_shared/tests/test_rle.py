# test_rle.py
# OpenDicomViewer
#
# The encoder's phase convention has no runtime signal: the host infers
# foreground from run parity alone, so an off-by-one-phase encoder produces a
# structurally valid payload that renders inverted, in both directions, with no
# error anywhere. These tests pin the phase against masks whose encoding was
# worked out by hand, and against a decoder written to match the Swift one.
# Licensed under the MIT License. See LICENSE for details.
"""Tests for the mask2d run-length encoding (PLUGIN_PROTOCOL.md section 5)."""

from __future__ import annotations

import random
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from _shared.rle import decode_rle, encode_mask, encode_rle, mask2d_payload  # noqa: E402


# ---------------------------------------------------------------------------
# Hand-computed examples
# ---------------------------------------------------------------------------


def test_hand_computed_centre_blob():
    """A 4x4 mask with a 2x2 centre blob.

        . . . .
        . # # .
        . # # .
        . . . .

    Row-major, the pixels are 5 background, 2 foreground, 2 background,
    2 foreground, 5 background. Runs begin with background, so the encoding is
    exactly that sequence with no leading zero.
    """
    mask = [
        [0, 0, 0, 0],
        [0, 1, 1, 0],
        [0, 1, 1, 0],
        [0, 0, 0, 0],
    ]
    rle, width, height = encode_mask(mask)
    assert (width, height) == (4, 4)
    assert rle == [5, 2, 2, 2, 5]
    assert sum(rle) == width * height


def test_leading_zero_when_first_pixel_is_foreground():
    """A mask starting foreground needs the zero-length background run.

        # # .
        . . .

    Two foreground, four background. The first run is background by
    definition, so it is emitted with length zero.
    """
    mask = [
        [1, 1, 0],
        [0, 0, 0],
    ]
    rle, width, height = encode_mask(mask)
    assert rle == [0, 2, 4]
    assert sum(rle) == width * height


def test_all_background_is_a_single_run():
    rle, width, height = encode_mask([[0, 0], [0, 0]])
    assert rle == [4]
    assert sum(rle) == width * height


def test_all_foreground_is_zero_then_everything():
    rle, width, height = encode_mask([[1, 1], [1, 1]])
    assert rle == [0, 4]
    assert sum(rle) == width * height


def test_single_foreground_pixel_at_the_end():
    """The trailing run is foreground, so no trailing background run follows."""
    rle, _, _ = encode_mask([[0, 0], [0, 1]])
    assert rle == [3, 1]


def test_row_major_not_column_major():
    """A mask that is asymmetric under transposition pins the traversal order.

        # .
        . .

    Row-major gives [0, 1, 3]; column-major would give the same here, so use a
    mask where the two differ:

        # #
        . #

    Row-major: 0 background, 2 foreground, 1 background, 1 foreground.
    Column-major would read #, ., #, # -> 0, 1, 1, 2.
    """
    rle, _, _ = encode_mask([[1, 1], [0, 1]])
    assert rle == [0, 2, 1, 1]


def test_encode_rle_of_flat_sequence_matches_mask_encoding():
    flat = [0, 0, 1, 1, 0]
    assert encode_rle(flat) == [2, 2, 1]


# ---------------------------------------------------------------------------
# Round trips
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("seed", range(12))
def test_round_trip_random_masks(seed):
    """Encode then decode reproduces the mask exactly, for any content."""
    rng = random.Random(seed)
    width, height = rng.randint(1, 17), rng.randint(1, 17)
    # Vary density so the sample covers all-background, sparse, dense, and
    # all-foreground masks rather than only the noisy middle.
    density = rng.choice([0.0, 0.05, 0.5, 0.95, 1.0])
    mask = [[1 if rng.random() < density else 0 for _ in range(width)]
            for _ in range(height)]

    rle, w, h = encode_mask(mask)
    assert (w, h) == (width, height)
    assert sum(rle) == width * height
    assert all(run >= 0 for run in rle)

    decoded = decode_rle(rle, width, height)
    expected = [bool(pixel) for row in mask for pixel in row]
    assert decoded == expected


def test_round_trip_blob_mask():
    """A filled disc, the shape segmentation actually produces."""
    size = 24
    centre, radius = (size - 1) / 2.0, 7.0
    mask = [
        [1 if (x - centre) ** 2 + (y - centre) ** 2 <= radius ** 2 else 0
         for x in range(size)]
        for y in range(size)
    ]
    rle, width, height = encode_mask(mask)
    assert sum(rle) == width * height
    assert decode_rle(rle, width, height) == [bool(p) for row in mask for p in row]
    # A disc is one run pair per row plus the gaps: far fewer runs than pixels,
    # which is the property the encoding is chosen for.
    assert len(rle) < size * size / 4


# ---------------------------------------------------------------------------
# numpy path
# ---------------------------------------------------------------------------


def test_numpy_array_takes_the_same_path():
    numpy = pytest.importorskip("numpy")
    array = numpy.zeros((4, 4), dtype=numpy.uint8)
    array[1:3, 1:3] = 1
    rle, width, height = encode_mask(array)
    assert (width, height) == (4, 4)
    assert rle == [5, 2, 2, 2, 5]


def test_numpy_float_mask_is_thresholded_by_truthiness():
    numpy = pytest.importorskip("numpy")
    array = numpy.array([[0.0, 1.0], [0.0, 0.0]], dtype=numpy.float32)
    rle, _, _ = encode_mask(array)
    assert rle == [1, 1, 2]


def test_numpy_non_2d_is_rejected():
    numpy = pytest.importorskip("numpy")
    with pytest.raises(ValueError):
        encode_mask(numpy.zeros((2, 2, 2), dtype=numpy.uint8))


# ---------------------------------------------------------------------------
# Payload shape and decoder validation
# ---------------------------------------------------------------------------


def test_mask2d_payload_shape():
    """The anti-diagonal reads 0,1,1,0 row-major: the two ones are one run.

    Written out because the mask looks like alternating pixels on the page and
    the row-major flattening is what makes them contiguous.
    """
    payload = mask2d_payload([[0, 1], [1, 0]], label="liver", confidence=0.9)
    assert payload == {"width": 2, "height": 2, "rle": [1, 2, 1],
                       "label": "liver", "confidence": 0.9}


def test_mask2d_payload_omits_absent_optionals():
    payload = mask2d_payload([[0, 0]])
    assert set(payload) == {"width", "height", "rle"}


def test_ragged_rows_are_rejected():
    with pytest.raises(ValueError):
        encode_mask([[0, 1], [0]])


def test_decoder_rejects_runs_that_do_not_sum():
    with pytest.raises(ValueError):
        decode_rle([2, 1], 2, 2)


def test_decoder_rejects_overflow():
    with pytest.raises(ValueError):
        decode_rle([0, 99], 2, 2)


def test_decoder_rejects_negative_runs():
    with pytest.raises(ValueError):
        decode_rle([-1, 5], 2, 2)
