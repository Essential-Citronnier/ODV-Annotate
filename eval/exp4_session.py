#!/usr/bin/env python3
# exp4_session.py
# OpenDicomViewer
#
# Experiment 4: does the `session` execution model earn its complexity?
#
# PLUGIN_PROTOCOL.md 1.2 admits `session` as a third supervision pattern on one
# premise: that for the SAM family, encoding an image costs far more than
# decoding a mask from a prompt, so caching the embedding and re-prompting is
# worth a session lifecycle, an LRU cache, and a `max_sessions` declaration.
# That premise is an empirical claim and it has never been measured. If the
# encode/decode ratio is near 1, `session` is unjustified machinery and should
# collapse into `resident-server`.
#
# Everything here runs against the real SAM 2 adapter over its real HTTP
# surface -- the adapter is started as a subprocess exactly as the host starts
# it -- so the numbers are what the host would see, not what an in-process
# microbenchmark would suggest.
# Licensed under the MIT License. See LICENSE for details.
"""Measure the encode/decode cost ratio that the `session` model rests on."""
from __future__ import annotations

import argparse
import base64
import csv
import io
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import CaseResult, Recorder, load_results  # noqa: E402

EXPERIMENT = "exp4_session"
REPO_ROOT = Path(__file__).resolve().parent.parent

# Soft-tissue window. The host renders what the user is looking at, and a user
# clicking on an abdominal structure is looking at a soft-tissue window, not at
# raw Hounsfield units.
WINDOW_CENTER = 50.0
WINDOW_WIDTH = 400.0


# ---------------------------------------------------------------------------
# Slice rendering
# ---------------------------------------------------------------------------


@dataclass
class Slice:
    """One rendered CT slice plus the body mask used to place plausible clicks."""

    series_id: str
    index: int
    png: bytes
    width: int
    height: int
    body_mask: Any  # numpy bool array, HxW

    @property
    def case_id(self) -> str:
        return f"{self.series_id}/s{self.index:04d}"


def _sorted_series_files(series_dir: Path) -> list[Path]:
    """Instance files ordered along the scan axis.

    Sorted on ImagePositionPatient rather than filename: TCIA filenames are not
    guaranteed to be in acquisition order, and a mis-ordered series would make
    "slice 200 of the series" mean nothing reproducible.
    """
    import pydicom

    entries = []
    for path in sorted(series_dir.rglob("*.dcm")):
        try:
            ds = pydicom.dcmread(str(path), stop_before_pixels=True)
        except Exception:  # noqa: BLE001 - a corrupt instance is skipped, not fatal
            continue
        position = getattr(ds, "ImagePositionPatient", None)
        key = float(position[2]) if position else float(getattr(ds, "InstanceNumber", 0))
        entries.append((key, path))
    entries.sort(key=lambda item: item[0])
    return [path for _, path in entries]


def render_slices(series_dir: Path, count: int, seed: int = 0) -> list[Slice]:
    """Render `count` slices spread through a series, as the host would.

    Slices are taken at even fractions of the series rather than contiguously:
    adjacent CT slices are nearly identical, and encoding the same anatomy five
    times would measure the machine's cache rather than the model.
    """
    import numpy as np
    import pydicom
    from PIL import Image

    files = _sorted_series_files(series_dir)
    if not files:
        raise FileNotFoundError(f"no DICOM instances under {series_dir}")

    # Interior of the series only: the first and last slices of an abdominal CT
    # are frequently air or table, where a click prompt is meaningless.
    fractions = [0.2 + 0.6 * i / max(1, count - 1) for i in range(count)]
    picks = sorted({min(len(files) - 1, int(f * len(files))) for f in fractions})

    out: list[Slice] = []
    for index in picks:
        ds = pydicom.dcmread(str(files[index]))
        pixels = ds.pixel_array.astype(np.float32)
        slope = float(getattr(ds, "RescaleSlope", 1.0) or 1.0)
        intercept = float(getattr(ds, "RescaleIntercept", 0.0) or 0.0)
        hu = pixels * slope + intercept

        low = WINDOW_CENTER - WINDOW_WIDTH / 2.0
        windowed = np.clip((hu - low) / WINDOW_WIDTH, 0.0, 1.0)
        grey = (windowed * 255.0).astype(np.uint8)

        buffer = io.BytesIO()
        Image.fromarray(grey).convert("RGB").save(buffer, format="PNG")

        # Body, not table or air: HU above -200 and inside the largest connected
        # region is a good enough approximation for placing prompts, and it does
        # not need a segmentation dependency.
        body = hu > -200.0
        out.append(Slice(series_dir.name, index, buffer.getvalue(),
                         int(grey.shape[1]), int(grey.shape[0]), body))
    return out


def prompt_points(slice_: Slice, count: int, seed: int) -> list[dict]:
    """Deterministic click prompts inside the body, normalized 0-1.

    Prompts must be reproducible across runs for the timing comparison to mean
    anything, and they must land on tissue: a click on air decodes an empty
    mask, which is a different code path in the model's mask head.
    """
    import numpy as np

    rng = np.random.default_rng(seed)
    ys, xs = np.nonzero(slice_.body_mask)
    if len(xs) == 0:
        raise ValueError(f"{slice_.case_id} has no body pixels")
    picks = rng.choice(len(xs), size=count, replace=False)
    return [{"x": float(xs[i]) / slice_.width,
             "y": float(ys[i]) / slice_.height,
             "label": 1} for i in picks]


def prompt_box(slice_: Slice) -> dict:
    """A box prompt around the body's bounding region, normalized 0-1."""
    import numpy as np

    ys, xs = np.nonzero(slice_.body_mask)
    x0, x1 = int(xs.min()), int(xs.max())
    y0, y1 = int(ys.min()), int(ys.max())
    # Shrink to a plausible user-drawn box over a structure rather than the
    # whole patient, which SAM treats as a near-degenerate prompt.
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    half_w, half_h = (x1 - x0) * 0.15, (y1 - y0) * 0.15
    return {"x": (cx - half_w) / slice_.width,
            "y": (cy - half_h) / slice_.height,
            "width": (2 * half_w) / slice_.width,
            "height": (2 * half_h) / slice_.height}


# ---------------------------------------------------------------------------
# The adapter under test
# ---------------------------------------------------------------------------
#
# Two transports, same protocol surface.
#
# `subprocess` is what the host does: spawn plugins/sam2/server.py on an
# assigned loopback port and speak HTTP to it. That is the default and the mode
# the numbers should be quoted from.
#
# `asgi` drives the identical FastAPI application object -- built by the same
# `_shared.serve.build_app` from the same adapter -- in this process, without a
# socket. It exists because some sandboxed environments deny bind(2) outright,
# and a measurement that cannot run there is worth less than one that runs with
# its omission stated. What it skips is exactly the kernel socket and the HTTP
# framing on it; routing, JSON parsing, `TaskRequest` validation, the
# threadpool offload, inference, RLE emission, response serialization, and the
# error envelope all execute unchanged.
#
# The omission is not neutral between the two operations being compared, and it
# is worth being precise about the direction. /session/open carries a ~200 kB
# base64 PNG; /task/prompt-mask carries a few hundred bytes of prompt but
# returns an RLE. Dropping transport therefore removes more from the encode
# side than from the decode side, so an encode/decode ratio measured over ASGI
# is if anything an *under*-estimate. It cannot inflate the quantity this
# experiment exists to test.


class _SyncASGIClient:
    """Synchronous facade over an httpx.AsyncClient on a background loop.

    Only `get`, `post`, and `close` are needed, and each blocks until the
    coroutine completes, so the experiment's timing code stays identical
    between the two transports.
    """

    def __init__(self, async_client: Any) -> None:
        import asyncio
        import threading

        self._client = async_client
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._loop.run_forever,
                                        daemon=True)
        self._thread.start()

    def _run(self, coro: Any) -> Any:
        import asyncio

        return asyncio.run_coroutine_threadsafe(coro, self._loop).result()

    def get(self, url: str, **kwargs: Any) -> Any:
        return self._run(self._client.get(url, **kwargs))

    def post(self, url: str, **kwargs: Any) -> Any:
        return self._run(self._client.post(url, **kwargs))

    def close(self) -> None:
        try:
            self._run(self._client.aclose())
        finally:
            self._loop.call_soon_threadsafe(self._loop.stop)
            self._thread.join(timeout=5)


