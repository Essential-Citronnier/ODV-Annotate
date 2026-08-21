# probe.py
# OpenDicomViewer
#
# The invocation layer of the plugin conformance kit: everything that runs an
# adapter and observes what it did.
#
# The kit's central rule is that it establishes conformance by RUNNING an
# adapter, never by reading its source. PluginAdapterLayoutTests.swift learned
# why the hard way: `--install-weights` is dispatched to a separate parser
# before the main one, so it never appears in `--help` even though it works,
# and four tests that asserted on the documentation failed against an adapter
# that was correct. Everything here therefore spawns a process, drives it, and
# reports what came back.
#
# Standard library only, deliberately. A third party runs this kit against
# their own adapter before they have an environment for it, and a checker that
# needed `pip install` first would be asking for the thing it is meant to
# verify can be built. That is also why the HTTP client is urllib and the PNG
# encoder below is fourteen lines of zlib rather than Pillow.
# Licensed under the MIT License. See LICENSE for details.
"""Process spawning, stdout classification, and HTTP probing for the kit."""

from __future__ import annotations

import json
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

__all__ = [
    "ERROR_CODES",
    "INPUT_KINDS",
    "OUTPUT_KINDS",
    "EXECUTION_MODELS",
    "Invocation",
    "Stdout",
    "ServerProcess",
    "HttpReply",
    "blocker_dir",
    "classify_stdout",
    "decode_rle",
    "free_port",
    "invoke",
    "listening_addresses",
    "make_png",
    "non_loopback_addresses",
]

# ---------------------------------------------------------------------------
# Protocol vocabulary. These are the closed sets PLUGIN_PROTOCOL.md defines;
# anything outside them is a conformance failure rather than an extension.
# ---------------------------------------------------------------------------

#: PLUGIN_PROTOCOL.md section 3, "Errors". No other code is valid.
ERROR_CODES = ("not_ready", "bad_input", "license_required",
               "out_of_memory", "internal")

#: Section 2, input table.
INPUT_KINDS = ("slice2d", "series3d", "roi", "points", "box", "text")

#: Section 2, output table.
OUTPUT_KINDS = ("text", "bbox", "mask2d", "seg3d", "metrics")

#: Section 1. Three, and only three.
EXECUTION_MODELS = ("resident-server", "session", "one-shot")

#: Heavy dependencies a conformant adapter must not need at module scope.
#: Section 4b: the weight hook is what populates the environment, so it cannot
#: require that environment to already exist. `--help` is in the same position
#: because the host probes an adapter before installing anything for it.
HEAVY_MODULES = (
    "torch", "torchvision", "transformers", "fastapi", "uvicorn", "starlette",
    "mlx", "mlx_lm", "mlx_vlm", "numpy", "PIL", "scipy", "SimpleITK",
    "highdicom", "pydicom", "nibabel", "totalsegmentator", "nnunetv2",
    "huggingface_hub", "safetensors", "cv2", "pandas", "sklearn",
)

#: Download libraries a `manual` weight source must not reach for, because
#: section 4b forbids it from attempting a download at all.
#:
#: The stdlib primitives (`http.client`, `urllib.request`) are deliberately NOT
#: here even though a download could be built on them. Blocking them would
#: break any adapter whose HTTP surface is `http.server`, which imports
#: `http.client` -- a false failure about the server for a check about weights.
#: `deny_network` below closes that gap at the socket instead, where the
#: distinction between serving and fetching is actually visible.
NETWORK_MODULES = (
    "huggingface_hub", "requests", "httpx", "aiohttp", "boto3", "ftplib",
)


# ---------------------------------------------------------------------------
# Running an adapter
# ---------------------------------------------------------------------------


@dataclass
class Invocation:
    """One completed run of an adapter, with everything it produced."""

    argv: list[str]
    returncode: int
    stdout: str
    stderr: str
    duration_s: float
    timed_out: bool = False

    @property
    def combined(self) -> str:
        return self.stdout + self.stderr

    @property
    def rejected_as_unknown_flag(self) -> bool:
        """Whether argparse refused a flag rather than the adapter refusing it.

        Copied in spirit from PluginAdapterLayoutTests.swift: argparse reports
        an unrecognized flag with this phrasing and exit 2. Any other failure
        means the flag was accepted and the adapter got further, which is the
        distinction that matters -- a conformance kit that could not tell "your
        adapter rejected my nonsense weight id" from "your adapter does not
        implement the flag" would be useless.
        """
        if self.returncode != 2:
            return False
        text = self.combined
        return ("unrecognized arguments" in text
                or "invalid choice" in text
                or re.search(r"error: unrecognized|no such option", text) is not None)

    def summary(self, limit: int = 240) -> str:
        """A short quotable excerpt for a failure reason."""
        text = (self.stdout.strip() or self.stderr.strip()).replace("\n", " ⏎ ")
        return text[:limit] + ("…" if len(text) > limit else "")


