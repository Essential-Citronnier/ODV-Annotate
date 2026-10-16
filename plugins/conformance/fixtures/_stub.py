# _stub.py
# OpenDicomViewer
#
# A conformant protocol-v1 adapter in the standard library alone, with every
# requirement switchable off one at a time.
#
# The fixtures exist to answer one question about the conformance kit: does
# each check actually fail when its requirement is violated? A check that
# cannot fail is not a check. Answering that needs adapters which are correct
# in every respect but one, so that a FAIL is attributable to the violation
# rather than to the fixture being a stub -- which is why the defect is a flag
# on a shared, conformant implementation rather than nine hand-written broken
# servers that could each be broken in unintended ways as well.
#
# `python -m plugins.conformance plugins/conformance/fixtures/conformant`
# passes every applicable check; each sibling directory sets exactly one flag
# below and must fail exactly the check that covers it.
#
# Standard library only, and no dependency on `_shared`: a fixture that
# imported the real implementation would test that implementation, not the kit.
# Licensed under the MIT License. See LICENSE for details.
"""A switchably-broken reference adapter for testing the conformance kit."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PROTOCOL_VERSION = 1


@dataclass
class Defects:
    """One violation class per flag. The conformant fixture sets none."""

    #: /health reports a protocol number the host refuses to route to.
    wrong_protocol: bool = False
    #: /health and /capabilities report an id the manifest does not declare.
    plugin_id_mismatch: bool = False
    #: Binds every interface rather than loopback (invariant 1).
    bind_all_interfaces: bool = False
    #: Ignores --port and listens on a fixed one of its own.
    fixed_port: bool = False
    #: The weight hook writes its error envelope to stderr only.
    envelope_on_stderr: bool = False
    #: Emits mask RLE that starts with a foreground run, no leading zero.
    rle_starts_foreground: bool = False
    #: Writes absolute output paths into result.json.
    absolute_output_paths: bool = False
    #: Emits one stdout line carrying both `ok` and `progress`.
    ambiguous_stdout: bool = False
    #: Uses an error code outside the protocol's enum.
    bad_error_code: bool = False
    #: Emits progress lines that are not the section 4 format.
    malformed_progress: bool = False
    #: Writes no result.json at all when a one-shot run fails.
    no_result_json: bool = False
    #: Refuses /session/open although /health reports ready.
    session_refuses_open: bool = False
    #: Accepts any --task and any input, succeeding on nonsense.
    oneshot_accepts_anything: bool = False
    #: Emits mask RLE whose runs do not sum to width*height.
    rle_bad_length: bool = False
    #: The weight hook rejects the section 4b flags as unrecognized.
    weight_hook_rejects_flags: bool = False
    #: A `manual` weight source downloads instead of verifying.
    manual_downloads: bool = False
    #: Refuses /session/close for a session_id it just issued.
    session_close_rejects: bool = False


# The probe slice the kit sends is 64x64 and its foreground prompt lands at
# pixel (24, 24). A stub cannot segment, so it returns a fixed rectangle
# containing that pixel -- a correct answer for the kit's fixed input, which is
# all the RLE phase check needs.
#
# The rectangle is anchored at the origin deliberately: a mask whose first
# pixel is foreground is exactly the case section 5 covers with "a leading
# zero-length run expresses a mask that starts as foreground", so the fixture's
# violation can be the literal one -- dropping that leading zero.
MASK_SIZE = 64
BLOCK = (0, 0, 40, 40)


def _block_mask() -> list[bool]:
    x0, y0, x1, y1 = BLOCK
    return [y0 <= y < y1 and x0 <= x < x1
            for y in range(MASK_SIZE) for x in range(MASK_SIZE)]


def encode_rle(flat: list[bool], starts_foreground: bool = False) -> list[int]:
    """Section 5 run lengths: row-major, alternating, background first.

    With `starts_foreground` the encoder drops the leading zero-length run, so
    its runs begin with foreground. That is the violation, and it is worth
    being precise about why it is dangerous rather than merely wrong: the
    payload stays well-formed, `width` and `height` still describe the grid,
    and the runs still sum to width*height. Nothing is detectably malformed.
    The host infers foreground from run parity alone, with no marker in the
    data, so it decodes the exact complement of the intended mask and renders
    it without raising.
    """
    runs: list[int] = []
    expecting = False
    current = 0
    for pixel in flat:
        if bool(pixel) == expecting:
            current += 1
        else:
            runs.append(current)
            expecting = bool(pixel)
            current = 1
    if current or runs:
        runs.append(current)
    if starts_foreground and runs and runs[0] == 0:
        return runs[1:]
    if starts_foreground:
        # The mask happens to start with background; shift the phase the other
        # way so the first run is still read as foreground by the host.
        return [0, *runs]
    return runs


def emit_progress(progress: float, message: str,
                  defects: "Defects | None" = None) -> None:
    if defects is not None and defects.malformed_progress:
        # Section 4 says `{"progress": <0-1 number>, "message": <string>}`.
        # A percentage in a string satisfies neither, and the host's parser
        # reads it as a progress line all the same -- so the install bar jumps
        # to a value it cannot interpret rather than failing visibly.
        sys.stdout.write(json.dumps(
            {"progress": f"{progress * 100:.0f}%", "message": message}) + "\n")
        sys.stdout.flush()
        return
    sys.stdout.write(json.dumps({"progress": round(float(progress), 4),
                                 "message": message}) + "\n")
    sys.stdout.flush()


def error_payload(code: str, message: str, recoverable: bool = True) -> dict:
    return {"ok": False,
            "error": {"code": code, "message": message, "recoverable": recoverable}}


# ---------------------------------------------------------------------------
# Weight hook (section 4b)
# ---------------------------------------------------------------------------


def run_install(argv: list[str], defects: Defects, manual: bool = False) -> int:
    parser = argparse.ArgumentParser(description="Stub weight installer.")
    parser.add_argument("--install-weights", action="store_true", required=True)
    parser.add_argument("--weight-id", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--dest", required=True)
    if not defects.weight_hook_rejects_flags:
        # THE VIOLATION, when set: an adapter that only tolerates the subset of
        # section 4b flags its own manifest happens to use breaks the moment
        # that manifest gains a `--repo`, a `--revision` or a `--task`.
        parser.add_argument("--repo", default=None)
        parser.add_argument("--revision", default=None)
        parser.add_argument("--task", default=None)
    args = parser.parse_args(argv)
    if defects.weight_hook_rejects_flags:
        args.repo = args.task = None

    dest = Path(args.dest).expanduser().resolve()
    dest.mkdir(parents=True, exist_ok=True)

    if defects.ambiguous_stdout:
        # Both keys on one line: the host cannot tell an envelope from a
        # progress line, which is how a licence gate degrades into "exit 1".
        sys.stdout.write(json.dumps(
            {"progress": 0.0, "ok": True, "message": "Checking"}) + "\n")
        sys.stdout.flush()
    else:
        emit_progress(0.0, f"Checking for '{args.weight_id}'", defects)

    if manual and args.source == "manual":
        expected = dest / "stub-checkpoint.pt"
        if defects.manual_downloads:
            # THE VIOLATION: section 4b forbids a manual source from attempting
            # a download at all. The gate exists because a human must accept
            # terms under a named account; an adapter that fetches the file
            # anyway routes around the one check the store enforces.
            import urllib.request

            urllib.request.urlopen("http://weights.invalid/stub.pt", timeout=5)
            return 0
        if expected.is_file():
            emit_progress(1.0, "Weights are ready", defects)
            return 0
        return _fail(
            defects,
            "license_required",
            f"The stub checkpoint is gated. Accept the terms at "
            f"https://example.invalid/terms, then place the checkpoint at "
            f"{expected}.")

    if args.source not in ("huggingface", "stub"):
        return _fail(defects, "bad_input",
                     f"this adapter does not know the '{args.source}' weight source")
    if args.weight_id != "stub-weight":
        return _fail(defects, "bad_input",
                     f"unknown weight id '{args.weight_id}'")

    # A real adapter downloads here. The stub writes the file it promises,
    # because exit 0 must mean the files are present under --dest.
    (dest / "stub-weight.bin").write_bytes(b"stub")
    emit_progress(1.0, f"Weights for '{args.weight_id}' are ready", defects)
    return 0


def _fail(defects: Defects, code: str, message: str) -> int:
    if defects.bad_error_code:
        code = "weights_missing"  # not in the section 3 enum
    payload = error_payload(code, message)
    if defects.envelope_on_stderr:
        # stderr only. The host reads the code from stdout, so license_required
        # never reaches the store's gate and the user sees a bare exit status.
        sys.stderr.write(json.dumps(payload) + "\n")
        sys.stderr.flush()
        return 1
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()
    sys.stderr.write(f"ERROR: {message}\n")
    return 1


# ---------------------------------------------------------------------------
# HTTP surface (section 3)
# ---------------------------------------------------------------------------


def serve(plugin_id: str, tasks: list[dict], defects: Defects,
          argv: list[str] | None = None, session: bool = False) -> int:
    parser = argparse.ArgumentParser(description=f"Stub adapter {plugin_id}.")
    if not defects.fixed_port:
        parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--log-level", default="info")
    args = parser.parse_args(argv)

    port = 18999 if defects.fixed_port else args.port
    if defects.bind_all_interfaces:
        bind = "0.0.0.0"
    else:
        if args.host not in ("127.0.0.1", "localhost", "::1"):
            raise SystemExit("refusing to bind a non-loopback address")
        bind = args.host

    reported_id = f"{plugin_id}-typo" if defects.plugin_id_mismatch else plugin_id
    protocol = 2 if defects.wrong_protocol else PROTOCOL_VERSION
    sessions: dict[str, float] = {}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_: object) -> None:
            pass

        def _send(self, payload: dict, status: int = 200) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            if not length:
                return {}
            try:
                parsed = json.loads(self.rfile.read(length))
            except ValueError:
                return {}
            return parsed if isinstance(parsed, dict) else {}

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            if self.path == "/health":
                self._send({"status": "ready", "plugin_id": reported_id,
                            "protocol": protocol, "memory_mb": 12.0})
            elif self.path == "/capabilities":
                self._send({"plugin_id": reported_id, "protocol": protocol,
                            "tasks": tasks})
            else:
                self._send(error_payload("bad_input", f"no route {self.path}"), 404)

        def do_POST(self) -> None:  # noqa: N802
            body = self._body()
            if session and self.path == "/session/open":
                if defects.session_refuses_open:
                    # Reports ready, then refuses to open. The host has no way
                    # to distinguish this from a plugin that never loaded.
                    self._send(error_payload(
                        "internal", "sessions are unavailable"))
                    return
                session_id = f"s-{len(sessions) + 1:04d}"
                sessions[session_id] = time.time()
                self._send({"ok": True, "session_id": session_id, "encode_ms": 1})
                return
            if session and self.path == "/session/close":
                if defects.session_close_rejects:
                    # Never releases the cached state. The host closes sessions
                    # when the user changes series; an adapter that refuses
                    # accumulates encodings until it exhausts memory.
                    self._send(error_payload(
                        "bad_input", "unknown session_id"))
                    return
                sessions.pop(str(body.get("session_id")), None)
                self._send({"ok": True})
                return
            if self.path.startswith("/task/"):
                task_id = self.path[len("/task/"):]
                known = {task["id"] for task in tasks}
                if task_id not in known:
                    self._send(error_payload(
                        "bad_input", f"unknown task '{task_id}'"), 404)
                    return
                self._send({"ok": True,
                            "outputs": _stub_outputs(tasks, task_id, defects),
                            "elapsed_ms": 1})
                return
            self._send(error_payload("bad_input", f"no route {self.path}"), 404)

    server = ThreadingHTTPServer((bind, port), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def _stub_outputs(tasks: list[dict], task_id: str, defects: Defects) -> dict:
    declared = next((task for task in tasks if task["id"] == task_id), {})
    outputs: dict = {}
    for kind in declared.get("outputs", []):
        if kind == "mask2d":
            runs = encode_rle(_block_mask(), defects.rle_starts_foreground)
            if defects.rle_bad_length:
                # Truncated: the runs no longer sum to width*height, so the
                # host's decoder reads past the end of what was actually
                # encoded and renders a mask with a torn edge.
                runs = runs[:-1]
            outputs["mask2d"] = {
                "width": MASK_SIZE, "height": MASK_SIZE, "rle": runs,
                "label": "stub", "confidence": 0.5,
            }
        elif kind == "text":
            outputs["text"] = "stub response"
        elif kind == "bbox":
            outputs["bbox"] = [{"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2,
                                "label": "stub", "confidence": 0.5}]
        elif kind == "metrics":
            outputs["metrics"] = {"stub": 1.0}
    return outputs


# ---------------------------------------------------------------------------
# One-shot surface (sections 4, 4c)
# ---------------------------------------------------------------------------


def run_oneshot(tasks: list[dict], defects: Defects,
                argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Stub one-shot adapter.")
    if defects.oneshot_accepts_anything:
        # THE VIOLATION: no `choices`, so any task id is accepted and the run
        # reports success for work the manifest never declared.
        parser.add_argument("--task", required=True)
    else:
        parser.add_argument("--task", required=True,
                            choices=[task["id"] for task in tasks])
    parser.add_argument("--out", required=True)
    for kind in ("slice2d", "series3d", "roi", "points", "box", "text"):
        parser.add_argument(f"--input-{kind}", dest=f"input_{kind}", default=None)
    parser.add_argument("--opt-fast", dest="opt_fast", default=None)
    args = parser.parse_args(argv)

    out_dir = Path(args.out).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    result_path = out_dir / "result.json"

    emit_progress(0.1, "Starting", defects)

    series = args.input_series3d
    if series and not os.path.isdir(series) and defects.oneshot_accepts_anything:
        # Succeeds on an input that does not exist.
        series = None
    if series and not os.path.isdir(series):
        # Section 4c: result.json is written on failure too, because the
        # adapter's own message is more actionable than an exit code.
        payload = error_payload("bad_input", f"series directory not found: {series}")
        if defects.bad_error_code:
            payload["error"]["code"] = "no_such_series"
        if not defects.no_result_json:
            # Section 4c: the host reads result.json whenever it exists,
            # including after a non-zero exit, because the adapter's own
            # message is more actionable than an exit code. Omitting it leaves
            # the user with "the plugin failed" and nothing else.
            result_path.write_text(json.dumps(payload, indent=2) + "\n")
        sys.stdout.write(json.dumps(payload) + "\n")
        sys.stdout.flush()
        return 1

    produced = out_dir / "stub-segmentation.dcm"
    produced.write_bytes(b"stub")
    location = str(produced) if defects.absolute_output_paths else produced.name
    emit_progress(1.0, "Complete", defects)
    result_path.write_text(json.dumps(
        {"ok": True, "outputs": {"seg3d": location, "metrics": {"stub": 1.0}},
         "elapsed_ms": 1}, indent=2) + "\n")
    return 0
