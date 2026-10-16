#!/usr/bin/env python3
# exp6_latency.py
# OpenDicomViewer
#
# Experiment 6: end-to-end latency on real hardware, per engine and per stage.
#
# Every timing in experiments 1-5 is either a CPU-only sandbox figure or a
# native run on a loaded machine (EVALUATION.md section 1). This experiment
# closes that gap. It drives each engine the way the host does -- spawn the
# process, poll /health until ready, send task requests over loopback HTTP,
# stop it -- and times every step from outside the process. exp3's `--bench`
# mode times stages from inside the adapter; this times what the user waits
# through, which also includes interpreter startup, imports, HTTP and JSON.
#
# What a row means:
#
#   <engine>/c<n>                      one cold start of a server engine:
#                                      spawn -> first /health answer -> ready,
#                                      then every request in the plan, then stop
#   totalsegmentator/<task>/<series>/r<n>
#                                      one one-shot invocation exactly as the
#                                      host spawns it, with per-stage times
#                                      taken from its progress lines
#
# Conditions are part of the measurement. Every row records the load average
# when it started, whether the idle gate (--max-load) was met and how long it
# waited, the power source, Low Power Mode and the thermal state. The October
# 2026 TotalSegmentator wall times were taken at load averages of 4.2-32.9 and
# could only be called indicative; a row that fails the gate here is kept and
# flagged rather than dropped.
#
# Memory is not measured here. exp3_totalseg_lowmem.py owns process-tree peak
# memory, and sampling it here would perturb the timings this file is for.
# Licensed under the MIT License. See LICENSE for details.
"""End-to-end latency of every engine, driven through the plugin protocol."""

from __future__ import annotations

import argparse
import base64
import csv
import json
import os
import re
import secrets
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from harness import CaseResult, Recorder, load_results, machine_profile
from exp3_resources import (
    EvalPaths,
    adapter_environment,
    load_manifest,
    plugin_by_id,
    prepare_slice,
)

EXPERIMENT = "exp6_latency"

# `gemma-builtin` is the AI menu's server (mlx-server/server.py), which is not a
# plugin and speaks its own endpoints; the rest are manifest plugin ids.
SERVER_ENGINES = ("gemma-builtin", "gemma-4-e4b", "sam2", "sam3")
ONESHOT_ENGINE = "totalsegmentator"
ALL_ENGINES = SERVER_ENGINES + (ONESHOT_ENGINE,)

# Fixed so every machine sees the same requests. The ROI is the centre of the
# image; the click positions spread over the soft-tissue region of an axial CT.
ROI = {"x": 0.35, "y": 0.35, "width": 0.3, "height": 0.3}
CLICKS = [(0.50, 0.50), (0.40, 0.45), (0.60, 0.55), (0.45, 0.62), (0.55, 0.40),
          (0.35, 0.55), (0.65, 0.45), (0.50, 0.35)]
GEMMA_TASKS = ("analyze", "detect-abnormalities", "describe-roi")
# Positions in instance order. Mid-series plus two either side of it, away from
# the air at the ends of the scan.
SLICE_FRACTIONS = (0.35, 0.5, 0.65)


# ---------------------------------------------------------------------------
# Conditions
# ---------------------------------------------------------------------------


def _command_output(argv: list[str]) -> str | None:
    try:
        return subprocess.run(argv, capture_output=True, text=True,
                              timeout=15).stdout
    except Exception:  # noqa: BLE001 -- absence is recorded, not fatal
        return None


def conditions() -> dict[str, Any]:
    """What the machine was doing when a case started."""
    out: dict[str, Any] = {}
    try:
        out["load_avg"] = [round(v, 2) for v in os.getloadavg()]
    except OSError:
        out["load_avg"] = None
    batt = _command_output(["pmset", "-g", "batt"]) or ""
    match = re.search(r"Now drawing from '([^']+)'", batt)
    out["power_source"] = match.group(1) if match else None
    settings = _command_output(["pmset", "-g"]) or ""
    match = re.search(r"lowpowermode\s+(\d)", settings)
    out["low_power_mode"] = (match.group(1) == "1") if match else None
    therm = _command_output(["pmset", "-g", "therm"]) or ""
    # On Apple Silicon this is usually a sentence saying no warning was
    # recorded; any other text is the warning itself. Keep it verbatim.
    out["thermal"] = " ".join(line.strip() for line in therm.splitlines()
                              if line.strip()) or None
    return out


