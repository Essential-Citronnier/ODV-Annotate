# test_serve.py
# OpenDicomViewer
#
# Conformance tests for the HTTP surface, run against a stub adapter so the
# protocol is exercised without any model weights. The important property is
# that a handler which raises for any reason still produces the protocol's
# error envelope: the host has no other way to tell the user what went wrong,
# and a bare 500 with an HTML body would surface as an unexplained failure.
# Licensed under the MIT License. See LICENSE for details.
"""Tests for the shared FastAPI scaffold."""

from __future__ import annotations

import base64
import io
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from _shared.protocol import ErrorCode, PluginError, TaskRequest, TaskSpec  # noqa: E402
from _shared.rle import mask2d_payload  # noqa: E402
from _shared.sam_session import SamSessionAdapter  # noqa: E402
from _shared.serve import build_app  # noqa: E402


def _client(adapter):
    from fastapi.testclient import TestClient

    return TestClient(build_app(adapter))


class StubAdapter:
    """A resident adapter with one task per behaviour under test."""

    plugin_id = "stub"

    def __init__(self) -> None:
        self.status = "ready"

    def tasks(self):
        return [
            TaskSpec(id="echo", label="Echo", inputs=["text"], outputs=["text"]),
            TaskSpec(id="boom", label="Boom", inputs=[], outputs=["text"]),
            TaskSpec(id="gated", label="Gated", inputs=[], outputs=["text"]),
        ]

    def health(self):
        return self.status, "stub detail", 128.0

    def run_task(self, task_id: str, request: TaskRequest):
        if task_id == "echo":
            return {"text": request.text(default="")}
        if task_id == "gated":
            raise PluginError(ErrorCode.LICENSE_REQUIRED, "accept the terms")
        raise ZeroDivisionError("unhandled failure inside the adapter")


# ---------------------------------------------------------------------------
# health and capabilities
# ---------------------------------------------------------------------------


def test_health_reports_protocol_one():
    body = _client(StubAdapter()).get("/health").json()
    assert body["protocol"] == 1
    assert body["plugin_id"] == "stub"
    assert body["status"] == "ready"


def test_health_reflects_a_loading_adapter():
    adapter = StubAdapter()
    adapter.status = "loading"
    assert _client(adapter).get("/health").json()["status"] == "loading"


def test_capabilities_lists_declared_tasks():
    body = _client(StubAdapter()).get("/capabilities").json()
    assert body["protocol"] == 1
    assert {task["id"] for task in body["tasks"]} == {"echo", "boom", "gated"}


# ---------------------------------------------------------------------------
# task envelope
# ---------------------------------------------------------------------------


def test_task_success_envelope():
    response = _client(StubAdapter()).post("/task/echo", json={"inputs": {"text": "hi"}})
    body = response.json()
    assert response.status_code == 200
    assert body["ok"] is True
    assert body["outputs"] == {"text": "hi"}
    assert isinstance(body["elapsed_ms"], int)


def test_task_accepts_an_empty_body():
    body = _client(StubAdapter()).post("/task/echo").json()
    assert body["ok"] is True


def test_unknown_task_is_a_bad_input_envelope_not_a_bare_404():
    response = _client(StubAdapter()).post("/task/nope", json={})
    body = response.json()
    assert response.status_code == 404
    assert body["ok"] is False
    assert body["error"]["code"] == "bad_input"


def test_malformed_json_body_is_bad_input():
    client = _client(StubAdapter())
    response = client.post("/task/echo", content=b"{not json",
                           headers={"content-type": "application/json"})
    assert response.json()["error"]["code"] == "bad_input"


def test_an_unexpected_exception_becomes_an_internal_envelope():
    """A handler that raises anything at all still answers in protocol terms."""
    body = _client(StubAdapter()).post("/task/boom", json={}).json()
    assert body["ok"] is False
    assert body["error"]["code"] == "internal"
    # The exception text is carried through: on a user's machine the cause is
    # routinely a missing library or a bad path, and a bare "internal error"
    # would leave them nothing to act on.
    assert "ZeroDivisionError" in body["error"]["message"]


def test_license_required_survives_as_its_own_code():
    """The host routes this one to the store's gate, so it must not be flattened."""
    body = _client(StubAdapter()).post("/task/gated", json={}).json()
    assert body["error"]["code"] == "license_required"
    assert body["error"]["recoverable"] is True


def test_a_resident_adapter_exposes_no_session_routes():
    client = _client(StubAdapter())
    assert client.post("/session/open", json={}).status_code == 404


# ---------------------------------------------------------------------------
# session adapters, driven through a fake backend
# ---------------------------------------------------------------------------


