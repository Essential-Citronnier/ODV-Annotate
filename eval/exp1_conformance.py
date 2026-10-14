#!/usr/bin/env python3
# exp1_conformance.py
# OpenDicomViewer -- plugin layer evaluation, experiment 1.
#
# The claim under test: the DICOM SEG the plugin layer writes is conformant and
# readable by an INDEPENDENT implementation, not merely by our own reader.
#
# "Independent" is the load-bearing word, so the reference decoder is dcmqi
# (QIICR), which is a different codebase, a different language, and a different
# author from highdicom, which our adapter encodes with. A round trip that only
# used highdicom would prove that highdicom is self-consistent and nothing else.
#
# Three stages, runnable separately so a slow one need not be repeated:
#
#   segment    run the adapter's own pipeline over each series, keeping the
#              per-structure NIfTI masks that the adapter normally discards, so
#              the SEG can be compared against exactly what was encoded.
#   roundtrip  decode each SEG with dcmqi's segimage2itkimage and compare
#              voxelwise, in physical space, against those masks.
#   audit      run the Segmentation IOD field audit (conformance_checks.py).
#
# ---------------------------------------------------------------------------
# MEASUREMENT ENVIRONMENT WARNING
#
# This evaluation environment reports no GPU to torch and denies the AF_UNIX
# bind(2) that nnU-Net's multiprocessing data loader requires. Segmentation
# therefore runs only under a substitution that replaces nnU-Net's worker pool
# with its own upstream sequential path (--sandbox-shim). That substitution
# preserves the computation exactly -- same preprocessor, same network, same
# export -- and changes only how it is scheduled. It does NOT preserve
# performance characteristics. Every duration recorded by this script is
# serial-CPU and must not be presented as laptop performance. Rows produced
# under the shim carry the note `sandbox-shim:nnunet-sequential`.
#
# Conformance conclusions are unaffected: a DICOM SEG is either standard or it
# is not, regardless of how fast the tensor that produced it was computed.
# ---------------------------------------------------------------------------
# Licensed under the MIT License. See LICENSE for details.
"""Standard-conformance evaluation of plugin-produced DICOM SEG files."""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "eval"))
sys.path.insert(0, str(REPO / "plugins"))

from harness import (  # noqa: E402
    CaseResult,
    Recorder,
    StageTimer,
    dice,
    load_results,
)
import conformance_checks as cc  # noqa: E402

EXPERIMENT = "exp1_conformance"
SHIM_NOTE = "sandbox-shim:nnunet-sequential"


# ---------------------------------------------------------------------------
# Sandbox substitution
# ---------------------------------------------------------------------------

# Written to a directory placed on sys.path and applied EXPLICITLY by the
# segmentation worker after the heavy imports have settled. Keeping it out of
# the adapter matters: the adapter is the thing being evaluated, and an
# evaluation that modifies its subject measures something else.
#
# An earlier version of this shim installed itself from an import hook. That
# does not work here, and the reason is worth recording: TotalSegmentator
# replaces nnUNetPredictor.predict_from_files at its own module import time
# (totalsegmentator.nnunet_runtime_patches), so a hook that fires during import
# is overwritten immediately afterwards and the run proceeds on the
# multiprocessing path -- silently, since the symptom is only slowness. The
# worker therefore imports first, patches second, and asserts the patch is in
# place before any inference starts.
_SHIM_SOURCE = '''\
"""nnU-Net scheduling substitutions for a sandbox that denies AF_UNIX bind.

Three substitutions, each replacing a scheduling mechanism with an equivalent
one that computes the same result:

  nnUNetPredictor.predict_from_files -> predict_from_files_sequential
      nnU-Net's preprocessing iterator builds a multiprocessing.Manager, whose
      server binds an AF_UNIX socket; where that bind is denied the manager
      dies and the predictor fails with EOFError before any inference runs.
      The sequential path is provided upstream and runs the same preprocessor,
      the same network, and the same export function with no worker processes.

  totalsegmentator.nnunet.Pool -> multiprocessing.pool.ThreadPool
      identical API, threads instead of processes, used only for writing the
      per-structure NIfTI files.

  torch.set_num_threads floor
      TotalSegmentator passes a torch.device object for CPU runs, which takes
      the branch written for GPU runs and calls torch.set_num_threads(1). With
      no accelerator visible that pins the entire forward pass to one core. The
      floor restores the thread count the same code would use had it taken its
      own `device == "cpu"` branch, which sets it to cpu_count().

Correctness preserved; performance characteristics NOT preserved.
"""
import os
import sys


def apply(threads=None):
    """Apply every substitution and return a list naming those applied."""
    applied = []
    import torch
    # Imported in this order so TotalSegmentator's own runtime patch of
    # predict_from_files lands before ours does.
    import totalsegmentator.nnunet as tsnn
    import nnunetv2.inference.predict_from_raw_data as prd

    predictor = prd.nnUNetPredictor
    if not getattr(predictor.__dict__.get("predict_from_files"), "_odv_seq", False):
        sequential = predictor.predict_from_files_sequential

        def predict_from_files(self, list_of_lists_or_source_folder,
                               output_folder_or_list_of_truncated_output_files,
                               save_probabilities=False, overwrite=True,
                               num_processes_preprocessing=3,
                               num_processes_segmentation_export=3,
                               folder_with_segs_from_prev_stage=None,
                               num_parts=1, part_id=0, **kwargs):
            return sequential(
                self, list_of_lists_or_source_folder,
                output_folder_or_list_of_truncated_output_files,
                save_probabilities=save_probabilities, overwrite=overwrite,
                folder_with_segs_from_prev_stage=folder_with_segs_from_prev_stage)

        predict_from_files._odv_seq = True
        predictor.predict_from_files = predict_from_files
        applied.append("nnUNetPredictor.predict_from_files->predict_from_files_sequential")

    if not getattr(tsnn, "_odv_threadpool", False):
        from multiprocessing.pool import ThreadPool
        tsnn.Pool = ThreadPool
        tsnn._odv_threadpool = True
        applied.append("totalsegmentator.nnunet.Pool->ThreadPool")

    floor = int(threads or os.cpu_count() or 1)
    if not getattr(torch.set_num_threads, "_odv_floor", False):
        real = torch.set_num_threads

        def set_num_threads(count):
            real(max(int(count), floor))

        set_num_threads._odv_floor = True
        torch.set_num_threads = set_num_threads
        real(floor)
        applied.append("torch.set_num_threads floor=%d" % floor)
    return applied


def verify():
    """Confirm the substitutions are in force. Raises if they are not."""
    import nnunetv2.inference.predict_from_raw_data as prd
    import totalsegmentator.nnunet as tsnn

    active = getattr(prd.nnUNetPredictor.__dict__.get("predict_from_files"),
                     "_odv_seq", False)
    if not active:
        raise RuntimeError(
            "sandbox shim did not take: predict_from_files is not the "
            "sequential wrapper. It was probably overwritten by a later import.")
    if not getattr(tsnn, "_odv_threadpool", False):
        raise RuntimeError("sandbox shim did not take: Pool is not ThreadPool")
    return True
'''