def wait_for_idle(max_load: float | None, max_wait_s: float) -> dict[str, Any]:
    """Block until the 1-minute load average falls to `max_load`, or give up.

    The gate never skips a case. A case that ran without the gate being met is
    recorded with `met: false` and can be excluded at analysis time, which is
    a decision for the reader of the data, not for this script.
    """
    if max_load is None:
        return {"threshold": None, "met": None, "waited_s": 0.0}
    started = time.monotonic()
    while True:
        load1 = os.getloadavg()[0]
        if load1 <= max_load:
            return {"threshold": max_load, "met": True,
                    "waited_s": round(time.monotonic() - started, 1)}
        if time.monotonic() - started >= max_wait_s:
            return {"threshold": max_load, "met": False,
                    "waited_s": round(time.monotonic() - started, 1),
                    "load1_at_giveup": round(load1, 2)}
        time.sleep(5)


def purge_file_cache(enabled: bool) -> bool | None:
    """Drop the file cache so a start reads its weights from disk.

    `purge` needs root. With `--purge`, run the script after `sudo -v` so the
    non-interactive `sudo -n` here succeeds; whether it did is recorded on
    every row, because a "cold" start from a warm cache is a different number.
    """
    if not enabled:
        return None
    proc = subprocess.run(["sudo", "-n", "/usr/sbin/purge"],
                          capture_output=True, text=True)
    return proc.returncode == 0


def host_tag(profile: dict) -> str:
    """A filename-safe machine label, e.g. `apple-m5-max-128gb`."""
    chip = profile.get("chip") or profile.get("machine") or "unknown"
    memory = profile.get("memory_reported") or ""
    raw = f"{chip}-{memory}".lower().replace(" ", "-")
    return re.sub(r"[^a-z0-9-]+", "", raw).strip("-")


# ---------------------------------------------------------------------------
# Environment check
# ---------------------------------------------------------------------------

# The locks are resolved for the bundled CPython 3.11 (PLUGIN_PROTOCOL.md
# section 7). A timing taken under any other interpreter or package set is a
# timing of a stack no user runs.
LOCKED_PYTHON = "3.11"

_INSTALLED_SNIPPET = (
    "import json, platform\n"
    "from importlib import metadata\n"
    "print(json.dumps({'python': platform.python_version(), 'packages': "
    "{d.metadata['Name'].lower().replace('_', '-'): d.version "
    "for d in metadata.distributions()}}))\n"
)


def locked_pins(requirements: Path) -> dict[str, str]:
    pins = {}
    for line in requirements.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        match = re.match(r"^([A-Za-z0-9_.\-\[\]]+)==([^\s;]+)", line)
        if match:
            name = re.sub(r"\[.*\]", "", match.group(1)).lower().replace("_", "-")
            pins[name] = match.group(2)
    return pins


def check_environment(python: Path, requirements: Path) -> dict[str, Any]:
    """Compare an engine's interpreter and packages with its lock."""
    if not python.exists():
        return {"ok": False, "python": None, "drift": {},
                "error": f"no interpreter at {python}"}
    proc = subprocess.run([str(python), "-I", "-c", _INSTALLED_SNIPPET],
                          capture_output=True, text=True, timeout=120)
    try:
        installed = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"ok": False, "python": None, "drift": {},
                "error": f"could not list packages: {proc.stderr.strip()[-300:]}"}
    drift = {}
    for name, version in locked_pins(requirements).items():
        have = installed["packages"].get(name)
        if have != version:
            drift[name] = {"locked": version, "installed": have}
    python_ok = installed["python"].startswith(LOCKED_PYTHON + ".")
    return {"ok": python_ok and not drift, "python": installed["python"],
            "python_ok": python_ok, "lock": str(requirements.name),
            "drift": drift}


def engine_environment(engine: str, repo: Path, paths: EvalPaths, manifest: dict,
                       builtin_python: Path | None) -> tuple[Path | None, Path]:
    """(interpreter, lock file) an engine runs under."""
    if engine == "gemma-builtin":
        return builtin_python, repo / "mlx-server/requirements.txt"
    plugin = plugin_by_id(manifest, engine)
    return (paths.venv_python(engine),
            repo / "plugins" / plugin["adapter_dir"] / plugin["requirements"])


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def http_json(method: str, url: str, token: str, body: dict | None = None,
              timeout: float = 600.0) -> tuple[int, dict | None, float]:
    """One request. Returns (status, parsed body or None, client-side ms)."""
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("X-ODV-Token", token)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            status = response.status
    except urllib.error.HTTPError as exc:
        raw, status = exc.read(), exc.code
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    try:
        parsed = json.loads(raw.decode()) if raw else None
    except (json.JSONDecodeError, UnicodeDecodeError):
        parsed = None
    return status, parsed, elapsed_ms


