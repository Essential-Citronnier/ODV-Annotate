# test_protocol.py
# OpenDicomViewer
#
# Covers the envelopes every adapter shares. The error-code assertions matter
# beyond typo-catching: the host dispatches on the string, routing
# `license_required` to the store's gate UI and everything else to a failure
# banner, so a wrong code turns an actionable state into a dead end.
# Licensed under the MIT License. See LICENSE for details.
"""Tests for the protocol v1 request and response envelopes."""

from __future__ import annotations

import base64
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from _shared.protocol import (  # noqa: E402
    PROTOCOL_VERSION,
    ErrorCode,
    PluginError,
    TaskRequest,
    TaskSpec,
    capabilities_payload,
    error_payload,
    health_payload,
    success_payload,
)


# ---------------------------------------------------------------------------
# Response shapes
# ---------------------------------------------------------------------------


def test_health_payload_shape():
    payload = health_payload("gemma-4-e4b", "ready", memory_mb=4512.04)
    assert payload == {"status": "ready", "plugin_id": "gemma-4-e4b",
                       "protocol": 1, "memory_mb": 4512.0}


def test_health_payload_omits_absent_optionals():
    assert set(health_payload("sam2", "loading")) == {"status", "plugin_id", "protocol"}


def test_health_payload_rejects_unknown_status():
    with pytest.raises(ValueError):
        health_payload("sam2", "warming-up")


def test_protocol_version_is_one():
    assert PROTOCOL_VERSION == 1
    assert health_payload("x", "ready")["protocol"] == 1
    assert capabilities_payload("x", [])["protocol"] == 1


def test_capabilities_payload_shape():
    spec = TaskSpec(
        id="analyze", label="Analyze Image",
        inputs=["slice2d", "text"], outputs=["text", "bbox"],
        options={"mode": {"type": "enum", "values": ["clinical"], "default": "clinical"}},
    )
    payload = capabilities_payload("gemma-4-e4b", [spec])
    assert payload["plugin_id"] == "gemma-4-e4b"
    task = payload["tasks"][0]
    assert task["id"] == "analyze"
    assert task["inputs"] == ["slice2d", "text"]
    assert task["outputs"] == ["text", "bbox"]
    assert task["options"]["mode"]["default"] == "clinical"


def test_capabilities_omits_empty_options():
    spec = TaskSpec(id="prompt-mask", label="Prompt", inputs=["points"], outputs=["mask2d"])
    assert "options" not in capabilities_payload("sam2", [spec])["tasks"][0]


def test_success_payload_rounds_elapsed_to_int():
    payload = success_payload({"text": "hello"}, 1839.6)
    assert payload == {"ok": True, "outputs": {"text": "hello"}, "elapsed_ms": 1840}


def test_error_payload_shape():
    payload = error_payload(ErrorCode.NOT_READY, "still loading", recoverable=True)
    assert payload == {"ok": False, "error": {"code": "not_ready",
                                              "message": "still loading",
                                              "recoverable": True}}


def test_error_codes_match_the_protocol_exactly():
    assert {c.value for c in ErrorCode} == {
        "not_ready", "bad_input", "license_required", "out_of_memory", "internal"
    }


def test_plugin_error_carries_its_payload():
    exc = PluginError(ErrorCode.LICENSE_REQUIRED, "accept the terms", recoverable=True)
    assert exc.to_payload()["error"]["code"] == "license_required"
    assert str(exc) == "accept the terms"


# ---------------------------------------------------------------------------
# Request parsing
# ---------------------------------------------------------------------------


def _png_base64() -> str:
    return base64.b64encode(b"\x89PNG\r\n\x1a\n fake").decode("ascii")


def test_empty_body_parses():
    request = TaskRequest(None)
    assert request.session_id is None
    assert request.inputs == {}
    assert request.options == {}


def test_slice2d_decodes_base64():
    request = TaskRequest({"inputs": {"slice2d": _png_base64()}})
    assert request.slice2d_bytes().startswith(b"\x89PNG")


def test_slice2d_tolerates_a_data_url_prefix():
    request = TaskRequest({"inputs": {"slice2d": "data:image/png;base64," + _png_base64()}})
    assert request.slice2d_bytes().startswith(b"\x89PNG")


def test_slice2d_missing_is_bad_input():
    with pytest.raises(PluginError) as info:
        TaskRequest({"inputs": {}}).slice2d_bytes()
    assert info.value.code is ErrorCode.BAD_INPUT
    assert info.value.recoverable is False