SHIM_MODULE = "odv_sandbox_shim"


def write_shim(directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{SHIM_MODULE}.py").write_text(_SHIM_SOURCE)
    return directory


# ---------------------------------------------------------------------------
# Stage: prepare
# ---------------------------------------------------------------------------


def stage_prepare(series_dirs: list[Path], prepared_root: Path,
                  recorder: Recorder, done: set[str],
                  max_slices: int | None = None) -> list[Path]:
    """Make each source series usable by the adapter, recording what had to change.

    This stage exists because of a defect it discovered rather than by design.
    highdicom reads `SliceThickness` unconditionally from the first source
    image when it builds the SEG's Pixel Measures. SliceThickness (0018,0050)
    is Type 2 in the CT Image IOD -- it may legitimately be present and empty,
    or, as here, absent from a de-identified archive export. Every series in
    this public cohort omits it, so the adapter's SEG export raises
    AttributeError on all of them and the plugin produces no output at all.

    The repair is to write a SliceThickness derived from the median spacing
    between consecutive ImagePositionPatient z values -- which is the number
    the geometry already implies -- into a *copy* of the series. Source data is
    never modified. Every case records `slice_thickness_repaired` so no result
    downstream can be read as though it came from an untouched series.

    This is a workaround for the evaluation, not a fix. The fix belongs in the
    adapter, and is reported as a finding.

    `max_slices` optionally keeps only a centred contiguous run of that many
    instances. Conformance is a property of the encoding, not of how much
    anatomy is covered, so a shorter series tests the same claim at a fraction
    of the CPU cost -- which matters here because segmentation runs without an
    accelerator. Any subsetting is recorded per case as `z_subset`, and the
    resulting SEG is still checked against the full set of instances that were
    actually given to the adapter.
    """
    import numpy as np
    import pydicom

    prepared: list[Path] = []
    for series_dir in series_dirs:
        case_id = f"prepare/{series_dir.name}"
        target = prepared_root / series_dir.name
        if case_id in done and target.is_dir() and list(target.glob("*.dcm")):
            prepared.append(target)
            print(f"  [skip] {case_id}", flush=True)
            continue

        started = time.perf_counter()
        try:
            files = sorted(series_dir.glob("*.dcm"))
            if not files:
                raise RuntimeError("no DICOM files")

            datasets = []
            for path in files:
                ds = pydicom.dcmread(str(path))
                if getattr(ds, "Modality", None) == "SEG":
                    continue
                datasets.append((float(ds.ImagePositionPatient[2]), path.name, ds))
            datasets.sort(key=lambda item: item[0])

            missing = [name for _, name, ds in datasets
                       if getattr(ds, "SliceThickness", None) in (None, "")]
            positions = [z for z, _, _ in datasets]
            gaps = np.diff(positions)
            derived = float(np.median(np.abs(gaps))) if len(gaps) else None
            uniform = bool(len(gaps) and np.allclose(np.abs(gaps), abs(gaps[0]),
                                                     atol=1e-3))

            subset = False
            if max_slices and len(datasets) > max_slices:
                middle = len(datasets) // 2
                start = max(0, middle - max_slices // 2)
                datasets = datasets[start:start + max_slices]
                positions = [z for z, _, _ in datasets]
                subset = True

            if target.is_dir():
                shutil.rmtree(target)
            target.mkdir(parents=True, exist_ok=True)
            for _, name, ds in datasets:
                if getattr(ds, "SliceThickness", None) in (None, "") and derived:
                    ds.SliceThickness = derived
                ds.save_as(str(target / name))

            notes = []
            if missing:
                notes.append("slice_thickness_repaired")
            if not uniform:
                notes.append("non-uniform-z-spacing")
            if subset:
                notes.append(f"z_subset:{len(datasets)}")

            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=True,
                wall_s=time.perf_counter() - started,
                metrics={
                    "source_series_dir": str(series_dir),
                    "prepared_series_dir": str(target),
                    "instances": len(datasets),
                    "instances_missing_slice_thickness": len(missing),
                    "z_subset": subset,
                    "derived_slice_thickness_mm": (round(derived, 6)
                                                   if derived else None),
                    "z_spacing_uniform": uniform,
                    "z_extent_mm": (round(positions[-1] - positions[0], 4)
                                    if positions else None),
                },
                notes=notes))
            prepared.append(target)
        except Exception as exc:  # noqa: BLE001 - a failure is a result
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False,
                wall_s=time.perf_counter() - started,
                error=f"{type(exc).__name__}: {exc}"))
    return prepared


# ---------------------------------------------------------------------------
# Stage: shipped
# ---------------------------------------------------------------------------


def stage_shipped(series_dirs: list[Path], work_root: Path, python: Path,
                  task: str, fast: bool, recorder: Recorder,
                  done: set[str]) -> None:
    """Invoke the shipped adapter exactly as the host does, on unmodified data.

    This stage exists to answer one question and to answer it on the record:
    *can the plugin, as shipped, produce a DICOM SEG for this public cohort at
    all?* It spawns `plugins/totalseg/run_segment.py` through its real CLI --
    `--task <task> --out <dir> --input-series3d <series>`, the exact command line
    PLUGIN_PROTOCOL.md section 4 specifies -- against the **unprepared** source
    series, with no shim and no repair. Nothing about the adapter is bypassed
    or substituted.

    A failure here is a result, not an obstacle. It is recorded with the
    adapter's own `result.json` error envelope, because that envelope is what
    the host would show the user, and the whole point of the protocol's
    §4c requirement is that the adapter explain itself rather than return a
    bare exit code.

    Runs are bounded by `timeout`: inference in this environment is CPU-only,
    and a case that exceeds the budget is recorded as a timeout rather than
    left to run. That is itself reportable -- it says the shipped path could
    not be demonstrated here, which is different from saying it is broken.
    """
    for series_dir in series_dirs:
        case_id = f"shipped/{series_dir.name}"
        if case_id in done:
            print(f"  [skip] {case_id}", flush=True)
            continue
        out_dir = work_root / "shipped" / series_dir.name
        if out_dir.is_dir():
            shutil.rmtree(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)

        argv = [str(python), str(REPO / "plugins" / "totalseg" / "run_segment.py"),
                "--task", task, "--out", str(out_dir),
                "--input-series3d", str(series_dir)]
        if task == "total":
            argv += ["--opt-fast", "true" if fast else "false"]

        started = time.perf_counter()
        timed_out = False
        try:
            proc = subprocess.run(argv, capture_output=True, text=True,
                                  timeout=SHIPPED_TIMEOUT_S)
            returncode, output = proc.returncode, (proc.stdout or "") + (proc.stderr or "")
        except subprocess.TimeoutExpired:
            timed_out = True
            returncode, output = None, ""
        wall = time.perf_counter() - started

        # §4/§4c: the adapter writes result.json on failure as well as success,
        # and the host reads it either way. Read it the same way.
        envelope: dict[str, Any] = {}
        result_path = out_dir / "result.json"
        if result_path.is_file():
            try:
                envelope = json.loads(result_path.read_text())
            except json.JSONDecodeError:
                envelope = {"_unparseable": result_path.read_text()[:500]}

        seg_path = out_dir / "segmentation.dcm"
        produced = seg_path.is_file()
        error_code = (envelope.get("error") or {}).get("code")
        error_message = (envelope.get("error") or {}).get("message")

        metrics = {
            "series_dir": str(series_dir),
            "invocation": " ".join(argv[1:]),
            "exit_code": returncode,
            "timed_out": timed_out,
            "result_json_written": result_path.is_file(),
            "error_code": error_code,
            "error_message": error_message,
            "seg_produced": produced,
            "task": task,
            "fast": fast,
        }
        if produced:
            metrics["seg_path"] = str(seg_path)
            metrics["seg_bytes"] = seg_path.stat().st_size

        if timed_out:
            error = (f"shipped adapter exceeded the {SHIPPED_TIMEOUT_S:.0f}s budget; "
                     f"inference here is CPU-only")
        elif not produced:
            error = (f"shipped adapter exited {returncode} without a SEG: "
                     f"{error_message or output[-400:]}")
        else:
            error = None

        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=produced, wall_s=wall,
            metrics=metrics, error=error,
            notes=["shipped-adapter-cli", "unmodified-source-series"]))


