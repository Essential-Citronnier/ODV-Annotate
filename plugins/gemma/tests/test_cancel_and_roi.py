# test_cancel_and_roi.py
# OpenDicomViewer
#
# Two behaviours the Gemma plugin must share with the built-in mlx-server:
# a host that hangs up stops the generation between tokens, and Describe ROI
# shows the model the region as a red rectangle with the same prompt text.
# Licensed under the MIT License. See LICENSE for details.
"""Cancellation and Describe ROI tests for the Gemma plugin (no MLX needed)."""

from __future__ import annotations

import base64
import importlib.util
import io
import os
import socket
import sys
import threading
import time
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import server  # noqa: E402
from _shared.protocol import ErrorCode, PluginError, TaskRequest  # noqa: E402
from _shared.vlm import GenerationCancelled  # noqa: E402

Image = pytest.importorskip("PIL.Image")

REPO = Path(__file__).resolve().parents[3]


def _png_b64(width=200, height=100) -> str:
    buffer = io.BytesIO()
    Image.new("RGB", (width, height)).save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode()


class _Processor:
    def __init__(self):
        self.messages = None

    def apply_chat_template(self, messages, add_generation_prompt=False):
        self.messages = messages
        return "FORMATTED"


def _ready_adapter(stream_generate, monkeypatch):
    adapter = server.GemmaAdapter()
    adapter.model._model = object()
    adapter.model._processor = _Processor()
    fake = types.ModuleType("mlx_vlm")
    fake.stream_generate = stream_generate
    monkeypatch.setitem(sys.modules, "mlx_vlm", fake)
    return adapter


# ---------------------------------------------------------------------------
# Cancellation
# ---------------------------------------------------------------------------


def test_generation_loop_stops_when_cancel_is_set(monkeypatch):
    cancel = threading.Event()
    produced = []

    def stream_generate(*_a, **_k):
        for index in range(1000):
            produced.append(index)
            if index == 3:
                cancel.set()
            yield types.SimpleNamespace(text="t")

    adapter = _ready_adapter(stream_generate, monkeypatch)
    with pytest.raises(GenerationCancelled):
        adapter.run_task("analyze", TaskRequest({"inputs": {"slice2d": _png_b64()}}),
                         cancel)
    assert len(produced) < 10


def test_run_task_still_works_without_cancel(monkeypatch):
    adapter = _ready_adapter(lambda *a, **k: iter(
        [types.SimpleNamespace(text='{"regions": []}')]), monkeypatch)
    outputs = adapter.run_task("detect-abnormalities",
                               TaskRequest({"inputs": {"slice2d": _png_b64()}}))
    assert outputs["bbox"] == []


