#!/usr/bin/env python3
# exp3_totalseg_lowmem.py
# OpenDicomViewer
#
# Experiment 3, follow-up: TotalSegmentator's peak memory under its low-memory
# settings, measured so a cheaper declaration can be justified rather than
# guessed.
#
# exp3_resources.py established the default `total` (fast, 3 mm) figure at
# 21.4-23.2 GB and the manifest declares 23.5 GB from it. That keeps the plugin
# off every 16-32 GB Mac. TotalSegmentator exposes settings that trade time for
# memory -- `force_split` (segment the volume in three overlapping z-slabs) and
# the resampling/saving thread counts -- and this script measures each of them
# on the same series, with the same instruments, so the comparison is between
# configurations and not between measurement methods.
#
# Two kinds of case, mirroring exp3_resources.py's own split:
#
#   seg/<variant>/<series>/r<n>      `totalsegmentator()` alone, the crosscheck
#                                    driver's scope. Isolates what each knob
#                                    does to the segmentation stage.
#   adapter/<task>/<series>/r<n>     run_segment.py exactly as the host spawns
#                                    a one-shot, SEG export included. This is
#                                    the figure a declaration must cover.
#
# Instruments. The exp3 instruments are kept so the numbers are comparable:
# `getrusage(RUSAGE_CHILDREN).ru_maxrss` read in a forked intermediate (the
# same reading run_subprocess_isolated makes) and, in seg cases, the child's
# own RUSAGE_SELF high-water mark. Both are per-process figures. That was
# sufficient under exp3's thread shim, where the whole pipeline ran in one
# process; it is not sufficient here, because this machine permits
# multiprocessing and nnU-Net then runs preprocessing and export in worker
# processes whose memory is concurrent with the parent's. A per-process
# maximum would understate what the arbiter has to budget for. So the
# intermediate also samples the whole process tree every 0.2 s through
# libproc's `proc_pid_rusage`, summing `ri_phys_footprint` (the figure
# Activity Monitor and the memory-pressure machinery use) and resident size
# across every descendant. `tree_peak_footprint_gb` is the number declarations
# are derived from; the per-process figures are recorded beside it.
#
# These are per-process-tree measurements, not system-wide ones, so other work
# on the machine does not enter them. It can still slow them down, which is
# why each case records the load average and the heaviest other processes at
# its start.
# Licensed under the MIT License. See LICENSE for details.
"""Peak memory and wall time of TotalSegmentator's low-memory settings."""

from __future__ import annotations

import argparse
import csv
import ctypes
import json
import os
import resource
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

from harness import CaseResult, Recorder

from exp3_resources import (
    EvalPaths,
    adapter_environment,
    last_envelope,
    load_manifest,
    plugin_by_id,
)

EXPERIMENT = "exp3_totalseg_lowmem"
PLUGIN_ID = "totalsegmentator"

# The segmentation-only variants. Every one keeps `fast=True`: that is the
# manifest's default for `total` and the only resolution whose weights the
# manifest ships (Dataset297). `nr_thr_resamp=1` is already TotalSegmentator's
# default; `nr_thr_saving` defaults to 6.
SEG_VARIANTS: dict[str, dict[str, Any]] = {
    "default": {},
    "force_split": {"force_split": True},
    "threads1": {"nr_thr_resamp": 1, "nr_thr_saving": 1},
    "force_split+threads1": {"force_split": True, "nr_thr_resamp": 1,
                             "nr_thr_saving": 1},
}


# ---------------------------------------------------------------------------
# libproc: per-process footprint, summed over a process tree
# ---------------------------------------------------------------------------


class _RusageInfoV4(ctypes.Structure):
    """`struct rusage_info_v4` from <sys/resource.h>, field for field."""

    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
        ("ri_cpu_time_qos_default", ctypes.c_uint64),
        ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
        ("ri_cpu_time_qos_background", ctypes.c_uint64),
        ("ri_cpu_time_qos_utility", ctypes.c_uint64),
        ("ri_cpu_time_qos_legacy", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64),
        ("ri_billed_system_time", ctypes.c_uint64),
        ("ri_serviced_system_time", ctypes.c_uint64),
        ("ri_logical_writes", ctypes.c_uint64),
        ("ri_lifetime_max_phys_footprint", ctypes.c_uint64),
        ("ri_instructions", ctypes.c_uint64),
        ("ri_cycles", ctypes.c_uint64),
        ("ri_billed_energy", ctypes.c_uint64),
        ("ri_serviced_energy", ctypes.c_uint64),
        ("ri_interval_max_phys_footprint", ctypes.c_uint64),
        ("ri_runnable_time", ctypes.c_uint64),
    ]


