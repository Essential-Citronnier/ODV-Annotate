#!/usr/bin/env python3
# exp3_resources.py
# OpenDicomViewer
#
# Experiment 3: resource characterisation and arbitration.
#
# Two questions, measured separately because they have very different
# defensibility in this environment.
#
# 1. What does each plugin actually cost? Install time, weight download size
#    and time, model load time, per-request inference time, and peak resident
#    memory. The install and download figures are substitution-free: they are
#    network and disk work that a sandbox does not distort. The inference
#    figures are CPU-only here and are labelled as such everywhere they appear.
#
# 2. Does the arbiter do what its policy says? The manifest's `ram_gb` is a
#    declaration, and PLUGIN_PROTOCOL.md invariant 4 makes the whole admission
#    policy rest on those declarations being roughly honest. This experiment
#    compares each declaration against the measured peak, and drives the real
#    ResourceArbiter -- compiled from the shipped source, not reimplemented in
#    Python -- through the scenarios the design claims it handles.
#
# Reimplementing the policy here would test this file's model of the policy
# rather than the policy, so the arbitration phase compiles
# Sources/OpenDicomViewer/Plugins/ResourceArbiter.swift into a small driver and
# reports what the shipped type actually decides.
# Licensed under the MIT License. See LICENSE for details.
"""Per-plugin resource measurement and empirical arbitration checks."""

from __future__ import annotations

import argparse
import json
import os
import resource
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Iterable

from harness import (
    CaseResult,
    Recorder,
    StageTimer,
    load_results,
    machine_profile,
    run_subprocess,
)

EXPERIMENT = "exp3_resources"

# The host's own interpreter search order (PluginEnvironmentLocator.findPython3):
# a Python bundled in the app when there is one, then Homebrew, then
# /usr/local. /usr/bin/python3 is deliberately never used, because on a machine
# without the Command Line Tools it is a shim that opens an installer dialog.
PYTHON_CANDIDATES = ("/opt/homebrew/bin/python3", "/usr/local/bin/python3")


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------


def load_manifest(repo: Path) -> dict:
    path = repo / "Sources/OpenDicomViewer/Resources/plugins.json"
    return json.loads(path.read_text())


def plugin_by_id(manifest: dict, plugin_id: str) -> dict:
    for plugin in manifest["plugins"]:
        if plugin["id"] == plugin_id:
            return plugin
    raise KeyError(f"no plugin '{plugin_id}' in the manifest")


def find_python() -> str:
    for candidate in PYTHON_CANDIDATES:
        if Path(candidate).is_file():
            return candidate
    raise RuntimeError(
        "no interpreter found in the host's search order: "
        + ", ".join(PYTHON_CANDIDATES))


def run_subprocess_isolated(argv: list[str], cwd: Path | None = None,
                            env: dict[str, str] | None = None,
                            timeout: float | None = None
                            ) -> tuple[int, str, float]:
    """Run a child and return (exit code, combined output, ITS OWN peak RSS).

    `harness.run_subprocess` reads `getrusage(RUSAGE_CHILDREN).ru_maxrss`
    around the call, but that field is a high-water mark over every child the
    calling process has ever reaped -- it never resets, and it is not a
    per-child figure. Its `max(after, before)` therefore returns the largest
    peak of any child so far, so in a run that measures several plugins
    serially, every plugin after the heaviest one inherits that plugin's peak.
    Verified directly: a 10 MB child spawned after an 800 MB child is reported
    at 850 MB.

    That silently makes the declared-versus-measured comparison meaningless,
    which is the substance of this experiment, so peak RSS is measured here
    instead. The target is spawned from a forked intermediate whose own
    children accounting starts empty, and that intermediate reports the figure
    back over a pipe. The number is then attributable to exactly one process.

    This is a defect in the shared harness rather than in this experiment;
    reported rather than fixed in place, since eval/harness.py belongs to
    another track.
    """
    read_fd, write_fd = os.pipe()
    pid = os.fork()

    if pid == 0:  # intermediate child
        exit_code = 0
        try:
            os.close(read_fd)
            proc = subprocess.run(argv, cwd=str(cwd) if cwd else None, env=env,
                                  capture_output=True, text=True, timeout=timeout)
            usage = resource.getrusage(resource.RUSAGE_CHILDREN)
            payload = json.dumps({
                "returncode": proc.returncode,
                "output": (proc.stdout or "") + (proc.stderr or ""),
                "maxrss": usage.ru_maxrss,
            })
        except subprocess.TimeoutExpired:
            payload = json.dumps({"timeout": True})
        except BaseException as exc:  # noqa: BLE001
            payload = json.dumps({"error": f"{type(exc).__name__}: {exc}"})
        try:
            with os.fdopen(write_fd, "w") as handle:
                handle.write(payload)
        except BaseException:  # noqa: BLE001
            exit_code = 1
        os._exit(exit_code)

    os.close(write_fd)
    with os.fdopen(read_fd) as handle:
        raw = handle.read()
    os.waitpid(pid, 0)

    if not raw:
        raise RuntimeError("the measurement subprocess reported nothing")
    record = json.loads(raw)
    if record.get("timeout"):
        raise subprocess.TimeoutExpired(argv, timeout or 0)
    if record.get("error"):
        raise RuntimeError(record["error"])

    # getrusage reports bytes on Darwin and kilobytes on Linux, the same
    # correction harness._maxrss_to_bytes applies.
    raw_rss = float(record["maxrss"])
    peak = raw_rss if sys.platform == "darwin" else raw_rss * 1024
    return record["returncode"], record["output"], peak


def directory_bytes(path: Path) -> int:
    """Bytes on disk under `path`, following the layout the host would create."""
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += (Path(root) / name).lstat().st_size
            except OSError:
                continue
    return total


# ---------------------------------------------------------------------------
# Paths, mirroring the host's PluginPaths layout
# ---------------------------------------------------------------------------


class EvalPaths:
    """The subset of the host's `PluginPaths` this experiment needs.

    Rooted wherever the caller asks rather than at Application Support, so a
    measurement run never disturbs a real installation and so the experiment
    works in an environment where Application Support is not writable. The
    directory names match the host's exactly, because the adapters resolve
    their own weight directories from the same convention.
    """

    def __init__(self, root: Path):
        self.root = root

    def plugin_root(self, plugin_id: str) -> Path:
        return self.root / plugin_id

    def venv(self, plugin_id: str) -> Path:
        return self.plugin_root(plugin_id) / ".venv"

    def venv_python(self, plugin_id: str) -> Path:
        return self.venv(plugin_id) / "bin/python3"

    def venv_pip(self, plugin_id: str) -> Path:
        return self.venv(plugin_id) / "bin/pip"

    def weights_root(self, plugin_id: str) -> Path:
        return self.plugin_root(plugin_id) / "weights"

    def weight_directory(self, plugin_id: str, weight_id: str) -> Path:
        return self.weights_root(plugin_id) / weight_id

    def runs_root(self, plugin_id: str) -> Path:
        return self.plugin_root(plugin_id) / "runs"


