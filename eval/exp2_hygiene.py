#!/usr/bin/env python3
# exp2_hygiene.py
# OpenDicomViewer -- plugin layer evaluation, Experiment 2, hygiene check.
#
# THIS IS NOT AN ACCURACY CLAIM.
#
# exp2_fidelity.py shows that the plugin path and the native path produce
# identical masks. Identical, on its own, is also what two equally broken paths
# produce: if the abstraction fed TotalSegmentator a mis-scaled volume, both
# comparisons would still agree perfectly with each other while the masks were
# nonsense. This script is the check against that -- it asks whether the masks
# coming out of the plugin path resemble expert reference masks to roughly the
# degree TotalSegmentator is published as resembling them.
#
# What it can and cannot support:
#   CAN  -- evidence that the pipeline did not silently break the model.
#   CANNOT -- any statement about TotalSegmentator's accuracy. That is
#             published, it is not this paper's contribution, and this cohort
#             (4 cases, the 3 mm fast model, a NIfTI-to-DICOM round trip) is
#             far too small and too indirect to say anything about it.
"""Sanity-check both paths against expert reference masks.

The reference release ships NIfTI volumes, but the plugin path consumes a DICOM
series by contract (PLUGIN_PROTOCOL.md section 2: `series3d` travels as a
filesystem path to a series directory). The reference CT is therefore written
out as a conformant DICOM CT series first, and BOTH paths read that same
series, so the conversion cannot advantage either one.

Usage:
    PYTHONPATH=eval python eval/exp2_hygiene.py \\
        --ground-truth .eval/data/ground_truth \\
        --out eval/results/exp2_hygiene.jsonl \\
        --python <ts-python>   # see eval/README.md
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

from exp2_fidelity import (  # noqa: E402
    CPU_ONLY_NOTE,
    REPO_ROOT,
    SANDBOX_NOTE,
    child_env,
    decode_seg_like_host,
    load_native_masks,
    resample_to_source,
    source_geometry,
    write_sitecustomize,
)
from harness import (  # noqa: E402
    CaseResult,
    Recorder,
    StageTimer,
    dice,
    load_results,
    machine_profile,
    run_subprocess,
)

EXPERIMENT = "exp2_hygiene"
ADAPTER = REPO_ROOT / "plugins" / "totalseg" / "run_segment.py"

# Published reference. Wasserthal et al., Radiology: Artificial Intelligence
# 2023;5(5):e230024 (doi:10.1148/ryai.230024). Verified against the retrieved
# article text rather than quoted from recall: "The proposed model showed a
# high Dice score (0.943) on the test set, which included a wide range of
# clinical data with major abnormalities."
#
# Note what that number is and is not. It is a single aggregate over the
# authors' own test set for the FULL-RESOLUTION model. It is not a per-
# structure figure, not the 3 mm `fast` model this check runs, and not
# measured on the four cases used here. It is drawn as a reference line so a
# reader can see the order of magnitude our masks land at; it is not a
# threshold either path is expected to meet. The band below is deliberately
# wide and is a
# smoke-test threshold, not a target: this check runs the 3 mm `fast` model,
# which trades resolution for speed and scores lower than the full-resolution
# model -- most visibly on small and thin structures -- and it runs on four
# cases through a NIfTI-to-DICOM conversion. A result inside the band means
# "the pipeline is not broken"; a result at the low end means nothing about the
# model.
PUBLISHED_DICE_FULL_RES = 0.943
PLAUSIBLE_BAND = (0.70, 1.00)

# Structures large enough that the 3 mm model's resolution penalty does not
# dominate, so a genuine pipeline break would be unmistakable. Reported
# separately from the all-structure figure rather than instead of it.
LARGE_STRUCTURES = (
    "liver", "spleen", "stomach", "aorta", "urinary_bladder",
    "kidney_left", "kidney_right", "lung_upper_lobe_left",
    "lung_upper_lobe_right", "lung_lower_lobe_left", "lung_lower_lobe_right",
    "heart", "autochthon_left", "autochthon_right",
)


def worker_nifti_to_dicom(args: argparse.Namespace) -> int:
    """Write a NIfTI CT volume out as a conformant single-frame DICOM series.

    Done with SimpleITK's DICOM writer so the geometry in the file is the
    geometry SimpleITK reads back, rather than one hand-assembled here. Both
    paths consume the result, so any conversion artefact is common-mode and
    cannot make the plugin path look better or worse than the native path.

    SliceThickness is written. The cohort's missing-tag defect is characterised
    in exp2_fidelity's probes; leaving it out here would only re-trigger the
    same known failure and tell us nothing new about accuracy.
    """
    import SimpleITK as sitk

    out = Path(args.output)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    # Some cases in the reference release carry non-orthonormal direction
    # cosines, which ITK refuses to read. Those cases are recorded as failures
    # rather than silently repaired: rescuing them would mean rewriting the
    # reference geometry, and a hygiene check whose reference was adjusted to
    # make it pass is not a check. The property belongs to those NIfTI files,
    # not to the plugin layer, and it is reported as such.
    image = sitk.ReadImage(str(args.input))
    image = sitk.Cast(image, sitk.sitkInt16)
    spacing = image.GetSpacing()
    study_uid = f"1.2.826.0.1.3680043.10.1337.{int(time.time())}.1"
    series_uid = f"1.2.826.0.1.3680043.10.1337.{int(time.time())}.2"
    frame_uid = f"1.2.826.0.1.3680043.10.1337.{int(time.time())}.3"

    writer = sitk.ImageFileWriter()
    writer.KeepOriginalImageUIDOn()
    direction = image.GetDirection()
    orientation = "\\".join(f"{direction[i]:.10g}"
                            for i in (0, 3, 6, 1, 4, 7))

    for index in range(image.GetSize()[2]):
        plane = image[:, :, index]
        position = image.TransformIndexToPhysicalPoint((0, 0, index))
        tags = {
            "0008|0060": "CT",
            "0008|0016": "1.2.840.10008.5.1.4.1.1.2",
            "0008|0018": f"{series_uid}.{index + 1}",
            "0008|0020": "20260101", "0008|0030": "120000",
            "0008|0050": "", "0008|0090": "",
            "0010|0010": "Reference^Case", "0010|0020": args.case_id,
            "0010|0030": "", "0010|0040": "",
            "0020|000d": study_uid, "0020|000e": series_uid,
            "0020|0010": "1", "0020|0011": "1",
            "0020|0013": str(index + 1),
            "0020|0052": frame_uid,
            "0020|0032": "\\".join(f"{v:.10g}" for v in position),
            "0020|0037": orientation,
            "0018|0050": f"{spacing[2]:.10g}",
            "0018|0088": f"{spacing[2]:.10g}",
            "0028|0030": f"{spacing[0]:.10g}\\{spacing[1]:.10g}",
            "0028|1052": "0", "0028|1053": "1",
            "0008|0070": "OpenDicomViewer evaluation",
        }
        for key, value in tags.items():
            plane.SetMetaData(key, value)
        writer.SetFileName(str(out / f"slice_{index:04d}.dcm"))
        writer.Execute(plane)
    print(json.dumps({"slices": image.GetSize()[2]}))
    return 0


def load_reference_masks(case_dir: Path, reference) -> dict[str, np.ndarray]:
    """Expert masks, resampled onto the DICOM grid the two paths were given."""
    masks: dict[str, np.ndarray] = {}
    for path in sorted((case_dir / "segmentations").glob("*.nii.gz")):
        name = path.name[: -len(".nii.gz")]
        array = resample_to_source(path, reference)
        if array.any():
            masks[name] = array
    return masks


def score(reference: dict[str, np.ndarray], predicted: dict[str, np.ndarray],
          voxel_ml: float) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Dice per structure against the expert masks, over structures the expert labelled.

    Restricted to structures present in the reference: a structure the expert
    did not label is outside the field of view or outside the release's label
    set, and scoring it would measure the reference's coverage rather than the
    pipeline's behaviour.
    """
    rows: list[dict[str, Any]] = []
    for name, truth in reference.items():
        got = predicted.get(name)
        if got is None:
            got = np.zeros_like(truth)
        rows.append({
            "structure": name,
            "dice": round(dice(truth, got), 6),
            "reference_voxels": int(truth.sum()),
            "predicted_voxels": int(got.sum()),
            "volume_delta_ml": round((int(got.sum()) - int(truth.sum())) * voxel_ml, 3),
            "large": name in LARGE_STRUCTURES,
        })
    if not rows:
        return rows, {"structures": 0}
    values = np.array([r["dice"] for r in rows])
    large = np.array([r["dice"] for r in rows if r["large"]])
    summary = {
        "structures": len(rows),
        "dice_mean": round(float(values.mean()), 4),
        "dice_median": round(float(np.median(values)), 4),
        "dice_large_mean": round(float(large.mean()), 4) if large.size else None,
        "large_structures": int(large.size),
        "in_plausible_band": bool(PLAUSIBLE_BAND[0] <= float(values.mean())
                                  <= PLAUSIBLE_BAND[1]),
        "worst": sorted(rows, key=lambda r: r["dice"])[:5],
    }
    return rows, summary