RUSAGE_INFO_V4 = 4
_libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
_libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int,
                                     ctypes.POINTER(_RusageInfoV4)]
_libproc.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p,
                                        ctypes.c_int]


def _rusage(pid: int) -> _RusageInfoV4 | None:
    info = _RusageInfoV4()
    if _libproc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(info)) != 0:
        return None  # exited between listing and reading
    return info


def _children(pid: int) -> list[int]:
    buf = (ctypes.c_int * 1024)()
    count = _libproc.proc_listchildpids(pid, buf, ctypes.sizeof(buf))
    return [buf[i] for i in range(max(0, count)) if buf[i] > 0]


def _tree(root: int) -> list[int]:
    pids, frontier = [], [root]
    while frontier:
        pid = frontier.pop()
        pids.append(pid)
        frontier.extend(_children(pid))
    return pids


class TreeSampler:
    """Polls a process tree and keeps the peaks a declaration has to cover."""

    def __init__(self, root: int, interval: float = 0.2):
        self.root = root
        self.interval = interval
        self.started = time.perf_counter()
        self.peak_footprint = 0
        self.peak_footprint_at = 0.0
        self.peak_resident = 0
        self.peak_processes = 0
        self.lifetime_max: dict[int, int] = {}
        self.samples = 0
        self.marks: list[tuple[float, str]] = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> "TreeSampler":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=2.0)

    def mark(self, label: str) -> None:
        self.marks.append((time.perf_counter() - self.started, label))

    def _run(self) -> None:
        while not self._stop.is_set():
            footprint = resident = processes = 0
            for pid in _tree(self.root):
                info = _rusage(pid)
                if info is None:
                    continue
                processes += 1
                footprint += info.ri_phys_footprint
                resident += info.ri_resident_size
                self.lifetime_max[pid] = max(self.lifetime_max.get(pid, 0),
                                             info.ri_lifetime_max_phys_footprint)
            self.samples += 1
            if footprint > self.peak_footprint:
                self.peak_footprint = footprint
                self.peak_footprint_at = time.perf_counter() - self.started
            self.peak_resident = max(self.peak_resident, resident)
            self.peak_processes = max(self.peak_processes, processes)
            self._stop.wait(self.interval)

    def stage_at(self, offset: float) -> str | None:
        """The last progress message the child printed before `offset`."""
        label = None
        for at, text in self.marks:
            if at <= offset:
                label = text
        return label

    def report(self) -> dict[str, Any]:
        root_max = self.lifetime_max.get(self.root, 0)
        return {
            "tree_peak_footprint_bytes": self.peak_footprint,
            "tree_peak_resident_bytes": self.peak_resident,
            "tree_peak_at_s": round(self.peak_footprint_at, 1),
            "tree_peak_stage": self.stage_at(self.peak_footprint_at),
            "tree_max_processes": self.peak_processes,
            "root_lifetime_max_footprint_bytes": root_max,
            "max_single_process_footprint_bytes":
                max(self.lifetime_max.values(), default=0),
            "samples": self.samples,
        }


# ---------------------------------------------------------------------------
# Measured subprocess
# ---------------------------------------------------------------------------