# How long the shipped adapter is given per case before the run is recorded as
# a timeout. Generous relative to a GPU run and still far short of what
# single-threaded CPU inference needs on a contended machine -- which is the
# point: the budget is what makes "could not be demonstrated here" a measured
# statement rather than an impression.
SHIPPED_TIMEOUT_S = float(os.environ.get("ODV_SHIPPED_TIMEOUT_S", 1800.0))


# ---------------------------------------------------------------------------
# Stage: fixture
# ---------------------------------------------------------------------------


def stage_fixture(series_dirs: list[Path], work_root: Path, python: Path,
                  recorder: Recorder, done: set[str]) -> None:
    """Encode deterministic masks through the adapter's real SEG exporter.

    Why this exists alongside `segment`. The claim under test is about the
    *encoding* -- whether the DICOM SEG our plugin layer writes is conformant
    and readable by an independent implementation. That claim is a property of
    `_export_dicom_seg`, which is what this stage exercises: the adapter's own
    function, unmodified, called on real DICOM series with real geometry. What
    the mask voxels mean is irrelevant to it. Segmentation *accuracy* is a
    different claim and belongs to the pipeline-fidelity experiment.

    Two things are gained by not routing conformance through nnU-Net.

    First, it runs. Inference here is CPU-only and, on a shared machine, did
    not complete within any reasonable budget (see eval/results/exp1_findings.md). A
    conformance result that cannot be reproduced without a free GPU is not much
    of a conformance result.

    Second, and more usefully, the mask content can be *chosen* to attack the
    encoder. Real TotalSegmentator output is well-behaved: compact blobs, no
    overlaps. It would not exercise the cases where a SEG writer actually
    fails. These fixtures deliberately include a structure that overlaps
    another, a structure one voxel thick, a structure present on a single
    slice, a structure touching the volume boundary, and a structure that is
    empty -- each of which probes a distinct part of the Segmentation IOD
    (respectively: the labelmap collapse, nearest-neighbour resampling,
    omit_empty_frames, frame position encoding, and segment admission).

    The masks are written on the source series' own grid, so no resampling
    happens before encoding and any difference observed downstream is
    attributable to the SEG round trip rather than to interpolation.
    """
    worker = work_root / "_fixture_worker.py"
    worker.parent.mkdir(parents=True, exist_ok=True)
    worker.write_text(_FIXTURE_WORKER)

    for series_dir in series_dirs:
        case_id = f"fixture/{series_dir.name}"
        if case_id in done:
            print(f"  [skip] {case_id}", flush=True)
            continue
        work = work_root / series_dir.name
        work.mkdir(parents=True, exist_ok=True)
        started = time.perf_counter()
        proc = subprocess.run(
            [str(python), str(worker), str(REPO), str(series_dir), str(work)],
            capture_output=True, text=True)
        wall = time.perf_counter() - started

        payload: dict[str, Any] = {}
        for line in reversed((proc.stdout or "").splitlines()):
            try:
                candidate = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(candidate, dict) and "ok" in candidate:
                payload = candidate
                break

        if proc.returncode != 0 or not payload.get("ok"):
            tail = ((proc.stderr or "") + (proc.stdout or ""))[-1500:]
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False, wall_s=wall,
                error=(payload.get("error")
                       or f"fixture worker exited {proc.returncode}: {tail}"),
                notes=["adapter-exporter"]))
            continue

        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=True, wall_s=wall,
            stages_s=payload.get("timings", {}),
            metrics={
                "series_dir": str(series_dir),
                "seg_path": payload["seg"],
                "masks_dir": payload["masks_dir"],
                "structure_count": len(payload["structures"]),
                "structures": payload["structures"],
                "fixture_design": payload.get("design", {}),
                "provenance": payload.get("provenance", {}),
                "seg_bytes": payload.get("seg_bytes"),
                "totalsegmentator_version": payload.get("totalsegmentator_version"),
            },
            notes=["adapter-exporter", "synthetic-masks"]))