def run_case(case_dir: Path, scratch: Path, shim_dir: Path, python: str,
             fast: bool, sandbox: bool, keep: bool) -> CaseResult:
    case_id = case_dir.name
    timer = StageTimer()
    env = child_env(shim_dir, scratch, sandbox)
    work = scratch / case_id
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    notes = [CPU_ONLY_NOTE,
             "hygiene check only -- not a claim about TotalSegmentator accuracy",
             "reference CT converted NIfTI -> DICOM; both paths read the same series"]
    if sandbox:
        notes.append(SANDBOX_NOTE)
    # No pixel-measures note here: worker_nifti_to_dicom writes SliceThickness,
    # so the tag is present and neither the adapter's derivation nor the
    # evaluation's old fallback is exercised on this path. Recording a patch
    # that never engaged would misattribute the result.
    started = time.perf_counter()
    peaks: dict[str, float] = {}

    def child(argv: list[str], stage: str, timeout: float = 7200.0) -> str:
        with timer.stage(stage):
            code, output, peak = run_subprocess(
                [python, str(Path(__file__).resolve())] + argv,
                cwd=REPO_ROOT, env=env, timeout=timeout)
        peaks[stage] = peak
        if code != 0:
            tail = "\n".join(output.strip().splitlines()[-12:])
            raise RuntimeError(f"stage {stage} exited {code}:\n{tail}")
        return output

    try:
        series_dir = work / "dicom"
        child(["--worker", "nifti-to-dicom", "--input", str(case_dir / "ct.nii.gz"),
               "--output", str(series_dir), "--case-id", case_id], "nifti_to_dicom")

        with timer.stage("geometry"):
            reference_image, uid_to_index, shape = source_geometry(series_dir)
            spacing = reference_image.GetSpacing()
            voxel_ml = float(np.prod(spacing)) / 1000.0

        with timer.stage("load_reference"):
            expert = load_reference_masks(case_dir, reference_image)

        # --- path B: native --------------------------------------------------
        native_dir = work / "native"
        child(["--worker", "native-from-series", "--series", str(series_dir),
               "--output", str(native_dir)] + (["--fast"] if fast else []),
              "native_inference")
        with timer.stage("resample_native"):
            native = {name: resample_to_source(path, reference_image)
                      for name, path in load_native_masks(native_dir).items()}
            native = {k: v for k, v in native.items() if v.any()}

        # --- path A: plugin, spawned as the host spawns it ---------------------
        plugin_dir = work / "plugin"
        plugin_dir.mkdir(parents=True, exist_ok=True)
        with timer.stage("plugin_adapter"):
            code, output, peak = run_subprocess(
                [python, str(ADAPTER), "--task", "total", "--out", str(plugin_dir),
                 "--input-series3d", str(series_dir),
                 "--opt-fast", "true" if fast else "false"],
                cwd=REPO_ROOT, env=env, timeout=7200.0)
        peaks["plugin_adapter"] = peak
        result_path = plugin_dir / "result.json"
        adapter_result = (json.loads(result_path.read_text())
                          if result_path.exists() else None)
        if code != 0 or not adapter_result or not adapter_result.get("ok"):
            detail = (adapter_result or {}).get("error", {})
            raise RuntimeError(f"plugin adapter exited {code}: "
                               f"{detail.get('code')}: {detail.get('message')}")
        with timer.stage("seg_decode_plugin"):
            plugin = decode_seg_like_host(
                plugin_dir / adapter_result["outputs"]["seg3d"], uid_to_index, shape)
        unplaced = int(plugin.pop("__unplaced_frames__", 0))

        with timer.stage("score"):
            native_rows, native_summary = score(expert, native, voxel_ml)
            plugin_rows, plugin_summary = score(expert, plugin, voxel_ml)
            # The fidelity claim, re-checked on this different input: whatever
            # the accuracy is, the two paths should still agree exactly.
            shared = sorted(set(native) | set(plugin))
            agreement = [
                {"structure": name,
                 "dice": round(dice(native.get(name, np.zeros(shape, dtype=bool)),
                                    plugin.get(name, np.zeros(shape, dtype=bool))), 6)}
                for name in shared]

        metrics: dict[str, Any] = {
            "case_dir": str(case_dir),
            "grid": list(shape),
            "voxel_ml": round(voxel_ml, 8),
            "fast": fast,
            "reference_structures": len(expert),
            "native_structures": len(native),
            "plugin_structures": len(plugin),
            "unplaced_frames_plugin": unplaced,
            "published_dice_full_res": PUBLISHED_DICE_FULL_RES,
            "plausible_band": list(PLAUSIBLE_BAND),
            "native_vs_reference": native_summary,
            "plugin_vs_reference": plugin_summary,
            "path_agreement_min_dice": (round(min(a["dice"] for a in agreement), 6)
                                        if agreement else None),
            "path_agreement_structures": len(agreement),
            "per_structure_native": native_rows,
            "per_structure_plugin": plugin_rows,
        }
        result = CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=True,
            wall_s=round(time.perf_counter() - started, 2),
            stages_s={k: round(v, 2) for k, v in timer.stages.items()},
            peak_rss_bytes=max(peaks.values()) if peaks else None,
            metrics=metrics, notes=notes)
    except Exception as exc:  # noqa: BLE001
        result = CaseResult(
            experiment=EXPERIMENT, case_id=case_id, ok=False,
            wall_s=round(time.perf_counter() - started, 2),
            stages_s={k: round(v, 2) for k, v in timer.stages.items()},
            peak_rss_bytes=max(peaks.values()) if peaks else None,
            metrics={"case_dir": str(case_dir)},
            error=f"{type(exc).__name__}: {exc}", notes=notes)
    finally:
        if not keep and work.exists():
            shutil.rmtree(work, ignore_errors=True)
    return result