def run_measured(argv: list[str], cwd: Path, env: dict[str, str],
                 timeout: float) -> dict[str, Any]:
    """Run `argv` from a forked intermediate and report every instrument.

    The intermediate is the same device as `run_subprocess_isolated`: its
    RUSAGE_CHILDREN accounting starts empty, so the per-process maxrss it
    reports belongs to this run alone. It also hosts the tree sampler, since it
    is the child's parent and can see every descendant.
    """
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:  # intermediate
        os.close(read_fd)
        payload: dict[str, Any]
        try:
            started = time.perf_counter()
            proc = subprocess.Popen(argv, cwd=str(cwd), env=env,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True)
            sampler = TreeSampler(proc.pid).start()
            lines: list[str] = []
            deadline = started + timeout
            assert proc.stdout is not None
            for line in proc.stdout:
                lines.append(line)
                stripped = line.strip()
                if stripped.startswith("{") and '"progress"' in stripped:
                    try:
                        sampler.mark(json.loads(stripped).get("message", ""))
                    except json.JSONDecodeError:
                        pass
                if time.perf_counter() > deadline:
                    proc.kill()
                    break
            code = proc.wait()
            wall = time.perf_counter() - started
            sampler.stop()
            usage = resource.getrusage(resource.RUSAGE_CHILDREN)
            payload = {"returncode": code, "output": "".join(lines),
                       "wall_s": wall, "children_maxrss_bytes": usage.ru_maxrss,
                       "timed_out": wall > timeout, **sampler.report()}
        except BaseException as exc:  # noqa: BLE001
            payload = {"error": f"{type(exc).__name__}: {exc}"}
        with os.fdopen(write_fd, "w") as handle:
            handle.write(json.dumps(payload))
        os._exit(0)

    os.close(write_fd)
    with os.fdopen(read_fd) as handle:
        raw = handle.read()
    os.waitpid(pid, 0)
    record = json.loads(raw)
    if record.get("error"):
        raise RuntimeError(record["error"])
    return record


# ---------------------------------------------------------------------------
# Contention context
# ---------------------------------------------------------------------------


def contention_snapshot() -> dict[str, Any]:
    """Load and the heaviest other processes, at the start of a case.

    Recorded because this machine is shared with other heavy jobs. They do not
    enter a per-tree memory figure, but they do stretch wall time.
    """
    heavy: list[dict[str, Any]] = []
    try:
        out = subprocess.run(["ps", "-Ao", "rss=,pcpu=,comm="], capture_output=True,
                             text=True, timeout=10).stdout
        rows = []
        for line in out.splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3:
                rows.append((int(parts[0]), float(parts[1]), parts[2]))
        for rss, cpu, comm in sorted(rows, reverse=True)[:3]:
            heavy.append({"rss_gb": round(rss * 1024 / 1e9, 2), "cpu_pct": cpu,
                          "command": Path(comm).name[:60]})
    except Exception:  # noqa: BLE001 -- context, not a measurement
        pass
    return {"loadavg": [round(x, 2) for x in os.getloadavg()],
            "heaviest_other_processes": heavy}


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

# The `__main__` guard is load-bearing. nnU-Net's pools use the `spawn` start
# method, which re-imports the parent's main module in every worker; an
# unguarded driver makes each worker begin a TotalSegmentator run of its own.
# exp3's CROSSCHECK_DRIVER has no guard and never hit this only because the
# thread shim meant no worker was ever spawned. A first pass of this script
# without the guard measured 35-44 GB, almost all of it in those spurious
# workers, and was discarded.
SEG_DRIVER = r'''
import json, resource, sys, time


def main():
    series, out_dir, kwargs = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
    started = time.perf_counter()
    error = None
    try:
        from totalsegmentator.python_api import totalsegmentator
        print(json.dumps({"progress": 0.1, "message": "segmentation"}), flush=True)
        totalsegmentator(input=series, output=out_dir, task="total", fast=True,
                         ml=False, quiet=True, **kwargs)
    except BaseException as exc:
        error = f"{type(exc).__name__}: {exc}"
    scale = 1 if sys.platform == "darwin" else 1024
    print(json.dumps({
        "ok": error is None,
        "getrusage_self_bytes":
            resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * scale,
        "pipeline_s": round(time.perf_counter() - started, 3),
        "error": error,
    }))


if __name__ == "__main__":
    main()
'''

SHIM_PREFIX = ("import exp3_mp_thread_shim, runpy, sys; "
               "sys.argv = sys.argv[1:]; "
               "runpy.run_path(sys.argv[0], run_name='__main__')")


def _gb(value: float | None) -> float | None:
    return round(value / 1e9, 3) if value else None