def adapter_environment(paths: EvalPaths, plugin_id: str,
                        repo: Path) -> dict[str, str]:
    """The environment the host gives an adapter subprocess.

    Mirrors `PluginEnvironmentLocator.processEnvironment`: the plugin's venv
    first on PATH, HOME preserved, and unbuffered stdout so progress lines
    arrive as they are printed rather than when a block buffer fills.

    The two `ODV_*_WEIGHTS` overrides are the adapters' own documented escape
    hatch for running against a weight tree outside an installed plugin, which
    is exactly this experiment's situation.
    """
    environment = dict(os.environ)
    environment["PATH"] = ":".join(
        [str(paths.venv(plugin_id) / "bin"), environment.get("PATH", "")])
    environment["PYTHONUNBUFFERED"] = "1"
    environment.setdefault("HOME", str(Path.home()))
    # PORTABILITY FINDING, not merely a local workaround.
    #
    # Recent huggingface_hub versions default to Hugging Face's Xet
    # content-addressed transfer backend for large files, which resolves to
    # cas-server.xethub.hf.co and transfer.xethub.hf.co -- hosts distinct from
    # huggingface.co. On a network that permits huggingface.co but not those
    # (verified here: huggingface.co returns 200, the Xet hosts are refused),
    # every weight download fails with a "CAS Client Error ... File
    # reconstruction error" that names neither the real cause nor a remedy.
    #
    # A hospital network with a domain allowlist is exactly such an
    # environment, and the adapters inherit this default without declaring it:
    # the manifest names a repo, not the hosts a download will actually
    # contact. Setting HF_HUB_DISABLE_XET routes over the classic CDN, which
    # is reachable. That changes how the bytes are fetched, not which bytes --
    # the resulting files are identical -- so a time measured this way is a
    # real download time over a slower transport, and an upper bound on the
    # Xet path.
    environment.setdefault("HF_HUB_DISABLE_XET", "1")
    if plugin_id == "sam2":
        environment["ODV_SAM2_WEIGHTS"] = str(
            paths.weight_directory("sam2", "sam2.1-hiera-small"))
    if plugin_id == "sam3":
        environment["ODV_SAM3_WEIGHTS"] = str(
            paths.weight_directory("sam3", "sam3-checkpoint"))
    return environment


# ---------------------------------------------------------------------------
# Stdout parsing
# ---------------------------------------------------------------------------


def last_envelope(output: str) -> dict | None:
    """The last protocol envelope on stdout.

    Section 4b disambiguation, applied in reverse: an object carrying `ok` is
    an envelope, one carrying `progress` is a progress line, anything else is a
    log line. Reading the last envelope rather than the first means a failure
    written after partial progress is what gets recorded.
    """
    found = None
    for line in output.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict) and "ok" in row:
            found = row
    return found


def progress_lines(output: str) -> list[dict]:
    """Every section 4 progress line on stdout, in order."""
    out = []
    for line in output.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict) and "progress" in row:
            out.append(row)
    return out


def envelope_metrics(envelope: dict | None) -> dict:
    if not envelope or not envelope.get("ok"):
        return {}
    return dict(envelope.get("outputs", {}).get("metrics", {}) or {})


def envelope_error(envelope: dict | None) -> str | None:
    if envelope is None:
        return "the adapter wrote no protocol envelope on stdout"
    if envelope.get("ok"):
        return None
    error = envelope.get("error", {})
    return f"{error.get('code', 'internal')}: {error.get('message', '')}"


# ---------------------------------------------------------------------------
# Phase: install
# ---------------------------------------------------------------------------


def phase_install(recorder: Recorder, repo: Path, paths: EvalPaths,
                  manifest: dict, plugin_ids: Iterable[str],
                  timeout: float, force: bool) -> None:
    """Create each plugin's virtualenv and install its requirements.

    The steps are the host's, in the host's order (PluginInstaller.install):
    `python3 -m venv`, `pip install --upgrade pip -q`, then
    `pip install -r requirements.txt`. Timing this is substitution-free -- it
    is network and disk work, unaffected by the sandbox's lack of a GPU -- and
    it is the number a user waits through once per plugin.
    """
    python = find_python()
    version = subprocess.run([python, "--version"], capture_output=True,
                             text=True).stdout.strip()

    for plugin_id in plugin_ids:
        case_id = f"install/{plugin_id}"
        plugin = plugin_by_id(manifest, plugin_id)
        venv = paths.venv(plugin_id)

        if venv.exists() and not force:
            print(f"  [skip] {case_id} (venv present; --force to rebuild)", flush=True)
            continue
        stale_note = None
        if venv.exists():
            try:
                shutil.rmtree(venv)
            except OSError as exc:
                # Some environments restrict recursive deletion inside a granted
                # path, and a half-deleted virtualenv would silently poison the
                # measurement. Setting it aside is enough for a clean rebuild,
                # and leaves the old tree available for inspection.
                stale = venv.with_name(f".venv.stale-{int(time.time())}")
                venv.rename(stale)
                stale_note = (f"previous venv could not be removed ({exc.strerror}); "
                              f"moved to {stale.name} and rebuilt from scratch")

        requirements = repo / "plugins" / plugin["adapter_dir"] / plugin["requirements"]
        timer = StageTimer()
        started = time.perf_counter()
        notes = [f"interpreter={python} ({version})",
                 "substitution-free: network and disk work, unaffected by GPU visibility"]
        if stale_note:
            notes.append(stale_note)
        metrics: dict[str, Any] = {"declared_disk_gb": plugin.get("disk_gb")}
        peak = 0.0

        try:
            paths.plugin_root(plugin_id).mkdir(parents=True, exist_ok=True)
            with timer.stage("venv_create"):
                code, output, rss = run_subprocess(
                    [python, "-m", "venv", str(venv)], timeout=timeout)
                peak = max(peak, rss)
            if code != 0:
                raise RuntimeError(f"venv creation failed: {output[-500:]}")

            with timer.stage("pip_upgrade"):
                code, output, rss = run_subprocess(
                    [str(paths.venv_pip(plugin_id)), "install", "--upgrade", "pip", "-q"],
                    timeout=timeout)
                peak = max(peak, rss)
            if code != 0:
                raise RuntimeError(f"pip upgrade failed: {output[-500:]}")

            with timer.stage("pip_requirements"):
                code, output, rss = run_subprocess(
                    [str(paths.venv_pip(plugin_id)), "install", "-r", str(requirements)],
                    timeout=timeout)
                peak = max(peak, rss)
            if code != 0:
                raise RuntimeError(f"requirements install failed: {output[-1500:]}")

            metrics["venv_bytes"] = directory_bytes(venv)
            metrics["venv_gb"] = round(metrics["venv_bytes"] / 1e9, 3)
            declared = plugin.get("disk_gb")
            if declared:
                metrics["venv_vs_declared_disk_ratio"] = round(
                    metrics["venv_gb"] / declared, 3)
            ok, error = True, None
        except Exception as exc:  # noqa: BLE001 - a failed install is a result
            ok, error = False, f"{type(exc).__name__}: {exc}"

        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=ok,
            wall_s=time.perf_counter() - started, stages_s=timer.stages,
            peak_rss_bytes=peak or None, metrics=metrics, error=error, notes=notes))


# ---------------------------------------------------------------------------
# Phase: weights
# ---------------------------------------------------------------------------