class ServerProcess:
    """A resident engine under test, started and stopped as the host does."""

    def __init__(self, argv: list[str], env: dict[str, str], cwd: Path,
                 log_path: Path, port: int, token: str):
        self.argv, self.env, self.cwd = argv, env, cwd
        self.log_path, self.port, self.token = log_path, port, token
        self.proc: subprocess.Popen | None = None
        self.spawned_at = 0.0

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def start(self) -> None:
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        log = open(self.log_path, "w")
        self.spawned_at = time.perf_counter()
        # Own process group, so stop() also reaches anything the server forks.
        self.proc = subprocess.Popen(self.argv, cwd=str(self.cwd), env=self.env,
                                     stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
        log.close()

    def wait_ready(self, timeout: float) -> dict[str, Any]:
        """Poll /health. Returns seconds from spawn to first answer and to ready."""
        first_answer = None
        last: dict | None = None
        deadline = self.spawned_at + timeout
        while time.perf_counter() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                raise RuntimeError(
                    f"server exited with {self.proc.returncode} before ready "
                    f"(log: {self.log_path})")
            try:
                status, body, _ = http_json("GET", f"{self.base}/health",
                                            self.token, timeout=5)
            except (urllib.error.URLError, ConnectionError, TimeoutError, OSError):
                time.sleep(0.05)
                continue
            now = time.perf_counter()
            if first_answer is None:
                first_answer = now - self.spawned_at
            last = body or {}
            if status == 200 and last.get("status") == "ready":
                return {"spawn_to_first_health_s": round(first_answer, 3),
                        "spawn_to_ready_s": round(now - self.spawned_at, 3),
                        "health": last}
            if last.get("status") == "error":
                raise RuntimeError(f"server reported error: {last}")
            time.sleep(0.1)
        raise TimeoutError(f"not ready after {timeout}s; last health: {last}")

    def stop(self) -> float:
        """SIGTERM the group, escalate after 15 s. Returns seconds to exit."""
        if self.proc is None or self.proc.poll() is not None:
            return 0.0
        t0 = time.perf_counter()
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait()
        except ProcessLookupError:
            pass
        return round(time.perf_counter() - t0, 3)


# ---------------------------------------------------------------------------
# Engine set-up
# ---------------------------------------------------------------------------


def host_environment(base: dict[str, str], weights_root: Path | None,
                     token: str | None) -> dict[str, str]:
    """Add what PLUGIN_PROTOCOL.md section 4d says the host provides."""
    env = dict(base)
    if weights_root is not None:
        env["ODV_WEIGHTS_DIR"] = str(weights_root)
    env["ODV_PARENT_PID"] = str(os.getpid())
    env["HF_HUB_OFFLINE"] = "1"
    env["TRANSFORMERS_OFFLINE"] = "1"
    if token is not None:
        env["ODV_PLUGIN_TOKEN"] = token
    return env


def build_server(engine: str, repo: Path, paths: EvalPaths, manifest: dict,
                 builtin_python: Path | None, workdir: Path,
                 cycle: int) -> ServerProcess:
    port, token = free_port(), secrets.token_hex(32)
    log_path = workdir / "logs" / f"{engine}-c{cycle}.log"
    if engine == "gemma-builtin":
        if builtin_python is None:
            raise RuntimeError("--builtin-python is required for gemma-builtin")
        env = host_environment(dict(os.environ), None, None)
        env.update({"ODV_AI_PORT": str(port), "ODV_AI_TOKEN": token,
                    "PYTHONUNBUFFERED": "1",
                    # The viewer points the built-in server at the Gemma
                    # plugin's copy of the same pinned model when one exists.
                    "ODV_MODEL_DIR": str(paths.weight_directory(
                        "gemma-4-e4b", "gemma-4-e4b-it-4bit"))})
        server_dir = repo / "mlx-server"
        return ServerProcess([str(builtin_python), str(server_dir / "server.py")],
                             env, server_dir, log_path, port, token)

    plugin = plugin_by_id(manifest, engine)
    entry = repo / "plugins" / plugin["adapter_dir"] / plugin["entry"]
    env = host_environment(adapter_environment(paths, engine, repo),
                           paths.weights_root(engine), token)
    argv = [str(paths.venv_python(engine)), str(entry), "--port", str(port)]
    return ServerProcess(argv, env, entry.parent, log_path, port, token)


def gemma_requests(engine: str, b64: str) -> list[tuple[str, str, dict]]:
    """(task label, path, body) for every Gemma task, in either API."""
    if engine == "gemma-builtin":
        return [
            ("analyze", "/analyze",
             {"image": b64, "mode": "clinical",
              "window_info": {"modality": "CT", "window_center": 40.0,
                              "window_width": 400.0}}),
            ("detect-abnormalities", "/detect-abnormalities",
             {"image": b64, "modality": "CT"}),
            ("describe-roi", "/describe-roi",
             {"image": b64, "roi": ROI, "context": "CT"}),
        ]
    return [
        ("analyze", "/task/analyze",
         {"inputs": {"slice2d": b64, "text": "CT"}, "options": {"mode": "clinical"}}),
        ("detect-abnormalities", "/task/detect-abnormalities",
         {"inputs": {"slice2d": b64, "text": "CT"}}),
        ("describe-roi", "/task/describe-roi",
         {"inputs": {"slice2d": b64, "roi": ROI, "text": "CT"}}),
    ]


def summarise_output(body: dict | None) -> dict[str, Any]:
    """Enough of a response to show it was real output, not an empty 200."""
    if not isinstance(body, dict):
        return {}
    outputs = body.get("outputs", body)
    out: dict[str, Any] = {}
    for key in ("bbox", "bounding_boxes", "regions"):
        if isinstance(outputs.get(key), list):
            out["boxes"] = len(outputs[key])
    for key in ("text", "description"):
        if isinstance(outputs.get(key), str):
            out["text_chars"] = len(outputs[key])
    mask = outputs.get("mask2d")
    if isinstance(mask, list) and mask:
        mask = mask[0]
    if isinstance(mask, dict) and isinstance(mask.get("rle"), list):
        out["mask_foreground_px"] = int(sum(mask["rle"][1::2]))
    if "elapsed_ms" in body:
        out["server_ms"] = body["elapsed_ms"]
    if body.get("ok") is False or "detail" in body:
        out["error"] = body.get("error") or body.get("detail")
    return out


def response_ok(status: int, body: dict | None, engine: str) -> bool:
    if status != 200 or body is None:
        return False
    if engine == "gemma-builtin":
        return True
    return bool(body.get("ok"))


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------


def run_server_cycle(engine: str, cycle: int, repo: Path, paths: EvalPaths,
                     manifest: dict, builtin_python: Path | None,
                     slices: list[tuple[str, Path]], args, workdir: Path
                     ) -> CaseResult:
    case_id = f"{engine}/c{cycle}"
    gate = wait_for_idle(args.max_load, args.idle_wait)
    purged = purge_file_cache(args.purge)
    metrics: dict[str, Any] = {"cycle": cycle, "idle_gate": gate,
                               "purged": purged, "conditions": conditions(),
                               "env_check": args.env_check, "requests": []}
    started = time.perf_counter()
    server = build_server(engine, repo, paths, manifest, builtin_python,
                          workdir, cycle)
    metrics["log"] = str(server.log_path.relative_to(workdir))
    error = None
    try:
        server.start()
        metrics.update(server.wait_ready(args.ready_timeout))
        health = metrics.pop("health")
        metrics["health_memory_mb"] = (health.get("memory_mb")
                                       or health.get("memory_usage_mb"))
        first = True
        for slice_label, png in slices:
            b64 = base64.b64encode(png.read_bytes()).decode("ascii")
            if engine in ("sam2", "sam3"):
                first = run_sam_slice(server, engine, slice_label, b64, args,
                                      metrics["requests"], first)
            else:
                plan = gemma_requests(engine, b64)
                plan = [p for p in plan if p[0] in args.gemma_tasks]
                for label, path, body in plan:
                    status, reply, ms = http_json("POST", server.base + path,
                                                  server.token, body,
                                                  timeout=args.request_timeout)
                    metrics["requests"].append({
                        "kind": "task", "task": label, "slice": slice_label,
                        "first_after_ready": first, "client_ms": round(ms, 1),
                        "ok": response_ok(status, reply, engine),
                        "http_status": status, **summarise_output(reply)})
                    first = False
        failed = [r for r in metrics["requests"] if not r["ok"]]
        if failed:
            error = f"{len(failed)} request(s) failed; first: {failed[0]}"
    except Exception as exc:  # noqa: BLE001 -- a failed cycle is a recorded result
        error = f"{type(exc).__name__}: {exc}"
    finally:
        metrics["stop_s"] = server.stop()

    return CaseResult(
        experiment=EXPERIMENT, case_id=case_id, ok=error is None,
        wall_s=round(time.perf_counter() - started, 3), metrics=metrics,
        error=error,
        notes=["timed from outside the process, through the same HTTP "
               "contract the host uses; includes interpreter start, imports, "
               "model load, HTTP and JSON"])


def run_sam_slice(server: ServerProcess, engine: str, slice_label: str, b64: str,
                  args, requests: list[dict], first: bool) -> bool:
    """Open a session on one slice, click `--prompts` times, close it."""
    status, reply, ms = http_json("POST", f"{server.base}/session/open",
                                  server.token, {"inputs": {"slice2d": b64}},
                                  timeout=args.request_timeout)
    ok = status == 200 and bool(reply and reply.get("ok"))
    requests.append({"kind": "session_open", "slice": slice_label,
                     "first_after_ready": first, "client_ms": round(ms, 1),
                     "server_encode_ms": (reply or {}).get("encode_ms"),
                     "ok": ok, "http_status": status})
    if not ok:
        return False
    session_id = reply["session_id"]
    for index, (x, y) in enumerate(CLICKS[:args.prompts]):
        body = {"session_id": session_id,
                "inputs": {"points": [{"x": x, "y": y, "label": 1}]}}
        status, out, ms = http_json("POST", f"{server.base}/task/prompt-mask",
                                    server.token, body,
                                    timeout=args.request_timeout)
        requests.append({"kind": "prompt", "slice": slice_label,
                         "prompt_index": index, "client_ms": round(ms, 1),
                         "ok": response_ok(status, out, engine),
                         "http_status": status, **summarise_output(out)})
    status, _, ms = http_json("POST", f"{server.base}/session/close",
                              server.token, {"session_id": session_id})
    requests.append({"kind": "session_close", "slice": slice_label,
                     "client_ms": round(ms, 1), "ok": status == 200,
                     "http_status": status})
    return False


def stage_series(series_dir: Path, workdir: Path) -> Path:
    """Symlink one series' files into a private directory, as the host does
    (PLUGIN_PROTOCOL.md section 2, "series3d holds one series")."""
    staged = Path(tempfile.mkdtemp(prefix="series-", dir=workdir))
    for path in sorted(series_dir.iterdir()):
        if path.is_file() and path.suffix.lower() == ".dcm":
            (staged / path.name).symlink_to(path.resolve())
    return staged


def run_oneshot(task: str, series_dir: Path, rep: int, repo: Path,
                paths: EvalPaths, manifest: dict, args, workdir: Path
                ) -> CaseResult:
    case_id = f"{ONESHOT_ENGINE}/{task}/{series_dir.name}/r{rep}"
    gate = wait_for_idle(args.max_load, args.idle_wait)
    purged = purge_file_cache(args.purge)
    metrics: dict[str, Any] = {"task": task, "series": series_dir.name,
                               "rep": rep, "idle_gate": gate, "purged": purged,
                               "conditions": conditions(),
                               "env_check": args.env_check}
    plugin = plugin_by_id(manifest, ONESHOT_ENGINE)
    entry = repo / "plugins" / plugin["adapter_dir"] / plugin["entry"]
    env = host_environment(adapter_environment(paths, ONESHOT_ENGINE, repo),
                           paths.weights_root(ONESHOT_ENGINE), None)
    staged = stage_series(series_dir, workdir)
    out_dir = Path(tempfile.mkdtemp(prefix="out-", dir=workdir))
    metrics["input_slice_count"] = sum(1 for _ in staged.iterdir())
    argv = [str(paths.venv_python(ONESHOT_ENGINE)), str(entry), "--task", task,
            "--out", str(out_dir), "--input-series3d", str(staged)]
    # The host passes every declared option at its default.
    for name, spec in (next(t for t in plugin["tasks"] if t["id"] == task)
                       .get("options") or {}).items():
        default = spec.get("default")
        if default is not None:
            value = str(default).lower() if isinstance(default, bool) else str(default)
            argv += [f"--opt-{name}", value]
    metrics["argv_options"] = argv[argv.index(str(staged)) + 1:]

    lines: list[tuple[float, str]] = []
    started = time.perf_counter()
    proc = subprocess.Popen(argv, cwd=str(entry.parent), env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, start_new_session=True)

    def pump() -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            lines.append((time.perf_counter() - started, line.rstrip("\n")))

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    error = None
    try:
        proc.wait(timeout=args.oneshot_timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        error = f"timed out after {args.oneshot_timeout}s"
    reader.join(timeout=10)
    wall = time.perf_counter() - started

    # Stage durations from the progress lines the adapter already emits: each
    # stage runs from its announcement to the next differently-named one, and
    # the last to process exit. Time to the first progress line is interpreter
    # start plus imports -- the per-invocation cost exp3 found invisible to the
    # adapter's own figures.
    progress = []
    for t, line in lines:
        if line.startswith("{"):
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict) and "progress" in row:
                progress.append((t, str(row.get("message", ""))))
    stages: dict[str, float] = {}
    if progress:
        stages["startup_to_first_progress"] = round(progress[0][0], 3)
        for (t, message), nxt in zip(progress, progress[1:] + [(wall, None)]):
            if nxt[1] == message:
                continue
            stages[message] = round(stages.get(message, 0.0) + nxt[0] - t, 3)

    result_path = out_dir / "result.json"
    result = None
    if result_path.is_file():
        try:
            result = json.loads(result_path.read_text())
        except json.JSONDecodeError:
            result = None
    metrics["exit_code"] = proc.returncode
    metrics["result_ok"] = bool(result and result.get("ok"))
    if result and result.get("ok"):
        metrics["adapter_elapsed_ms"] = result.get("elapsed_ms")
        seg = result.get("outputs", {}).get("seg3d")
        if seg and (out_dir / seg).is_file():
            metrics["seg_bytes"] = (out_dir / seg).stat().st_size
    if error is None and not (proc.returncode == 0 and metrics["result_ok"]):
        error = (f"exit {proc.returncode}; result: "
                 f"{(result or {}).get('error', 'no result.json')}")
    if args.keep_outputs:
        metrics["out_dir"] = str(out_dir)
    else:
        subprocess.run(["rm", "-rf", str(out_dir), str(staged)])

    return CaseResult(
        experiment=EXPERIMENT, case_id=case_id, ok=error is None,
        wall_s=round(wall, 3), stages_s=stages, metrics=metrics, error=error,
        notes=["spawned exactly as the host spawns a one-shot; TotalSegmentator "
               "ships CPU-only, so these are CPU timings by design"])


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------


def _describe(values: list[float]) -> dict[str, Any]:
    values = sorted(values)
    if not values:
        return {}
    if len(values) >= 2:
        q1, median, q3 = statistics.quantiles(values, n=4, method="inclusive")
    else:
        q1 = median = q3 = values[0]
    return {"n": len(values), "median": round(median, 3), "q1": round(q1, 3),
            "q3": round(q3, 3), "min": round(values[0], 3),
            "max": round(values[-1], 3)}


def summary_rows(rows: list[dict], gated_only: bool) -> list[dict]:
    """Median (IQR) per engine and measure. Failed cases are excluded from
    timings and counted separately, so a summary never hides them."""
    series: dict[tuple[str, str, str], list[float]] = {}
    failures: dict[str, int] = {}
    drifted: dict[str, int] = {}

    def add(engine: str, measure: str, unit: str, value: Any) -> None:
        if isinstance(value, (int, float)):
            series.setdefault((engine, measure, unit), []).append(float(value))

    for row in rows:
        engine = row["case_id"].split("/")[0]
        if not row.get("ok"):
            failures[engine] = failures.get(engine, 0) + 1
            continue
        m = row.get("metrics", {})
        if not (m.get("env_check") or {}).get("ok"):
            # A stack that differs from the lock is not the shipped stack.
            drifted[engine] = drifted.get(engine, 0) + 1
            continue
        if gated_only and (m.get("idle_gate") or {}).get("met") is False:
            continue
        if engine == ONESHOT_ENGINE:
            task = m.get("task")
            add(engine, f"{task}: wall", "s", row.get("wall_s"))
            for stage, value in (row.get("stages_s") or {}).items():
                add(engine, f"{task}: {stage}", "s", value)
            continue
        add(engine, "spawn to first /health", "s", m.get("spawn_to_first_health_s"))
        add(engine, "spawn to ready", "s", m.get("spawn_to_ready_s"))
        add(engine, "stop", "s", m.get("stop_s"))
        requests = m.get("requests", [])
        for r in requests:
            if not r.get("ok"):
                continue
            if r["kind"] == "task":
                which = "first" if r.get("first_after_ready") else "warm"
                add(engine, f"{r['task']} ({which})", "ms", r["client_ms"])
            elif r["kind"] == "session_open":
                which = "first" if r.get("first_after_ready") else "warm"
                add(engine, f"session open ({which})", "ms", r["client_ms"])
            elif r["kind"] == "prompt":
                which = "first click" if r.get("prompt_index") == 0 else "later clicks"
                add(engine, f"prompt ({which})", "ms", r["client_ms"])
        # What a user waits for on the first click of a slice: the encode and
        # the first decode together.
        opens = {r["slice"]: r["client_ms"] for r in requests
                 if r["kind"] == "session_open" and r.get("ok")}
        for r in requests:
            if r["kind"] == "prompt" and r.get("prompt_index") == 0 and r.get("ok") \
                    and r["slice"] in opens:
                add(engine, "open + first click", "ms", opens[r["slice"]] + r["client_ms"])

    out = []
    for (engine, measure, unit), values in sorted(series.items()):
        out.append({"engine": engine, "measure": measure, "unit": unit,
                    **_describe(values)})
    for engine, count in sorted(failures.items()):
        out.append({"engine": engine, "measure": "failed cases", "unit": "count",
                    "n": count})
    for engine, count in sorted(drifted.items()):
        out.append({"engine": engine, "measure": "excluded: env differs from lock",
                    "unit": "count", "n": count})
    return out


def write_summary(results: Path, csv_path: Path, gated_only: bool) -> None:
    header, rows = load_results(results)
    table = summary_rows(rows, gated_only)
    fields = ["engine", "measure", "unit", "n", "median", "q1", "q3", "min", "max"]
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in table:
            writer.writerow({k: row.get(k) for k in fields})
    machine = header.get("machine", {})
    print(f"\n{machine.get('chip')} · {machine.get('memory_reported')} · "
          f"{len(rows)} cases{' (idle-gated only)' if gated_only else ''}")
    for row in table:
        if row["unit"] == "count":
            print(f"  {row['engine']:18s} {row['measure']}: {row['n']}")
        else:
            print(f"  {row['engine']:18s} {row['measure']:38s} "
                  f"{row['median']:>10.3f} {row['unit']:2s} "
                  f"(IQR {row['q1']:.3f}-{row['q3']:.3f}, n={row['n']})")
    print(f"summary: {csv_path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    repo_default = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=repo_default)
    parser.add_argument("--env-root", type=Path, default=None,
                        help="Plugin environments (default: <repo>/.eval/plugin-envs, "
                             "as created by exp3_resources.py)")
    parser.add_argument("--series", type=Path, nargs="+", default=None,
                        help="DICOM series directories (one series each)")
    parser.add_argument("--engines", default=",".join(ALL_ENGINES),
                        help=f"Comma-separated subset of {', '.join(ALL_ENGINES)}")
    parser.add_argument("--builtin-python", type=Path, default=None,
                        help="Interpreter with mlx-server/requirements.txt "
                             "installed (needed for gemma-builtin)")
    parser.add_argument("--cycles", type=int, default=5,
                        help="Cold starts per server engine")
    parser.add_argument("--slices-per-series", type=int, default=len(SLICE_FRACTIONS),
                        help=f"Slices per series, at fractions {SLICE_FRACTIONS}")
    parser.add_argument("--gemma-tasks", default=",".join(GEMMA_TASKS))
    parser.add_argument("--prompts", type=int, default=5,
                        help=f"Clicks per SAM session (max {len(CLICKS)})")
    parser.add_argument("--oneshot-tasks", default="total,total_lowmem")
    parser.add_argument("--oneshot-reps", type=int, default=3,
                        help="Runs per one-shot task and series")
    parser.add_argument("--max-load", type=float, default=2.0,
                        help="Idle gate: wait for this 1-minute load average "
                             "before each case (negative disables)")
    parser.add_argument("--idle-wait", type=float, default=600.0,
                        help="Longest wait for the idle gate, seconds")
    parser.add_argument("--purge", action="store_true",
                        help="Drop the file cache before each case (run `sudo -v` first)")
    parser.add_argument("--ready-timeout", type=float, default=900.0)
    parser.add_argument("--request-timeout", type=float, default=600.0)
    parser.add_argument("--oneshot-timeout", type=float, default=3600.0)
    parser.add_argument("--keep-outputs", action="store_true")
    parser.add_argument("--allow-env-drift", action="store_true",
                        help="Run engines whose environment differs from the "
                             "lock (dry runs only; recorded on every row)")
    parser.add_argument("--results", type=Path, default=None,
                        help="JSONL (default: eval/results/exp6_latency_<machine>.jsonl)")
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--gated-only", action="store_true",
                        help="Summary: exclude cases whose idle gate was not met")
    args = parser.parse_args(argv)
    if args.max_load is not None and args.max_load < 0:
        args.max_load = None
    args.gemma_tasks = [t for t in args.gemma_tasks.split(",") if t]
    args.prompts = max(1, min(args.prompts, len(CLICKS)))

    repo = args.repo.resolve()
    profile = machine_profile()
    results = args.results or (repo / "eval/results"
                               / f"{EXPERIMENT}_{host_tag(profile)}.jsonl")
    csv_path = results.with_suffix(".csv")
    if args.summary_only:
        write_summary(results, csv_path, args.gated_only)
        return 0

    engines = [e for e in args.engines.split(",") if e]
    unknown = set(engines) - set(ALL_ENGINES)
    if unknown:
        parser.error(f"unknown engine(s): {', '.join(sorted(unknown))}")
    if not args.series:
        parser.error("--series is required")
    series = [s.resolve() for s in args.series]
    # Absolute, because each server is started with its own directory as cwd.
    builtin_python = (Path(os.path.abspath(args.builtin_python))
                      if args.builtin_python else None)

    manifest = load_manifest(repo)
    paths = EvalPaths((args.env_root or repo / ".eval/plugin-envs").resolve())
    workdir = repo / ".eval/exp6"
    workdir.mkdir(parents=True, exist_ok=True)

    # Keep the machine awake for exactly as long as this process lives.
    subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())])

    target = paths.venv_python(ONESHOT_ENGINE) if ONESHOT_ENGINE in engines else None
    recorder = Recorder(results, EXPERIMENT, target_python=target)
    done = recorder.done_case_ids()
    print(f"results: {results}", flush=True)

    slices: list[tuple[str, Path]] = []
    if any(e in SERVER_ENGINES for e in engines):
        for s in series:
            for fraction in SLICE_FRACTIONS[:args.slices_per_series]:
                png = workdir / "slices" / f"{s.name}_{int(fraction * 100):02d}.png"
                if not png.is_file():
                    prepare_slice(s, png, fraction)
                slices.append((png.stem, png))

    for engine in engines:
        python, lock = engine_environment(engine, repo, paths, manifest,
                                          builtin_python)
        env_check = (check_environment(python, lock) if python is not None
                     else {"ok": False, "error": "no interpreter given"})
        if not env_check["ok"]:
            print(f"  [env] {engine}: does not match {lock.name}: "
                  f"python={env_check.get('python')} "
                  f"drift={len(env_check.get('drift', {}))} package(s) "
                  f"{env_check.get('error') or ''}", flush=True)
            if not args.allow_env_drift:
                print(f"  [skip] {engine} (rebuild the environment from the lock, "
                      f"or pass --allow-env-drift for a dry run)", flush=True)
                continue
        args.env_check = env_check
        if engine == ONESHOT_ENGINE:
            for task in [t for t in args.oneshot_tasks.split(",") if t]:
                for s in series:
                    for rep in range(args.oneshot_reps):
                        case_id = f"{engine}/{task}/{s.name}/r{rep}"
                        if case_id in done:
                            continue
                        print(f"{case_id} ...", flush=True)
                        recorder.write(run_oneshot(task, s, rep, repo, paths,
                                                   manifest, args, workdir))
            continue
        for cycle in range(args.cycles):
            case_id = f"{engine}/c{cycle}"
            if case_id in done:
                continue
            print(f"{case_id} ...", flush=True)
            recorder.write(run_server_cycle(engine, cycle, repo, paths, manifest,
                                            builtin_python, slices, args,
                                            workdir))

    write_summary(results, csv_path, args.gated_only)
    return 0


if __name__ == "__main__":
    sys.exit(main())