def measure_case(recorder: Recorder, case_id: str, argv: list[str], cwd: Path,
                 env: dict[str, str], timeout: float, metrics: dict[str, Any],
                 notes: list[str], declared: float | None,
                 result_json: Path | None = None) -> None:
    """Run one case and record it.

    `result_json` is where a one-shot adapter writes its envelope: section 4
    puts it in `<out>/result.json`, not on stdout, which carries only progress
    and log lines. The segmentation-only driver prints its envelope instead.
    """
    if result_json is not None and result_json.exists():
        result_json.unlink()  # never read a previous run's envelope
    context = contention_snapshot()
    try:
        record = run_measured(argv, cwd, env, timeout)
    except Exception as exc:  # noqa: BLE001
        recorder.write(CaseResult(experiment=EXPERIMENT, case_id=case_id, ok=False,
                                  wall_s=0.0, metrics=metrics,
                                  error=f"{type(exc).__name__}: {exc}", notes=notes))
        return

    envelope = last_envelope(record["output"])
    if result_json is not None:
        try:
            envelope = json.loads(result_json.read_text())
        except (OSError, ValueError):
            envelope = None
    error = None
    if record.get("timed_out"):
        error = f"timed out after {timeout}s"
    elif envelope is None:
        error = "no envelope: " + record["output"][-400:]
    elif not envelope.get("ok"):
        error = envelope.get("error")
        if isinstance(error, dict):
            error = f"{error.get('code')}: {error.get('message')}"

    metrics = dict(metrics)
    metrics["contention_at_start"] = context
    metrics["exit_code"] = record["returncode"]
    metrics["tree_peak_footprint_gb"] = _gb(record["tree_peak_footprint_bytes"])
    metrics["tree_peak_resident_gb"] = _gb(record["tree_peak_resident_bytes"])
    metrics["tree_peak_at_s"] = record["tree_peak_at_s"]
    metrics["tree_peak_stage"] = record["tree_peak_stage"]
    metrics["tree_max_processes"] = record["tree_max_processes"]
    metrics["root_lifetime_max_footprint_gb"] = _gb(
        record["root_lifetime_max_footprint_bytes"])
    metrics["max_single_process_footprint_gb"] = _gb(
        record["max_single_process_footprint_bytes"])
    # Bytes on Darwin; the same reading exp3's bench and crosscheck report.
    maxrss = float(record["children_maxrss_bytes"])
    if sys.platform != "darwin":
        maxrss *= 1024
    metrics["children_maxrss_gb"] = _gb(maxrss)
    if envelope and envelope.get("getrusage_self_bytes"):
        metrics["getrusage_self_gb"] = _gb(envelope["getrusage_self_bytes"])
        metrics["pipeline_s"] = envelope.get("pipeline_s")
    if declared and metrics["tree_peak_footprint_gb"]:
        metrics["declared_ram_gb"] = declared
        metrics["tree_peak_vs_declared_ratio"] = round(
            metrics["tree_peak_footprint_gb"] / declared, 3)

    recorder.write(CaseResult(
        experiment=EXPERIMENT, case_id=case_id,
        ok=(record["returncode"] == 0 and not error), wall_s=record["wall_s"],
        peak_rss_bytes=record["tree_peak_footprint_bytes"] or None,
        metrics=metrics, error=error, notes=notes))


def base_notes(thread_shim: bool) -> list[str]:
    notes = [
        "device: the adapter passes TotalSegmentator's default device='gpu', "
        "which resolves to CUDA and falls back to CPU on a Mac; every case "
        "here therefore runs on the CPU, as the shipped plugin does",
        "peak_rss_bytes is tree_peak_footprint: phys_footprint summed over the "
        "child and all its descendants, sampled every 0.2 s via proc_pid_rusage",
        "children_maxrss_gb is exp3's instrument (largest single descendant's "
        "ru_maxrss from a forked intermediate), kept for comparability",
    ]
    if thread_shim:
        notes.append(
            "THREAD SUBSTITUTION APPLIED (eval/exp3_mp_thread_shim.py), as in "
            "exp3_resources.py, so the whole pipeline is one process and the "
            "figures are directly comparable with the 22.70 GB bench row")
    else:
        notes.append(
            "no thread substitution: nnU-Net's multiprocessing ran natively, "
            "as it does under the host")
    return notes


