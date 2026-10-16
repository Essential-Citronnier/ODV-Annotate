# test_serve_cancel.py
# OpenDicomViewer
#
# A host that gives up on a task (its timeout fired, the user retried) closes
# the connection. The serve layer must notice and tell a handler that declared
# a `cancel` parameter to stop, while handlers without one keep working as
# before. Disconnects only exist over a real socket, so these tests run uvicorn
# on an ephemeral loopback port rather than through TestClient.
# Licensed under the MIT License. See LICENSE for details.
"""Tests for cancel-on-disconnect in the shared FastAPI scaffold."""

from __future__ import annotations

import socket
import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from _shared.protocol import TaskRequest, TaskSpec  # noqa: E402
from _shared.serve import _accepts_cancel, build_app  # noqa: E402
from _shared.vlm import GenerationCancelled  # noqa: E402

httpx = pytest.importorskip("httpx")
uvicorn = pytest.importorskip("uvicorn")


def serve_in_thread(app):
    """Run `app` under uvicorn on an ephemeral port; return (base_url, stop)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, lifespan="off", log_level="warning"))
    thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        if time.monotonic() > deadline or not thread.is_alive():
            raise RuntimeError("uvicorn did not start")
        time.sleep(0.02)

    def stop():
        server.should_exit = True
        thread.join(10)
        sock.close()

    return f"http://127.0.0.1:{port}", stop


class SlowAdapter:
    """One slow task; records whether and how it was told to stop."""

    plugin_id = "slow"

    def __init__(self, accepts_cancel: bool) -> None:
        self.started = threading.Event()
        self.stopped = threading.Event()
        self.finished = threading.Event()
        self.received_cancel: list[object] = []
        if accepts_cancel:
            self.run_task = self._run_task_cancellable
        else:
            self.run_task = self._run_task_plain

    def tasks(self):
        return [TaskSpec(id="slow", label="Slow", inputs=[], outputs=["text"])]

    def health(self):
        return "ready", None, None

    def _loop(self, cancel, seconds: float):
        self.started.set()
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if cancel is not None and cancel.wait(0.05):
                self.stopped.set()
                raise GenerationCancelled()
            time.sleep(0 if cancel is not None else 0.05)
        self.finished.set()
        return {"text": "done"}

    def _run_task_cancellable(self, task_id: str, request: TaskRequest,
                              cancel: threading.Event | None = None):
        self.received_cancel.append(cancel)
        return self._loop(cancel, 20.0)

    def _run_task_plain(self, task_id: str, request: TaskRequest):
        return self._loop(None, float(request.text(default="1.5")))


def test_signature_detection():
    assert _accepts_cancel(SlowAdapter(True).run_task)
    assert not _accepts_cancel(SlowAdapter(False).run_task)


def test_hanging_up_sets_the_cancel_event():
    adapter = SlowAdapter(accepts_cancel=True)
    base_url, stop = serve_in_thread(build_app(adapter, token=""))
    try:
        # The read timeout is the hang-up: httpx abandons the response and
        # closes the connection while the task is still running.
        with pytest.raises(httpx.ReadTimeout):
            httpx.post(f"{base_url}/task/slow", json={},
                       timeout=httpx.Timeout(10.0, read=1.0))
        assert adapter.started.is_set()
        assert adapter.stopped.wait(5), "client hang-up did not cancel the task"
        assert not adapter.finished.is_set()
        assert isinstance(adapter.received_cancel[0], threading.Event)
    finally:
        stop()


def test_hanging_up_is_detected_behind_the_token_middleware():
    # The token check used to be a BaseHTTPMiddleware, under which the route
    # never saw http.disconnect. It must not hide the hang-up.
    adapter = SlowAdapter(accepts_cancel=True)
    base_url, stop = serve_in_thread(build_app(adapter, token="secret"))
    try:
        assert httpx.post(f"{base_url}/task/slow", json={}).status_code == 401
        with pytest.raises(httpx.ReadTimeout):
            httpx.post(f"{base_url}/task/slow", json={},
                       headers={"X-ODV-Token": "secret"},
                       timeout=httpx.Timeout(10.0, read=1.0))
        assert adapter.stopped.wait(5), "client hang-up did not cancel the task"
    finally:
        stop()


def test_a_handler_without_cancel_still_completes():
    adapter = SlowAdapter(accepts_cancel=False)
    base_url, stop = serve_in_thread(build_app(adapter, token=""))
    try:
        response = httpx.post(f"{base_url}/task/slow",
                              json={"inputs": {"text": "0.8"}}, timeout=10.0)
        assert response.status_code == 200
        assert response.json()["outputs"] == {"text": "done"}
    finally:
        stop()