def invoke(
    python: str | os.PathLike,
    entry: str,
    args: Sequence[str],
    cwd: str | os.PathLike,
    plugins_root: str | os.PathLike,
    timeout: float = 120.0,
    extra_env: Mapping[str, str] | None = None,
    blocked_modules: Sequence[str] | None = None,
    deny_network: bool = False,
) -> Invocation:
    """Run `python <entry> <args>` from `cwd` and capture everything.

    `plugins_root` goes on PYTHONPATH because adapters import `_shared` as a
    package rooted there; the host does the same when it spawns them.
    `blocked_modules` installs an import blocker in the child, which is how the
    kit establishes that a mode works without a dependency rather than merely
    that it works on a machine which happens to have one. `deny_network` does
    the same for outbound connections.
    """
    env = dict(os.environ)
    env.pop("PYTHONHOME", None)
    path_parts = [str(plugins_root)]
    stack: list[Any] = []

    if blocked_modules or deny_network:
        blocker = _write_blocker(blocked_modules or (), deny_network)
        stack.append(blocker)
        path_parts.insert(0, str(blocker.name))

    env["PYTHONPATH"] = os.pathsep.join(path_parts)
    env["PYTHONUNBUFFERED"] = "1"
    # Keep a stray user-level license key out of every probe: section 4b says
    # the key travels in the environment, and a kit that leaked the operator's
    # into an adapter run would be testing a state the host never creates.
    env.pop("ODV_PLUGIN_LICENSE_KEY", None)
    if extra_env:
        env.update(extra_env)

    argv = [str(python), str(entry), *args]
    started = time.perf_counter()
    try:
        completed = subprocess.run(
            argv, cwd=str(cwd), env=env, capture_output=True, text=True,
            timeout=timeout, check=False,
        )
        result = Invocation(
            argv=argv, returncode=completed.returncode,
            stdout=completed.stdout, stderr=completed.stderr,
            duration_s=time.perf_counter() - started,
        )
    except subprocess.TimeoutExpired as exc:
        result = Invocation(
            argv=argv, returncode=-1,
            stdout=exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or ""),
            stderr=exc.stderr.decode() if isinstance(exc.stderr, bytes) else (exc.stderr or ""),
            duration_s=time.perf_counter() - started, timed_out=True,
        )
    finally:
        for item in stack:
            item.cleanup()
    return result


class _Blocker:
    def __init__(self, directory: tempfile.TemporaryDirectory) -> None:
        self._directory = directory
        self.name = directory.name

    def cleanup(self) -> None:
        self._directory.cleanup()


#: Marker the child prints when it tries something the probe forbids. The kit
#: looks for this rather than for a traceback, so an adapter that catches the
#: error and reports it politely is still caught having tried.
VIOLATION_MARKER = "ODV-CONFORMANCE-VIOLATION"

_BLOCKER_SOURCE = '''\
# Written by the ODV plugin conformance kit. Denies a fixed set of imports, and
# optionally any outbound network connection, so that "this works without its
# heavy dependencies" and "this did not attempt a download" are observed rather
# than assumed. sitecustomize is imported by `site` before the target script
# runs.
import sys

_BLOCKED = frozenset({blocked!r})
_DENY_NETWORK = {deny_network!r}
_MARKER = "ODV-CONFORMANCE-VIOLATION"


if _DENY_NETWORK:
    import socket as _socket

    # Connecting out is denied; binding and accepting are not. That asymmetry is
    # the point: a `manual` weight source must not fetch anything, but an
    # adapter is perfectly entitled to serve HTTP on loopback, and a blunter
    # block would confuse the two.
    def _refuse(name):
        def guard(self, *args, **kwargs):
            message = "%s: outbound network (%s) is denied for this probe" % (
                _MARKER, name)
            sys.stderr.write(message + "\\n")
            sys.stderr.flush()
            raise OSError(message)

        return guard

    _socket.socket.connect = _refuse("socket.connect")
    _socket.socket.connect_ex = _refuse("socket.connect_ex")
    _socket.create_connection = lambda *a, **k: (_ for _ in ()).throw(
        OSError("%s: outbound network (create_connection) is denied" % _MARKER))


class _ConformanceImportBlocker:
    def find_spec(self, fullname, path=None, target=None):
        if fullname in _BLOCKED or fullname.split(".")[0] in _BLOCKED:
            message = "%s: import of %r is blocked for this probe" % (
                _MARKER, fullname)
            sys.stderr.write(message + "\\n")
            sys.stderr.flush()
            raise ImportError(message)
        return None

    # Python 3.9 still consults the legacy hook on some paths.
    def find_module(self, fullname, path=None):
        self.find_spec(fullname, path)
        return None


if _BLOCKED:
    sys.meta_path.insert(0, _ConformanceImportBlocker())
'''


