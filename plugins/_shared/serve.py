# serve.py
# OpenDicomViewer
#
# The HTTP surface of PLUGIN_PROTOCOL.md section 3, built once for the three
# resident adapters.
#
# An adapter supplies a small object describing what it can do and how to run a
# task; this module owns the routes, the error mapping, and the loopback bind.
# The bind matters: invariant 1 says a plugin must not send image data to any
# network destination, and binding 0.0.0.0 would make the adapter itself the
# destination for anything else on the network.
# Licensed under the MIT License. See LICENSE for details.
"""FastAPI scaffold implementing the resident and session HTTP contract."""

from __future__ import annotations

import argparse
import hmac
import json
import os
import time
from typing import Any, Callable, Mapping, Protocol, Sequence

# Imported at module scope rather than inside build_app because FastAPI
# resolves route annotations through the module's globals. Under
# `from __future__ import annotations` every annotation is a string, so a
# function-local `Request` import is invisible at resolution time and the
# request body is silently reinterpreted as a query parameter. Only adapters
# that serve HTTP import this module, so the dependency costs the one-shot
# adapter nothing.
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

# Re-exported so that `serve` remains the single place to look for the HTTP
# execution models. Adapters import it from `_shared.cli` instead, because
# importing this module costs the whole web stack and argument parsing must
# work before that stack is installed.
from .cli import parse_server_args
from .lifeline import start_parent_watch
from .protocol import (
    ErrorCode,
    PluginError,
    TaskRequest,
    TaskSpec,
    capabilities_payload,
    error_payload,
    health_payload,
    success_payload,
)

__all__ = ["Adapter", "build_app", "run_adapter", "parse_server_args",
           "start_parent_watch", "TOKEN_ENV", "TOKEN_HEADER"]

# The host generates a token per launch and passes it in this variable; every
# request must then carry it in TOKEN_HEADER and name loopback in its Host
# header. The Host check defeats DNS-rebinding pages that would otherwise reach
# a loopback port from the browser; the token keeps other local processes out.
# Started by hand without the variable (development, the conformance kit), the
# adapter stays open as before.
TOKEN_ENV = "ODV_PLUGIN_TOKEN"
TOKEN_HEADER = "x-odv-token"
_ALLOWED_HOSTS = {"127.0.0.1", "localhost"}


def _host_allowed(host_header: str | None) -> bool:
    if not host_header:
        return False
    host = host_header.strip().lower()
    if host.startswith("[::1]"):
        return True
    if host.startswith("["):
        return False
    return host.rsplit(":", 1)[0] in _ALLOWED_HOSTS


class Adapter(Protocol):
    """What an adapter must provide for `build_app` to serve it."""

    plugin_id: str

    def tasks(self) -> Sequence[TaskSpec]:
        """Runtime capability list. The host trusts this over the manifest."""

    def health(self) -> tuple[str, str | None, float | None]:
        """Return ``(status, detail, memory_mb)``; status is loading/ready/error."""

    def run_task(self, task_id: str, request: TaskRequest) -> Mapping[str, Any]:
        """Execute a task and return its `outputs` object."""


class SessionAdapter(Adapter, Protocol):
    """A `session` adapter additionally opens and closes per-image state."""

    def open_session(self, request: TaskRequest) -> tuple[str, float]:
        """Encode the input and return ``(session_id, encode_ms)``."""

    def close_session(self, session_id: str) -> bool:
        """Release cached state. Returns False if it was already gone."""


def _as_error_response(exc: BaseException) -> JSONResponse:
    """Map any exception to the protocol's error body.

    Unexpected exceptions become `internal` with the exception text attached:
    an adapter runs in a venv on a user's machine where the failure mode is
    routinely a missing library or a wrong file path, and a bare "internal
    error" would strand the user with nothing to act on.
    """
    if isinstance(exc, PluginError):
        return JSONResponse(status_code=exc.http_status, content=exc.to_payload())
    message = f"{type(exc).__name__}: {exc}"
    return JSONResponse(
        status_code=200,
        content=error_payload(ErrorCode.INTERNAL, message, recoverable=False),
    )