# Runs in the TotalSegmentator interpreter. Calls the adapter's own
# `_structure_masks`, `_volumes_ml` and `_export_dicom_seg` -- this is a driver
# for the adapter, not a reimplementation of it.
_FIXTURE_WORKER = '''\
import json, sys, time
from pathlib import Path

repo = Path(sys.argv[1])
series_dir = Path(sys.argv[2])
work = Path(sys.argv[3])

sys.path.insert(0, str(repo / "plugins"))
sys.path.insert(0, str(repo / "plugins" / "totalseg"))

import numpy as np
import SimpleITK as sitk
import run_segment as rs
from _shared.progress import ProgressReporter

reporter = ProgressReporter(stream=sys.stderr)
masks_dir = work / "masks"
masks_dir.mkdir(parents=True, exist_ok=True)
timings = {}

t0 = time.perf_counter()
reader = sitk.ImageSeriesReader()
reader.SetFileNames(reader.GetGDCMSeriesFileNames(str(series_dir)))
reference = reader.Execute()
timings["reference_read_s"] = time.perf_counter() - t0

nx, ny, nz = reference.GetSize()
zz, yy, xx = np.mgrid[0:nz, 0:ny, 0:nx]
cy, cx = ny // 2, nx // 2

# Each fixture targets a specific encoder behaviour. Names are borrowed from
# TotalSegmentator's vocabulary so the SNOMED coverage check is meaningful.
design = {
    "liver": "solid ellipsoid, well-conditioned control",
    "aorta": "thin 1-voxel-thick shell, stresses nearest-neighbour resampling",
    "spleen": "single-slice structure, stresses omit_empty_frames",
    "stomach": "overlaps liver, exposes labelmap collapse ordering",
    "urinary_bladder": "touches the volume boundary in x and y",
    "gallbladder": "empty, must be dropped before encoding",
}

radius = max(6, min(nx, ny) // 6)
masks = {
    "liver": (((zz - nz // 2) ** 2) / max(1, (nz // 4) ** 2)
              + ((yy - cy) ** 2) / float(radius * radius)
              + ((xx - cx) ** 2) / float(radius * radius)) < 1.0,
    "aorta": np.abs(np.sqrt((yy - cy) ** 2.0 + (xx - cx) ** 2.0)
                    - (radius * 1.6)) < 1.0,
    "spleen": ((np.abs(zz - max(1, nz // 4)) <= 0)
               & (((yy - cy // 2) ** 2 + (xx - cx // 2) ** 2) < (radius * radius) / 4)),
    # Deliberately shares voxels with liver.
    "stomach": (((zz - nz // 2) ** 2) / max(1, (nz // 4) ** 2)
                + ((yy - cy) ** 2) / float(radius * radius)
                + ((xx - cx) ** 2) / float(radius * radius)) < 0.35,
    "urinary_bladder": ((yy < 3) & (xx < 3)),
    "gallbladder": np.zeros((nz, ny, nx), dtype=bool),
}

t0 = time.perf_counter()
for name, array in masks.items():
    image = sitk.GetImageFromArray(array.astype(np.uint8))
    image.CopyInformation(reference)
    sitk.WriteImage(image, str(masks_dir / (name + ".nii.gz")))
timings["fixture_write_s"] = time.perf_counter() - t0

provenance = {
    "module": rs.__file__,
    "export_function": "run_segment._export_dicom_seg",
    "mask_scan_function": "run_segment._structure_masks",
    "volumes_function": "run_segment._volumes_ml",
    "adapter_sha256": __import__("hashlib").sha256(
        Path(rs.__file__).read_bytes()).hexdigest()[:16],
    "masks": "synthetic, written on the source series grid",
}

t0 = time.perf_counter()
selected = rs._structure_masks(masks_dir)
timings["mask_scan_s"] = time.perf_counter() - t0

t0 = time.perf_counter()
volumes = rs._volumes_ml(selected)
timings["volumes_s"] = time.perf_counter() - t0

seg_path = work / rs.SEG_FILENAME
try:
    t0 = time.perf_counter()
    rs._export_dicom_seg(series_dir, selected, seg_path, "total", reporter)
    timings["seg_export_s"] = time.perf_counter() - t0
except BaseException as exc:
    print(json.dumps({"ok": False,
                      "error": "%s: %s" % (type(exc).__name__, exc),
                      "timings": timings}))
    raise SystemExit(1)

print(json.dumps({
    "ok": True,
    "seg": str(seg_path),
    "masks_dir": str(masks_dir),
    "structures": [name for name, _ in selected],
    "design": design,
    "volumes_ml": volumes,
    "seg_bytes": seg_path.stat().st_size,
    "provenance": provenance,
    "timings": timings,
    "totalsegmentator_version": rs._totalsegmentator_version(),
}))
'''


# ---------------------------------------------------------------------------
# Stage: segment
# ---------------------------------------------------------------------------

# The adapter's pipeline, driven stage by stage so the intermediate masks
# survive. The functions called here are the adapter's own -- this is not a
# reimplementation of it -- but `pipeline()` runs them inside a
# TemporaryDirectory that is deleted before the process exits, and the
# round-trip comparison needs the masks that went in.
_SEGMENT_WORKER = '''\
import json, sys, time
from pathlib import Path

repo = Path(sys.argv[1])
series_dir = Path(sys.argv[2])
work = Path(sys.argv[3])
task = sys.argv[4]
fast = sys.argv[5] == "true"
shim_dir = sys.argv[6] if len(sys.argv) > 6 else ""

sys.path.insert(0, str(repo / "plugins"))
sys.path.insert(0, str(repo / "plugins" / "totalseg"))
import run_segment as rs
from _shared.progress import ProgressReporter

shim_applied = []
if shim_dir:
    # Import the model stack first, then patch, then verify. See the comment on
    # _SHIM_SOURCE: patching during import is silently undone.
    sys.path.insert(0, shim_dir)
    import totalsegmentator.python_api  # noqa: F401
    import odv_sandbox_shim
    shim_threads = int(sys.argv[7]) if len(sys.argv) > 7 and sys.argv[7] else None
    shim_applied = odv_sandbox_shim.apply(threads=shim_threads)
    odv_sandbox_shim.verify()

reporter = ProgressReporter(stream=sys.stderr)
masks_dir = work / "masks"
masks_dir.mkdir(parents=True, exist_ok=True)
timings = {}

t0 = time.perf_counter()
rs._run_totalsegmentator(series_dir, masks_dir, rs.TASKS[task], fast, reporter)
timings["inference_s"] = time.perf_counter() - t0

t0 = time.perf_counter()
masks = rs._structure_masks(masks_dir)
timings["mask_scan_s"] = time.perf_counter() - t0

t0 = time.perf_counter()
volumes = rs._volumes_ml(masks)
timings["volumes_s"] = time.perf_counter() - t0

t0 = time.perf_counter()
rs._export_dicom_seg(series_dir, masks, work / rs.SEG_FILENAME, rs.TASKS[task], reporter)
timings["seg_export_s"] = time.perf_counter() - t0

print(json.dumps({
    "ok": True,
    "seg": str(work / rs.SEG_FILENAME),
    "masks_dir": str(masks_dir),
    "structures": [name for name, _ in masks],
    "volumes_ml": volumes,
    "timings": timings,
    "totalsegmentator_version": rs._totalsegmentator_version(),
    "shim_applied": shim_applied,
}))
'''


def stage_segment(series_dirs: list[Path], work_root: Path, python: Path,
                  task: str, fast: bool, use_shim: bool,
                  recorder: Recorder, done: set[str],
                  threads: int | None = None) -> None:
    worker = work_root / "_segment_worker.py"
    worker.parent.mkdir(parents=True, exist_ok=True)
    worker.write_text(_SEGMENT_WORKER)

    env = dict(os.environ)
    notes: list[str] = []
    shim_dir = ""
    if use_shim:
        shim_dir = str(write_shim(work_root / "_shim"))
        notes.append(SHIM_NOTE)

    for series_dir in series_dirs:
        case_id = f"segment/{series_dir.name}"
        if case_id in done:
            print(f"  [skip] {case_id}", flush=True)
            continue
        work = work_root / series_dir.name
        work.mkdir(parents=True, exist_ok=True)
        started = time.perf_counter()
        proc = subprocess.run(
            [str(python), str(worker), str(REPO), str(series_dir), str(work),
             task, "true" if fast else "false", shim_dir, str(threads or "")],
            capture_output=True, text=True, env=env)
        wall = time.perf_counter() - started

        payload: dict[str, Any] = {}
        for line in reversed((proc.stdout or "").splitlines()):
            try:
                candidate = json.loads(line)
            except json.JSONDecodeError:
                continue
            if candidate.get("ok"):
                payload = candidate
                break

        if proc.returncode != 0 or not payload:
            tail = ((proc.stderr or "") + (proc.stdout or ""))[-1200:]
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False, wall_s=wall,
                error=f"segmentation worker exited {proc.returncode}: {tail}",
                notes=notes))
            continue

        recorder.write(CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=True, wall_s=wall,
            stages_s=payload.get("timings", {}),
            metrics={
                "series_dir": str(series_dir),
                "seg_path": payload["seg"],
                "masks_dir": payload["masks_dir"],
                "structure_count": len(payload["structures"]),
                "task": task,
                "fast": fast,
                "totalsegmentator_version": payload.get("totalsegmentator_version"),
                "volumes_ml": payload.get("volumes_ml", {}),
            },
            notes=notes))