def phase_weights(recorder: Recorder, repo: Path, paths: EvalPaths,
                  manifest: dict, plugin_ids: Iterable[str],
                  timeout: float, force: bool) -> None:
    """Run each task's section 4b weight hook and measure what it fetched.

    The adapter's own hook is used rather than a direct download, because what
    the evaluation needs to characterise is the install the host actually
    performs -- including, for a gated weight, the hook correctly refusing to
    download anything.
    """
    for plugin_id in plugin_ids:
        plugin = plugin_by_id(manifest, plugin_id)
        entry = repo / "plugins" / plugin["adapter_dir"] / plugin["entry"]
        environment = adapter_environment(paths, plugin_id, repo)

        seen: set[str] = set()
        for task in plugin["tasks"]:
            for weight in task.get("weights", []):
                weight_id = weight["id"]
                if weight_id in seen:
                    continue
                seen.add(weight_id)

                case_id = f"weights/{plugin_id}/{weight_id}"
                dest = paths.weight_directory(plugin_id, weight_id)
                if dest.exists() and directory_bytes(dest) > 0 and not force:
                    print(f"  [skip] {case_id} (present; --force to refetch)", flush=True)
                    continue

                argv = [str(paths.venv_python(plugin_id)), str(entry),
                        "--install-weights", "--weight-id", weight_id,
                        "--source", weight["source"], "--dest", str(dest)]
                if weight.get("repo"):
                    argv += ["--repo", weight["repo"]]
                if weight.get("task"):
                    argv += ["--task", weight["task"]]

                started = time.perf_counter()
                notes = ["substitution-free: download and disk work"]
                if weight["source"] == "huggingface":
                    notes.append(
                        "HF_HUB_DISABLE_XET=1: the Xet CAS backend is "
                        "unreachable from this network, so the download used "
                        "the plain LFS endpoint. Same bytes, slower transport, "
                        "so this time is an upper bound")
                if os.environ.get("ALL_PROXY") or os.environ.get("all_proxy"):
                    # huggingface_hub reaches the hub through httpx, which
                    # needs the socksio extra to speak to a SOCKS proxy. Where
                    # the measurement environment interposes one, that extra
                    # must be present in the plugin venv or every hub download
                    # fails on an ImportError that has nothing to do with the
                    # adapter. Recorded because it adds a package the manifest
                    # does not declare.
                    notes.append(
                        "environment interposes a SOCKS proxy; httpx[socks] was "
                        "added to this plugin's venv so huggingface_hub can "
                        "reach the hub. Not a manifest dependency, and it "
                        "inflates the measured venv size slightly")
                try:
                    code, output, peak = run_subprocess_isolated(
                        argv, cwd=entry.parent, env=environment, timeout=timeout)
                    envelope = last_envelope(output)
                    error = envelope_error(envelope) if code != 0 or envelope else None
                    # Exit 0 with no envelope is the success path: section 4b
                    # only requires an envelope on failure.
                    if code == 0 and envelope is None:
                        error = None
                    ok = code == 0 and error is None
                except subprocess.TimeoutExpired:
                    ok, error, peak, output = False, f"timed out after {timeout}s", None, ""

                elapsed = time.perf_counter() - started
                landed = directory_bytes(dest) if dest.exists() else 0
                metrics: dict[str, Any] = {
                    "source": weight["source"],
                    "gate": task["license"]["gate"],
                    "declared_size_gb": weight.get("size_gb"),
                    "downloaded_bytes": landed,
                    "downloaded_gb": round(landed / 1e9, 4),
                    "exit_code": code if "code" in dir() else None,
                    "progress_lines": len(progress_lines(output)),
                }
                if weight.get("size_gb") and landed:
                    metrics["downloaded_vs_declared_ratio"] = round(
                        (landed / 1e9) / weight["size_gb"], 3)
                if elapsed > 0 and landed:
                    metrics["download_mb_per_s"] = round(landed / 1e6 / elapsed, 2)
                if task["license"]["gate"] != "open":
                    notes.append(
                        "gated weight: a non-zero exit with a license_required "
                        "envelope is the correct behaviour, not a failure of the adapter")

                recorder.write(CaseResult(
                    experiment=EXPERIMENT, case_id=case_id, ok=ok,
                    wall_s=elapsed, peak_rss_bytes=peak,
                    metrics=metrics, error=error, notes=notes))


# ---------------------------------------------------------------------------
# Phase: bench
# ---------------------------------------------------------------------------


def phase_bench(recorder: Recorder, repo: Path, paths: EvalPaths,
                manifest: dict, plugin_ids: Iterable[str], slice_png: Path | None,
                series_dir: Path | None, repeat: int, timeout: float,
                totalseg_threads: bool) -> None:
    """Invoke each adapter's `--bench` mode and record its own stage timings.

    Peak RSS comes from the kernel's accounting for the exited child rather
    than from the adapter, because a process cannot observe its own high-water
    mark reliably after the fact. The stage breakdown comes from the adapter,
    because nothing outside it can separate weight load from inference.
    """
    for plugin_id in plugin_ids:
        plugin = plugin_by_id(manifest, plugin_id)
        entry = repo / "plugins" / plugin["adapter_dir"] / plugin["entry"]
        environment = adapter_environment(paths, plugin_id, repo)
        execution = plugin["execution"]

        notes = [f"execution={execution}",
                 "inference timings are CPU-only sandbox figures: this process "
                 "sees no GPU (see machine.gpu_visible in the file header) and "
                 "they must not be presented as desktop performance",
                 "peak RSS measured per child by run_subprocess_isolated, not "
                 "by harness.run_subprocess, whose RUSAGE_CHILDREN reading is a "
                 "cumulative high-water mark across all children and attributes "
                 "the heaviest previous child's peak to every later one"]

        argv = [str(paths.venv_python(plugin_id)), str(entry), "--bench",
                "--repeat", str(repeat)]
        if execution == "one-shot" and totalseg_threads:
            # -X importtime is not wanted; the shim must simply be imported
            # before the adapter, which `-c "import shim; runpy(entry)"` does
            # without editing the adapter.
            argv = [str(paths.venv_python(plugin_id)),
                    "-c",
                    "import exp3_mp_thread_shim, runpy, sys; "
                    "sys.argv = sys.argv[1:]; "
                    "runpy.run_path(sys.argv[0], run_name='__main__')",
                    str(entry), "--bench", "--repeat", str(repeat)]

        if execution == "one-shot":
            if series_dir is None:
                print(f"  [skip] bench/{plugin_id} (no --series)", flush=True)
                continue
            run_dir = paths.runs_root(plugin_id) / "bench"
            run_dir.mkdir(parents=True, exist_ok=True)
            argv += ["--input-series3d", str(series_dir), "--out", str(run_dir),
                     "--task", "total", "--opt-fast", "true"]
            if totalseg_threads:
                # nnU-Net runs preprocessing and export in multiprocessing
                # pools, whose AF_UNIX IPC this sandbox denies; the failure
                # surfaces as a bare EOFError. The shim swaps in a thread pool
                # so the pipeline completes. Injected through PYTHONPATH and
                # PYTHONSTARTUP-equivalent import rather than installed, so
                # nothing about the plugin environment changes.
                shim_dir = Path(__file__).resolve().parent
                environment["PYTHONPATH"] = ":".join(
                    [str(shim_dir), environment.get("PYTHONPATH", "")]).strip(":")
                environment["ODV_EXP3_THREAD_SHIM"] = "1"
                notes.append(
                    "THREAD SUBSTITUTION APPLIED: multiprocessing.Pool replaced "
                    "with a thread pool (eval/exp3_mp_thread_shim.py) because "
                    "this sandbox denies the AF_UNIX bind process pools require. "
                    "Preserves correctness; DESTROYS performance characteristics. "
                    "The wall time below is an upper bound, not a laptop figure.")
        else:
            if slice_png is None:
                print(f"  [skip] bench/{plugin_id} (no --slice)", flush=True)
                continue
            argv += ["--input-slice2d", str(slice_png)]

        case_id = f"bench/{plugin_id}"
        started = time.perf_counter()
        try:
            code, output, peak = run_subprocess_isolated(
                argv, cwd=entry.parent, env=environment, timeout=timeout)
        except subprocess.TimeoutExpired:
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False,
                wall_s=time.perf_counter() - started,
                error=f"timed out after {timeout}s", notes=notes))
            continue

        envelope = last_envelope(output)
        error = envelope_error(envelope)
        metrics = envelope_metrics(envelope)
        if not metrics and envelope and envelope.get("partial"):
            # A run that failed partway still measured the stages it finished.
            # Those are recorded as measurements of what did happen, with the
            # error kept alongside so the row is never read as a success.
            metrics = dict(envelope["partial"])
        stages = {name[len("stage_s."):]: value
                  for name, value in metrics.items() if name.startswith("stage_s.")}
        keep = {name: value for name, value in metrics.items()
                if not name.startswith("stage_s.")}
        keep["declared_ram_gb"] = plugin.get("ram_gb")
        keep["exit_code"] = code
        keep["progress_lines"] = len(progress_lines(output))
        # The input is part of the measurement, not context for it: a peak RSS
        # figure means nothing without the volume that produced it, and two
        # runs of the same plugin on different series are otherwise
        # indistinguishable rows under the same case_id.
        if series_dir is not None:
            keep["input_series"] = series_dir.name
            keep["input_slice_count"] = sum(
                1 for p in series_dir.iterdir()
                if p.suffix.lower() == ".dcm" or p.is_file() and not p.name.startswith("."))
        if slice_png is not None:
            keep["input_slice_png"] = Path(slice_png).name
        if peak and plugin.get("ram_gb"):
            keep["peak_rss_gb"] = round(peak / 1e9, 3)
            keep["peak_vs_declared_ratio"] = round((peak / 1e9) / plugin["ram_gb"], 3)

        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=(code == 0 and error is None),
            wall_s=time.perf_counter() - started, stages_s=stages,
            peak_rss_bytes=peak, metrics=keep, error=error, notes=notes))