class AdapterClient:
    """Protocol client for the SAM 2 adapter over either transport."""

    def __init__(self, weights: Path, port: int, log_path: Path,
                 transport: str = "auto"):
        self.weights = weights
        self.port = port
        self.log_path = log_path
        self.requested = transport
        self.transport: str | None = None
        self.base = f"http://127.0.0.1:{port}"
        self.proc: subprocess.Popen | None = None
        self._log = None
        self._client = None
        self._adapter = None

    # -- lifecycle ---------------------------------------------------------

    def __enter__(self) -> "AdapterClient":
        if self.requested in ("auto", "subprocess"):
            try:
                self._start_subprocess()
                self.transport = "subprocess"
                return self
            except Exception as exc:  # noqa: BLE001
                if self.requested == "subprocess":
                    raise
                print(f"  subprocess transport unavailable ({exc}); "
                      f"falling back to in-process ASGI", flush=True)
                self._stop_subprocess()
        self._start_asgi()
        self.transport = "asgi"
        return self

    def __exit__(self, *exc: object) -> None:
        self._stop_subprocess()
        if self._client is not None:
            self._client.close()

    def _start_subprocess(self) -> None:
        import httpx

        env = dict(os.environ)
        env["ODV_SAM2_WEIGHTS"] = str(self.weights)
        env["PYTHONPATH"] = str(REPO_ROOT / "plugins")
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self._log = open(self.log_path, "w")
        self.proc = subprocess.Popen(
            [sys.executable, str(REPO_ROOT / "plugins" / "sam2" / "server.py"),
             "--port", str(self.port), "--log-level", "warning"],
            stdout=self._log, stderr=subprocess.STDOUT, env=env,
        )
        self._client = httpx.Client(base_url=self.base, timeout=600.0)
        self._await_ready()

    def _await_ready(self, timeout: float = 120.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                detail = ""
                if self.log_path.is_file():
                    detail = self.log_path.read_text().strip().splitlines()[-1:]
                    detail = f": {detail[0]}" if detail else ""
                raise RuntimeError(
                    f"adapter exited with {self.proc.returncode}{detail}")
            try:
                response = self._client.get("/health", timeout=5.0)
                if response.status_code == 200 and \
                        response.json().get("status") == "ready":
                    return
            except Exception:  # noqa: BLE001 - not up yet
                pass
            time.sleep(0.3)
        raise TimeoutError(f"adapter not ready within {timeout}s")

    def _stop_subprocess(self) -> None:
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None
        if self._log is not None:
            self._log.close()
            self._log = None

    def _start_asgi(self) -> None:
        import httpx

        os.environ["ODV_SAM2_WEIGHTS"] = str(self.weights)
        sys.path.insert(0, str(REPO_ROOT / "plugins"))
        from _shared.serve import build_app  # noqa: PLC0415
        from sam2.server import build_adapter  # noqa: PLC0415

        self._adapter = build_adapter()
        app = build_app(self._adapter)
        # httpx's ASGI transport is async-only, so the app runs on an event loop
        # in a background thread and each call is dispatched onto it
        # synchronously. The dispatch costs tens of microseconds against
        # operations measured in milliseconds, and it applies equally to encode
        # and decode, so it does not bias the ratio.
        self._client = _SyncASGIClient(
            httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                              base_url="http://adapter.local", timeout=600.0))
        # The lifespan hook is not run by ASGITransport; these adapters do their
        # work lazily on first use, so there is nothing to start, but health
        # must still answer before the experiment treats the adapter as up.
        body = self._client.get("/health").json()
        if body.get("protocol") != 1:
            raise RuntimeError(f"unexpected /health from ASGI app: {body}")

    # -- protocol calls ----------------------------------------------------

    def health(self) -> dict:
        return self._client.get("/health").json()

    def capabilities(self) -> dict:
        return self._client.get("/capabilities").json()

    def open_session(self, png: bytes) -> tuple[dict, float]:
        """POST /session/open. Returns (body, client wall seconds)."""
        payload = {"inputs": {"slice2d": base64.b64encode(png).decode("ascii")}}
        started = time.perf_counter()
        response = self._client.post("/session/open", json=payload)
        elapsed = time.perf_counter() - started
        return response.json(), elapsed

    def prompt(self, session_id: str, *, points: Sequence[dict] | None = None,
               box: dict | None = None, multimask: bool = False,
               ) -> tuple[dict, float]:
        """POST /task/prompt-mask. Returns (body, client wall seconds)."""
        inputs: dict[str, Any] = {}
        if points:
            inputs["points"] = list(points)
        if box:
            inputs["box"] = box
        payload = {"session_id": session_id, "inputs": inputs,
                   "options": {"multimask": multimask}}
        started = time.perf_counter()
        response = self._client.post("/task/prompt-mask", json=payload)
        elapsed = time.perf_counter() - started
        return response.json(), elapsed

    def close_session(self, session_id: str) -> dict:
        return self._client.post("/session/close",
                                 json={"session_id": session_id}).json()

    def rss_bytes(self) -> float | None:
        """Resident set of whichever process is holding the model."""
        try:
            import psutil

            pid = self.proc.pid if self.proc is not None else os.getpid()
            return float(psutil.Process(pid).memory_info().rss)
        except Exception:  # noqa: BLE001 - a metrics read must not fail a case
            return None


# ---------------------------------------------------------------------------
# Cross-language RLE check against the host's own Swift decoder
# ---------------------------------------------------------------------------


SWIFT_HARNESS = r'''
import Foundation

// Decode mask2d payloads with the host's own PluginMask2D.decodeMask(), so the
// convention is checked against the real consumer rather than a Python
// re-implementation of it. A phase disagreement renders inverted masks and is
// silent on both sides, which is exactly why this check exists.
struct Payload: Codable { let masks: [PluginMask2D] }

let data = FileHandle.standardInput.readDataToEndOfFile()
let payload = try! JSONDecoder().decode(Payload.self, from: data)

var results: [[String: Any]] = []
for mask in payload.masks {
    guard let bits = mask.decodeMask() else {
        results.append(["ok": false])
        continue
    }
    var count = 0
    var first = -1
    var last = -1
    for (i, bit) in bits.enumerated() where bit {
        count += 1
        if first < 0 { first = i }
        last = i
    }
    results.append(["ok": true, "width": mask.width, "height": mask.height,
                    "total": bits.count, "count": count,
                    "first": first, "last": last])
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: results))
'''