# ---------------------------------------------------------------------------
# Stage: dcmqi round trip
# ---------------------------------------------------------------------------


def dcmqi_binary(name: str, explicit: Path | None = None) -> Path:
    """Locate a dcmqi command-line tool.

    Preferred source is the `dcmqi` PyPI wheel, which ships QIICR's own
    prebuilt binaries; falling back to PATH lets a system installation be used
    instead. The version actually used is recorded per case, because "dcmqi
    read it" is only a meaningful statement with a version attached.
    """
    if explicit:
        candidate = Path(explicit) / name
        if candidate.is_file():
            return candidate
    try:
        import dcmqi  # noqa: PLC0415 - optional dependency of this experiment

        candidate = Path(dcmqi.__file__).parent / "bin" / name
        if candidate.is_file():
            return candidate
    except ImportError:
        pass
    found = shutil.which(name)
    if found:
        return Path(found)
    raise FileNotFoundError(
        f"{name} not found. Install QIICR's reference implementation with "
        f"`pip install dcmqi`, or pass --dcmqi-bin.")


def dcmqi_version(binary: Path) -> str:
    out = subprocess.run([str(binary), "--version"], capture_output=True, text=True)
    text = (out.stdout or "") + (out.stderr or "")
    for line in text.splitlines():
        if "tag:" in line:
            return line.strip()
    return text.strip().splitlines()[0] if text.strip() else "unknown"


def _read_itk(path: Path):
    import SimpleITK as sitk

    return sitk.ReadImage(str(path))


def _geometry(image) -> dict:
    return {
        "size": list(image.GetSize()),
        "spacing": [round(v, 6) for v in image.GetSpacing()],
        "origin": [round(v, 4) for v in image.GetOrigin()],
        "direction": [round(v, 6) for v in image.GetDirection()],
    }


def _geometry_matches(a: dict, b: dict, tol: float = 1e-3) -> dict:
    def close(x, y):
        return len(x) == len(y) and all(abs(float(p) - float(q)) <= tol
                                        for p, q in zip(x, y))
    return {
        "size": a["size"] == b["size"],
        "spacing": close(a["spacing"], b["spacing"]),
        "origin": close(a["origin"], b["origin"]),
        "direction": close(a["direction"], b["direction"]),
    }