def _write_blocker(names: Sequence[str], deny_network: bool = False) -> _Blocker:
    directory = tempfile.TemporaryDirectory(prefix="odv-conformance-blocker-")
    source = _BLOCKER_SOURCE.format(blocked=tuple(sorted(names)),
                                    deny_network=bool(deny_network))
    Path(directory.name, "sitecustomize.py").write_text(source)
    return _Blocker(directory)


def blocker_dir(names: Sequence[str], deny_network: bool = False) -> _Blocker:
    """Public handle on the probe's import/network blocker, for the kit's tests."""
    return _write_blocker(names, deny_network)


# ---------------------------------------------------------------------------
# Stdout line discipline (section 4b)
# ---------------------------------------------------------------------------


@dataclass
class Stdout:
    """A run's stdout, partitioned the way the host partitions it.

    Section 4b: "an object carrying `ok` is an envelope, one carrying
    `progress` is a progress line, and anything else is a log line". The three
    must be distinguishable. `ambiguous` collects lines that are both, which is
    how a licence gate degrades into a bare exit status.
    """

    progress: list[dict] = field(default_factory=list)
    envelopes: list[dict] = field(default_factory=list)
    logs: list[str] = field(default_factory=list)
    ambiguous: list[dict] = field(default_factory=list)
    malformed_progress: list[dict] = field(default_factory=list)
    malformed_envelopes: list[dict] = field(default_factory=list)

    @property
    def envelope(self) -> dict | None:
        return self.envelopes[0] if self.envelopes else None


def classify_stdout(text: str) -> Stdout:
    """Partition stdout into progress lines, envelopes, and log lines."""
    out = Stdout()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            parsed = json.loads(stripped)
        except ValueError:
            out.logs.append(line)
            continue
        if not isinstance(parsed, dict):
            out.logs.append(line)
            continue

        has_ok = "ok" in parsed
        has_progress = "progress" in parsed
        if has_ok and has_progress:
            out.ambiguous.append(parsed)
        elif has_ok:
            (out.envelopes if _envelope_wellformed(parsed)
             else out.malformed_envelopes).append(parsed)
        elif has_progress:
            (out.progress if _progress_wellformed(parsed)
             else out.malformed_progress).append(parsed)
        else:
            out.logs.append(line)
    return out


def _progress_wellformed(obj: Mapping[str, Any]) -> bool:
    value = obj.get("progress")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if not 0.0 <= float(value) <= 1.0:
        return False
    return isinstance(obj.get("message", ""), str)


def _envelope_wellformed(obj: Mapping[str, Any]) -> bool:
    if obj.get("ok") is True:
        return True
    if obj.get("ok") is not False:
        return False
    error = obj.get("error")
    if not isinstance(error, Mapping):
        return False
    return isinstance(error.get("code"), str) and isinstance(error.get("message"), str)


# ---------------------------------------------------------------------------
# HTTP probing (sections 3, 6, 7)
# ---------------------------------------------------------------------------


@dataclass
class HttpReply:
    status: int
    body: Any
    raw: str
    error: str | None = None

    @property
    def ok(self) -> bool:
        return self.error is None


def _request(url: str, payload: Any = None, timeout: float = 20.0) -> HttpReply:
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers,
                                     method="POST" if data is not None else "GET")
    # No proxy: the adapter is on loopback and an inherited http_proxy would
    # otherwise send a conformance probe to a proxy that cannot reach it.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", "replace")
            status = response.getcode()
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        status = exc.code
    except Exception as exc:  # noqa: BLE001 - any transport failure is a result
        return HttpReply(status=0, body=None, raw="", error=f"{type(exc).__name__}: {exc}")
    try:
        return HttpReply(status=status, body=json.loads(raw), raw=raw)
    except ValueError:
        return HttpReply(status=status, body=None, raw=raw,
                         error="response body is not JSON")