def build_swift_decoder(workdir: Path) -> Path | None:
    """Compile the host's PluginTypes.swift into a decoder oracle.

    Returns None when the toolchain is unavailable, in which case the RLE check
    falls back to the Python mirror in `_shared.rle` and says so.
    """
    if shutil.which("swiftc") is None:
        return None
    source = REPO_ROOT / "Sources" / "OpenDicomViewer" / "Plugins" / "PluginTypes.swift"
    if not source.is_file():
        return None
    workdir.mkdir(parents=True, exist_ok=True)
    main = workdir / "main.swift"
    main.write_text(SWIFT_HARNESS)
    binary = workdir / "odv_decode_check"
    # A writable module cache is passed explicitly: the default lives under a
    # temporary directory this process may not create modules in.
    result = subprocess.run(
        ["swiftc", "-O", "-module-cache-path", str(workdir / "modulecache"),
         "-o", str(binary), str(main), str(source)],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not binary.is_file():
        print(f"  swiftc unavailable: {result.stderr.strip()[:200]}", flush=True)
        return None
    return binary


def swift_decode(binary: Path, masks: Sequence[dict]) -> list[dict]:
    """Run the Swift decoder over mask2d payloads."""
    body = json.dumps({"masks": [
        {"width": m["width"], "height": m["height"], "rle": m["rle"],
         "label": m.get("label"), "confidence": m.get("confidence")}
        for m in masks
    ]})
    result = subprocess.run([str(binary)], input=body, capture_output=True,
                            text=True, timeout=300)
    if result.returncode != 0:
        raise RuntimeError(f"swift decoder failed: {result.stderr[:300]}")
    return json.loads(result.stdout)


def as_mask_list(mask2d: Any) -> list[dict]:
    """Protocol section 3 allows `mask2d` to be an object or a list."""
    if isinstance(mask2d, list):
        return mask2d
    return [mask2d]


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------


def phase_roundtrip(adapter: AdapterClient, slices: Sequence[Slice],
                    recorder: Recorder, swift: Path | None,
                    notes: list[str]) -> None:
    """A real click and box round trip, with the RLE verified end to end.

    This is the deliverable that closes the architecture document's largest
    verification gap: SAM 2 inference had never been exercised against real
    weights, so prompt conversion, mask geometry, and the RLE phase convention
    were asserted only by construction.
    """
    import numpy as np

    from _shared.rle import decode_rle

    print("Phase A: protocol round trip", flush=True)
    for slice_ in slices[:3]:
        # `click` runs first and its mask is reused by `click+negative`, which
        # places its negative point inside that mask. An uncontrolled negative
        # point -- one at an independent random location -- tests nothing: it
        # can attach to a different structure and enlarge the mask, so it
        # cannot distinguish a correctly wired `label` field from one that
        # ignores or inverts it. Excluding a region the model just included is
        # the comparison that can fail.
        baseline_mask: dict[str, Any] = {}
        for kind in ("click", "click-multimask", "box", "click+negative"):
            case_id = f"roundtrip/{slice_.case_id}/{kind}"
            started = time.perf_counter()
            stages: dict[str, float] = {}
            metrics: dict[str, Any] = {}
            try:
                body, open_s = adapter.open_session(slice_.png)
                stages["open_session"] = open_s
                if not body.get("ok"):
                    raise RuntimeError(f"/session/open: {body}")
                session_id = body["session_id"]

                points = prompt_points(slice_, 2, seed=slice_.index)
                if kind == "box":
                    result, task_s = adapter.prompt(session_id, box=prompt_box(slice_))
                elif kind == "click-multimask":
                    result, task_s = adapter.prompt(session_id, points=points[:1],
                                                    multimask=True)
                elif kind == "click+negative":
                    if not baseline_mask:
                        raise RuntimeError(
                            "the `click` case must succeed first; its mask is "
                            "the region this case excludes from")
                    negative = _negative_point_inside(baseline_mask, points[0])
                    if negative is None:
                        raise RuntimeError(
                            "no interior point far enough from the positive "
                            "click to place a controlled negative prompt")
                    metrics["negative_point"] = negative
                    # The control arm: identical coordinates, `label` flipped to
                    # foreground. Comparing against it rather than against the
                    # single-click baseline isolates the label field, which is
                    # the only thing that differs between the two requests.
                    control, control_s = adapter.prompt(
                        session_id,
                        points=[points[0], dict(negative, label=1)])
                    stages["prompt_control"] = control_s
                    if not control.get("ok"):
                        raise RuntimeError(f"control arm: {control}")
                    metrics["control_mask"] = as_mask_list(
                        control["outputs"]["mask2d"])[0]
                    result, task_s = adapter.prompt(
                        session_id, points=[points[0], negative])
                else:
                    result, task_s = adapter.prompt(session_id, points=points[:1])
                stages["prompt"] = task_s

                if not result.get("ok"):
                    raise RuntimeError(f"/task/prompt-mask: {result}")
                masks = as_mask_list(result["outputs"]["mask2d"])
                metrics["n_candidates"] = len(masks)
                metrics["server_elapsed_ms"] = result.get("elapsed_ms")

                # Geometry: the mask must be on the slice grid the host is
                # displaying, or the overlay is silently misregistered.
                for mask in masks:
                    if (mask["width"], mask["height"]) != (slice_.width, slice_.height):
                        raise AssertionError(
                            f"mask {mask['width']}x{mask['height']} != slice "
                            f"{slice_.width}x{slice_.height}")
                    if sum(mask["rle"]) != slice_.width * slice_.height:
                        raise AssertionError("runs do not sum to width*height")

                best = masks[0]
                python_bits = decode_rle(best["rle"], best["width"], best["height"])
                python_count = int(sum(python_bits))
                metrics["mask_pixels"] = python_count
                metrics["mask_fraction"] = python_count / (best["width"] * best["height"])
                metrics["confidence"] = best.get("confidence")
                metrics["leading_run_is_background"] = True  # asserted below
                metrics["rle_runs"] = len(best["rle"])

                # A plausible mask: non-empty, and not the whole image.
                if not 0 < python_count < best["width"] * best["height"]:
                    raise AssertionError(f"implausible mask area {python_count}")

                # The prompt point itself must be inside the returned mask for a
                # positive click. This is the check that would catch an x/y
                # transposition, which geometry alone would not.
                if kind in ("click", "click-multimask"):
                    px = int(round(points[0]["x"] * best["width"]))
                    py = int(round(points[0]["y"] * best["height"]))
                    metrics["prompt_inside_mask"] = bool(
                        python_bits[py * best["width"] + px])

                if kind == "click":
                    baseline_mask = {"bits": python_bits, "width": best["width"],
                                     "height": best["height"],
                                     "pixels": python_count}

                if kind == "click+negative":
                    # What must hold is that marking a point background pushes
                    # the mask away from it *relative to marking the same point
                    # foreground*. Total mask area must not be asserted on:
                    # excluding a region can make the model settle on a
                    # different and even larger structure, which was observed.
                    # Nor can a single pixel be asserted on: SAM predicts at
                    # 256x256 and the adapter upsamples, so one pixel is below
                    # the model's resolving power. Local occupancy under a
                    # label flip is the comparison that isolates the field.
                    negative = metrics["negative_point"]
                    control = metrics.pop("control_mask")
                    control_bits = decode_rle(control["rle"], control["width"],
                                              control["height"])
                    occupancy_negative = _local_occupancy(
                        python_bits, best["width"], best["height"], negative)
                    occupancy_control = _local_occupancy(
                        control_bits, control["width"], control["height"],
                        negative)
                    metrics["occupancy_label0"] = occupancy_negative
                    metrics["occupancy_label1"] = occupancy_control
                    metrics["label_respected"] = (
                        occupancy_negative < occupancy_control)
                    metrics["baseline_pixels"] = baseline_mask["pixels"]
                    metrics["pixels_delta"] = python_count - baseline_mask["pixels"]
                    if not metrics["label_respected"]:
                        raise AssertionError(
                            f"flipping `label` at ({negative['x']:.3f}, "
                            f"{negative['y']:.3f}) did not move the mask away "
                            f"from it: occupancy {occupancy_negative:.3f} with "
                            f"label=0 vs {occupancy_control:.3f} with label=1")

                if swift is not None:
                    swift_out = swift_decode(swift, masks)
                    if not swift_out[0].get("ok"):
                        raise AssertionError("Swift decoder rejected the payload")
                    metrics["swift_count"] = swift_out[0]["count"]
                    metrics["swift_agrees"] = (swift_out[0]["count"] == python_count)
                    # Phase: the first foreground index must match. A decoder
                    # that inverted the convention would report a complementary
                    # count and a different first index.
                    first_python = python_bits.index(True) if python_count else -1
                    metrics["swift_first_matches"] = \
                        (swift_out[0]["first"] == first_python)
                    if not metrics["swift_agrees"] or not metrics["swift_first_matches"]:
                        raise AssertionError(
                            f"Swift/Python RLE disagreement: swift={swift_out[0]}, "
                            f"python count={python_count} first={first_python}")
                else:
                    metrics["swift_agrees"] = None

                adapter.close_session(session_id)
                recorder.write(CaseResult(
                    experiment=EXPERIMENT, case_id=case_id, ok=True,
                    wall_s=time.perf_counter() - started, stages_s=stages,
                    peak_rss_bytes=adapter.rss_bytes(), metrics=metrics,
                    notes=notes + ["phase=roundtrip"]))
            except Exception as exc:  # noqa: BLE001 - failures are recorded
                recorder.write(CaseResult(
                    experiment=EXPERIMENT, case_id=case_id, ok=False,
                    wall_s=time.perf_counter() - started, stages_s=stages,
                    metrics=metrics, error=f"{type(exc).__name__}: {exc}",
                    notes=notes + ["phase=roundtrip"]))


# Occupancy is read over a disk this many pixels in radius around the negative
# prompt. SAM predicts its mask at 256x256 and the adapter upsamples to the
# slice grid, so a single pixel is below the model's resolving power and a
# per-pixel assertion would be testing the upsampler. A neighbourhood is the
# smallest region the model can actually act on.
NEGATIVE_WINDOW_PX = 16

# Keep the negative prompt away from the image border, where the "furthest
# foreground pixel" rule otherwise lands on table or air at the edge of the
# field of view.
NEGATIVE_MARGIN_PX = 24


def _negative_point_inside(baseline: dict, positive: dict,
                           min_separation: float = 0.12) -> dict | None:
    """A background prompt inside the mask a positive click just produced.

    Chosen as the interior foreground pixel furthest from the positive click,
    so the two prompts describe genuinely different regions and the model is
    being asked to exclude something it had included, rather than being handed
    a contradiction at essentially the same coordinate.
    """
    import numpy as np

    width, height = baseline["width"], baseline["height"]
    bits = np.asarray(baseline["bits"], dtype=bool).reshape(height, width)
    ys, xs = np.nonzero(bits)
    if len(xs) == 0:
        return None
    margin = NEGATIVE_MARGIN_PX
    interior = ((xs > margin) & (xs < width - margin)
                & (ys > margin) & (ys < height - margin))
    ys, xs = ys[interior], xs[interior]
    if len(xs) == 0:
        return None
    px, py = positive["x"] * width, positive["y"] * height
    distances = np.hypot(xs - px, ys - py)
    index = int(np.argmax(distances))
    if distances[index] < min_separation * max(width, height):
        return None
    return {"x": float(xs[index]) / width, "y": float(ys[index]) / height,
            "label": 0}


def _local_occupancy(bits: Sequence[bool], width: int, height: int,
                     point: dict, radius: int = NEGATIVE_WINDOW_PX) -> float:
    """Fraction of mask pixels in a square window around a normalized point."""
    import numpy as np

    grid = np.asarray(bits, dtype=bool).reshape(height, width)
    cx = int(round(point["x"] * width))
    cy = int(round(point["y"] * height))
    x0, x1 = max(0, cx - radius), min(width, cx + radius + 1)
    y0, y1 = max(0, cy - radius), min(height, cy + radius + 1)
    return float(grid[y0:y1, x0:x1].mean())


def phase_ratio(adapter: AdapterClient, slices: Sequence[Slice],
                recorder: Recorder, encode_reps: int, prompts: int,
                decode_reps: int, notes: list[str]) -> None:
    """The measurement the design decision rests on.

    Three levels are recorded per operation because they answer different
    questions. `encode_ms` from the adapter is the model's own encoder cost.
    Server `elapsed_ms` adds prompt conversion and RLE emission. Client wall
    time adds JSON and loopback transport, and is what the host's interactive
    latency actually is -- so it is the level at which the design should be
    judged.
    """
    print("Phase B: encode and decode cost", flush=True)
    for slice_ in slices:
        # Encode repeatedly. Each repetition opens a fresh session, which is
        # exactly the cost a resident-server design would pay per prompt.
        for rep in range(encode_reps):
            case_id = f"encode/{slice_.case_id}/rep{rep}"
            started = time.perf_counter()
            try:
                body, wall = adapter.open_session(slice_.png)
                if not body.get("ok"):
                    raise RuntimeError(str(body))
                recorder.write(CaseResult(
                    experiment=EXPERIMENT, case_id=case_id, ok=True, wall_s=wall,
                    stages_s={"client_wall": wall},
                    peak_rss_bytes=adapter.rss_bytes(),
                    metrics={"op": "encode", "rep": rep,
                             "series": slice_.series_id, "slice": slice_.index,
                             "encode_ms": body.get("encode_ms"),
                             "client_ms": wall * 1000.0,
                             "png_bytes": len(slice_.png)},
                    notes=notes + ["phase=ratio"]))
                adapter.close_session(body["session_id"])
            except Exception as exc:  # noqa: BLE001
                recorder.write(CaseResult(
                    experiment=EXPERIMENT, case_id=case_id, ok=False,
                    wall_s=time.perf_counter() - started,
                    error=f"{type(exc).__name__}: {exc}",
                    metrics={"op": "encode", "series": slice_.series_id},
                    notes=notes + ["phase=ratio"]))

        # Decode repeatedly against one cached embedding.
        try:
            body, _ = adapter.open_session(slice_.png)
            session_id = body["session_id"]
        except Exception as exc:  # noqa: BLE001
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=f"decode/{slice_.case_id}/setup",
                ok=False, wall_s=0.0, error=f"{type(exc).__name__}: {exc}",
                notes=notes + ["phase=ratio"]))
            continue

        points = prompt_points(slice_, prompts, seed=slice_.index)
        for j, point in enumerate(points):
            for rep in range(decode_reps):
                case_id = f"decode/{slice_.case_id}/p{j:02d}/rep{rep}"
                started = time.perf_counter()
                try:
                    result, wall = adapter.prompt(session_id, points=[point])
                    if not result.get("ok"):
                        raise RuntimeError(str(result))
                    mask = as_mask_list(result["outputs"]["mask2d"])[0]
                    area = sum(mask["rle"][1::2])
                    recorder.write(CaseResult(
                        experiment=EXPERIMENT, case_id=case_id, ok=True,
                        wall_s=wall, stages_s={"client_wall": wall},
                        peak_rss_bytes=adapter.rss_bytes(),
                        metrics={"op": "decode", "rep": rep, "prompt": j,
                                 "series": slice_.series_id, "slice": slice_.index,
                                 "server_ms": result.get("elapsed_ms"),
                                 "client_ms": wall * 1000.0,
                                 "mask_pixels": area,
                                 "confidence": mask.get("confidence")},
                        notes=notes + ["phase=ratio"]))
                except Exception as exc:  # noqa: BLE001
                    recorder.write(CaseResult(
                        experiment=EXPERIMENT, case_id=case_id, ok=False,
                        wall_s=time.perf_counter() - started,
                        error=f"{type(exc).__name__}: {exc}",
                        metrics={"op": "decode", "series": slice_.series_id},
                        notes=notes + ["phase=ratio"]))
        adapter.close_session(session_id)