# ---------------------------------------------------------------------------
# Phase: memory cross-check
# ---------------------------------------------------------------------------

# A 6x divergence between a plugin's declared and measured memory is the kind
# of claim that should not rest on one mechanism, especially when the harness's
# own peak-RSS reading was found to be unreliable (see run_subprocess_isolated).
# This phase measures the same run three ways that fail independently:
#
#   getrusage_children  the parent's per-child accounting, what the bench uses
#   getrusage_self      the child's own high-water mark, read from inside
#   sampled_self        the child polling itself on a timer, which catches a
#                       peak that a final read could in principle miss
#
# psutil-style external sampling is deliberately not attempted: this sandbox
# denies the sysctl it needs, so it would report zero and look like a
# disagreement rather than an unavailable instrument.
CROSSCHECK_DRIVER = r'''
import json, resource, sys, threading, time

series, out_dir, task, fast = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

sampled = [0]
stop = [False]


def sample():
    while not stop[0]:
        sampled[0] = max(sampled[0],
                         resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
        time.sleep(0.3)


watcher = threading.Thread(target=sample, daemon=True)
watcher.start()

started = time.perf_counter()
error = None
try:
    from totalsegmentator.python_api import totalsegmentator

    totalsegmentator(input=series, output=out_dir, task=task,
                     fast=(fast == "true"), ml=False, quiet=True)
except BaseException as exc:
    error = f"{type(exc).__name__}: {exc}"
elapsed = time.perf_counter() - started

stop[0] = True
watcher.join(timeout=2.0)

scale = 1 if sys.platform == "darwin" else 1024
print(json.dumps({
    "getrusage_self_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * scale,
    "sampled_self_bytes": sampled[0] * scale,
    "getrusage_children_bytes":
        resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss * scale,
    "pipeline_s": round(elapsed, 3),
    "error": error,
}))
'''


def phase_crosscheck(recorder: Recorder, repo: Path, paths: EvalPaths,
                     manifest: dict, series_dirs: list[Path], timeout: float,
                     totalseg_threads: bool) -> None:
    """Measure TotalSegmentator's peak three independent ways, per series.

    Recorded as ordinary cases so the cross-check is part of the results file
    rather than a claim about work done elsewhere.
    """
    plugin_id = "totalsegmentator"
    plugin = plugin_by_id(manifest, plugin_id)
    declared = plugin.get("ram_gb")
    python = paths.venv_python(plugin_id)

    for series_dir in series_dirs:
        case_id = f"crosscheck/{plugin_id}/{series_dir.name}"
        if case_id in recorder.done_case_ids():
            print(f"  [skip] {case_id} (already recorded)", flush=True)
            continue

        notes = [f"input_series={series_dir.name}",
                 "three independent peak-RSS instruments on one run; they "
                 "share no code path, so agreement is evidence and "
                 "disagreement localises the faulty one",
                 "CPU-only sandbox figure for the timing; the memory figures "
                 "are real allocations"]
        environment = adapter_environment(paths, plugin_id, repo)
        if totalseg_threads:
            shim_dir = Path(__file__).resolve().parent
            environment["PYTHONPATH"] = ":".join(
                [str(shim_dir), environment.get("PYTHONPATH", "")]).strip(":")
            notes.append(
                "THREAD SUBSTITUTION APPLIED: multiprocessing replaced with "
                "threads (eval/exp3_mp_thread_shim.py). For a single series "
                "nnU-Net computes num_processes=min(len(cases),3)=1, so this "
                "replaces one worker process with one worker thread and the "
                "total allocation is unchanged; it is the wall time that is "
                "affected, not the peak")

        run_dir = paths.runs_root(plugin_id) / f"crosscheck-{series_dir.name}"
        run_dir.mkdir(parents=True, exist_ok=True)

        driver = paths.plugin_root(plugin_id) / "crosscheck_driver.py"
        driver.parent.mkdir(parents=True, exist_ok=True)
        driver.write_text(CROSSCHECK_DRIVER)

        started = time.perf_counter()
        argv = [str(python), str(driver), str(series_dir), str(run_dir),
                "total", "true"]
        try:
            if totalseg_threads:
                argv = [str(python), "-c",
                        "import exp3_mp_thread_shim, runpy, sys; "
                        "sys.argv = sys.argv[1:]; "
                        "runpy.run_path(sys.argv[0], run_name='__main__')",
                        str(driver), str(series_dir), str(run_dir),
                        "total", "true"]
            code, output, peak = run_subprocess_isolated(
                argv, cwd=driver.parent, env=environment, timeout=timeout)
        except subprocess.TimeoutExpired:
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False,
                wall_s=time.perf_counter() - started,
                error=f"timed out after {timeout}s", notes=notes))
            continue

        envelope = last_envelope(output)
        metrics: dict[str, Any] = {"declared_ram_gb": declared,
                                   "input_series": series_dir.name,
                                   "exit_code": code}
        if envelope:
            for key in ("getrusage_self_bytes", "sampled_self_bytes",
                        "getrusage_children_bytes", "pipeline_s"):
                if key in envelope:
                    metrics[key] = envelope[key]
            for key in ("getrusage_self_bytes", "sampled_self_bytes"):
                if envelope.get(key) and declared:
                    metrics[key.replace("_bytes", "_gb")] = round(
                        envelope[key] / 1e9, 3)
                    metrics[key.replace("_bytes", "_vs_declared_ratio")] = round(
                        (envelope[key] / 1e9) / declared, 3)
        if peak:
            metrics["parent_measured_peak_gb"] = round(peak / 1e9, 3)
            if declared:
                metrics["parent_vs_declared_ratio"] = round(
                    (peak / 1e9) / declared, 3)

        # The instruments are expected to agree closely. The spread is recorded
        # so a reader can see that they did rather than take it on trust.
        readings = [metrics.get("getrusage_self_gb"),
                    metrics.get("sampled_self_gb"),
                    metrics.get("parent_measured_peak_gb")]
        present = [value for value in readings if value]
        if len(present) > 1:
            metrics["instrument_spread_gb"] = round(max(present) - min(present), 3)
            metrics["instrument_max_gb"] = max(present)
            metrics["instrument_min_gb"] = min(present)

        error = envelope.get("error") if envelope else None
        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=case_id,
            ok=(code == 0 and not error), wall_s=time.perf_counter() - started,
            peak_rss_bytes=peak, metrics=metrics, error=error, notes=notes))


# ---------------------------------------------------------------------------
# Phase: arbitration
# ---------------------------------------------------------------------------