def stage_roundtrip(rows: list[dict], recorder: Recorder, done: set[str],
                    dcmqi_bin: Path | None, keep: Path | None) -> None:
    """Decode each SEG with dcmqi and compare voxelwise against its input masks.

    The comparison is done in the source series' physical space. dcmqi returns
    the decoded segmentation on the grid the SEG encodes, which -- because the
    adapter omits empty frames -- can be cropped in z relative to the source.
    Resampling both onto the source reference geometry with nearest neighbour
    is what makes the Dice a statement about agreement rather than about extent,
    and the extent difference is reported separately as a geometry finding.

    Two reference points, not one, because they answer different questions and
    conflating them would misattribute a defect:

      `intended`  the adapter's input mask, resampled onto the source grid.
                  Dice against this measures the whole path, encoder included.
      `encoded`   what the adapter actually handed to highdicom. The adapter
                  builds a single uint8 labelmap and assigns `label[mask] =
                  index` per structure in order, so where two structures
                  overlap the later index overwrites the earlier one and those
                  voxels are gone before encoding begins. Dice against this
                  isolates the encode/decode round trip proper.

    A structure whose `dice_vs_encoded` is 1.0 while `dice_vs_intended` is
    below 1.0 was damaged by our adapter and faithfully transported by DICOM.
    The reverse would indicate a genuine round-trip defect. Reporting only the
    first number would blame dcmqi for our loss; reporting only the second
    would hide the loss entirely.
    """
    import numpy as np
    import SimpleITK as sitk

    binary = dcmqi_binary("segimage2itkimage", dcmqi_bin)
    version = dcmqi_version(binary)

    for row in rows:
        metrics = row.get("metrics", {})
        seg_path = Path(metrics.get("seg_path", ""))
        series_dir = Path(metrics.get("series_dir", ""))
        masks_dir = Path(metrics.get("masks_dir", ""))
        name = series_dir.name
        case_id = f"roundtrip/{row['case_id'].split('/', 1)[0]}/{name}"
        if case_id in done:
            print(f"  [skip] {case_id}", flush=True)
            continue
        if not seg_path.is_file():
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False, wall_s=0.0,
                error=f"SEG absent: {seg_path}"))
            continue

        timer = StageTimer()
        started = time.perf_counter()
        out_dir = (keep or seg_path.parent) / "dcmqi"
        shutil.rmtree(out_dir, ignore_errors=True)
        out_dir.mkdir(parents=True, exist_ok=True)

        try:
            with timer.stage("dcmqi_decode_s"):
                proc = subprocess.run(
                    [str(binary), "--inputDICOM", str(seg_path),
                     "--outputDirectory", str(out_dir), "-t", "nii", "-p", "seg"],
                    capture_output=True, text=True)
            if proc.returncode != 0:
                raise RuntimeError(
                    f"segimage2itkimage exited {proc.returncode}: "
                    f"{((proc.stderr or '') + (proc.stdout or ''))[-800:]}")

            meta_path = out_dir / "seg-meta.json"
            if not meta_path.is_file():
                candidates = list(out_dir.glob("*meta.json"))
                if not candidates:
                    raise RuntimeError("dcmqi wrote no metadata JSON")
                meta_path = candidates[0]
            meta = json.loads(meta_path.read_text())

            # dcmqi packs non-overlapping segments into shared label files;
            # segmentAttributes is one list per output file.
            decoded: dict[str, tuple[Path, int]] = {}
            attribute_groups = meta.get("segmentAttributes", [])
            files = sorted(out_dir.glob("seg*.nii")) + sorted(out_dir.glob("seg*.nii.gz"))
            files = [f for f in files if "meta" not in f.name]
            for index, group in enumerate(attribute_groups):
                if index >= len(files):
                    break
                for attribute in group:
                    label = attribute.get("SegmentLabel") or attribute.get("SegmentDescription")
                    decoded[label] = (files[index], int(attribute["labelID"]))

            with timer.stage("reference_read_s"):
                reader = sitk.ImageSeriesReader()
                reader.SetFileNames(reader.GetGDCMSeriesFileNames(str(series_dir)))
                reference = reader.Execute()
            reference_geom = _geometry(reference)

            # Reproduce the adapter's labelmap collapse to obtain, per
            # structure, exactly the voxels that were handed to the encoder.
            # This mirrors _export_dicom_seg's ordering: structures sorted by
            # name, `label[array] = index` from 1, later index wins.
            with timer.stage("rebuild_encoded_s"):
                intended: dict[str, Any] = {}
                order: list[str] = []
                for mask_path in sorted(masks_dir.glob("*.nii.gz")):
                    structure = mask_path.name[: -len(".nii.gz")]
                    native = sitk.ReadImage(str(mask_path))
                    resampled = sitk.Resample(
                        native, reference, sitk.Transform(),
                        sitk.sitkNearestNeighbor, 0, native.GetPixelID())
                    array = sitk.GetArrayFromImage(resampled) > 0
                    if not array.any():
                        # The adapter drops these before encoding; not a
                        # round-trip failure.
                        continue
                    intended[structure] = array
                    order.append(structure)

                labelmap = np.zeros(
                    sitk.GetArrayFromImage(reference).shape, dtype=np.uint16)
                for index, structure in enumerate(order, start=1):
                    labelmap[intended[structure]] = index

            per_structure: list[dict] = []
            with timer.stage("compare_s"):
                for index, structure in enumerate(order, start=1):
                    want = intended[structure]
                    encoded = labelmap == index
                    entry: dict[str, Any] = {
                        "structure": structure,
                        "intended_voxels": int(want.sum()),
                        "encoded_voxels": int(encoded.sum()),
                        "overwritten_by_later_segment": int((want & ~encoded).sum()),
                    }
                    if structure not in decoded:
                        entry.update({"present_in_seg": False,
                                      "dice_vs_intended": 0.0,
                                      "dice_vs_encoded": 0.0,
                                      "decoded_voxels": 0,
                                      "voxel_difference": -int(encoded.sum())})
                        per_structure.append(entry)
                        continue

                    label_file, label_id = decoded[structure]
                    label_image = _read_itk(label_file)
                    entry["decoded_geometry"] = _geometry(label_image)
                    entry["geometry_matches_source"] = _geometry_matches(
                        entry["decoded_geometry"], reference_geom)
                    resampled = sitk.Resample(
                        label_image, reference, sitk.Transform(),
                        sitk.sitkNearestNeighbor, 0, label_image.GetPixelID())
                    got = sitk.GetArrayFromImage(resampled) == label_id
                    entry.update({
                        "present_in_seg": True,
                        "label_id": label_id,
                        "decoded_voxels": int(got.sum()),
                        "voxel_difference": int(got.sum()) - int(encoded.sum()),
                        "dice_vs_encoded": round(dice(encoded, got), 6),
                        "dice_vs_intended": round(dice(want, got), 6),
                        "false_positive_voxels": int((got & ~encoded).sum()),
                        "false_negative_voxels": int((~got & encoded).sum()),
                    })
                    per_structure.append(entry)

            geometry_ok = all(all(e.get("geometry_matches_source", {}).values())
                              for e in per_structure if e.get("present_in_seg"))
            encoded_dices = [e["dice_vs_encoded"] for e in per_structure]
            intended_dices = [e["dice_vs_intended"] for e in per_structure]
            overwritten = [e for e in per_structure
                           if e["overwritten_by_later_segment"] > 0]
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=True,
                wall_s=time.perf_counter() - started, stages_s=timer.stages,
                metrics={
                    "series_dir": str(series_dir),
                    "seg_path": str(seg_path),
                    "dcmqi_version": version,
                    "structures_compared": len(per_structure),
                    "structures_exact_vs_encoded": sum(
                        1 for d in encoded_dices if d == 1.0),
                    "structures_exact_vs_intended": sum(
                        1 for d in intended_dices if d == 1.0),
                    "structures_missing_from_seg": sum(
                        1 for e in per_structure if not e.get("present_in_seg")),
                    "min_dice_vs_encoded": round(min(encoded_dices), 6) if encoded_dices else None,
                    "mean_dice_vs_encoded": round(
                        sum(encoded_dices) / len(encoded_dices), 6) if encoded_dices else None,
                    "min_dice_vs_intended": round(min(intended_dices), 6) if intended_dices else None,
                    "mean_dice_vs_intended": round(
                        sum(intended_dices) / len(intended_dices), 6) if intended_dices else None,
                    "structures_with_overlap_loss": len(overwritten),
                    "voxels_lost_to_overlap": sum(
                        e["overwritten_by_later_segment"] for e in per_structure),
                    "total_voxel_difference": sum(
                        abs(e.get("voxel_difference", 0)) for e in per_structure),
                    "geometry_preserved": geometry_ok,
                    "reference_geometry": reference_geom,
                    "per_structure": per_structure,
                }))
        except Exception as exc:  # noqa: BLE001 - a failure is a result
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False,
                wall_s=time.perf_counter() - started, stages_s=timer.stages,
                error=f"{type(exc).__name__}: {exc}"))


# ---------------------------------------------------------------------------
# Stage: field audit
# ---------------------------------------------------------------------------


def stage_audit(rows: list[dict], recorder: Recorder, done: set[str]) -> None:
    snomed = cc.snomed_reference_map()

    for row in rows:
        metrics = row.get("metrics", {})
        seg_path = Path(metrics.get("seg_path", ""))
        series_dir = Path(metrics.get("series_dir", ""))
        case_id = f"audit/{row['case_id'].split('/', 1)[0]}/{series_dir.name}"
        if case_id in done:
            print(f"  [skip] {case_id}", flush=True)
            continue
        if not seg_path.is_file():
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False, wall_s=0.0,
                error=f"SEG absent: {seg_path}"))
            continue

        started = time.perf_counter()
        try:
            findings = cc.audit_seg(seg_path, series_dir)
            summary = {f.check: f.status for f in findings}

            # How much specific coding was available but not used. This is the
            # difference between "conformant" and "semantically useful", and it
            # is only answerable because TotalSegmentator publishes a mapping.
            coverage = None
            if snomed:
                import pydicom

                seg = pydicom.dcmread(str(seg_path), stop_before_pixels=True)
                labels = [getattr(s, "SegmentLabel", "")
                          for s in getattr(seg, "SegmentSequence", []) or []]
                available = [label for label in labels if label in snomed]
                coverage = {
                    "segments": len(labels),
                    "specific_code_available_upstream": len(available),
                    "specific_code_emitted": sum(
                        1 for s in getattr(seg, "SegmentSequence", []) or []
                        if cc._code_tuple(
                            cc._first(s, "SegmentedPropertyTypeCodeSequence"))[1]
                        not in (None, *cc.GENERIC_ANATOMY_CODES)),
                }

            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id,
                ok=cc.worst_status(findings) != "FAIL",
                wall_s=time.perf_counter() - started,
                metrics={
                    "seg_path": str(seg_path),
                    "series_dir": str(series_dir),
                    "worst_status": cc.worst_status(findings),
                    "status_by_check": summary,
                    "findings": [f.as_dict() for f in findings],
                    "snomed_coverage": coverage,
                },
                error=None if cc.worst_status(findings) != "FAIL" else "; ".join(
                    f.detail for f in findings if f.status == "FAIL")))
        except Exception as exc:  # noqa: BLE001
            recorder.write(CaseResult(
                experiment=EXPERIMENT, case_id=case_id, ok=False,
                wall_s=time.perf_counter() - started,
                error=f"{type(exc).__name__}: {exc}"))


