# test_probe_primitives.py
# OpenDicomViewer
#
# Unit tests for the kit's own machinery.
#
# The fixture tests establish that each CHECK catches its violation. These
# establish that the primitives those checks are built on are right in the
# first place -- because a kit whose RLE decoder disagreed with the host's
# would report conformance failures that are its own bug, which is the most
# expensive kind of false positive a conformance tool can produce.
# Licensed under the MIT License. See LICENSE for details.
"""The RLE decoder, the stdout classifier, the loopback rule, the PNG encoder."""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from plugins.conformance.probe import (  # noqa: E402
    classify_stdout,
    decode_rle,
    is_loopback,
    make_png,
)


# ---------------------------------------------------------------------------
# The RLE decoder must agree with the Swift host decoder, exactly
# ---------------------------------------------------------------------------


def test_the_swift_decoder_fixture_decodes_identically():
    """[3, 2, 3] over a 4x2 grid puts foreground at flat indices 3 and 4.

    This is the fixture PluginMask2D.decodeMask is tested against on the Swift
    side, reproduced here on purpose: the two decoders agreeing on this exact
    vector is what makes the kit's phase check meaningful rather than a second
    opinion.
    """
    assert decode_rle([3, 2, 3], 4, 2) == [
        False, False, False, True,
        True, False, False, False,
    ]


def test_a_leading_zero_means_the_mask_starts_foreground():
    """Section 5 admits a leading zero-length run for exactly this case."""
    assert decode_rle([0, 2, 2], 4, 1) == [True, True, False, False]


def test_runs_that_do_not_sum_to_the_frame_are_rejected():
    with pytest.raises(ValueError, match="runs sum to"):
        decode_rle([3, 2], 4, 2)


def test_runs_that_overflow_the_frame_are_rejected():
    with pytest.raises(ValueError, match="overflow"):
        decode_rle([3, 99], 4, 2)


def test_a_negative_run_is_rejected():
    with pytest.raises(ValueError, match="non-negative"):
        decode_rle([3, -1, 6], 4, 2)


def test_the_phase_convention_is_not_symmetric():
    """The same runs read in the other phase give the complement.

    This is the whole hazard section 5 exists to prevent: nothing in the
    payload distinguishes the two readings, so an encoder that picks the wrong
    one produces a mask the host renders inverted, silently.
    """
    correct = decode_rle([0, 4, 4], 4, 2)
    shifted = decode_rle([4, 4], 4, 2)
    assert correct == [not pixel for pixel in shifted]


# ---------------------------------------------------------------------------
# Stdout line discipline
# ---------------------------------------------------------------------------


def test_the_three_line_kinds_are_partitioned():
    out = classify_stdout(
        '{"progress": 0.5, "message": "halfway"}\n'
        '{"ok": false, "error": {"code": "internal", "message": "boom"}}\n'
        'Loading the model...\n'
        '{"unrelated": true}\n'
    )
    assert len(out.progress) == 1
    assert len(out.envelopes) == 1
    # A JSON object carrying neither key is a log line, per section 4b.
    assert len(out.logs) == 2


def test_a_line_carrying_both_keys_is_ambiguous_not_either():
    out = classify_stdout('{"ok": true, "progress": 0.5}\n')
    assert out.ambiguous and not out.progress and not out.envelopes


def test_a_progress_value_outside_zero_to_one_is_malformed():
    out = classify_stdout('{"progress": 42, "message": "x"}\n')
    assert out.malformed_progress and not out.progress


def test_a_progress_value_that_is_a_string_is_malformed():
    out = classify_stdout('{"progress": "50%", "message": "x"}\n')
    assert out.malformed_progress and not out.progress


def test_an_envelope_without_a_code_is_malformed():
    out = classify_stdout('{"ok": false, "error": {"message": "no code"}}\n')
    assert out.malformed_envelopes and not out.envelopes


def test_a_pretty_printed_envelope_is_not_read_as_one_line():
    """Section 4b requires a single JSON line; the host reads stdout by line."""
    out = classify_stdout('{\n  "ok": false,\n  "error": {"code": "internal"}\n}\n')
    assert not out.envelopes


def test_non_json_lines_are_logs():
    out = classify_stdout("Fetching weights\n[1/4] done\n")
    assert len(out.logs) == 2 and not out.progress and not out.envelopes


# ---------------------------------------------------------------------------
# The loopback rule
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("address", ["127.0.0.1", "127.0.1.1", "::1",
                                     "localhost", "::ffff:127.0.0.1"])
def test_loopback_addresses_are_recognised(address):
    assert is_loopback(address)


@pytest.mark.parametrize("address", ["0.0.0.0", "::", "*", "192.168.1.10",
                                     "10.0.0.4", "172.20.3.108", ""])
def test_wildcard_and_routable_addresses_are_not_loopback(address):
    """`0.0.0.0` is the case that matters: it is every interface, not none."""
    assert not is_loopback(address)


# ---------------------------------------------------------------------------
# The PNG encoder
# ---------------------------------------------------------------------------


def test_the_png_encoder_produces_a_decodable_image():
    """The kit encodes its probe slice with zlib alone, so it must be right.

    Decoded here by hand rather than with Pillow -- which the kit deliberately
    does not depend on -- so this test holds in the same bare environment the
    kit is meant to run in.
    """
    width, height = 4, 3
    data = make_png(width, height, lambda x, y: (x * 10, y * 10, 7))
    assert data[:8] == b"\x89PNG\r\n\x1a\n"

    chunks = {}
    offset = 8
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        tag = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])[0]
        assert crc == zlib.crc32(tag + payload) & 0xFFFFFFFF, f"bad CRC on {tag!r}"
        chunks[tag] = payload
        offset += 12 + length

    w, h, depth, colour = struct.unpack(">IIBB", chunks[b"IHDR"][:10])
    assert (w, h, depth, colour) == (width, height, 8, 2)  # 8-bit truecolour

    raw = zlib.decompress(chunks[b"IDAT"])
    stride = width * 3 + 1
    assert len(raw) == stride * height
    for y in range(height):
        assert raw[y * stride] == 0, "filter type must be None"
        for x in range(width):
            start = y * stride + 1 + x * 3
            assert tuple(raw[start:start + 3]) == (x * 10, y * 10, 7)