ARBITER_DRIVER = r'''
// Generated by eval/exp3_resources.py. Drives the shipped ResourceArbiter.
//
// Compiled against Sources/OpenDicomViewer/Plugins/ResourceArbiter.swift so
// that what is measured is the policy the application ships, not a Python
// restatement of it. Reads scenarios as JSON on stdin, writes decisions as
// JSON on stdout.
import Foundation

// Every optional field is spelled `Optional` rather than given a default:
// Swift's synthesized Decodable does not fall back to a property's default
// value when the key is absent, it throws, so a default here would be a
// silent trap for any scenario that omits a field.
struct ResidentIn: Decodable {
    let id: String
    let ram: Double
    let lastUsed: Double?
    let evictable: Bool?
}

struct ScenarioIn: Decodable {
    let name: String
    let physicalGB: Double
    let availableGB: Double?
    let residentFraction: Double?
    let safetyMarginGB: Double?
    let request: ResidentIn
    let residents: [ResidentIn]?
    let oneShot: Bool?
}

struct DecisionOut: Encodable {
    let name: String
    let decision: String
    let evictions: [String]
    let admitted: Bool
    let refusalRequiredGB: Double?
    let refusalAvailableGB: Double?
    let declaredBudgetGB: Double
    let liveHeadroomGB: Double
    let residentDemandGB: Double
}

let epoch = Date(timeIntervalSince1970: 1_700_000_000)

func residency(_ input: ResidentIn) -> PluginResidency {
    PluginResidency(pluginID: input.id,
                    declaredRamGB: input.ram,
                    lastUsed: epoch.addingTimeInterval(input.lastUsed ?? 0),
                    isEvictable: input.evictable ?? true)
}

let data = FileHandle.standardInput.readDataToEndOfFile()
let scenarios = try JSONDecoder().decode([ScenarioIn].self, from: data)
var results: [DecisionOut] = []

for scenario in scenarios {
    let available = scenario.availableGB ?? scenario.physicalGB
    let arbiter = ResourceArbiter(
        residentFraction: scenario.residentFraction ?? 0.5,
        safetyMarginGB: scenario.safetyMarginGB ?? 2.0,
        probe: MemoryProbe.fixed(physicalGB: scenario.physicalGB,
                                 availableGB: available))
    let request = residency(scenario.request)
    let residents = (scenario.residents ?? []).map(residency)
    let decision = (scenario.oneShot ?? false)
        ? arbiter.admitOneShot(request, residents: residents)
        : arbiter.admit(request, residents: residents)

    var label = "admit"
    var requiredGB: Double? = nil
    var availableOut: Double? = nil
    switch decision {
    case .admit: label = "admit"
    case .evictThenAdmit: label = "evictThenAdmit"
    case .refuse(let required, let avail):
        label = "refuse"
        requiredGB = required
        availableOut = avail
    }

    let status = MemoryStatus(physicalGB: scenario.physicalGB, availableGB: available)
    results.append(DecisionOut(
        name: scenario.name,
        decision: label,
        evictions: decision.evictions,
        admitted: decision.isAdmitted,
        refusalRequiredGB: requiredGB,
        refusalAvailableGB: availableOut,
        declaredBudgetGB: arbiter.declaredBudgetGB(status),
        liveHeadroomGB: arbiter.liveHeadroomGB(status),
        residentDemandGB: residents.reduce(0) { $0 + $1.declaredRamGB }))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(results))
'''


def build_arbiter_driver(repo: Path, workdir: Path) -> Path:
    """Compile the shipped arbiter into a small stdin/stdout driver."""
    workdir.mkdir(parents=True, exist_ok=True)
    source = workdir / "main.swift"
    source.write_text(ARBITER_DRIVER)
    binary = workdir / "arbiter_driver"
    argv = [
        "swiftc", "-O",
        # A private module cache: the shared one is not writable here, and a
        # failed cache write aborts the build rather than degrading.
        "-module-cache-path", str(workdir / "module-cache"),
        "-o", str(binary), str(source),
        str(repo / "Sources/OpenDicomViewer/Plugins/ResourceArbiter.swift"),
        str(repo / "Sources/OpenDicomViewer/Plugins/PluginTypes.swift"),
    ]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise RuntimeError(f"arbiter driver build failed:\n{result.stderr[-2000:]}")
    return binary


def arbitration_scenarios(manifest: dict) -> list[dict]:
    """The scenarios the design's section 6 claims to handle.

    Declared RAM comes from the manifest rather than being restated here, so a
    manifest edit changes what is tested rather than silently invalidating it.
    """
    ram = {plugin["id"]: plugin["ram_gb"] for plugin in manifest["plugins"]}
    gemma, sam2, sam3, ts = (ram["gemma-4-e4b"], ram["sam2"],
                             ram["sam3"], ram["totalsegmentator"])

    def residency(plugin_id: str, last_used: float = 0.0,
                  evictable: bool = True) -> dict:
        return {"id": plugin_id, "ram": ram[plugin_id],
                "lastUsed": last_used, "evictable": evictable}

    return [
        # The case the design exists for: 16 GiB, Gemma resident, a
        # TotalSegmentator one-shot arrives. 5.0 + 3.5 exceeds the 8 GiB budget.
        {"name": "16gb/oneshot-evicts-resident-gemma", "physicalGB": 16.0,
         "request": {"id": "totalsegmentator", "ram": ts},
         "residents": [residency("gemma-4-e4b")], "oneShot": True},
        # Same demand on 32 GiB: the budget is 16 GiB and both fit.
        {"name": "32gb/oneshot-coexists-with-gemma", "physicalGB": 32.0,
         "request": {"id": "totalsegmentator", "ram": ts},
         "residents": [residency("gemma-4-e4b")], "oneShot": True},
        # A plugin mid-request must block admission rather than be stopped
        # under the user.
        {"name": "16gb/busy-resident-is-not-evictable", "physicalGB": 16.0,
         "request": {"id": "totalsegmentator", "ram": ts},
         "residents": [residency("gemma-4-e4b", evictable=False)],
         "oneShot": True},
        # A session plugin holding open sessions is likewise non-evictable.
        # The demand must actually exceed the budget for this to be a test of
        # non-evictability: SAM 2 (3.0) plus Gemma (5.0) is exactly 8.0 and
        # fits a 16 GiB budget, so that pairing would be admitted whether or
        # not the resident were evictable and would prove nothing.
        {"name": "16gb/session-holder-is-not-evictable", "physicalGB": 16.0,
         "request": {"id": "sam3", "ram": sam3},
         "residents": [residency("sam2", evictable=False)]},
        # The same demand with the session closed: the plugin becomes
        # evictable and the request is admitted after stopping it. Paired with
        # the case above, this isolates non-evictability as the cause of the
        # refusal rather than the memory arithmetic.
        {"name": "16gb/same-demand-admits-once-session-closes", "physicalGB": 16.0,
         "request": {"id": "sam3", "ram": sam3},
         "residents": [residency("sam2", evictable=True)]},
        # SAM 2 and Gemma together are exactly the 16 GiB budget. Recorded
        # because a policy whose headline case turns on an exact-equality
        # comparison of one-decimal JSON figures is worth showing to be stable:
        # the arbiter's epsilon is what keeps 3.0 + 5.0 <= 8.0 from failing on
        # binary floating point.
        {"name": "16gb/exact-budget-boundary-admits", "physicalGB": 16.0,
         "request": {"id": "gemma-4-e4b", "ram": gemma},
         "residents": [residency("sam2")]},
        # Eviction order is least-recently-used first, and stops at the first
        # arrangement that fits rather than clearing the whole set.
        {"name": "24gb/evicts-lru-first-and-stops", "physicalGB": 24.0,
         "request": {"id": "sam3", "ram": sam3},
         "residents": [residency("sam2", last_used=0),
                       residency("gemma-4-e4b", last_used=100)]},
        {"name": "16gb/evicts-both-when-one-is-not-enough", "physicalGB": 16.0,
         "request": {"id": "sam3", "ram": sam3},
         "residents": [residency("sam2", last_used=0),
                       residency("gemma-4-e4b", last_used=100)]},
        # Re-entering a running server must never evict it.
        {"name": "8gb/reentrant-start-does-not-evict-itself", "physicalGB": 8.0,
         "request": {"id": "gemma-4-e4b", "ram": gemma},
         "residents": [residency("gemma-4-e4b")]},
        # A one-shot sibling of a resident server of the same id is NOT exempt:
        # the subprocess's peak lands on top of the server's.
        {"name": "16gb/oneshot-not-exempt-from-own-resident-sibling",
         "physicalGB": 16.0,
         "request": {"id": "totalsegmentator", "ram": ts},
         "residents": [residency("totalsegmentator", last_used=0),
                       residency("gemma-4-e4b", last_used=100)],
         "oneShot": True},
        # Live headroom overrides a comfortable declared budget: the machine is
        # large but currently loaded, and the arbiter must side with the machine.
        {"name": "64gb-but-loaded/live-headroom-refuses", "physicalGB": 64.0,
         "availableGB": 3.0, "request": {"id": "gemma-4-e4b", "ram": gemma}},
        # Nothing fits on an empty small machine either.
        {"name": "16gb/refuses-what-cannot-fit-at-all", "physicalGB": 16.0,
         "request": {"id": "enormous", "ram": 12.0}},
        {"name": "32gb/sam2-then-gemma", "physicalGB": 32.0,
         "request": {"id": "gemma-4-e4b", "ram": gemma},
         "residents": [residency("sam2")]},
        # --- The residency-reporting gap -----------------------------------
        # One instant in time, described two ways. A TotalSegmentator one-shot
        # is running and holding its 3.5 GB peak; the user now starts Gemma
        # (5.0 GB) from the store. Together that is 8.5 GB against an 8 GiB
        # budget, so the correct decision is to wait.
        #
        # The pair isolates whether the policy is told. `residentSet()` derives
        # residency from `runtimeStates`, which a one-shot never enters -- it
        # is spawned, tracked in `busy` and `activityProgress`, and reaped,
        # without ever being `.ready`. So the second scenario is the one the
        # host actually presents, and the divergence between the two rows is
        # the cost of the omission rather than a fault in the policy.
        {"name": "16gb/start-server-while-oneshot-runs-reported", "physicalGB": 16.0,
         "request": {"id": "gemma-4-e4b", "ram": gemma},
         "residents": [residency("totalsegmentator", evictable=False)]},
        {"name": "16gb/start-server-while-oneshot-runs-unreported",
         "physicalGB": 16.0,
         "request": {"id": "gemma-4-e4b", "ram": gemma},
         "residents": []},
        # --- Declared versus measured -------------------------------------
        # The bench phase measures TotalSegmentator peaking near 21 GB on a
        # 411-slice CT while its manifest declares 3.5. These two rows ask the
        # arbiter the same question with each figure, on the 16 GiB machine the
        # policy is designed around.
        #
        # With the declaration the request is admitted, because 3.5 fits an
        # 8 GiB budget comfortably. With the measurement it is refused, because
        # 21 GB exceeds both the budget and the machine. The policy is correct
        # in both cases -- it is answering the question it was asked -- and the
        # divergence is entirely a consequence of which number the manifest
        # carries. That is what makes an inaccurate declaration a correctness
        # problem for admission rather than a documentation nit.
        {"name": "16gb/totalseg-admitted-on-its-declaration", "physicalGB": 16.0,
         "request": {"id": "totalsegmentator", "ram": ts},
         "residents": [], "oneShot": True},
        {"name": "16gb/totalseg-refused-on-its-measurement", "physicalGB": 16.0,
         "request": {"id": "totalsegmentator", "ram": 20.9},
         "residents": [], "oneShot": True},
    ]