# ---------------------------------------------------------------------------
# Stage: sample for the external viewer checklist
# ---------------------------------------------------------------------------


def stage_sample(rows: list[dict], destination: Path) -> Path | None:
    """Assemble the SEG and source instances a human needs for docs/EXTERNAL_VIEWER_CHECKLIST.md.

    The checklist cannot be executed by this evaluation -- driving 3D Slicer and
    OHIF needs a display and a person. What can be done here is to leave behind
    exactly the files that procedure asks for, together with the expectations
    the operator should check against, so the manual step is a comparison
    rather than an exploration.

    The smallest successful case is chosen: a human is going to load this by
    hand, and a 48-instance series is as good a conformance witness as a
    500-instance one.
    """
    import pydicom

    candidates = [r for r in rows
                  if r["ok"]
                  and (r["case_id"].startswith("segment/")
                       or r["case_id"].startswith("fixture/"))
                  and Path(r["metrics"].get("seg_path", "")).is_file()]
    if not candidates:
        print("sample: no successfully produced SEG to publish", flush=True)
        return None

    def seg_size(row: dict) -> int:
        return Path(row["metrics"]["seg_path"]).stat().st_size

    chosen = min(candidates, key=seg_size)
    seg_path = Path(chosen["metrics"]["seg_path"])
    series_dir = Path(chosen["metrics"]["series_dir"])

    if destination.is_dir():
        shutil.rmtree(destination)
    (destination / "source_series").mkdir(parents=True, exist_ok=True)
    shutil.copy(seg_path, destination / "segmentation.dcm")

    seg = pydicom.dcmread(str(seg_path))
    referenced: set[str] = set()
    for series in getattr(seg, "ReferencedSeriesSequence", []) or []:
        for instance in getattr(series, "ReferencedInstanceSequence", []) or []:
            uid = getattr(instance, "ReferencedSOPInstanceUID", None)
            if uid:
                referenced.add(uid)

    # Copy the instances the SEG actually references, so the operator cannot
    # load a superset and mistake a coverage gap for a rendering bug.
    copied = 0
    positions: list[float] = []
    source_series_uid = None
    for path in sorted(series_dir.glob("*.dcm")):
        ds = pydicom.dcmread(str(path), stop_before_pixels=True)
        if ds.SOPInstanceUID not in referenced:
            continue
        shutil.copy(path, destination / "source_series" / path.name)
        positions.append(float(ds.ImagePositionPatient[2]))
        source_series_uid = ds.SeriesInstanceUID
        copied += 1

    labels = [getattr(s, "SegmentLabel", "?")
              for s in getattr(seg, "SegmentSequence", []) or []]
    notes = chosen.get("notes", [])

    lines = [
        "# External viewer sample",
        "",
        "Produced by `eval/exp1_conformance.py --stages sample`. Load this with",
        "`docs/EXTERNAL_VIEWER_CHECKLIST.md` open beside you and check what you see",
        "against the expectations below.",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Case | `{chosen['case_id']}` |",
        f"| Source series UID | `{source_series_uid}` |",
        f"| Source instances (as referenced by the SEG) | {copied} |",
        f"| Segments | {len(labels)} |",
        f"| SEG frames | {int(getattr(seg, 'NumberOfFrames', 0) or 0)} |",
        f"| SegmentationType | {getattr(seg, 'SegmentationType', '?')} |",
        f"| FrameOfReferenceUID | `{getattr(seg, 'FrameOfReferenceUID', '?')}` |",
        f"| z extent (mm) | {round(min(positions), 2) if positions else '?'} "
        f"to {round(max(positions), 2) if positions else '?'} |",
        f"| Run notes | {', '.join(notes) if notes else '(none)'} |",
        "",
        "## Expected segment labels",
        "",
        "These are the names a viewer should show. If it shows `Segment_1`,",
        "`Segment_2`, ... instead, that is check S3/O3 failing.",
        "",
    ]
    lines += [f"{index}. `{label}`" for index, label in enumerate(labels, start=1)]
    lines += [
        "",
        "## Expected anatomic placement",
        "",
        "Use a structure with obvious cranio-caudal asymmetry to test for a z-flip",
        "(check S6/O5). Scroll from the first slice to the last and confirm each",
        "mask stays on the structure its label names.",
        "",
        "## Caveat on the source instances",
        "",
        "These are a *prepared* copy of a public TCIA series: the archive export",
        "omits `SliceThickness`, which the adapter's SEG export requires, so the",
        "value implied by the slice positions was written in. Nothing else was",
        "changed. See `eval/results/exp1_findings.md`.",
        "",
    ]
    (destination / "SAMPLE.md").write_text("\n".join(lines))
    print(f"sample: wrote {destination} ({copied} instances, {len(labels)} segments)",
          flush=True)
    return destination


# ---------------------------------------------------------------------------
# Derived tables
# ---------------------------------------------------------------------------


# What each producing stage means, spelled out in the derived tables. A bare
# stage name ("fixture") invites the reader to assume a test double wrote the
# SEG; every row here was written by the shipped adapter's own encoder, and the
# column says so.
PRODUCER_LABEL = {
    "fixture": "shipped-adapter-encoder/synthetic-masks",
    "segment": "shipped-adapter-full-pipeline",
    "shipped": "shipped-adapter-cli",
}