def worker_native_from_series(args: argparse.Namespace) -> int:
    from totalsegmentator.python_api import totalsegmentator

    totalsegmentator(input=str(args.series), output=str(args.output),
                     task="total", fast=args.fast, ml=False, quiet=True)
    return 0


def write_csv(rows_path: Path, csv_path: Path) -> int:
    import csv


    _, rows = load_results(rows_path)
    fields = ["case_id", "path", "structure", "dice", "reference_voxels",
              "predicted_voxels", "volume_delta_ml", "large", "ok"]
    written = 0
    with open(csv_path, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            metrics = row.get("metrics") or {}
            for path_name, key in (("native", "per_structure_native"),
                                   ("plugin", "per_structure_plugin")):
                for entry in metrics.get(key) or []:
                    writer.writerow({"case_id": row["case_id"], "path": path_name,
                                     "ok": row["ok"], **entry})
                    written += 1
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--worker",
                        choices=["nifti-to-dicom", "native-from-series"],
                        help=argparse.SUPPRESS)
    parser.add_argument("--input", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--series", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--output", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--case-id", default="CASE", help=argparse.SUPPRESS)

    parser.add_argument("--ground-truth", type=Path,
                        default=REPO_ROOT / ".eval" / "data" / "ground_truth")
    parser.add_argument("--out", type=Path,
                        default=REPO_ROOT / "eval" / "results" / "exp2_hygiene.jsonl")
    parser.add_argument("--csv", type=Path, default=None)
    parser.add_argument("--scratch", type=Path,
                        default=REPO_ROOT / ".eval" / "scratch" / "exp2h")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--max-cases", type=int, default=4)
    parser.add_argument("--fast", dest="fast", action="store_true", default=True)
    parser.add_argument("--no-fast", dest="fast", action="store_false")
    parser.add_argument("--no-sandbox-substitution", dest="sandbox",
                        action="store_false", default=True)
    parser.add_argument("--keep-intermediates", action="store_true")
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args(argv)

    if args.worker:
        return {"nifti-to-dicom": worker_nifti_to_dicom,
                "native-from-series": worker_native_from_series}[args.worker](args)

    cases = [p for p in sorted(args.ground_truth.iterdir())
             if p.is_dir() and (p / "ct.nii.gz").exists()
             and (p / "segmentations").is_dir()]
    if not cases:
        parser.error(f"no reference cases under {args.ground_truth}")
    cases = cases[: args.max_cases]

    args.scratch.mkdir(parents=True, exist_ok=True)
    shim_dir = write_sitecustomize(args.scratch)
    recorder = Recorder(args.out, EXPERIMENT, target_python=args.python)
    done = recorder.done_case_ids() if args.resume else set()

    print(f"{EXPERIMENT}: {len(cases)} reference cases -> {args.out}", flush=True)
    print(f"  accelerator visible: {machine_profile()['gpu_visible']}", flush=True)
    print("  NOTE: hygiene check, not an accuracy claim", flush=True)
    # done_case_ids() deliberately reports only SUCCESSES, so --resume retries
    # a case that failed. That is the right default (a failure is often
    # transient), but it appends a second row for a case that fails again, and
    # a silently duplicated failure row is confusing to whoever reads the file
    # later. Announce the retry so the duplicate is explained at the point it
    # is created. The JSONL stays append-only -- it is the audit trail, and
    # both attempts belong in it; exp2_tables.py reports each case once.
    previously_failed = {row["case_id"] for row in
                         (load_results(args.out)[1] if args.out.exists() else [])
                         if not row.get("ok")} - done
    for case in cases:
        if case.name in done:
            print(f"  [skip] {case.name}", flush=True)
            continue
        if case.name in previously_failed:
            print(f"  [retry] {case.name} failed on an earlier run; "
                  "a second row will be appended", flush=True)
        recorder.write(run_case(case, args.scratch, shim_dir, args.python,
                                args.fast, args.sandbox, args.keep_intermediates))

    csv_path = args.csv or args.out.with_suffix(".csv")
    print(f"\nper-structure rows: {write_csv(args.out, csv_path)} -> {csv_path}",
          flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