def shim_env(env: dict[str, str]) -> dict[str, str]:
    env = dict(env)
    shim_dir = Path(__file__).resolve().parent
    env["PYTHONPATH"] = ":".join([str(shim_dir), env.get("PYTHONPATH", "")]).strip(":")
    env["ODV_EXP3_THREAD_SHIM"] = "1"
    return env


def run_seg(recorder: Recorder, repo: Path, paths: EvalPaths, series: Path,
            variants: list[str], repeat: int, timeout: float, thread_shim: bool,
            env: dict[str, str]) -> None:
    python = str(paths.venv_python(PLUGIN_ID))
    driver = paths.plugin_root(PLUGIN_ID) / "lowmem_seg_driver.py"
    driver.write_text(SEG_DRIVER)
    if thread_shim:
        env = shim_env(env)
    for variant in variants:
        kwargs = SEG_VARIANTS[variant]
        for n in range(1, repeat + 1):
            suffix = "+shim" if thread_shim else ""
            case_id = f"seg/{variant}{suffix}/{series.name}/r{n}"
            if case_id in recorder.done_case_ids():
                print(f"  [skip] {case_id}", flush=True)
                continue
            out = paths.runs_root(PLUGIN_ID) / f"lowmem-{variant}{suffix}-{series.name}"
            out.mkdir(parents=True, exist_ok=True)
            argv = [python, str(driver), str(series), str(out), json.dumps(kwargs)]
            if thread_shim:
                argv = [python, "-c", SHIM_PREFIX, *argv[1:]]
            measure_case(recorder, case_id, argv, driver.parent, env, timeout,
                         {"scope": "segmentation", "variant": variant,
                          "kwargs": kwargs, "task": "total", "fast": True,
                          "thread_shim": thread_shim, "repeat": n,
                          "input_series": series.name,
                          "input_slice_count": len(list(series.glob("*.dcm")))},
                         base_notes(thread_shim), declared=None)


def run_adapter(recorder: Recorder, repo: Path, paths: EvalPaths, manifest: dict,
                series: Path, tasks: list[str], repeat: int, timeout: float,
                env: dict[str, str], threads: str | None = None) -> None:
    plugin = plugin_by_id(manifest, PLUGIN_ID)
    entry = repo / "plugins" / plugin["adapter_dir"] / plugin["entry"]
    python = str(paths.venv_python(PLUGIN_ID))
    for task in tasks:
        declared = next((t.get("ram_gb") for t in plugin["tasks"] if t["id"] == task),
                        None) or plugin.get("ram_gb")
        label = task if threads is None else f"{task}+threads{threads.replace(',', '-')}"
        run_env = dict(env)
        if threads is not None:
            # run_segment.THREADS_ENV: nr_thr_resamp,nr_thr_saving
            run_env["ODV_TOTALSEG_THREADS"] = threads
        for n in range(1, repeat + 1):
            case_id = f"adapter/{label}/{series.name}/r{n}"
            if case_id in recorder.done_case_ids():
                print(f"  [skip] {case_id}", flush=True)
                continue
            out = paths.runs_root(PLUGIN_ID) / f"lowmem-adapter-{label}-{series.name}"
            out.mkdir(parents=True, exist_ok=True)
            argv = [python, str(entry), "--task", task, "--out", str(out),
                    "--input-series3d", str(series)]
            measure_case(recorder, case_id, argv, entry.parent, run_env, timeout,
                         {"scope": "adapter one-shot (segmentation, volumes, "
                                   "DICOM SEG export)",
                          "task": task, "threads_override": threads,
                          "thread_shim": False, "repeat": n,
                          "input_series": series.name,
                          "input_slice_count": len(list(series.glob("*.dcm")))},
                         base_notes(False), declared=declared,
                         result_json=out / "result.json")


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------