class ServerProcess:
    """A spawned resident/session adapter, polled until it answers /health.

    Used as a context manager so a failed check never leaves a model resident.
    """

    def __init__(
        self,
        python: str | os.PathLike,
        entry: str,
        cwd: str | os.PathLike,
        plugins_root: str | os.PathLike,
        port: int,
        extra_args: Sequence[str] = (),
        extra_env: Mapping[str, str] | None = None,
    ) -> None:
        self.port = port
        self.argv = [str(python), str(entry), "--port", str(port), *extra_args]
        self._cwd = str(cwd)
        env = dict(os.environ)
        env["PYTHONPATH"] = str(plugins_root)
        env["PYTHONUNBUFFERED"] = "1"
        env.pop("ODV_PLUGIN_LICENSE_KEY", None)
        if extra_env:
            env.update(extra_env)
        self._env = env
        self.process: subprocess.Popen | None = None
        self._out_path: Path | None = None
        self._tmp: tempfile.TemporaryDirectory | None = None

    def __enter__(self) -> "ServerProcess":
        self._tmp = tempfile.TemporaryDirectory(prefix="odv-conformance-server-")
        self._out_path = Path(self._tmp.name, "server.log")
        handle = open(self._out_path, "w")
        self._handle = handle
        self.process = subprocess.Popen(
            self.argv, cwd=self._cwd, env=self._env,
            stdout=handle, stderr=subprocess.STDOUT, text=True,
        )
        return self

    def __exit__(self, *exc: object) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        try:
            self._handle.close()
        except Exception:  # noqa: BLE001
            pass
        # Read the log before the temp dir goes away; a failure reason that
        # quotes the adapter's own traceback is worth far more than "no reply".
        self._log_text = self.log()
        if self._tmp is not None:
            self._tmp.cleanup()
            self._tmp = None

    def log(self) -> str:
        if self._out_path is not None and self._out_path.exists():
            return self._out_path.read_text("utf-8", "replace")
        return getattr(self, "_log_text", "")

    @property
    def exited(self) -> bool:
        return self.process is not None and self.process.poll() is not None

    def url(self, path: str, host: str = "127.0.0.1") -> str:
        return f"http://{host}:{self.port}{path}"

    def get(self, path: str, host: str = "127.0.0.1", timeout: float = 20.0) -> HttpReply:
        return _request(self.url(path, host), timeout=timeout)

    def post(self, path: str, payload: Any, host: str = "127.0.0.1",
             timeout: float = 120.0) -> HttpReply:
        return _request(self.url(path, host), payload=payload, timeout=timeout)

    def wait_for_health(self, timeout: float = 90.0) -> HttpReply:
        """Poll /health until it answers, or the process dies, or time runs out.

        Answering at all is what is waited for -- not `status == "ready"`. An
        adapter whose weights are absent reports `error` with a reason and that
        is conformant; the host distinguishes the two and so does the kit.
        """
        deadline = time.monotonic() + timeout
        last = HttpReply(status=0, body=None, raw="", error="never polled")
        while time.monotonic() < deadline:
            if self.exited:
                return HttpReply(
                    status=0, body=None, raw="",
                    error=f"process exited with code {self.process.returncode} "
                          f"before answering /health")
            last = self.get("/health", timeout=5.0)
            if last.ok:
                return last
            time.sleep(0.25)
        return last


def free_port() -> int:
    """A port nothing is listening on.

    Binding to port 0 and reading the assignment is the reliable way; where the
    environment forbids binding at all, a random high port is tried instead so
    the kit degrades to "probably free" rather than refusing to run.
    """
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            return int(sock.getsockname()[1])
    except OSError:
        import random

        return random.randint(20000, 60000)


def listening_addresses(pid: int) -> tuple[set[str], str | None]:
    """IP addresses `pid` is listening on, and why the answer is unavailable.

    Returns ``(addresses, error)``. An empty set with no error means the
    process holds no listening socket; a non-None error means the kit could not
    look, which is reported as an inconclusive check rather than a pass.
    """
    if sys.platform.startswith("linux"):
        return _listening_linux(pid)
    return _listening_lsof(pid)