# What each scenario must decide for the design's section 6 claims to hold.
# Written as an expectation rather than an assertion so that a divergence is
# recorded as a finding instead of aborting the run.
ARBITRATION_EXPECTATIONS: dict[str, dict[str, Any]] = {
    "16gb/oneshot-evicts-resident-gemma":
        {"decision": "evictThenAdmit", "evictions": ["gemma-4-e4b"]},
    "32gb/oneshot-coexists-with-gemma": {"decision": "admit", "evictions": []},
    "16gb/busy-resident-is-not-evictable": {"decision": "refuse", "evictions": []},
    "16gb/session-holder-is-not-evictable": {"decision": "refuse", "evictions": []},
    "16gb/same-demand-admits-once-session-closes":
        {"decision": "evictThenAdmit", "evictions": ["sam2"]},
    "16gb/exact-budget-boundary-admits": {"decision": "admit", "evictions": []},
    "24gb/evicts-lru-first-and-stops":
        {"decision": "evictThenAdmit", "evictions": ["sam2"]},
    "16gb/evicts-both-when-one-is-not-enough":
        {"decision": "evictThenAdmit", "evictions": ["sam2", "gemma-4-e4b"]},
    "8gb/reentrant-start-does-not-evict-itself": {"decision": "admit", "evictions": []},
    # Both residents are stopped, not just the same-id sibling: after evicting
    # TotalSegmentator (LRU first) the remaining 5.0 GB of Gemma plus the
    # incoming 3.5 GB is 8.5 GB, which still exceeds the 8 GiB budget. The
    # design text says only that the sibling is "as evictable as any other",
    # and this is what that implies.
    "16gb/oneshot-not-exempt-from-own-resident-sibling":
        {"decision": "evictThenAdmit", "evictions": ["totalsegmentator", "gemma-4-e4b"]},
    "64gb-but-loaded/live-headroom-refuses": {"decision": "refuse", "evictions": []},
    "16gb/refuses-what-cannot-fit-at-all": {"decision": "refuse", "evictions": []},
    "32gb/sam2-then-gemma": {"decision": "admit", "evictions": []},
    # Told the truth, the policy is correct: the running one-shot is
    # non-evictable, 3.5 + 5.0 exceeds the 8 GiB budget, and Gemma waits.
    "16gb/start-server-while-oneshot-runs-reported":
        {"decision": "refuse", "evictions": []},
    # Not told, it admits, and the machine ends up holding 8.5 GB of declared
    # demand against an 8 GiB budget. Both rows are the shipped policy behaving
    # exactly as written; the difference between them is what the host omits.
    "16gb/start-server-while-oneshot-runs-unreported":
        {"decision": "admit", "evictions": []},
    # Both rows are the shipped policy answering correctly. The pair exists to
    # show that the answer is decided by the manifest figure, and that this
    # plugin's figure is wrong by roughly 6x in the direction that admits work
    # the machine cannot hold.
    "16gb/totalseg-admitted-on-its-declaration":
        {"decision": "admit", "evictions": []},
    "16gb/totalseg-refused-on-its-measurement":
        {"decision": "refuse", "evictions": []},
}


def phase_arbitration(recorder: Recorder, repo: Path, manifest: dict,
                      workdir: Path) -> None:
    """Drive the shipped ResourceArbiter through the design's scenarios."""
    started = time.perf_counter()
    try:
        binary = build_arbiter_driver(repo, workdir)
    except Exception as exc:  # noqa: BLE001 - a build failure is a result
        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id="arbitration/build", ok=False,
            wall_s=time.perf_counter() - started, error=f"{type(exc).__name__}: {exc}",
            notes=["could not compile the shipped arbiter; no arbitration "
                   "measurement is possible without it"]))
        return

    recorder.write(CaseResult(
        experiment=EXPERIMENT, case_id="arbitration/build", ok=True,
        wall_s=time.perf_counter() - started,
        metrics={"binary": str(binary)},
        notes=["compiled from Sources/OpenDicomViewer/Plugins/ResourceArbiter.swift; "
               "decisions below are the shipped policy's, not a reimplementation"]))

    scenarios = arbitration_scenarios(manifest)
    result = subprocess.run([str(binary)], input=json.dumps(scenarios),
                            capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id="arbitration/run", ok=False,
            wall_s=0.0, error=f"driver exited {result.returncode}: {result.stderr[-800:]}"))
        return

    decisions = json.loads(result.stdout)
    for decision in decisions:
        name = decision["name"]
        expected = ARBITRATION_EXPECTATIONS.get(name)
        notes = ["decision produced by the shipped ResourceArbiter"]
        if expected is None:
            ok, error = True, None
            notes.append("no expectation declared; recorded as observation")
        else:
            matches = (decision["decision"] == expected["decision"]
                       and decision["evictions"] == expected["evictions"])
            ok = matches
            error = None if matches else (
                f"expected {expected['decision']} {expected['evictions']}, "
                f"got {decision['decision']} {decision['evictions']}")
            notes.append(f"expected={expected['decision']} {expected['evictions']}")

        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=f"arbitration/{name}", ok=ok,
            wall_s=0.0, metrics=decision, error=error, notes=notes))


