#!/usr/bin/env python3
"""Shared runner for the plugin evaluation experiments.

Every experiment records the same envelope — what was run, on which input, how
long each stage took, what peak memory it reached, and whether it succeeded —
as one JSON object per line. A failed case is written as a failure rather than
dropped: an evaluation that silently omits what did not work reports a
survivorship-biased result.

The peak-memory measurement is the subprocess's own maximum resident set size as
reported by the kernel (`getrusage` on the child), not a sampled estimate. On
Darwin the value is bytes; on Linux it is kilobytes. That difference is handled
here rather than in each experiment.
"""
from __future__ import annotations

import json
import os
import platform
import resource
import subprocess
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any, Iterator


def _maxrss_to_bytes(maxrss: int) -> float:
    """getrusage reports bytes on Darwin and kilobytes on Linux."""
    return float(maxrss) if platform.system() == "Darwin" else float(maxrss) * 1024


def machine_profile() -> dict:
    """Record the hardware an experiment ran on.

    A timing without its machine is not interpretable, and this evaluation
    exists partly because an earlier attempt produced numbers whose provenance
    could not be defended.
    """
    profile: dict[str, Any] = {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "logical_cores": os.cpu_count(),
    }

    # sysconf is the portable route and works even where sysctl is restricted.
    try:
        profile["memory_bytes"] = (os.sysconf("SC_PHYS_PAGES")
                                   * os.sysconf("SC_PAGE_SIZE"))
    except (ValueError, OSError):
        profile["memory_bytes"] = None

    if platform.system() == "Darwin":
        # system_profiler rather than sysctl: some sandboxed environments deny
        # the sysctl calls outright, and a machine profile that silently comes
        # back empty defeats the purpose of recording one.
        try:
            out = subprocess.run(["system_profiler", "SPHardwareDataType"],
                                 capture_output=True, text=True, timeout=30).stdout
            for line in out.splitlines():
                if ":" not in line:
                    continue
                key, _, value = line.partition(":")
                key, value = key.strip(), value.strip()
                if key == "Chip":
                    profile["chip"] = value
                elif key == "Model Name":
                    profile["model"] = value
                elif key == "Total Number of Cores":
                    profile["cores"] = value
                elif key == "Memory":
                    profile["memory_reported"] = value
        except Exception:  # noqa: BLE001 — absence is recorded, not fatal
            pass

    profile["gpu_visible"] = _gpu_visible()
    return profile


def _gpu_visible() -> dict:
    """Whether an accelerator is actually reachable from this process.

    Recorded per run because it is the single largest determinant of inference
    time, and because a sandboxed process on a GPU machine can see no GPU at
    all — a discrepancy that silently invalidates any timing compared against a
    desktop run.
    """
    out: dict[str, Any] = {"torch_mps": None, "torch_cuda": None}
    try:
        import torch  # noqa: PLC0415 — optional, only present in some envs

        out["torch_mps"] = bool(torch.backends.mps.is_available())
        out["torch_cuda"] = bool(torch.cuda.is_available())
    except Exception:  # noqa: BLE001 — torch absent is a valid answer
        pass
    return out


@dataclass
class StageTimer:
    """Accumulates named stage durations within one case."""

    stages: dict[str, float] = field(default_factory=dict)

    @contextmanager
    def stage(self, name: str) -> Iterator[None]:
        t0 = time.perf_counter()
        try:
            yield
        finally:
            self.stages[name] = self.stages.get(name, 0.0) + time.perf_counter() - t0


@dataclass
class CaseResult:
    """One experiment applied to one input."""

    experiment: str
    case_id: str
    ok: bool
    wall_s: float
    stages_s: dict[str, float] = field(default_factory=dict)
    peak_rss_bytes: float | None = None
    metrics: dict[str, Any] = field(default_factory=dict)
    error: str | None = None
    notes: list[str] = field(default_factory=list)


class Recorder:
    """Appends CaseResults to a JSONL file and echoes progress.

    Append rather than rewrite: a long experiment that dies partway should leave
    the cases it finished on disk.
    """

    def __init__(self, path: Path, experiment: str):
        self.path = Path(path)
        self.experiment = experiment
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            header = {"_header": True, "experiment": experiment,
                      "machine": machine_profile(),
                      "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
            with open(self.path, "w") as f:
                f.write(json.dumps(header) + "\n")

    def write(self, result: CaseResult) -> None:
        with open(self.path, "a") as f:
            f.write(json.dumps(asdict(result)) + "\n")
        status = "ok " if result.ok else "FAIL"
        detail = "" if result.ok else f"  {result.error}"
        print(f"  [{status}] {result.case_id}  {result.wall_s:.1f}s{detail}", flush=True)

    def done_case_ids(self) -> set[str]:
        """Case ids already recorded, so a rerun can resume."""
        if not self.path.exists():
            return set()
        out = set()
        for line in self.path.read_text().splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not row.get("_header") and row.get("ok"):
                out.add(row["case_id"])
        return out


def run_subprocess(argv: list[str], cwd: Path | None = None,
                   env: dict[str, str] | None = None,
                   timeout: float | None = None) -> tuple[int, str, float]:
    """Run a child process, returning (exit code, combined output, peak RSS bytes).

    Peak RSS is read from the kernel's accounting for children reaped during the
    call. It is attributed to this child on the assumption that no other child
    ran concurrently in this process, which the experiments honour by running
    cases serially.
    """
    before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    proc = subprocess.run(argv, cwd=str(cwd) if cwd else None, env=env,
                          capture_output=True, text=True, timeout=timeout)
    after = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    peak = _maxrss_to_bytes(max(after, before))
    return proc.returncode, (proc.stdout or "") + (proc.stderr or ""), peak


def dice(a, b) -> float:
    """Dice coefficient between two boolean arrays.

    Defined as 1.0 when both are empty: two identical empty segmentations agree
    completely, and the fidelity experiment compares many structures that are
    legitimately absent from a given field of view.
    """
    import numpy as np

    a = np.asarray(a, dtype=bool)
    b = np.asarray(b, dtype=bool)
    total = int(a.sum()) + int(b.sum())
    if total == 0:
        return 1.0
    return 2.0 * float((a & b).sum()) / float(total)


def load_results(path: Path) -> tuple[dict, list[dict]]:
    """Read a JSONL result file into (header, rows)."""
    header: dict = {}
    rows: list[dict] = []
    for line in Path(path).read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("_header"):
            header = row
        else:
            rows.append(row)
    return header, rows


if __name__ == "__main__":
    print(json.dumps(machine_profile(), indent=2))