def write_tables(results_path: Path) -> list[Path]:
    _, rows = load_results(results_path)
    stem = results_path.with_suffix("")
    written: list[Path] = []

    structure_rows = []
    for row in rows:
        if not row["case_id"].startswith("roundtrip/") or not row["ok"]:
            continue
        parts = row["case_id"].split("/")
        stage, case = (parts[1], parts[2]) if len(parts) > 2 else ("", parts[1])
        producer = PRODUCER_LABEL.get(stage, stage)
        for entry in row["metrics"].get("per_structure", []):
            geometry = entry.get("geometry_matches_source", {})
            structure_rows.append({
                "producer": producer,
                "case": case,
                "structure": entry["structure"],
                "present_in_seg": entry.get("present_in_seg"),
                "intended_voxels": entry.get("intended_voxels"),
                "encoded_voxels": entry.get("encoded_voxels"),
                "decoded_voxels": entry.get("decoded_voxels"),
                "overwritten_by_later_segment": entry.get("overwritten_by_later_segment"),
                "voxel_difference": entry.get("voxel_difference"),
                "dice_vs_encoded": entry.get("dice_vs_encoded"),
                "dice_vs_intended": entry.get("dice_vs_intended"),
                "false_positive_voxels": entry.get("false_positive_voxels"),
                "false_negative_voxels": entry.get("false_negative_voxels"),
                "geometry_size_match": geometry.get("size"),
                "geometry_spacing_match": geometry.get("spacing"),
                "geometry_origin_match": geometry.get("origin"),
                "geometry_direction_match": geometry.get("direction"),
            })
    if structure_rows:
        path = Path(f"{stem}_roundtrip.csv")
        with open(path, "w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(structure_rows[0]))
            writer.writeheader()
            writer.writerows(structure_rows)
        written.append(path)

    audit_rows = []
    for row in rows:
        if not row["case_id"].startswith("audit/"):
            continue
        parts = row["case_id"].split("/")
        stage, case = (parts[1], parts[2]) if len(parts) > 2 else ("", parts[1])
        producer = PRODUCER_LABEL.get(stage, stage)
        if not row["ok"] and not row["metrics"]:
            audit_rows.append({"producer": producer, "case": case,
                               "check": "(audit failed)", "status": "FAIL",
                               "detail": row.get("error", "")})
            continue
        for finding in row["metrics"].get("findings", []):
            audit_rows.append({"producer": producer, "case": case,
                               "check": finding["check"],
                               "status": finding["status"],
                               "detail": finding["detail"]})
    if audit_rows:
        path = Path(f"{stem}_audit.csv")
        with open(path, "w", newline="") as handle:
            writer = csv.DictWriter(
                handle, fieldnames=["producer", "case", "check", "status", "detail"])
            writer.writeheader()
            writer.writerows(audit_rows)
        written.append(path)

    return written


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def discover_series(data_dir: Path, minimum_slices: int) -> list[Path]:
    found = []
    for child in sorted(Path(data_dir).iterdir()):
        if not child.is_dir():
            continue
        count = len(list(child.glob("*.dcm")))
        if count >= minimum_slices:
            found.append(child)
        else:
            print(f"  skipping {child.name}: {count} DICOM files "
                  f"(< --min-slices {minimum_slices})", flush=True)
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path,
                        default=REPO / ".eval" / "data" / "tcia",
                        help="Directory of source DICOM series directories")
    parser.add_argument("--work", type=Path, default=REPO / ".eval" / "exp1",
                        help="Scratch directory for masks and produced SEGs")
    parser.add_argument("--results", type=Path,
                        default=REPO / "eval" / "results" / "exp1_conformance.jsonl")
    parser.add_argument("--python", type=Path,
                        default=Path(sys.executable),
                        help="Interpreter with TotalSegmentator installed, e.g. "
                             "the totalsegmentator plugin's venv python "
                             "(default: the interpreter running this script)")
    parser.add_argument("--dcmqi-bin", type=Path, default=None,
                        help="Directory containing dcmqi command-line tools")
    parser.add_argument("--task", default="total", choices=["total", "heartchambers_highres"])
    parser.add_argument("--fast", default="true", choices=["true", "false"])
    parser.add_argument("--max-cases", type=int, default=None)
    parser.add_argument("--min-slices", type=int, default=20)
    parser.add_argument("--max-slices", type=int, default=None,
                        help="Keep only a centred run of this many instances per "
                             "series. Conformance does not depend on extent, and "
                             "segmentation here is CPU-only. Recorded per case.")
    parser.add_argument("--stages", default="prepare,segment,roundtrip,audit",
                        help="Comma-separated subset of prepare,shipped,fixture,"
                             "segment,roundtrip,audit,sample")
    parser.add_argument("--threads", type=int, default=None,
                        help="Torch thread floor for the shim. Defaults to the "
                             "core count; lower it when the machine is shared.")
    parser.add_argument("--sample-dir", type=Path,
                        default=REPO / "eval" / "results" / "external_viewer_sample",
                        help="Where the sample SEG for the external viewer "
                             "checklist is assembled")
    parser.add_argument("--sandbox-shim", action="store_true",
                        help="Substitute nnU-Net's worker pool with its sequential "
                             "path. Required where AF_UNIX bind is denied. Preserves "
                             "correctness, NOT timing.")
    parser.add_argument("--series", type=Path, nargs="*", default=None,
                        help="Explicit series directories, overriding --data")
    args = parser.parse_args(argv)

    stages = [s.strip() for s in args.stages.split(",") if s.strip()]
    recorder = Recorder(args.results, EXPERIMENT)
    done = recorder.done_case_ids()

    series = ([Path(p) for p in args.series] if args.series
              else discover_series(args.data, args.min_slices))
    if args.max_cases:
        series = series[: args.max_cases]

    if "prepare" in stages:
        print(f"prepare: {len(series)} series", flush=True)
        series = stage_prepare(series, args.work / "prepared", recorder, done,
                               max_slices=args.max_slices)
    elif "segment" in stages or "fixture" in stages:
        # Segmenting without preparing is only correct if the series already
        # carries SliceThickness; the adapter raises AttributeError otherwise.
        prepared_root = args.work / "prepared"
        if prepared_root.is_dir():
            existing = [prepared_root / s.name for s in series
                        if (prepared_root / s.name).is_dir()]
            if existing:
                print(f"using {len(existing)} previously prepared series",
                      flush=True)
                series = existing

    if "shipped" in stages:
        print(f"shipped: {len(series)} series", flush=True)
        stage_shipped(series, args.work, args.python, args.task,
                      args.fast == "true", recorder, done)

    if "fixture" in stages:
        print(f"fixture: {len(series)} series", flush=True)
        stage_fixture(series, args.work, args.python, recorder, done)

    if "segment" in stages:
        print(f"segment: {len(series)} series", flush=True)
        stage_segment(series, args.work, args.python, args.task,
                      args.fast == "true", args.sandbox_shim, recorder, done,
                      threads=args.threads)

    _, rows = load_results(args.results)
    segmented = [r for r in rows
                 if r["ok"] and (r["case_id"].startswith("segment/")
                                 or r["case_id"].startswith("fixture/"))]

    if "roundtrip" in stages:
        print(f"roundtrip: {len(segmented)} SEGs", flush=True)
        stage_roundtrip(segmented, recorder, done, args.dcmqi_bin, None)

    if "audit" in stages:
        print(f"audit: {len(segmented)} SEGs", flush=True)
        stage_audit(segmented, recorder, done)

    if "sample" in stages:
        stage_sample(segmented, args.sample_dir)

    for path in write_tables(args.results):
        print(f"wrote {path}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