# ---------------------------------------------------------------------------
# Phase: restart cost
# ---------------------------------------------------------------------------


def phase_restart(recorder: Recorder, repo: Path, paths: EvalPaths,
                  manifest: dict, plugin_ids: Iterable[str],
                  slice_png: Path | None, timeout: float) -> None:
    """Measure what an eviction costs the user.

    An eviction is only as cheap as the restart that follows it, and the
    restart cost is the evicted plugin's cold model-load time -- the arbiter
    frees memory by stopping a process, so nothing of its loaded weights
    survives. This runs the same load the adapter performs on startup, twice,
    so that a warm filesystem cache does not flatter the number a user would
    actually wait through after a segmentation finishes.
    """
    if slice_png is None:
        print("  [skip] restart (no --slice)", flush=True)
        return

    for plugin_id in plugin_ids:
        plugin = plugin_by_id(manifest, plugin_id)
        if plugin["execution"] == "one-shot":
            continue
        entry = repo / "plugins" / plugin["adapter_dir"] / plugin["entry"]
        environment = adapter_environment(paths, plugin_id, repo)

        for attempt in ("cold", "warm"):
            case_id = f"restart/{plugin_id}/{attempt}"
            argv = [str(paths.venv_python(plugin_id)), str(entry), "--bench",
                    "--input-slice2d", str(slice_png), "--repeat", "1"]
            started = time.perf_counter()
            try:
                code, output, peak = run_subprocess_isolated(
                    argv, cwd=entry.parent, env=environment, timeout=timeout)
            except subprocess.TimeoutExpired:
                recorder.write(CaseResult(
                    experiment=EXPERIMENT, case_id=case_id, ok=False,
                    wall_s=time.perf_counter() - started,
                    error=f"timed out after {timeout}s"))
                continue

            envelope = last_envelope(output)
            metrics = envelope_metrics(envelope)
            load_s = metrics.get("stage_s.model_load")
            import_s = metrics.get("stage_s.import", 0.0) or 0.0
            keep = {
                "attempt": attempt,
                "model_load_s": load_s,
                "import_s": import_s,
                # What a user waits through when the arbiter restarts this
                # plugin: process spawn, imports, and weight load.
                "restart_cost_s": (round(import_s + load_s, 3)
                                   if load_s is not None else None),
                "declared_ram_gb": plugin.get("ram_gb"),
            }
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=(code == 0),
                wall_s=time.perf_counter() - started,
                peak_rss_bytes=peak, metrics=keep,
                error=envelope_error(envelope),
                notes=["restart cost after an arbiter eviction is a cold model "
                       "load: stopping the process discards the loaded weights",
                       "CPU-only sandbox figure; a machine with a visible GPU "
                       "would load to a different device"]))


# ---------------------------------------------------------------------------
# Slice preparation
# ---------------------------------------------------------------------------