def phase_cumulative(adapter: AdapterClient, slices: Sequence[Slice],
                     recorder: Recorder, prompts: int, notes: list[str]) -> None:
    """Session caching against the resident-server alternative, measured.

    The alternative is not hypothetical: a `resident-server` SAM would have to
    accept the slice with every prompt and encode it again, because it holds no
    per-image state. Both arms are run for the same prompts on the same slice,
    so the crossover point is measured rather than extrapolated from phase B.
    """
    print("Phase C: cumulative cost, session vs re-encode", flush=True)
    for slice_ in slices[:3]:
        points = prompt_points(slice_, prompts, seed=slice_.index + 500)

        # Arm 1: session. Open once, prompt N times.
        case_id = f"cumulative/{slice_.case_id}/session"
        started = time.perf_counter()
        try:
            body, open_s = adapter.open_session(slice_.png)
            if not body.get("ok"):
                raise RuntimeError(str(body))
            session_id = body["session_id"]
            cumulative = [open_s]
            for point in points:
                result, wall = adapter.prompt(session_id, points=[point])
                if not result.get("ok"):
                    raise RuntimeError(str(result))
                cumulative.append(cumulative[-1] + wall)
            adapter.close_session(session_id)
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=True,
                wall_s=time.perf_counter() - started,
                stages_s={"open": open_s},
                peak_rss_bytes=adapter.rss_bytes(),
                metrics={"op": "cumulative", "arm": "session",
                         "series": slice_.series_id, "slice": slice_.index,
                         "n_prompts": len(points),
                         "cumulative_s": cumulative},
                notes=notes + ["phase=cumulative"]))
        except Exception as exc:  # noqa: BLE001
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False,
                wall_s=time.perf_counter() - started,
                error=f"{type(exc).__name__}: {exc}",
                notes=notes + ["phase=cumulative"]))

        # Arm 2: re-encode. Open, prompt once, close -- per prompt.
        case_id = f"cumulative/{slice_.case_id}/reencode"
        started = time.perf_counter()
        try:
            cumulative = [0.0]
            for point in points:
                body, open_s = adapter.open_session(slice_.png)
                if not body.get("ok"):
                    raise RuntimeError(str(body))
                session_id = body["session_id"]
                result, wall = adapter.prompt(session_id, points=[point])
                if not result.get("ok"):
                    raise RuntimeError(str(result))
                adapter.close_session(session_id)
                cumulative.append(cumulative[-1] + open_s + wall)
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=True,
                wall_s=time.perf_counter() - started,
                peak_rss_bytes=adapter.rss_bytes(),
                metrics={"op": "cumulative", "arm": "reencode",
                         "series": slice_.series_id, "slice": slice_.index,
                         "n_prompts": len(points),
                         "cumulative_s": cumulative},
                notes=notes + ["phase=cumulative"]))
        except Exception as exc:  # noqa: BLE001
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False,
                wall_s=time.perf_counter() - started,
                error=f"{type(exc).__name__}: {exc}",
                notes=notes + ["phase=cumulative"]))


def phase_eviction(adapter: AdapterClient, slices: Sequence[Slice],
                   recorder: Recorder, max_sessions: int,
                   notes: list[str]) -> None:
    """LRU eviction at the boundary the manifest declares.

    Protocol 1.2 requires the adapter to bound its cache and evict
    least-recently-used. The behaviour that matters to the host is the error it
    gets back: a `not_ready`, which it recovers from by reopening, rather than
    a `bad_input`, which it would surface to the user as a failure.
    """
    print("Phase D: LRU eviction", flush=True)
    case_id = f"eviction/max{max_sessions}"
    started = time.perf_counter()
    metrics: dict[str, Any] = {"op": "eviction", "max_sessions": max_sessions}
    try:
        source = slices[0]
        opened: list[str] = []
        for i in range(max_sessions + 1):
            body, _ = adapter.open_session(source.png)
            if not body.get("ok"):
                raise RuntimeError(str(body))
            opened.append(body["session_id"])
        metrics["opened"] = len(opened)
        metrics["rss_after_open_bytes"] = adapter.rss_bytes()

        point = prompt_points(source, 1, seed=7)
        # The first session is the least recently used and must be gone.
        evicted, _ = adapter.prompt(opened[0], points=point)
        metrics["evicted_ok"] = evicted.get("ok")
        metrics["evicted_error_code"] = (evicted.get("error") or {}).get("code")
        metrics["evicted_recoverable"] = (evicted.get("error") or {}).get("recoverable")

        # Everything after it must still answer.
        survivors = []
        for session_id in opened[1:]:
            result, _ = adapter.prompt(session_id, points=point)
            survivors.append(bool(result.get("ok")))
        metrics["survivors_ok"] = survivors

        # Recency, not insertion order: touching the oldest survivor must save
        # it from the next eviction.
        adapter.prompt(opened[1], points=point)
        body, _ = adapter.open_session(source.png)
        fresh = body["session_id"]
        touched, _ = adapter.prompt(opened[1], points=point)
        metrics["touched_survives"] = bool(touched.get("ok"))
        untouched, _ = adapter.prompt(opened[2], points=point)
        metrics["untouched_evicted"] = not untouched.get("ok")

        for session_id in opened[1:] + [fresh]:
            adapter.close_session(session_id)

        ok = (metrics["evicted_ok"] is False
              and metrics["evicted_error_code"] == "not_ready"
              and all(survivors)
              and metrics["touched_survives"]
              and metrics["untouched_evicted"])
        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=ok,
            wall_s=time.perf_counter() - started, metrics=metrics,
            peak_rss_bytes=adapter.rss_bytes(),
            error=None if ok else "eviction did not behave as the protocol requires",
            notes=notes + ["phase=eviction"]))
    except Exception as exc:  # noqa: BLE001
        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=False,
            wall_s=time.perf_counter() - started, metrics=metrics,
            error=f"{type(exc).__name__}: {exc}",
            notes=notes + ["phase=eviction"]))


def phase_implicit(adapter: AdapterClient, slices: Sequence[Slice],
                   recorder: Recorder, reps: int, notes: list[str]) -> None:
    """The narrower design question the ratio alone does not settle.

    A large encode/decode ratio justifies *caching the embedding*. It does not
    by itself justify an explicit session lifecycle -- `session_id`,
    /session/open, /session/close, an LRU store, a declared `max_sessions` --
    because a plain `resident-server` could reach the same cache implicitly:
    accept `slice2d` with every prompt, hash it, and reuse the embedding on a
    hit. That alternative costs one extra hash and one extra image decode per
    prompt, and nothing else.

    So this phase measures what the implicit design would pay per prompt, at
    the same three levels as everything else, and the report compares it to the
    decode cost rather than to the encode cost. If the overhead is small next
    to a decode, the session lifecycle is not a *performance* necessity and its
    justification has to be made on other grounds -- which is a different, and
    weaker, claim than the one the architecture document currently makes.
    """
    import hashlib

    print("Phase F: implicit content-addressed cache alternative", flush=True)
    for slice_ in slices[:3]:
        case_id = f"implicit/{slice_.case_id}"
        started = time.perf_counter()
        try:
            b64_encode, b64_decode, hashing, png_decode = [], [], [], []
            for _ in range(reps):
                t0 = time.perf_counter()
                encoded = base64.b64encode(slice_.png).decode("ascii")
                b64_encode.append(time.perf_counter() - t0)

                t0 = time.perf_counter()
                raw = base64.b64decode(encoded, validate=True)
                b64_decode.append(time.perf_counter() - t0)

                t0 = time.perf_counter()
                hashlib.blake2b(raw, digest_size=16).hexdigest()
                hashing.append(time.perf_counter() - t0)

                # The image decode is what an implicit cache would still have to
                # do on a miss but could skip on a hit; timed separately so the
                # comparison can be made either way.
                t0 = time.perf_counter()
                from _shared.sam_session import decode_png  # noqa: PLC0415

                decode_png(raw)
                png_decode.append(time.perf_counter() - t0)

            overhead_ms = (statistics.median(b64_encode)
                           + statistics.median(b64_decode)
                           + statistics.median(hashing)) * 1000.0
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=True,
                wall_s=time.perf_counter() - started,
                metrics={"op": "implicit", "series": slice_.series_id,
                         "slice": slice_.index, "reps": reps,
                         "png_bytes": len(slice_.png),
                         "b64_encode_ms": statistics.median(b64_encode) * 1000.0,
                         "b64_decode_ms": statistics.median(b64_decode) * 1000.0,
                         "hash_ms": statistics.median(hashing) * 1000.0,
                         "png_decode_ms": statistics.median(png_decode) * 1000.0,
                         "implicit_overhead_ms": overhead_ms},
                notes=notes + ["phase=implicit"]))
        except Exception as exc:  # noqa: BLE001
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False,
                wall_s=time.perf_counter() - started,
                error=f"{type(exc).__name__}: {exc}",
                metrics={"op": "implicit", "series": slice_.series_id},
                notes=notes + ["phase=implicit"]))