def build_app(adapter: Adapter, on_startup: Callable[[], None] | None = None,
              token: str | None = None):
    """Build the FastAPI app exposing `adapter` over protocol v1.

    `token` defaults to $ODV_PLUGIN_TOKEN; when set, requests without it (or
    addressed to a non-loopback Host) are refused.
    """
    from contextlib import asynccontextmanager

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if on_startup is not None:
            on_startup()
        yield

    app = FastAPI(title=f"ODV plugin: {adapter.plugin_id}", lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)

    expected = (token if token is not None else os.environ.get(TOKEN_ENV, "")).strip()
    if expected:
        @app.middleware("http")
        async def require_local_caller(request: Request, call_next):
            if not _host_allowed(request.headers.get("host")):
                return JSONResponse(status_code=403, content=error_payload(
                    ErrorCode.BAD_INPUT, "Forbidden host", recoverable=False))
            supplied = request.headers.get(TOKEN_HEADER, "")
            if not hmac.compare_digest(supplied.encode(), expected.encode()):
                return JSONResponse(status_code=401, content=error_payload(
                    ErrorCode.BAD_INPUT, "Missing or invalid token", recoverable=False))
            return await call_next(request)

    @app.get("/health")
    async def health() -> dict:
        status, detail, memory_mb = adapter.health()
        return health_payload(adapter.plugin_id, status, detail, memory_mb)

    @app.get("/capabilities")
    async def capabilities() -> dict:
        return capabilities_payload(adapter.plugin_id, adapter.tasks())

    @app.post("/task/{task_id}")
    async def run_task(task_id: str, request: Request):
        started = time.perf_counter()
        try:
            body = await _json_body(request)
            known = {task.id for task in adapter.tasks()}
            if task_id not in known:
                raise PluginError(
                    ErrorCode.BAD_INPUT,
                    f"unknown task '{task_id}'; this plugin serves "
                    f"{', '.join(sorted(known))}",
                    recoverable=False,
                    http_status=404,
                )
            outputs = await _in_threadpool(adapter.run_task, task_id, TaskRequest(body))
        except BaseException as exc:  # noqa: BLE001 - every failure gets an envelope
            return _as_error_response(exc)
        return success_payload(outputs, (time.perf_counter() - started) * 1000.0)

    if hasattr(adapter, "open_session"):
        @app.post("/session/open")
        async def open_session(request: Request):
            try:
                body = await _json_body(request)
                session_id, encode_ms = await _in_threadpool(
                    adapter.open_session, TaskRequest(body)
                )
            except BaseException as exc:  # noqa: BLE001
                return _as_error_response(exc)
            return {"ok": True, "session_id": session_id,
                    "encode_ms": int(round(encode_ms))}

        @app.post("/session/close")
        async def close_session(request: Request):
            try:
                body = await _json_body(request)
                session_id = (body or {}).get("session_id")
                if not isinstance(session_id, str) or not session_id:
                    raise PluginError(
                        ErrorCode.BAD_INPUT, "session_id is required",
                        recoverable=False,
                    )
                adapter.close_session(session_id)
            except BaseException as exc:  # noqa: BLE001
                return _as_error_response(exc)
            return {"ok": True}

    return app


async def _json_body(request: Request) -> dict:
    """Read a JSON object body, tolerating an empty one."""
    raw = await request.body()
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except ValueError as exc:
        raise PluginError(
            ErrorCode.BAD_INPUT, f"request body is not valid JSON: {exc}",
            recoverable=False,
        ) from None
    if not isinstance(parsed, dict):
        raise PluginError(
            ErrorCode.BAD_INPUT, "request body must be a JSON object", recoverable=False
        )
    return parsed


async def _in_threadpool(fn, *args):
    """Run a blocking handler off the event loop.

    Inference holds the GIL in C extensions for seconds at a time; on the event
    loop that would stall /health and make the host declare the plugin dead
    mid-request.
    """
    return await run_in_threadpool(fn, *args)


def parse_server_args(description: str, argv: Sequence[str] | None = None):
    """Parse the CLI the host spawns a resident adapter with."""
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--port", type=int, required=True,
                        help="TCP port on 127.0.0.1 assigned by the host")
    parser.add_argument("--host", default="127.0.0.1",
                        help=argparse.SUPPRESS)  # loopback only; present for tests
    parser.add_argument("--log-level", default="info")
    return parser.parse_args(argv)


def run_adapter(adapter: Adapter, args, on_startup: Callable[[], None] | None = None) -> None:
    """Serve `adapter` on the host-assigned port until terminated."""
    import uvicorn

    if args.host not in ("127.0.0.1", "localhost", "::1"):
        raise SystemExit("refusing to bind a non-loopback address")

    # Section 4d: a server whose host has crashed exits instead of holding
    # its model in memory indefinitely.
    start_parent_watch()

    uvicorn.run(
        build_app(adapter, on_startup=on_startup),
        host=args.host,
        port=args.port,
        log_level=args.log_level,
        # Single worker: every adapter here holds a model in process memory and
        # none of them are fork-safe.
        workers=1,
    )