def test_slice2d_optional_returns_none():
    assert TaskRequest({}).slice2d_bytes(required=False) is None


def test_slice2d_invalid_base64_is_bad_input():
    with pytest.raises(PluginError) as info:
        TaskRequest({"inputs": {"slice2d": "not base64 !!!"}}).slice2d_bytes()
    assert info.value.code is ErrorCode.BAD_INPUT


def test_series3d_missing_directory_is_bad_input(tmp_path):
    with pytest.raises(PluginError) as info:
        TaskRequest({"inputs": {"series3d": str(tmp_path / "nope")}}).series3d_path()
    assert info.value.code is ErrorCode.BAD_INPUT


def test_series3d_existing_directory_passes(tmp_path):
    assert TaskRequest({"inputs": {"series3d": str(tmp_path)}}).series3d_path() == str(tmp_path)


def test_rect_parses_normalized_values():
    request = TaskRequest({"inputs": {"roi": {"x": 0.1, "y": 0.2,
                                              "width": 0.3, "height": 0.4}}})
    roi = request.rect("roi")
    assert (roi.x, roi.y, roi.width, roi.height) == (0.1, 0.2, 0.3, 0.4)
    assert roi.to_pixels(100, 100) == (10, 20, 40, 60)


def test_rect_to_pixels_clamps_out_of_range():
    request = TaskRequest({"inputs": {"box": {"x": -0.5, "y": 0.9,
                                              "width": 2.0, "height": 2.0}}})
    x0, y0, x1, y1 = request.rect("box").to_pixels(100, 100)
    assert (x0, y0) == (0, 90)
    assert (x1, y1) == (100, 100)


def test_rect_absent_is_none_when_optional():
    assert TaskRequest({}).rect("roi") is None


def test_rect_non_numeric_is_bad_input():
    with pytest.raises(PluginError) as info:
        TaskRequest({"inputs": {"roi": {"x": "left"}}}).rect("roi")
    assert info.value.code is ErrorCode.BAD_INPUT


def test_points_parse_label_as_foreground_flag():
    request = TaskRequest({"inputs": {"points": [
        {"x": 0.5, "y": 0.4, "label": 1},
        {"x": 0.1, "y": 0.2, "label": 0},
    ]}})
    points = request.points()
    assert [p.is_foreground for p in points] == [True, False]
    assert points[0].to_pixels(512, 512) == (256, 205)


def test_points_default_to_foreground_when_label_absent():
    request = TaskRequest({"inputs": {"points": [{"x": 0.5, "y": 0.5}]}})
    assert request.points()[0].is_foreground is True


def test_points_required_but_absent_is_bad_input():
    with pytest.raises(PluginError) as info:
        TaskRequest({}).points(required=True)
    assert info.value.code is ErrorCode.BAD_INPUT


def test_point_to_pixels_stays_inside_the_image():
    request = TaskRequest({"inputs": {"points": [{"x": 1.0, "y": 1.0, "label": 1}]}})
    assert request.points()[0].to_pixels(64, 64) == (63, 63)


def test_text_defaults_when_absent():
    assert TaskRequest({}).text(default="CT") == "CT"


def test_option_enum_falls_back_on_an_unknown_value():
    """A mode the adapter no longer serves runs the default rather than failing.

    The manifest and the adapter can drift by a release; refusing the whole
    request would be a worse outcome than running the default mode.
    """
    request = TaskRequest({"options": {"mode": "sepia"}})
    assert request.option_enum("mode", ["clinical", "detailed"], "clinical") == "clinical"


def test_option_enum_passes_a_known_value():
    request = TaskRequest({"options": {"mode": "detailed"}})
    assert request.option_enum("mode", ["clinical", "detailed"], "clinical") == "detailed"


@pytest.mark.parametrize("raw,expected", [
    (True, True), (False, False), ("true", True), ("false", False),
    ("1", True), ("no", False), (None, True),
])
def test_option_bool_accepts_json_and_string_forms(raw, expected):
    options = {} if raw is None else {"fast": raw}
    assert TaskRequest({"options": options}).option_bool("fast", default=True) is expected


def test_malformed_inputs_object_is_rejected():
    with pytest.raises(PluginError) as info:
        TaskRequest({"inputs": ["slice2d"]})
    assert info.value.code is ErrorCode.BAD_INPUT