def phase_threads(slices: Sequence[Slice], weights: Path, recorder: Recorder,
                  thread_counts: Sequence[int], notes: list[str]) -> None:
    """How encode and decode respond to added parallel compute.

    The ratio measured here is a CPU ratio, and the design will be deployed on
    a machine with a GPU. Rather than assert that the ratio transfers, this
    phase measures the two operations' sensitivity to compute width. An encoder
    that scales with cores is compute-bound and would be accelerated by a GPU;
    a decoder that does not scale is bound by launch and Python overhead, which
    a GPU does not remove. The gap between the two scaling exponents bounds how
    far the ratio could compress on an accelerator.
    """
    print("Phase E: thread scaling", flush=True)
    script = Path(__file__).resolve()
    for threads in thread_counts:
        case_id = f"threads/{threads}"
        started = time.perf_counter()
        env = dict(os.environ)
        env["ODV_SAM2_WEIGHTS"] = str(weights)
        env["PYTHONPATH"] = str(REPO_ROOT / "plugins")
        env["OMP_NUM_THREADS"] = str(threads)
        env["MKL_NUM_THREADS"] = str(threads)
        try:
            result = subprocess.run(
                [sys.executable, str(script), "--thread-worker",
                 "--threads", str(threads), "--weights", str(weights)],
                capture_output=True, text=True, env=env, timeout=1800,
                input=json.dumps({"png_b64": base64.b64encode(slices[0].png).decode(),
                                  "points": prompt_points(slices[0], 5, seed=11)}),
            )
            if result.returncode != 0:
                raise RuntimeError(result.stderr[-400:])
            payload = json.loads(result.stdout.strip().splitlines()[-1])
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=True,
                wall_s=time.perf_counter() - started,
                metrics={"op": "threads", "threads": threads, **payload},
                notes=notes + ["phase=threads"]))
        except Exception as exc:  # noqa: BLE001
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False,
                wall_s=time.perf_counter() - started,
                error=f"{type(exc).__name__}: {exc}",
                metrics={"op": "threads", "threads": threads},
                notes=notes + ["phase=threads"]))


def phase_work(slices: Sequence[Slice], weights: Path, recorder: Recorder,
               notes: list[str]) -> None:
    """Arithmetic work and resident memory, measured device-independently.

    Every latency in this experiment is CPU-only, and the design will be
    deployed on a machine with a GPU. Rather than argue that the measured ratio
    transfers, this phase measures the quantity an accelerator does not change:
    the floating-point work each operation performs. A GPU changes how fast
    those operations retire, not how many there are, so a FLOP ratio bounds the
    latency ratio from a direction no device can reverse -- for the encode to
    stop dominating, an accelerator would have to make the encoder's arithmetic
    cheaper per operation than the decoder's, which is the opposite of how
    wider parallel hardware behaves on the larger of two workloads.

    Peak resident memory of a bare adapter process is recorded here too,
    against the 3.0 GB the manifest declares -- invariant 4 makes that
    declaration load-bearing for the arbiter's admission decisions.
    """
    print("Phase G: arithmetic work and resident memory", flush=True)
    script = Path(__file__).resolve()
    env = dict(os.environ)
    env["ODV_SAM2_WEIGHTS"] = str(weights)
    env["PYTHONPATH"] = str(REPO_ROOT / "plugins")

    case_id = "work/flops"
    started = time.perf_counter()
    try:
        from harness import run_subprocess  # noqa: PLC0415

        payload = json.dumps({
            "png_b64": base64.b64encode(slices[0].png).decode(),
            "points": prompt_points(slices[0], 3, seed=23),
        })
        # run_subprocess reads the child's own peak RSS from the kernel, which
        # is the number the arbiter's declaration should be checked against.
        input_path = Path(tempfile.mkstemp(suffix=".json")[1])
        input_path.write_text(payload)
        # The child writes its result to a file rather than stdout:
        # run_subprocess merges stderr, and torch's loaders emit progress bars
        # there, so the last line of the combined stream is not reliably the
        # payload.
        result_path = Path(tempfile.mkstemp(suffix=".json")[1])
        code, output, peak_rss = run_subprocess(
            [sys.executable, str(script), "--work-worker",
             "--weights", str(weights), "--work-input", str(input_path),
             "--work-output", str(result_path)],
            env=env, timeout=1800,
        )
        input_path.unlink(missing_ok=True)
        if code != 0:
            raise RuntimeError(output[-500:])
        metrics = json.loads(result_path.read_text())
        result_path.unlink(missing_ok=True)
        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=True,
            wall_s=time.perf_counter() - started, peak_rss_bytes=peak_rss,
            metrics={"op": "work", **metrics,
                     "declared_ram_gb": 3.0,
                     "peak_rss_gb": peak_rss / 1e9},
            notes=notes + ["phase=work"]))
    except Exception as exc:  # noqa: BLE001
        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=False,
            wall_s=time.perf_counter() - started,
            error=f"{type(exc).__name__}: {exc}",
            metrics={"op": "work"}, notes=notes + ["phase=work"]))


def work_worker(weights: Path, input_path: Path,
                output_path: Path) -> int:
    """Count FLOPs for one encode and one decode, and break the decode down.

    The decode figure quoted elsewhere is the whole /task/prompt-mask path. It
    is worth knowing how much of that is the mask decoder itself versus mask
    post-processing and RLE emission, because the parts differ in what an
    accelerator would do to them.
    """
    import torch
    from PIL import Image

    payload = json.loads(Path(input_path).read_text())
    png = base64.b64decode(payload["png_b64"])
    points = payload["points"]

    os.environ["ODV_SAM2_WEIGHTS"] = str(weights)
    sys.path.insert(0, str(REPO_ROOT / "plugins"))
    from sam2.server import Sam2Backend  # noqa: PLC0415
    from _shared.rle import mask2d_payload  # noqa: PLC0415

    backend = Sam2Backend()
    backend.ensure_loaded()
    image = Image.open(io.BytesIO(png)).convert("RGB")
    width, height = image.size
    pixel_points = [(int(p["x"] * width), int(p["y"] * height), 1) for p in points]

    state = backend.encode(image)
    backend.decode(state, pixel_points[:1], None, None, False)

    out: dict[str, Any] = {}

    # Parameter counts are exact and need no profiler.
    model = backend._model  # noqa: SLF001 - measuring the adapter's own model
    def count(module: Any) -> int:
        return sum(p.numel() for p in module.parameters())

    try:
        out["params_total"] = count(model)
        out["params_vision_encoder"] = count(model.vision_encoder) \
            if hasattr(model, "vision_encoder") else None
        for name in ("mask_decoder", "prompt_encoder"):
            if hasattr(model, name):
                out[f"params_{name}"] = count(getattr(model, name))
    except Exception as exc:  # noqa: BLE001
        out["params_error"] = str(exc)

    # FLOPs via torch's dispatch-level counter: it counts the operations that
    # actually ran, so it needs no model-specific accounting and cannot drift
    # from the code path the adapter uses.
    try:
        from torch.utils.flop_counter import FlopCounterMode  # noqa: PLC0415

        with FlopCounterMode(display=False) as counter:
            fresh = backend.encode(image)
        out["encode_flops"] = counter.get_total_flops()

        with FlopCounterMode(display=False) as counter:
            backend.decode(fresh, pixel_points[:1], None, None, False)
        out["decode_flops"] = counter.get_total_flops()

        if out["decode_flops"]:
            out["flop_ratio"] = out["encode_flops"] / out["decode_flops"]
    except Exception as exc:  # noqa: BLE001
        out["flops_error"] = f"{type(exc).__name__}: {exc}"

    # Where the decode's wall time actually goes.
    processor = backend._processor  # noqa: SLF001
    try:
        input_points = [[[[int(x), int(y)] for x, y, _ in pixel_points[:1]]]]
        input_labels = [[[1]]]
        prep = processor(input_points=input_points, input_labels=input_labels,
                         original_sizes=state["original_sizes"],
                         return_tensors="pt")
        t0 = time.perf_counter()
        for _ in range(5):
            processor(input_points=input_points, input_labels=input_labels,
                      original_sizes=state["original_sizes"], return_tensors="pt")
        out["decode_prompt_prep_ms"] = (time.perf_counter() - t0) / 5 * 1000.0

        t0 = time.perf_counter()
        for _ in range(5):
            with torch.inference_mode():
                outputs = model(image_embeddings=state["embeddings"],
                                multimask_output=False, **prep)
        out["decode_model_ms"] = (time.perf_counter() - t0) / 5 * 1000.0

        t0 = time.perf_counter()
        for _ in range(5):
            masks = processor.post_process_masks(
                outputs.pred_masks, state["original_sizes"], binarize=False)[0]
        out["decode_postprocess_ms"] = (time.perf_counter() - t0) / 5 * 1000.0

        flat = masks.reshape(-1, masks.shape[-2], masks.shape[-1])
        mask = (flat[0] > 0).detach().to("cpu").numpy()
        t0 = time.perf_counter()
        for _ in range(5):
            payload_out = mask2d_payload(mask, confidence=0.5)
        out["decode_rle_ms"] = (time.perf_counter() - t0) / 5 * 1000.0
        out["rle_runs"] = len(payload_out["rle"])
        out["mask_pixels"] = int(mask.sum())
    except Exception as exc:  # noqa: BLE001
        out["breakdown_error"] = f"{type(exc).__name__}: {exc}"

    out["embedding_bytes"] = _state_bytes(state)
    out["torch_threads"] = torch.get_num_threads()
    Path(output_path).write_text(json.dumps(out))
    return 0