def _serve_in_thread(app):
    uvicorn = pytest.importorskip("uvicorn")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    uv = uvicorn.Server(uvicorn.Config(app, lifespan="off", log_level="warning"))
    thread = threading.Thread(target=uv.run, kwargs={"sockets": [sock]}, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not uv.started:
        if time.monotonic() > deadline or not thread.is_alive():
            raise RuntimeError("uvicorn did not start")
        time.sleep(0.02)

    def stop():
        uv.should_exit = True
        thread.join(10)
        sock.close()

    return f"http://127.0.0.1:{port}", stop


_ROI = {"x": 0.1, "y": 0.1, "width": 0.3, "height": 0.3}


@pytest.mark.parametrize("path, make_body", [
    ("/task/describe-roi",
     lambda image: {"inputs": {"slice2d": image, "text": "CT", "roi": _ROI}}),
    ("/describe-roi", lambda image: {"image": image, "context": "CT", "roi": _ROI}),
])
def test_client_hang_up_stops_the_token_loop(monkeypatch, path, make_body):
    """Over a real socket, through the token middleware, protocol and legacy routes."""
    httpx = pytest.importorskip("httpx")
    from _shared.serve import build_app

    started = threading.Event()
    tokens = []
    finished = threading.Event()

    def stream_generate(*_a, **_k):
        started.set()
        for _ in range(400):  # ~20 s if nobody stops it
            time.sleep(0.05)
            tokens.append(1)
            yield types.SimpleNamespace(text="t")
        finished.set()

    adapter = _ready_adapter(stream_generate, monkeypatch)
    app = build_app(adapter, token="secret")
    server.attach_legacy_routes(app, adapter)
    body = make_body(_png_b64())

    base_url, stop = _serve_in_thread(app)
    try:
        with pytest.raises(httpx.ReadTimeout):
            httpx.post(base_url + path, json=body, headers={"X-ODV-Token": "secret"},
                       timeout=httpx.Timeout(10.0, read=1.0))
        assert started.is_set(), "generation never started"
        # The model lock is free again once the cancelled run has unwound.
        assert adapter.model._lock.acquire(timeout=5), "hang-up did not stop the run"
        adapter.model._lock.release()
        count = len(tokens)
        time.sleep(0.3)
        assert len(tokens) == count, "tokens kept coming after the hang-up"
        assert not finished.is_set()
    finally:
        stop()


# ---------------------------------------------------------------------------
# Describe ROI parity with mlx-server
# ---------------------------------------------------------------------------


def test_describe_roi_marks_the_region_and_points_at_it(monkeypatch):
    seen = {}

    def stream_generate(model, processor, prompt, image=None, **_k):
        seen["image"] = image[0]
        return iter([types.SimpleNamespace(text='{"label": "liver", "description": "ok"}')])

    adapter = _ready_adapter(stream_generate, monkeypatch)
    outputs = adapter.run_task("describe-roi", TaskRequest({"inputs": {
        "slice2d": _png_b64(200, 100),
        "roi": {"x": 0.25, "y": 0.2, "width": 0.5, "height": 0.6}}}))

    assert outputs == {"text": "liver: ok"}
    image = seen["image"]
    # The outline runs along the ROI's edges; the rest of the slice is untouched.
    assert image.getpixel((50, 50)) == (255, 0, 0)    # left edge, x = 0.25 * 200
    assert image.getpixel((100, 20)) == (255, 0, 0)   # top edge, y = 0.2 * 100
    assert image.getpixel((100, 50)) == (0, 0, 0)     # inside
    assert image.getpixel((10, 10)) == (0, 0, 0)      # outside
    text = adapter.model._processor.messages[-1]["content"][1]["text"]
    assert "red rectangle" in text
    assert "x=0.250, y=0.200, width=0.500, height=0.600" in text
    assert "Context: none" in text


@pytest.mark.parametrize("roi", [
    {"x": 0.5, "y": 0.5, "width": 0.0, "height": 0.2},
    {"x": 2.0, "y": 0.5, "width": 0.5, "height": 0.2},
    {"x": "a", "y": 0.5, "width": 0.5, "height": 0.2},
])
def test_unusable_roi_is_bad_input(monkeypatch, roi):
    adapter = _ready_adapter(lambda *a, **k: iter([]), monkeypatch)
    with pytest.raises(PluginError) as caught:
        adapter.run_task("describe-roi", TaskRequest({"inputs": {
            "slice2d": _png_b64(), "roi": roi}}))
    assert caught.value.code is ErrorCode.BAD_INPUT


def _load_builtin_server():
    """mlx-server/server.py under another module name (both are `server`)."""
    pytest.importorskip("fastapi")
    os.environ.setdefault("ODV_AI_TOKEN", "test-token")
    spec = importlib.util.spec_from_file_location(
        "odv_builtin_mlx_server", REPO / "mlx-server" / "server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_describe_roi_matches_the_builtin_server():
    builtin = _load_builtin_server()
    assert server.DESCRIBE_ROI_PROMPT_TEMPLATE == builtin.DESCRIBE_ROI_PROMPT_TEMPLATE

    base = Image.new("RGB", (640, 480), (30, 30, 30))
    roi = (0.1, 0.2, 0.33, 0.41)
    assert server.mark_roi(base, roi).tobytes() == builtin._mark_roi(base, roi).tobytes()


def test_legacy_routes_read_the_json_body(monkeypatch):
    # They answered 422 ("query parameter `request` missing") before: the
    # Request annotation did not resolve under postponed annotations.
    pytest.importorskip("httpx")
    from fastapi.testclient import TestClient

    from _shared.serve import build_app

    adapter = _ready_adapter(lambda *a, **k: iter(
        [types.SimpleNamespace(text='{"label": "x", "description": "y", "regions": []}')]),
        monkeypatch)
    app = build_app(adapter, token="")
    server.attach_legacy_routes(app, adapter)
    client = TestClient(app)
    image = _png_b64()
    for path, body in [
        ("/analyze", {"image": image, "window_info": {"modality": "CT"}}),
        ("/describe-roi", {"image": image, "roi": _ROI}),
        ("/detect-abnormalities", {"image": image, "modality": "CT"}),
    ]:
        response = client.post(path, json=body)
        assert response.status_code == 200, (path, response.text)