def prepare_slice(series_dir: Path, out_png: Path) -> Path:
    """Render one mid-series slice to PNG, as the host does before a request.

    The host sends `slice2d` as a rendered PNG (PLUGIN_PROTOCOL.md section 2),
    so the benchmark's input is a rendering rather than raw pixel data. A
    mid-series slice is used because the ends of a CT are often air.
    """
    import numpy as np
    import pydicom
    from PIL import Image

    files = sorted(p for p in series_dir.iterdir()
                   if p.is_file() and not p.name.startswith("."))
    if not files:
        raise RuntimeError(f"no DICOM files in {series_dir}")

    datasets = []
    for path in files:
        try:
            dataset = pydicom.dcmread(str(path), stop_before_pixels=True)
        except Exception:  # noqa: BLE001 - a non-DICOM file is skipped
            continue
        position = getattr(dataset, "InstanceNumber", None)
        datasets.append((position if position is not None else 0, path))
    if not datasets:
        raise RuntimeError(f"no readable DICOM in {series_dir}")
    datasets.sort(key=lambda item: item[0])
    chosen = datasets[len(datasets) // 2][1]

    dataset = pydicom.dcmread(str(chosen))
    pixels = dataset.pixel_array.astype(np.float32)
    slope = float(getattr(dataset, "RescaleSlope", 1.0) or 1.0)
    intercept = float(getattr(dataset, "RescaleIntercept", 0.0) or 0.0)
    hounsfield = pixels * slope + intercept

    # A soft-tissue window, which is what a viewer would be showing when a user
    # clicks to segment. Fixed rather than derived so the benchmark input is
    # reproducible across series.
    center, width = 40.0, 400.0
    low, high = center - width / 2, center + width / 2
    windowed = np.clip((hounsfield - low) / (high - low), 0.0, 1.0)
    image = Image.fromarray((windowed * 255).astype(np.uint8)).convert("RGB")

    out_png.parent.mkdir(parents=True, exist_ok=True)
    image.save(out_png)
    return chosen


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------


def write_summary(results_path: Path, manifest: dict, csv_path: Path) -> None:
    """Flatten the JSONL into the per-plugin table the paper needs."""
    import csv

    header, rows = load_results(results_path)
    declared = {plugin["id"]: plugin for plugin in manifest["plugins"]}

    per_plugin: dict[str, dict[str, Any]] = {}
    for plugin_id, plugin in declared.items():
        per_plugin[plugin_id] = {
            "plugin_id": plugin_id,
            "execution": plugin["execution"],
            "declared_ram_gb": plugin["ram_gb"],
            "declared_disk_gb": plugin["disk_gb"],
        }

    for row in rows:
        case = row["case_id"]
        parts = case.split("/")
        if len(parts) < 2:
            continue
        phase, plugin_id = parts[0], parts[1]
        entry = per_plugin.get(plugin_id)
        if entry is None:
            continue
        metrics = row.get("metrics", {})
        stages = row.get("stages_s", {})

        if phase == "install":
            entry["install_ok"] = row["ok"]
            entry["install_s"] = round(row["wall_s"], 2)
            entry["venv_create_s"] = round(stages.get("venv_create", 0.0), 2)
            entry["pip_s"] = round(stages.get("pip_requirements", 0.0), 2)
            entry["venv_gb"] = metrics.get("venv_gb")
            entry["install_error"] = row.get("error")
        elif phase == "weights":
            # Weights are keyed per weight id, and a given id may appear
            # several times because a failed attempt is kept on the record
            # alongside the retry that succeeded. Summing across attempts
            # would report the cost of the failures as part of the download
            # time, so each id keeps only its authoritative attempt: the
            # successful one if there is one, otherwise the last failure.
            weight_id = parts[2] if len(parts) > 2 else "weights"
            attempts = entry.setdefault("_weights", {})
            previous = attempts.get(weight_id)
            if previous is None or (row["ok"] and not previous["ok"]) or (
                    row["ok"] == previous["ok"]):
                attempts[weight_id] = {
                    "ok": row["ok"],
                    "wall_s": row["wall_s"],
                    "downloaded_gb": metrics.get("downloaded_gb") or 0.0,
                    "gate": metrics.get("gate"),
                    "error": row.get("error"),
                    "attempts": (previous or {}).get("attempts", 0) + 1,
                }
        elif phase == "bench":
            # Prefer the most informative attempt rather than simply the last.
            # Several attempts exist where an environment problem was diagnosed
            # and worked around, and the run that got furthest is the one whose
            # numbers describe the plugin. Ranked: a success beats a partial
            # run, and a partial run beats one that failed before loading.
            rank = (2 if row["ok"] else
                    1 if any(key in stages for key in
                             ("model_load", "encode", "inference",
                              "Running segmentation")) else 0)
            if rank < entry.get("_bench_rank", -1):
                continue
            entry["_bench_rank"] = rank
            entry["bench_ok"] = row["ok"]
            entry["bench_error"] = row.get("error")
            entry["peak_rss_gb"] = metrics.get("peak_rss_gb")
            entry["peak_vs_declared_ratio"] = metrics.get("peak_vs_declared_ratio")
            entry["device"] = metrics.get("device")
            for name, value in stages.items():
                entry[f"stage_s.{name}"] = round(value, 3)
            for key in ("encode_ms_mean", "decode_ms_mean", "encode_decode_ratio",
                        "inference_ms_mean", "structure_count", "pipeline_s"):
                if key in metrics:
                    entry[key] = metrics[key]
        elif phase == "restart" and metrics.get("attempt") == "cold":
            entry["restart_cost_s"] = metrics.get("restart_cost_s")

    # Collapse the per-weight attempts into the plugin's row. Times and sizes
    # add across a plugin's several weight ids -- those are genuinely separate
    # downloads -- but never across attempts at the same id.
    for entry in per_plugin.values():
        entry.pop("_bench_rank", None)
        attempts = entry.pop("_weights", None)
        if not attempts:
            continue
        entry["weight_s"] = round(
            sum(a["wall_s"] for a in attempts.values()), 2)
        entry["weight_gb"] = round(
            sum(a["downloaded_gb"] for a in attempts.values()), 4)
        entry["weight_gate"] = ";".join(
            sorted({a["gate"] for a in attempts.values() if a["gate"]}))
        entry["weight_ids_ok"] = sum(1 for a in attempts.values() if a["ok"])
        entry["weight_ids_total"] = len(attempts)
        entry["weight_retries"] = sum(
            a["attempts"] - 1 for a in attempts.values())
        # Only errors from attempts that never succeeded are reported: a stale
        # message beside a successful download would read as a live failure.
        errors = [a["error"] for a in attempts.values()
                  if not a["ok"] and a["error"]]
        entry["weight_error"] = " | ".join(errors)

    columns: list[str] = []
    for entry in per_plugin.values():
        for key in entry:
            if key not in columns:
                columns.append(key)

    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with open(csv_path, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        for plugin_id in declared:
            writer.writerow(per_plugin[plugin_id])

    arbitration = [row for row in rows if row["case_id"].startswith("arbitration/")
                   and row["case_id"] != "arbitration/build"]
    if arbitration:
        arb_path = csv_path.with_name(csv_path.stem + "_arbitration.csv")
        fields = ["scenario", "decision", "evictions", "admitted", "matches_design",
                  "declaredBudgetGB", "liveHeadroomGB", "residentDemandGB",
                  "refusalRequiredGB", "refusalAvailableGB", "divergence"]
        with open(arb_path, "w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            for row in arbitration:
                metrics = row.get("metrics", {})
                writer.writerow({
                    "scenario": row["case_id"].split("/", 1)[1],
                    "decision": metrics.get("decision"),
                    "evictions": ";".join(metrics.get("evictions", [])),
                    "admitted": metrics.get("admitted"),
                    "matches_design": row["ok"],
                    "declaredBudgetGB": metrics.get("declaredBudgetGB"),
                    "liveHeadroomGB": metrics.get("liveHeadroomGB"),
                    "residentDemandGB": metrics.get("residentDemandGB"),
                    "refusalRequiredGB": metrics.get("refusalRequiredGB"),
                    "refusalAvailableGB": metrics.get("refusalAvailableGB"),
                    "divergence": row.get("error") or "",
                })
        print(f"wrote {arb_path}")

    print(f"wrote {csv_path}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    repo_default = Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=repo_default,
                        help="Repository root")
    parser.add_argument("--env-root", type=Path, default=None,
                        help="Where plugin virtualenvs and weights are created "
                             "(default <repo>/.eval/plugin-envs)")
    parser.add_argument("--results", type=Path, default=None,
                        help="JSONL output (default <repo>/eval/results/exp3_resources.jsonl)")
    parser.add_argument("--csv", type=Path, default=None,
                        help="Derived CSV (default <repo>/eval/results/exp3_resources.csv)")
    parser.add_argument("--series", type=Path, default=None,
                        help="A DICOM series directory, for slice rendering and "
                             "the one-shot benchmark")
    parser.add_argument("--crosscheck-series", type=Path, nargs="*", default=None,
                        help="Series directories for the memory cross-check "
                             "phase; defaults to --series")
    parser.add_argument("--slice", dest="slice_png", type=Path, default=None,
                        help="A rendered PNG slice; derived from --series when absent")
    parser.add_argument("--plugins", default="sam2,sam3,gemma-4-e4b,totalsegmentator",
                        help="Comma-separated plugin ids")
    parser.add_argument("--phases", default="install,weights,bench,restart,crosscheck,arbitration",
                        help="Comma-separated phases to run")
    parser.add_argument("--repeat", type=int, default=3,
                        help="Inference repetitions in the bench phase")
    parser.add_argument("--timeout", type=float, default=7200.0,
                        help="Per-subprocess timeout in seconds")
    parser.add_argument("--force", action="store_true",
                        help="Rebuild environments and refetch weights")
    parser.add_argument("--totalseg-threads", action="store_true",
                        help="Disable nnU-Net dataloader workers. Needed where "
                             "the sandbox denies multiprocessing IPC; preserves "
                             "correctness but not performance characteristics")
    parser.add_argument("--summary-only", action="store_true",
                        help="Rewrite the CSV from an existing JSONL and exit")
    args = parser.parse_args(argv)

    repo = args.repo.resolve()
    env_root = (args.env_root or repo / ".eval/plugin-envs").resolve()
    results = (args.results or repo / "eval/results/exp3_resources.jsonl").resolve()
    csv_path = (args.csv or repo / "eval/results/exp3_resources.csv").resolve()
    manifest = load_manifest(repo)

    if args.summary_only:
        write_summary(results, manifest, csv_path)
        return 0

    paths = EvalPaths(env_root)
    plugin_ids = [p.strip() for p in args.plugins.split(",") if p.strip()]
    phases = [p.strip() for p in args.phases.split(",") if p.strip()]
    recorder = Recorder(results, EXPERIMENT)

    profile = machine_profile()
    print(f"machine: {profile.get('chip', profile['machine'])}, "
          f"{profile['logical_cores']} cores, gpu_visible={profile['gpu_visible']}",
          flush=True)

    # Resolved here rather than at use: adapters are spawned with their own
    # adapter directory as the working directory, so a relative path on the
    # command line would resolve against plugins/<id>/ and not find the file.
    slice_png = args.slice_png.resolve() if args.slice_png else None
    if slice_png is None and args.series is not None:
        slice_png = env_root / "bench_slice.png"
        source = prepare_slice(args.series.resolve(), slice_png)
        print(f"rendered {slice_png} from {source.name}", flush=True)

    if "install" in phases:
        print("phase: install", flush=True)
        phase_install(recorder, repo, paths, manifest, plugin_ids,
                      args.timeout, args.force)
    if "weights" in phases:
        print("phase: weights", flush=True)
        phase_weights(recorder, repo, paths, manifest, plugin_ids,
                      args.timeout, args.force)
    if "bench" in phases:
        print("phase: bench", flush=True)
        phase_bench(recorder, repo, paths, manifest, plugin_ids, slice_png,
                    args.series.resolve() if args.series else None,
                    args.repeat, args.timeout, args.totalseg_threads)
    if "restart" in phases:
        print("phase: restart", flush=True)
        phase_restart(recorder, repo, paths, manifest, plugin_ids,
                      slice_png, args.timeout)
    if "crosscheck" in phases:
        print("phase: crosscheck", flush=True)
        crosscheck_series = args.crosscheck_series
        if not crosscheck_series:
            crosscheck_series = [args.series] if args.series else []
        phase_crosscheck(recorder, repo, paths, manifest,
                         [Path(s).resolve() for s in crosscheck_series],
                         args.timeout, args.totalseg_threads)
    if "arbitration" in phases:
        print("phase: arbitration", flush=True)
        phase_arbitration(recorder, repo, manifest, env_root / "arbiter-driver")

    write_summary(results, manifest, csv_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