class FakeBackend:
    """A backend that segments a fixed rectangle around the first click.

    Standing in for SAM lets the whole session contract -- open, prompt, close,
    eviction, mask geometry, RLE emission -- be tested without weights.
    """

    def __init__(self, ready: bool = True, error: PluginError | None = None) -> None:
        self.ready = ready
        self.error = error
        self.encode_calls = 0

    def availability(self):
        if self.error is not None:
            return "error", self.error.message
        return ("ready", None) if self.ready else ("loading", "warming up")

    def ensure_loaded(self):
        if self.error is not None:
            raise self.error

    def encode(self, image):
        self.encode_calls += 1
        return {"size": image.size}

    def decode(self, state, points, box, text, multimask):
        import numpy as np

        width, height = state["size"]

        def stamp(radius: int):
            mask = np.zeros((height, width), dtype=np.uint8)
            if points:
                x, y, _ = points[0]
                mask[max(0, y - radius):y + radius + 1,
                     max(0, x - radius):x + radius + 1] = 1
            elif box is not None:
                x0, y0, x1, y1 = box
                mask[y0:y1, x0:x1] = 1
            return mask

        if multimask:
            # Three candidates at different scales, best-first, as SAM does.
            return [(stamp(2), 0.87), (stamp(3), 0.61), (stamp(1), 0.44)]
        return [(stamp(2), 0.87)]


def _png(width: int = 32, height: int = 24) -> str:
    from PIL import Image

    buffer = io.BytesIO()
    Image.new("RGB", (width, height), (10, 20, 30)).save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def _session_adapter(backend=None, max_sessions: int = 4, text: bool = False):
    return SamSessionAdapter(plugin_id="fake", backend=backend or FakeBackend(),
                             max_sessions=max_sessions, supports_text_prompt=text)


def test_session_open_returns_an_id_and_encode_time():
    body = _client(_session_adapter()).post(
        "/session/open", json={"inputs": {"slice2d": _png()}}).json()
    assert body["ok"] is True
    assert body["session_id"].startswith("s-")
    assert isinstance(body["encode_ms"], int)


def test_prompt_mask_round_trip_produces_a_decodable_mask():
    """The full path: encode once, prompt, and get RLE the host can decode."""
    from _shared.rle import decode_rle

    client = _client(_session_adapter())
    session_id = client.post("/session/open",
                             json={"inputs": {"slice2d": _png(32, 24)}}).json()["session_id"]

    body = client.post("/task/prompt-mask", json={
        "session_id": session_id,
        "inputs": {"points": [{"x": 0.5, "y": 0.5, "label": 1}]},
    }).json()

    assert body["ok"] is True
    mask = body["outputs"]["mask2d"]
    assert (mask["width"], mask["height"]) == (32, 24)
    assert sum(mask["rle"]) == 32 * 24
    assert mask["confidence"] == pytest.approx(0.87)
    # A 5x5 stamp around the click: the count pins that the encoder and the
    # host's decoder agree on which phase is foreground.
    assert sum(decode_rle(mask["rle"], 32, 24)) == 25


def test_a_single_mask_is_emitted_as_a_bare_object():
    """Section 3 allows either shape; one mask stays the simple one."""
    client = _client(_session_adapter())
    session_id = client.post("/session/open",
                             json={"inputs": {"slice2d": _png()}}).json()["session_id"]
    body = client.post("/task/prompt-mask", json={
        "session_id": session_id,
        "inputs": {"points": [{"x": 0.5, "y": 0.5, "label": 1}]},
    }).json()
    assert isinstance(body["outputs"]["mask2d"], dict)


def test_multimask_returns_a_best_first_list():
    """SAM's multimask output, in the list shape section 3 added for it."""
    from _shared.rle import decode_rle

    client = _client(_session_adapter())
    session_id = client.post("/session/open",
                             json={"inputs": {"slice2d": _png(32, 24)}}).json()["session_id"]
    body = client.post("/task/prompt-mask", json={
        "session_id": session_id,
        "inputs": {"points": [{"x": 0.5, "y": 0.5, "label": 1}]},
        "options": {"multimask": True},
    }).json()

    masks = body["outputs"]["mask2d"]
    assert isinstance(masks, list) and len(masks) == 3
    confidences = [m["confidence"] for m in masks]
    assert confidences == sorted(confidences, reverse=True)
    # Every candidate must be independently well-formed, not just the first.
    for mask in masks:
        assert (mask["width"], mask["height"]) == (32, 24)
        assert sum(mask["rle"]) == 32 * 24
        assert sum(decode_rle(mask["rle"], 32, 24)) > 0