def _listening_lsof(pid: int) -> tuple[set[str], str | None]:
    for candidate in ("/usr/sbin/lsof", "/usr/bin/lsof", "lsof"):
        try:
            completed = subprocess.run(
                [candidate, "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN"],
                capture_output=True, text=True, timeout=30, check=False,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        addresses: set[str] = set()
        for line in completed.stdout.splitlines()[1:]:
            match = re.search(r"(\S+):(\d+)\s+\(LISTEN\)", line)
            if match:
                addresses.add(match.group(1).strip("[]"))
        return addresses, None
    return set(), "lsof is not available to enumerate listening sockets"


def _listening_linux(pid: int) -> tuple[set[str], str | None]:
    try:
        inodes = set()
        fd_dir = Path("/proc") / str(pid) / "fd"
        for entry in fd_dir.iterdir():
            try:
                target = os.readlink(entry)
            except OSError:
                continue
            match = re.fullmatch(r"socket:\[(\d+)\]", target)
            if match:
                inodes.add(match.group(1))
    except OSError as exc:
        return set(), f"cannot read /proc/{pid}/fd: {exc}"

    addresses: set[str] = set()
    for table, width in (("/proc/net/tcp", 4), ("/proc/net/tcp6", 16)):
        try:
            lines = Path(table).read_text().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            fields = line.split()
            if len(fields) < 10 or fields[3] != "0A":  # 0A == TCP_LISTEN
                continue
            if fields[9] not in inodes:
                continue
            addresses.add(_decode_proc_address(fields[1].split(":")[0], width))
    return addresses, None


def _decode_proc_address(hex_text: str, width: int) -> str:
    raw = bytes.fromhex(hex_text)
    if width == 4:
        return socket.inet_ntop(socket.AF_INET, struct.pack("<I", struct.unpack(">I", raw)[0]))
    words = struct.unpack("<4I", raw)
    packed = struct.pack(">4I", *(struct.unpack("<I", struct.pack(">I", w))[0] for w in words))
    return socket.inet_ntop(socket.AF_INET6, packed)


def is_loopback(address: str) -> bool:
    """Whether an address a server bound is loopback-only.

    The wildcard forms are the point of the check: `0.0.0.0` and `::` are not
    loopback, they are "every interface this machine has", which is what
    invariant 1 forbids.
    """
    text = address.strip().strip("[]").lower()
    if text in ("0.0.0.0", "::", "*", ""):
        return False
    if text.startswith("127.") or text in ("::1", "localhost"):
        return True
    if text.startswith("::ffff:127."):
        return True
    return False


def non_loopback_addresses() -> list[str]:
    """This machine's non-loopback IPv4 addresses, best effort.

    Used to try reaching an adapter from an address it should not answer on.
    Both discovery routes are permitted to fail; the socket-enumeration check
    is the primary evidence and this is corroboration.
    """
    found: set[str] = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.add(info[4][0])
    except OSError:
        pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(1.0)
            sock.connect(("192.0.2.1", 9))  # TEST-NET-1, never routed
            found.add(sock.getsockname()[0])
    except OSError:
        pass
    return sorted(address for address in found if not is_loopback(address))


# ---------------------------------------------------------------------------
# Synthetic inputs and the RLE convention (section 5)
# ---------------------------------------------------------------------------


def make_png(width: int, height: int,
             shade: Callable[[int, int], tuple[int, int, int]] | None = None) -> bytes:
    """Encode an RGB PNG with zlib alone.

    A slice2d input is a base64 PNG, so probing a task means producing one.
    Pillow would be the obvious way and is exactly what the kit must not
    require: an adapter author runs this before their environment exists.
    """
    if shade is None:
        def shade(x: int, y: int) -> tuple[int, int, int]:  # noqa: ARG001
            return (32, 32, 32)

    rows = bytearray()
    for y in range(height):
        rows.append(0)  # filter type 0 (None)
        for x in range(width):
            rows.extend(bytes(max(0, min(255, int(c))) for c in shade(x, y)))

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
            + chunk(b"IEND", b""))


def decode_rle(rle: Sequence[int], width: int, height: int) -> list[bool]:
    """Decode section 5 run lengths exactly as the Swift host decoder does.

    Row-major, runs alternate background/foreground starting with background,
    a leading zero expresses a mask that starts foreground. Foreground is
    inferred purely from run parity with no marker in the data, which is why an
    encoder that emits the wrong phase produces a well-formed payload that
    renders inverted. Reproducing the host's decode is the only way to see it.
    """
    total = int(width) * int(height)
    if total <= 0:
        raise ValueError("width and height must both be positive")
    out = [False] * total
    index = 0
    foreground = False
    for run in rle:
        if not isinstance(run, int) or isinstance(run, bool) or run < 0:
            raise ValueError(f"run lengths must be non-negative integers, got {run!r}")
        if index + run > total:
            raise ValueError("runs overflow width * height")
        if foreground and run:
            for i in range(index, index + run):
                out[i] = True
        index += run
        foreground = not foreground
    if index != total:
        raise ValueError(f"runs sum to {index}, expected {total}")
    return out


def iter_masks(value: Any) -> Iterable[dict]:
    """Yield each mask2d object. Section 3 permits a single object or a list."""
    if isinstance(value, Mapping):
        yield dict(value)
    elif isinstance(value, (list, tuple)):
        for item in value:
            if isinstance(item, Mapping):
                yield dict(item)