def thread_worker(threads: int, weights: Path) -> int:
    """In-process encode/decode timing at a fixed torch thread count.

    Run as a subprocess because torch's thread count cannot be changed
    meaningfully after the first parallel region.
    """
    import torch
    from PIL import Image

    torch.set_num_threads(threads)
    payload = json.loads(sys.stdin.read())
    png = base64.b64decode(payload["png_b64"])
    points = payload["points"]

    os.environ["ODV_SAM2_WEIGHTS"] = str(weights)
    sys.path.insert(0, str(REPO_ROOT / "plugins"))
    from sam2.server import Sam2Backend  # noqa: PLC0415

    backend = Sam2Backend()
    backend.ensure_loaded()
    image = Image.open(io.BytesIO(png)).convert("RGB")
    width, height = image.size
    pixel_points = [(int(p["x"] * width), int(p["y"] * height), 1) for p in points]

    # One untimed pass: the first call through torch pays lazy kernel selection
    # that belongs to neither operation.
    state = backend.encode(image)
    backend.decode(state, pixel_points[:1], None, None, False)

    encodes = []
    for _ in range(3):
        t0 = time.perf_counter()
        state = backend.encode(image)
        encodes.append(time.perf_counter() - t0)

    decodes = []
    for point in pixel_points:
        for _ in range(3):
            t0 = time.perf_counter()
            backend.decode(state, [point], None, None, False)
            decodes.append(time.perf_counter() - t0)

    embedding_bytes = _state_bytes(state)
    print(json.dumps({
        "torch_threads": torch.get_num_threads(),
        "encode_ms_median": statistics.median(encodes) * 1000.0,
        "decode_ms_median": statistics.median(decodes) * 1000.0,
        "encode_ms": [e * 1000.0 for e in encodes],
        "decode_ms": [d * 1000.0 for d in decodes],
        "ratio_median": statistics.median(encodes) / statistics.median(decodes),
        "embedding_bytes": embedding_bytes,
    }))
    return 0


def _state_bytes(state: Any) -> int | None:
    """Bytes held by one cached session, which is what max_sessions bounds."""
    try:
        import torch

        total = 0
        stack = [state]
        while stack:
            item = stack.pop()
            if isinstance(item, torch.Tensor):
                total += item.element_size() * item.nelement()
            elif isinstance(item, dict):
                stack.extend(item.values())
            elif isinstance(item, (list, tuple)):
                stack.extend(item)
        return total
    except Exception:  # noqa: BLE001
        return None


# ---------------------------------------------------------------------------
# Summary and figures
# ---------------------------------------------------------------------------


def _rows_where(rows: Iterable[dict], **conditions: Any) -> list[dict]:
    out = []
    for row in rows:
        metrics = row.get("metrics") or {}
        if all(metrics.get(key) == value for key, value in conditions.items()):
            out.append(row)
    return out