def test_a_box_prompt_alone_is_accepted():
    client = _client(_session_adapter())
    session_id = client.post("/session/open",
                             json={"inputs": {"slice2d": _png()}}).json()["session_id"]
    body = client.post("/task/prompt-mask", json={
        "session_id": session_id,
        "inputs": {"box": {"x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5}},
    }).json()
    assert body["ok"] is True


def test_the_encoder_runs_once_per_session_not_per_prompt():
    """The reason this plugin is a session at all."""
    backend = FakeBackend()
    client = _client(_session_adapter(backend))
    session_id = client.post("/session/open",
                             json={"inputs": {"slice2d": _png()}}).json()["session_id"]
    for _ in range(5):
        client.post("/task/prompt-mask", json={
            "session_id": session_id,
            "inputs": {"points": [{"x": 0.5, "y": 0.5, "label": 1}]}})
    assert backend.encode_calls == 1


def test_prompting_without_a_session_is_bad_input():
    body = _client(_session_adapter()).post(
        "/task/prompt-mask",
        json={"inputs": {"points": [{"x": 0.5, "y": 0.5, "label": 1}]}}).json()
    assert body["error"]["code"] == "bad_input"


def test_prompting_an_evicted_session_is_not_ready():
    """Eviction is recoverable: the host reopens the session and retries."""
    client = _client(_session_adapter(max_sessions=1))
    first = client.post("/session/open",
                        json={"inputs": {"slice2d": _png()}}).json()["session_id"]
    client.post("/session/open", json={"inputs": {"slice2d": _png()}})

    body = client.post("/task/prompt-mask", json={
        "session_id": first,
        "inputs": {"points": [{"x": 0.5, "y": 0.5, "label": 1}]}}).json()
    assert body["error"]["code"] == "not_ready"
    assert body["error"]["recoverable"] is True


def test_a_prompt_with_no_geometry_is_rejected():
    client = _client(_session_adapter())
    session_id = client.post("/session/open",
                             json={"inputs": {"slice2d": _png()}}).json()["session_id"]
    body = client.post("/task/prompt-mask",
                       json={"session_id": session_id, "inputs": {}}).json()
    assert body["error"]["code"] == "bad_input"


def test_close_is_idempotent_over_http():
    client = _client(_session_adapter())
    session_id = client.post("/session/open",
                             json={"inputs": {"slice2d": _png()}}).json()["session_id"]
    assert client.post("/session/close", json={"session_id": session_id}).json()["ok"]
    assert client.post("/session/close", json={"session_id": session_id}).json()["ok"]


def test_close_without_an_id_is_bad_input():
    body = _client(_session_adapter()).post("/session/close", json={}).json()
    assert body["error"]["code"] == "bad_input"


def test_a_gated_backend_reports_license_required_through_the_envelope():
    """SAM 3's unsatisfied-gate path, exercised without any weights."""
    gate = PluginError(ErrorCode.LICENSE_REQUIRED, "accept the terms at <url>")
    body = _client(_session_adapter(FakeBackend(error=gate))).post(
        "/session/open", json={"inputs": {"slice2d": _png()}}).json()
    assert body["error"]["code"] == "license_required"


def test_a_gated_backend_reports_error_status_on_health():
    gate = PluginError(ErrorCode.LICENSE_REQUIRED, "accept the terms at <url>")
    body = _client(_session_adapter(FakeBackend(error=gate))).get("/health").json()
    assert body["status"] == "error"
    assert "accept the terms" in body["detail"]


def test_a_text_capable_adapter_declares_the_text_input():
    inputs = _client(_session_adapter(text=True)).get(
        "/capabilities").json()["tasks"][0]["inputs"]
    assert "text" in inputs


def test_a_geometric_only_adapter_does_not_declare_text():
    inputs = _client(_session_adapter()).get(
        "/capabilities").json()["tasks"][0]["inputs"]
    assert "text" not in inputs


def test_host_token_is_enforced_when_set():
    from fastapi.testclient import TestClient

    app = build_app(StubAdapter(), token="secret")
    client = TestClient(app, base_url="http://127.0.0.1:9000")
    assert client.get("/health").status_code == 401
    assert client.get("/health", headers={"X-ODV-Token": "wrong"}).status_code == 401
    assert client.get("/health", headers={"X-ODV-Token": "secret"}).status_code == 200
    foreign = client.get("/health", headers={"X-ODV-Token": "secret",
                                             "Host": "evil.example:9000"})
    assert foreign.status_code == 403
    assert foreign.json()["ok"] is False


def test_token_comes_from_the_environment(monkeypatch):
    from fastapi.testclient import TestClient

    monkeypatch.setenv("ODV_PLUGIN_TOKEN", "from-env")
    client = TestClient(build_app(StubAdapter()), base_url="http://localhost:9000")
    assert client.get("/health").status_code == 401
    assert client.get("/health", headers={"X-ODV-Token": "from-env"}).status_code == 200


def test_no_token_leaves_a_hand_started_adapter_open(monkeypatch):
    monkeypatch.delenv("ODV_PLUGIN_TOKEN", raising=False)
    assert _client(StubAdapter()).get("/health").status_code == 200