def write_summary(results: Path, csv_path: Path) -> list[dict[str, Any]]:
    """One row per configuration and series: max, median and spread of peaks."""
    groups: dict[tuple[str, str], list[dict]] = {}
    for line in results.read_text().splitlines():
        row = json.loads(line)
        if row.get("_header"):
            continue
        config, series = row["case_id"].rsplit("/", 2)[0], row["metrics"].get("input_series")
        groups.setdefault((config, series), []).append(row)

    out = []
    for (config, series), rows in sorted(groups.items()):
        good = [r for r in rows if r["ok"]]
        peaks = [r["metrics"]["tree_peak_footprint_gb"] for r in good]
        walls = [r["wall_s"] for r in good]
        single = [r["metrics"].get("children_maxrss_gb") for r in good]
        out.append({
            "config": config,
            "input_series": series,
            "runs_ok": len(good),
            "runs_failed": len(rows) - len(good),
            "tree_peak_gb_max": max(peaks) if peaks else None,
            "tree_peak_gb_median": round(statistics.median(peaks), 3) if peaks else None,
            "tree_peak_gb_min": min(peaks) if peaks else None,
            "children_maxrss_gb_max": max(s for s in single if s) if any(single) else None,
            "peak_stage": good[0]["metrics"].get("tree_peak_stage") if good else None,
            "max_processes": max((r["metrics"].get("tree_max_processes") or 0)
                                 for r in good) if good else None,
            "wall_s_median": round(statistics.median(walls), 1) if walls else None,
            "wall_s_min": round(min(walls), 1) if walls else None,
            "wall_s_max": round(max(walls), 1) if walls else None,
            "declared_ram_gb": good[0]["metrics"].get("declared_ram_gb") if good else None,
            "first_error": next((r["error"] for r in rows if not r["ok"]), None),
        })
    if out:
        with open(csv_path, "w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(out[0]))
            writer.writeheader()
            writer.writerows(out)
    return out


def main(argv: list[str] | None = None) -> int:
    repo_default = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=repo_default)
    parser.add_argument("--env-root", type=Path, default=None,
                        help="defaults to <repo>/.eval/plugin-envs")
    parser.add_argument("--results", type=Path, default=None)
    parser.add_argument("--csv", type=Path, default=None)
    parser.add_argument("--series", type=Path, nargs="+", default=[])
    parser.add_argument("--seg-variants", default="",
                        help="comma-separated keys of SEG_VARIANTS")
    parser.add_argument("--adapter-tasks", default="",
                        help="comma-separated manifest task ids")
    parser.add_argument("--adapter-threads", default=None,
                        help="adapter cases: 'nr_thr_resamp,nr_thr_saving' "
                             "override (run_segment.THREADS_ENV)")
    parser.add_argument("--thread-shim", action="store_true",
                        help="seg cases only: run under exp3's thread shim")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=3600.0)
    parser.add_argument("--summary-only", action="store_true")
    args = parser.parse_args(argv)

    repo = args.repo.resolve()
    results = args.results or repo / "eval/results/exp3_totalseg_lowmem.jsonl"
    csv_path = args.csv or results.with_suffix(".csv")
    if not args.summary_only:
        paths = EvalPaths(args.env_root or repo / ".eval/plugin-envs")
        manifest = load_manifest(repo)
        recorder = Recorder(results, EXPERIMENT)
        env = adapter_environment(paths, PLUGIN_ID, repo)
        # What the host sets; the adapter resolves TOTALSEG_HOME_DIR from it.
        env["ODV_WEIGHTS_DIR"] = str(paths.weights_root(PLUGIN_ID))
        env.pop("TOTALSEG_HOME_DIR", None)
        env["TOTALSEG_HOME_DIR"] = str(paths.weight_directory(
            PLUGIN_ID, "Dataset297_TotalSegmentator_total_3mm_1559subj"))
        variants = [v for v in args.seg_variants.split(",") if v]
        tasks = [t for t in args.adapter_tasks.split(",") if t]
        for series in args.series:
            if variants:
                run_seg(recorder, repo, paths, series, variants, args.repeat,
                        args.timeout, args.thread_shim, dict(env))
            if tasks:
                run_adapter(recorder, repo, paths, manifest, series, tasks,
                            args.repeat, args.timeout, dict(env),
                            args.adapter_threads)
    for row in write_summary(results, csv_path):
        print(json.dumps(row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