def summarize(results_path: Path, csv_path: Path) -> dict:
    """Condense the JSONL into the numbers the paper reports."""
    header, rows = load_results(results_path)
    ok_rows = [r for r in rows if r.get("ok")]

    encode = _rows_where(ok_rows, op="encode")
    decode = _rows_where(ok_rows, op="decode")

    def field(rows_: Sequence[dict], key: str) -> list[float]:
        return [float(r["metrics"][key]) for r in rows_
                if r["metrics"].get(key) is not None]

    summary: dict[str, Any] = {
        "n_encode": len(encode),
        "n_decode": len(decode),
        "gpu_visible": (header.get("machine") or {}).get("gpu_visible"),
        "chip": (header.get("machine") or {}).get("chip"),
    }

    # A partial phase selection is a supported way to run this script, so every
    # derived quantity below is conditional on its phase having produced rows.
    levels = {
        "model": (field(encode, "encode_ms"), field(decode, "server_ms")),
        "client": (field(encode, "client_ms"), field(decode, "client_ms")),
    }
    for level, (enc, dec) in levels.items():
        if not enc or not dec:
            continue
        summary[f"encode_ms_{level}_median"] = statistics.median(enc)
        summary[f"decode_ms_{level}_median"] = statistics.median(dec)
        summary[f"encode_ms_{level}_iqr"] = _iqr(enc)
        summary[f"decode_ms_{level}_iqr"] = _iqr(dec)
        summary[f"ratio_{level}_median"] = statistics.median(enc) / statistics.median(dec)

    # Per-slice ratios: the spread that matters is across slices, since a
    # single-slice ratio would not tell us whether the design holds generally.
    per_slice: list[float] = []
    slices = {r["metrics"]["slice"] for r in encode if "slice" in r["metrics"]}
    for index in sorted(slices):
        enc = field(_rows_where(encode, slice=index), "client_ms")
        dec = field(_rows_where(decode, slice=index), "client_ms")
        if enc and dec:
            per_slice.append(statistics.median(enc) / statistics.median(dec))
    if per_slice:
        summary["ratio_client_per_slice"] = per_slice
        summary["ratio_client_per_slice_median"] = statistics.median(per_slice)
        summary["ratio_client_per_slice_min"] = min(per_slice)
        summary["ratio_client_per_slice_max"] = max(per_slice)

    # Break-even: prompts after which a session has repaid its encode.
    if per_slice:
        summary["breakeven_prompts"] = 2  # session pays 1 encode; re-encode pays N

    implicit = _rows_where(ok_rows, op="implicit")
    if implicit:
        overheads = field(implicit, "implicit_overhead_ms")
        summary["implicit_overhead_ms_median"] = statistics.median(overheads)
        summary["implicit_png_decode_ms_median"] = statistics.median(
            field(implicit, "png_decode_ms"))
        if summary.get("decode_ms_client_median"):
            summary["implicit_overhead_vs_decode"] = (
                statistics.median(overheads) / summary["decode_ms_client_median"])
            summary["implicit_overhead_plus_pngdecode_vs_decode"] = (
                (statistics.median(overheads)
                 + summary["implicit_png_decode_ms_median"])
                / summary["decode_ms_client_median"])

    threads = _rows_where(ok_rows, op="threads")
    if threads:
        summary["thread_scaling"] = sorted(
            [{"threads": r["metrics"]["threads"],
              "encode_ms": r["metrics"]["encode_ms_median"],
              "decode_ms": r["metrics"]["decode_ms_median"],
              "ratio": r["metrics"]["ratio_median"]} for r in threads],
            key=lambda d: d["threads"])
        embedding = [r["metrics"].get("embedding_bytes") for r in threads
                     if r["metrics"].get("embedding_bytes")]
        if embedding:
            summary["embedding_bytes"] = embedding[0]

    work = _rows_where(ok_rows, op="work")
    if work:
        metrics = work[-1]["metrics"]
        for key in ("encode_flops", "decode_flops", "flop_ratio",
                    "params_total", "params_vision_encoder",
                    "params_mask_decoder", "params_prompt_encoder",
                    "decode_prompt_prep_ms", "decode_model_ms",
                    "decode_postprocess_ms", "decode_rle_ms",
                    "peak_rss_gb", "declared_ram_gb", "embedding_bytes"):
            if metrics.get(key) is not None:
                summary[key] = metrics[key]
        if metrics.get("embedding_bytes"):
            summary["session_cache_bytes_max"] = (
                metrics["embedding_bytes"] * 4)  # max_sessions = 4

    eviction = _rows_where(rows, op="eviction")
    if eviction:
        summary["eviction"] = eviction[-1]["metrics"]
        summary["eviction_ok"] = eviction[-1]["ok"]

    roundtrip = [r for r in rows if "phase=roundtrip" in (r.get("notes") or [])]
    summary["roundtrip_total"] = len(roundtrip)
    summary["roundtrip_ok"] = sum(1 for r in roundtrip if r.get("ok"))
    summary["roundtrip_swift_verified"] = sum(
        1 for r in roundtrip if (r.get("metrics") or {}).get("swift_agrees"))
    summary["roundtrip_prompt_inside"] = sum(
        1 for r in roundtrip if (r.get("metrics") or {}).get("prompt_inside_mask"))
    negatives = [r for r in roundtrip
                 if (r.get("metrics") or {}).get("label_respected") is not None]
    summary["roundtrip_negative_cases"] = len(negatives)
    summary["roundtrip_label_respected"] = sum(
        1 for r in negatives if r["metrics"]["label_respected"])
    # Recorded but deliberately not asserted on: excluding a region can make
    # the model settle on a larger neighbouring structure, so the sign of this
    # delta is not a correctness signal.
    summary["roundtrip_negative_pixels_delta"] = [
        r["metrics"].get("pixels_delta") for r in negatives]

    # A case id that failed and was later re-run successfully is reported
    # separately from one that never succeeded. Both stay in the file --
    # dropping the failed attempt would hide that a retry was needed -- but
    # only the second kind is an outstanding failure.
    succeeded = {r["case_id"] for r in ok_rows}
    failures = [r for r in rows if not r.get("ok")]
    outstanding = [r for r in failures if r["case_id"] not in succeeded]
    summary["n_failed"] = len(outstanding)
    summary["failed_case_ids"] = [r["case_id"] for r in outstanding][:20]
    summary["n_failed_then_retried"] = len(failures) - len(outstanding)
    summary["retried_case_ids"] = sorted(
        {r["case_id"] for r in failures if r["case_id"] in succeeded})[:20]

    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with open(csv_path, "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["quantity", "value"])
        for key, value in summary.items():
            writer.writerow([key, json.dumps(value) if isinstance(value, (list, dict))
                             else value])
    return summary


def _iqr(values: Sequence[float]) -> list[float]:
    ordered = sorted(values)
    if len(ordered) < 4:
        return [ordered[0], ordered[-1]] if ordered else []
    quantiles = statistics.quantiles(ordered, n=4, method="inclusive")
    return [quantiles[0], quantiles[2]]


# Colour is bound to the operation, not to the panel: encode is blue and
# decode is orange everywhere they appear, so the cross-reference between
# panels needs no legend lookup.
C_ENCODE = "#2f5d8a"
C_DECODE = "#c26a3d"
C_NEUTRAL = "#666666"
C_ALARM = "#a03030"


def make_figures(results_path: Path, figures_dir: Path) -> list[Path]:
    """The two figures the paper needs: what it costs, and whether it transfers."""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    plt.rcParams.update({
        "font.size": 8, "axes.titlesize": 8, "axes.labelsize": 8,
        "xtick.labelsize": 6.5, "ytick.labelsize": 6.5, "legend.fontsize": 7,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.grid": True, "grid.alpha": 0.22, "axes.axisbelow": True,
        "figure.dpi": 300,
    })

    header, rows = load_results(results_path)
    ok_rows = [r for r in rows if r.get("ok")]
    encode = [float(r["metrics"]["client_ms"])
              for r in _rows_where(ok_rows, op="encode")]
    decode = [float(r["metrics"]["client_ms"])
              for r in _rows_where(ok_rows, op="decode")]
    figures_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    if not encode or not decode:
        print("  no ratio rows; skipping figures", flush=True)
        return written

    machine = header.get("machine") or {}
    gpu = machine.get("gpu_visible") or {}
    accelerated = bool(gpu.get("torch_mps") or gpu.get("torch_cuda"))
    device_note = ("CPU only, no accelerator visible to the measuring process"
                   if not accelerated else "accelerator visible")
    chip = machine.get("chip", machine.get("machine", "unknown"))

    def panel_letter(ax: Any, letter: str) -> None:
        ax.text(-0.16, 1.06, letter, transform=ax.transAxes, fontsize=10,
                fontweight="bold", va="bottom", ha="left")

    # =====================================================================
    # Figure 1 — the measurement the design rests on
    # =====================================================================
    fig = plt.figure(figsize=(7.2, 3.0))
    grid = fig.add_gridspec(1, 2, width_ratios=[1.0, 1.35], wspace=0.34,
                            left=0.09, right=0.985, top=0.80, bottom=0.17)
    ax_a = fig.add_subplot(grid[0, 0])
    ax_b = fig.add_subplot(grid[0, 1])

    # -- A: per-operation cost --------------------------------------------
    rng = np.random.default_rng(0)
    for pos, values, colour in ((1, encode, C_ENCODE), (2, decode, C_DECODE)):
        ax_a.scatter(pos + rng.normal(0, 0.055, len(values)), values, s=5,
                     color=colour, alpha=0.45, linewidths=0)
        median = statistics.median(values)
        ax_a.hlines(median, pos - 0.28, pos + 0.28, color=colour, lw=2.0,
                    zorder=5)
        ax_a.annotate(f"{median:,.0f} ms", (pos + 0.31, median), va="center",
                      ha="left", fontsize=7.5, color=colour, fontweight="bold")
    ratio = statistics.median(encode) / statistics.median(decode)
    ax_a.set_yscale("log")
    ax_a.set_xlim(0.55, 2.75)
    ax_a.set_xticks([1, 2])
    ax_a.set_xticklabels([f"encode\n/session/open\nn={len(encode)}",
                          f"decode\n/task/prompt-mask\nn={len(decode)}"])
    ax_a.set_ylabel("round-trip latency (ms)")
    ax_a.set_yticks([50, 100, 500, 1000, 2000])
    ax_a.set_yticklabels(["50", "100", "500", "1000", "2000"])
    ax_a.grid(axis="y", which="both", alpha=0.22)
    ax_a.set_title(f"Encoding a slice costs {ratio:.0f}× decoding a prompt",
                   loc="left")
    panel_letter(ax_a, "a")

    # -- B: cumulative cost, both arms measured ---------------------------
    def mean_curve(rows_: Sequence[dict]) -> np.ndarray | None:
        curves = [np.asarray(r["metrics"]["cumulative_s"], dtype=float)
                  for r in rows_ if r["metrics"].get("cumulative_s")]
        if not curves:
            return None
        length = min(len(c) for c in curves)
        return np.mean([c[:length] for c in curves], axis=0)

    session_curve = mean_curve(_rows_where(ok_rows, op="cumulative",
                                           arm="session"))
    reencode_curve = mean_curve(_rows_where(ok_rows, op="cumulative",
                                            arm="reencode"))
    n_series = len(_rows_where(ok_rows, op="cumulative", arm="session"))

    if session_curve is not None and reencode_curve is not None:
        n = np.arange(len(session_curve))
        ax_b.fill_between(n, session_curve, reencode_curve, color=C_DECODE,
                          alpha=0.09, linewidth=0)
        ax_b.plot(n, reencode_curve, "-", color=C_DECODE, lw=1.8)
        ax_b.plot(n, session_curve, "-", color=C_ENCODE, lw=1.8)
        ax_b.plot(n[::2], reencode_curve[::2], "o", color=C_DECODE, ms=3.2)
        ax_b.plot(n[::2], session_curve[::2], "o", color=C_ENCODE, ms=3.2)

        # Direct labels rather than a legend box, anchored partway along each
        # curve so neither collides with the title or leaves the axes.
        mid = max(1, int(len(n) * 0.62))
        ax_b.annotate("re-encode every prompt\n(resident-server)",
                      (n[mid], reencode_curve[mid]), xytext=(-8, 2),
                      textcoords="offset points", ha="right", va="bottom",
                      color=C_DECODE, fontsize=7)
        # Above its own curve: below it would run into the x tick labels, since
        # the session curve sits close to the axis floor by construction.
        ax_b.annotate("encode once, re-prompt (session)",
                      (n[mid], session_curve[mid]), xytext=(0, 7),
                      textcoords="offset points", ha="center", va="bottom",
                      color=C_ENCODE, fontsize=7)

        ahead = np.nonzero(session_curve < reencode_curve)[0]
        if len(ahead):
            k = int(ahead[0])
            ax_b.axvline(k, color=C_NEUTRAL, ls=":", lw=1.0)
            ax_b.annotate(f"session ahead\nfrom prompt {k}",
                          (k, reencode_curve[-1] * 1.03), xytext=(4, 0),
                          textcoords="offset points", ha="left", va="top",
                          color=C_NEUTRAL, fontsize=7)
        gap = reencode_curve[-1] - session_curve[-1]
        ax_b.annotate(f"{gap:.0f} s saved\nover {len(n) - 1} prompts",
                      (n[-1] - 0.3, reencode_curve[-1] * 0.55), ha="right",
                      va="center", fontsize=7.5, color="#333333")
        ax_b.set_xlabel("prompts issued on one slice")
        ax_b.set_ylabel("cumulative wall time (s)")
        ax_b.margins(x=0.04)
        ax_b.set_ylim(0, reencode_curve[-1] * 1.12)
        ax_b.set_title("Caching repays its encode at the second prompt",
                       loc="left", pad=9)
        panel_letter(ax_b, "b")

    # Wrapped onto two lines: as one left-anchored line this ran past the right
    # edge of the canvas and the device caveat — the part a reader most needs —
    # was the piece that got clipped.
    fig.suptitle(
        f"SAM 2 (sam2.1-hiera-small) over the ODV plugin protocol · {chip}\n"
        f"{device_note} · mean of {n_series} slices in b",
        fontsize=7, y=1.005, color="#555555", x=0.09, ha="left",
        linespacing=1.5)
    path = figures_dir / "exp4_encode_decode.png"
    fig.savefig(path, dpi=300, bbox_inches="tight")
    plt.close(fig)
    written.append(path)

    # =====================================================================
    # Figure 2 — would the ratio survive a GPU?
    # =====================================================================
    threads = sorted(_rows_where(ok_rows, op="threads"),
                     key=lambda r: r["metrics"]["threads"])
    work = _rows_where(ok_rows, op="work")
    if len(threads) >= 2:
        fig2 = plt.figure(figsize=(7.2, 2.9))
        grid2 = fig2.add_gridspec(1, 3, wspace=0.42, left=0.075, right=0.985,
                                  top=0.79, bottom=0.18)
        ax_c = fig2.add_subplot(grid2[0, 0])
        ax_d = fig2.add_subplot(grid2[0, 1])
        ax_e = fig2.add_subplot(grid2[0, 2])

        counts = [r["metrics"]["threads"] for r in threads]
        enc = [r["metrics"]["encode_ms_median"] for r in threads]
        dec = [r["metrics"]["decode_ms_median"] for r in threads]

        ax_c.plot(counts, [c / counts[0] for c in counts], ":",
                  color=C_NEUTRAL, lw=1.1)
        ax_c.annotate("linear", (counts[-1], counts[-1] / counts[0]),
                      xytext=(-2, -8), textcoords="offset points", ha="right",
                      va="top", color=C_NEUTRAL, fontsize=7)
        ax_c.plot(counts, [enc[0] / e for e in enc], "-o", color=C_ENCODE,
                  lw=1.8, ms=3.5)
        ax_c.plot(counts, [dec[0] / d for d in dec], "-o", color=C_DECODE,
                  lw=1.8, ms=3.5)
        ax_c.annotate("encode", (counts[-1], enc[0] / enc[-1]), xytext=(-2, 6),
                      textcoords="offset points", ha="right", color=C_ENCODE,
                      fontsize=7)
        ax_c.annotate("decode", (counts[-1], dec[0] / dec[-1]), xytext=(-2, -9),
                      textcoords="offset points", ha="right", color=C_DECODE,
                      fontsize=7)
        ax_c.set_xscale("log", base=2)
        ax_c.set_xticks(counts)
        ax_c.set_xticklabels([str(c) for c in counts])
        ax_c.set_xlabel("CPU threads")
        ax_c.set_ylabel(f"speed-up vs {counts[0]} thread")
        ax_c.margins(0.06)
        ax_c.set_title("Encode absorbs added\ncompute; decode does not",
                       loc="left")
        panel_letter(ax_c, "c")

        ratios = [r["metrics"]["ratio_median"] for r in threads]
        ax_d.plot(counts, ratios, "-o", color=C_ENCODE, lw=1.8, ms=4)
        for i, (c, r) in enumerate(zip(counts, ratios)):
            if i in (0, len(counts) - 1):
                ax_d.annotate(f"{r:.0f}×", (c, r), textcoords="offset points",
                              xytext=(0, 7), ha="center", fontsize=7.5,
                              color=C_ENCODE)
        ax_d.axhline(1.0, color=C_ALARM, ls="--", lw=1.1)
        ax_d.annotate("ratio 1: session\nunjustified", (counts[0], 1.0),
                      xytext=(3, 5), textcoords="offset points", fontsize=7,
                      color=C_ALARM, va="bottom")
        ax_d.set_yscale("log")
        ax_d.set_xscale("log", base=2)
        ax_d.set_xticks(counts)
        ax_d.set_xticklabels([str(c) for c in counts])
        ax_d.set_yticks([1, 3, 10, 30])
        ax_d.set_yticklabels(["1", "3", "10", "30"])
        ax_d.set_ylim(0.7, 60)
        ax_d.set_xlabel("CPU threads")
        ax_d.set_ylabel("encode / decode ratio")
        ax_d.set_title("Wider compute compresses\nthe ratio, never closes it",
                       loc="left")
        panel_letter(ax_d, "d")

        # -- E: the device-independent bound ------------------------------
        if work:
            metrics = work[-1]["metrics"]
            latency_ratio = statistics.median(encode) / statistics.median(decode)
            flop_ratio = metrics.get("flop_ratio")
            bars = [("measured\nlatency", latency_ratio, C_ENCODE),
                    ("arithmetic\nwork (FLOPs)", flop_ratio, C_NEUTRAL)]
            bars = [b for b in bars if b[1]]
            for i, (label, value, colour) in enumerate(bars):
                # Points with stems, not filled bars: the value axis is log.
                ax_e.vlines(i, 1.0, value, color=colour, lw=1.2, alpha=0.5)
                ax_e.plot(i, value, "o", color=colour, ms=7)
                ax_e.annotate(f"{value:.0f}×", (i, value),
                              xytext=(0, 8), textcoords="offset points",
                              ha="center", fontsize=8, fontweight="bold",
                              color=colour)
            ax_e.axhline(1.0, color=C_ALARM, ls="--", lw=1.1)
            ax_e.set_yscale("log")
            ax_e.set_xlim(-0.6, len(bars) - 0.4)
            ax_e.set_xticks(range(len(bars)))
            ax_e.set_xticklabels([b[0] for b in bars])
            ax_e.set_yticks([1, 10, 100])
            ax_e.set_yticklabels(["1", "10", "100"])
            ax_e.set_ylim(0.7, 300)
            ax_e.set_ylabel("encode / decode ratio")
            ax_e.set_title("Arithmetic favours encode\neven further than time",
                           loc="left")
            panel_letter(ax_e, "e")

        fig2.suptitle(
            f"Does the ratio survive an accelerator? · {chip} · {device_note}",
            fontsize=7, y=0.985, color="#555555", x=0.075, ha="left")
        path2 = figures_dir / "exp4_thread_scaling.png"
        fig2.savefig(path2, dpi=300, bbox_inches="tight")
        plt.close(fig2)
        written.append(path2)

    return written


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", type=Path,
                        default=REPO_ROOT / ".eval" / "data",
                        help="Root of the fetched public cohort")
    parser.add_argument("--weights", type=Path,
                        default=REPO_ROOT / ".eval" / "weights" / "sam2",
                        help="Directory holding the SAM 2 transformers checkpoint")
    parser.add_argument("--out", type=Path,
                        default=REPO_ROOT / "eval" / "results" / "exp4_session.jsonl")
    parser.add_argument("--csv", type=Path,
                        default=REPO_ROOT / "eval" / "results" / "exp4_session.csv")
    parser.add_argument("--figures", type=Path,
                        default=REPO_ROOT / "eval" / "figures")
    parser.add_argument("--slices", type=int, default=6,
                        help="Slices to encode, spread through the series")
    parser.add_argument("--series", type=int, default=2,
                        help="Series to draw slices from")
    parser.add_argument("--encode-reps", type=int, default=5)
    parser.add_argument("--prompts", type=int, default=12)
    parser.add_argument("--decode-reps", type=int, default=3)
    parser.add_argument("--max-sessions", type=int, default=4,
                        help="Must match MAX_SESSIONS in the adapter")
    parser.add_argument("--port", type=int, default=8931)
    parser.add_argument("--transport", choices=("auto", "subprocess", "asgi"),
                        default="auto",
                        help="How to reach the adapter. `subprocess` is what "
                             "the host does and is preferred; `asgi` drives the "
                             "same app in-process for environments that deny "
                             "bind(2). `auto` tries the former and falls back.")
    parser.add_argument("--threads", type=int, default=None,
                        help="Internal: torch thread count for --thread-worker")
    parser.add_argument("--thread-worker", action="store_true",
                        help="Internal: run one thread-scaling measurement")
    parser.add_argument("--work-worker", action="store_true",
                        help="Internal: count FLOPs and break the decode down")
    parser.add_argument("--work-input", type=Path, default=None,
                        help="Internal: JSON payload for --work-worker")
    parser.add_argument("--work-output", type=Path, default=None,
                        help="Internal: where --work-worker writes its result")
    parser.add_argument("--summarize-only", action="store_true",
                        help="Recompute the CSV and figures from an existing JSONL")
    parser.add_argument("--phases", default="all",
                        help="Comma-separated subset of "
                             "roundtrip,ratio,cumulative,eviction,implicit,"
                             "threads,work — appends to an existing JSONL")
    args = parser.parse_args(argv)

    if args.thread_worker:
        return thread_worker(args.threads or 1, args.weights)

    if args.work_worker:
        return work_worker(args.weights, args.work_input,
                           args.work_output)

    if args.summarize_only:
        summary = summarize(args.out, args.csv)
        figures = make_figures(args.out, args.figures)
        print(json.dumps(summary, indent=2, default=str))
        print("\n".join(str(p) for p in figures))
        return 0

    all_phases = ("roundtrip", "ratio", "cumulative", "eviction", "implicit",
                  "threads", "work")
    selected = set(all_phases) if args.phases == "all" else {
        p.strip() for p in args.phases.split(",") if p.strip()}
    unknown = selected - set(all_phases)
    if unknown:
        print(f"unknown phases: {sorted(unknown)}", file=sys.stderr)
        return 2

    series_dirs = sorted(d for d in (args.data_root / "tcia").iterdir()
                         if d.is_dir() and any(d.rglob("*.dcm")))
    if not series_dirs:
        print(f"no DICOM series under {args.data_root / 'tcia'}", file=sys.stderr)
        return 2
    series_dirs = series_dirs[:args.series]

    per_series = max(1, args.slices // len(series_dirs))
    slices: list[Slice] = []
    for series_dir in series_dirs:
        slices.extend(render_slices(series_dir, per_series))
    print(f"{len(slices)} slices from {len(series_dirs)} series", flush=True)

    notes = [
        "SAM 2 via transformers Sam2Model on the real adapter's HTTP surface",
        "no accelerator visible to this process; timings are CPU-only and are "
        "not desktop performance",
    ]

    recorder = Recorder(args.out, EXPERIMENT)
    swift = build_swift_decoder(Path(tempfile.mkdtemp(prefix="odv_swiftdec_")))
    if swift is None:
        notes.append("Swift decoder unavailable; RLE checked against the Python "
                     "mirror only")
    else:
        print(f"Swift decoder oracle: {swift}", flush=True)

    log_path = args.out.parent / "exp4_adapter.log"
    with AdapterClient(args.weights, args.port, log_path,
                       transport=args.transport) as adapter:
        # Recorded on every row: which transport produced the number is part of
        # what the number means, and a reader must not have to infer it.
        notes.append(f"transport={adapter.transport}")
        if adapter.transport == "asgi":
            notes.append(
                "in-process ASGI: bind(2) denied in this environment. Loopback "
                "socket and HTTP framing are omitted; routing, validation, "
                "inference, and RLE emission are unchanged. The omission "
                "removes more from encode (200 kB PNG upload) than from decode, "
                "so the ratio reported is a lower bound.")
        health = adapter.health()
        capabilities = adapter.capabilities()
        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id="adapter/handshake",
            ok=(health.get("protocol") == 1 and health.get("status") == "ready"),
            wall_s=0.0,
            metrics={"op": "handshake", "health": health,
                     "capabilities": capabilities,
                     "swift_oracle": swift is not None},
            notes=notes))

        # One untimed session: the first inference through torch pays lazy
        # kernel selection that belongs to no operation being measured.
        warm, _ = adapter.open_session(slices[0].png)
        if warm.get("ok"):
            adapter.prompt(warm["session_id"],
                           points=prompt_points(slices[0], 1, seed=1))
            adapter.close_session(warm["session_id"])

        if "roundtrip" in selected:
            phase_roundtrip(adapter, slices, recorder, swift, notes)
        if "ratio" in selected:
            phase_ratio(adapter, slices, recorder, args.encode_reps,
                        args.prompts, args.decode_reps, notes)
        if "cumulative" in selected:
            phase_cumulative(adapter, slices, recorder, args.prompts, notes)
        if "eviction" in selected:
            phase_eviction(adapter, slices, recorder, args.max_sessions, notes)
        if "implicit" in selected:
            phase_implicit(adapter, slices, recorder, max(5, args.encode_reps),
                           notes)

    # Both of these run their own subprocesses and must not contend with a
    # resident adapter holding the model.
    if "threads" in selected:
        phase_threads(slices, args.weights, recorder, [1, 2, 4, 8], notes)
    if "work" in selected:
        phase_work(slices, args.weights, recorder, notes)

    summary = summarize(args.out, args.csv)
    figures = make_figures(args.out, args.figures)
    print(json.dumps(summary, indent=2, default=str))
    for path in figures:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
