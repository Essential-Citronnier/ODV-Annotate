#!/usr/bin/env python3
"""Experiment 7: prompt-driven and VLM plugins on public CT.

Two questions, neither of them about model accuracy:

1. SAM 2 / SAM 3 (session plugins). Does a click placed inside a reference
   structure come back as a mask over that structure? A click sent through the
   protocol is a normalized coordinate; the adapter converts it against the
   encoded image's size, and the mask returns as run-length encoding over that
   grid. A transposed axis, an off-by-one scale or an inverted RLE phase would
   each put the mask somewhere else, so per-structure Dice against the
   reference is a coordinate-mapping check. A deliberately transposed click is
   sent for every structure as a negative control: the check is only
   meaningful if that control scores clearly lower.

2. Gemma 4 E4B (resident-server VLM). Does the protocol round trip complete on
   real CT, and do the returned boxes land on the body rather than on air?
   Reported descriptively.

Each server runs under a process-tree memory sampler (the exp3 instrument), so
this experiment also yields a measured peak for the plugins whose declarations
exp3 could not audit. It must not run while exp6 runs: both would perturb each
other.

Data: TotalSegmentator reference cases (Zenodo 10047292, CC BY 4.0) under
`.eval/data/ground_truth/<case>/{ct.nii.gz,segmentations/*.nii.gz}`.

Click placement: the plan called for the structure centroid, but the centroid
of a non-convex structure (colon, ribs, vessels) can fall outside it, which
would test placement rather than mapping. The click is therefore the interior
pixel farthest from the structure's boundary on the chosen slice; whether the
centroid would have fallen inside is recorded per row.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import secrets
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

from harness import CaseResult, Recorder, machine_profile
from exp3_resources import EvalPaths, load_manifest
from exp3_totalseg_lowmem import TreeSampler
from exp6_latency import (
    build_server,
    check_environment,
    engine_environment,
    host_tag,
    http_json,
    response_ok,
)

EXPERIMENT = "exp7_prompt_vlm"
SAM_ENGINES = ("sam2", "sam3")
VLM_ENGINE = "gemma-4-e4b"
WINDOW = (40.0, 400.0)          # soft-tissue window, centre / width (HU)
MIN_AREA_PX = 100               # structures smaller than this on their slice are skipped
GEMMA_SLICE_FRACTIONS = (0.35, 0.5, 0.65)
GEMMA_PROMPT = "CT"


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------


def read_volume(path: Path) -> np.ndarray:
    """Array in [z, y, x] order. Raises on files ITK cannot read."""
    import SimpleITK as sitk
    return sitk.GetArrayFromImage(sitk.ReadImage(str(path)))


def render_png(slice_hu: np.ndarray) -> bytes:
    from PIL import Image
    centre, width = WINDOW
    lo, hi = centre - width / 2, centre + width / 2
    scaled = np.clip((slice_hu.astype(np.float32) - lo) / (hi - lo), 0, 1)
    image = Image.fromarray((scaled * 255).round().astype(np.uint8), mode="L")
    buffer = io.BytesIO()
    image.convert("RGB").save(buffer, format="PNG")
    return buffer.getvalue()


def body_mask(slice_hu: np.ndarray) -> np.ndarray:
    """Largest connected component above -500 HU, holes filled."""
    from scipy import ndimage
    mask = slice_hu > -500
    labels, count = ndimage.label(mask)
    if count == 0:
        return mask
    sizes = ndimage.sum(mask, labels, range(1, count + 1))
    body = labels == (int(np.argmax(sizes)) + 1)
    return ndimage.binary_fill_holes(body)


def interior_click(mask2d: np.ndarray) -> tuple[int, int, bool]:
    """(x, y) of the pixel farthest from the boundary; whether centroid is inside."""
    from scipy import ndimage
    distance = ndimage.distance_transform_edt(mask2d)
    y, x = np.unravel_index(int(np.argmax(distance)), distance.shape)
    cy, cx = ndimage.center_of_mass(mask2d)
    centroid_inside = bool(mask2d[int(round(cy)), int(round(cx))])
    return int(x), int(y), centroid_inside


def structure_targets(case_dir: Path) -> tuple[np.ndarray, list[dict]]:
    """CT volume and one target per reference structure: slice, click, mask."""
    ct = read_volume(case_dir / "ct.nii.gz")
    targets = []
    for seg_path in sorted((case_dir / "segmentations").glob("*.nii.gz")):
        mask = read_volume(seg_path) > 0
        if mask.shape != ct.shape:
            continue
        zs = np.nonzero(mask.any(axis=(1, 2)))[0]
        if zs.size == 0:
            continue
        # Central slice by voxel mass, not by extent, so a structure that is
        # mostly at one end of its range is clicked where most of it is.
        z_mass = mask.sum(axis=(1, 2))
        z = int(round(float(np.average(np.arange(mask.shape[0]), weights=z_mass))))
        if not mask[z].any():
            z = int(zs[np.argmin(np.abs(zs - z))])
        m2 = mask[z]
        area = int(m2.sum())
        if area < MIN_AREA_PX:
            continue
        x, y, centroid_inside = interior_click(m2)
        name = seg_path.name.removesuffix(".nii.gz")
        targets.append({"structure": name, "z": z, "area_px": area,
                        "click": (x, y), "centroid_inside": centroid_inside,
                        "mask": m2})
    return ct, targets


# ---------------------------------------------------------------------------
# Protocol helpers
# ---------------------------------------------------------------------------


def decode_rle(payload: dict) -> np.ndarray:
    """Mirror of the host's Swift decoder: row-major, background run first."""
    width, height = int(payload["width"]), int(payload["height"])
    flat = np.zeros(width * height, dtype=bool)
    position, foreground = 0, False
    for run in payload["rle"]:
        if foreground:
            flat[position:position + run] = True
        position += run
        foreground = not foreground
    return flat.reshape(height, width)


def dice(a: np.ndarray, b: np.ndarray) -> float:
    total = int(a.sum()) + int(b.sum())
    return 1.0 if total == 0 else 2.0 * int((a & b).sum()) / total


def first_mask(body: dict | None) -> dict | None:
    outputs = (body or {}).get("outputs", body or {})
    mask = outputs.get("mask2d") if isinstance(outputs, dict) else None
    if isinstance(mask, list):
        mask = mask[0] if mask else None
    return mask if isinstance(mask, dict) else None


def click_body(session_id: str, x: int, y: int, width: int, height: int) -> dict:
    # The adapter converts with round(v * size), so v = pixel / size maps back
    # to exactly this pixel.
    return {"session_id": session_id,
            "inputs": {"points": [{"x": x / width, "y": y / height, "label": 1}]}}


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------


def start_measured(engine: str, repo: Path, paths: EvalPaths, manifest: dict,
                   workdir: Path, ready_timeout: float):
    server = build_server(engine, repo, paths, manifest, None, workdir, 0)
    server.start()
    sampler = TreeSampler(server.proc.pid).start()
    ready = server.wait_ready(ready_timeout)
    return server, sampler, ready


def memory_report(sampler: TreeSampler) -> dict[str, Any]:
    report = sampler.report()
    peak = report["tree_peak_footprint_bytes"]
    report["tree_peak_gb"] = round(peak / 1e9, 3)
    report["tree_peak_gib"] = round(peak / 2**30, 3)
    return report


def run_sam_case(engine: str, case: str, case_dir: Path, repo: Path,
                 paths: EvalPaths, manifest: dict, args, workdir: Path
                 ) -> CaseResult:
    started = time.perf_counter()
    metrics: dict[str, Any] = {"case": case, "env_check": args.env_check,
                               "structures": []}
    error = None
    try:
        ct, targets = structure_targets(case_dir)
    except Exception as exc:  # noqa: BLE001 -- unreadable reference is a recorded result
        return CaseResult(experiment=EXPERIMENT, case_id=f"{engine}/{case}",
                          ok=False, wall_s=round(time.perf_counter() - started, 3),
                          metrics=metrics, error=f"reference unreadable: "
                          f"{type(exc).__name__}: {exc}")
    server = sampler = None
    try:
        server, sampler, ready = start_measured(engine, repo, paths, manifest,
                                                workdir, args.ready_timeout)
        metrics["spawn_to_ready_s"] = ready["spawn_to_ready_s"]
        by_slice: dict[int, list[dict]] = {}
        for t in targets:
            by_slice.setdefault(t["z"], []).append(t)
        for z, group in sorted(by_slice.items()):
            b64 = base64.b64encode(render_png(ct[z])).decode("ascii")
            status, reply, open_ms = http_json(
                "POST", f"{server.base}/session/open", server.token,
                {"inputs": {"slice2d": b64}}, timeout=args.request_timeout)
            if not (status == 200 and reply and reply.get("ok")):
                for t in group:
                    metrics["structures"].append({
                        "structure": t["structure"], "z": z, "ok": False,
                        "error": f"session open failed: HTTP {status}"})
                continue
            session_id = reply["session_id"]
            height, width = ct[z].shape
            for t in group:
                x, y = t["click"]
                row: dict[str, Any] = {
                    "structure": t["structure"], "z": z, "area_px": t["area_px"],
                    "click": [x, y], "centroid_inside": t["centroid_inside"]}
                status, out, ms = http_json(
                    "POST", f"{server.base}/task/prompt-mask", server.token,
                    click_body(session_id, x, y, width, height),
                    timeout=args.request_timeout)
                payload = first_mask(out)
                row["ok"] = response_ok(status, out, engine) and payload is not None
                row["client_ms"] = round(ms, 1)
                if row["ok"]:
                    predicted = decode_rle(payload)
                    row["grid_matches"] = predicted.shape == t["mask"].shape
                    row["dice"] = (round(dice(predicted, t["mask"]), 4)
                                   if row["grid_matches"] else None)
                    row["predicted_px"] = int(predicted.sum())
                else:
                    row["error"] = (out or {}).get("error") or f"HTTP {status}"
                # Negative control: the same click with x and y swapped, as a
                # transposed mapping would send it.
                if x != y and 0 <= y < width and 0 <= x < height:
                    status, out, _ = http_json(
                        "POST", f"{server.base}/task/prompt-mask", server.token,
                        click_body(session_id, y, x, width, height),
                        timeout=args.request_timeout)
                    control = first_mask(out)
                    if response_ok(status, out, engine) and control is not None:
                        row["control_transposed_dice"] = round(
                            dice(decode_rle(control), t["mask"]), 4)
                metrics["structures"].append(row)
            http_json("POST", f"{server.base}/session/close", server.token,
                      {"session_id": session_id})
        failed = [s for s in metrics["structures"] if not s.get("ok")]
        if failed:
            error = f"{len(failed)} structure(s) failed; first: {failed[0]}"
    except Exception as exc:  # noqa: BLE001 -- a failed case is a recorded result
        error = f"{type(exc).__name__}: {exc}"
    finally:
        if sampler is not None:
            sampler.stop()
            metrics["memory"] = memory_report(sampler)
        if server is not None:
            server.stop()
    return CaseResult(experiment=EXPERIMENT, case_id=f"{engine}/{case}",
                      ok=error is None, wall_s=round(time.perf_counter() - started, 3),
                      metrics=metrics, error=error,
                      notes=["coordinate-mapping check, not an accuracy measure; "
                             "one positive click per structure, single-mask output"])


def box_on_body(box: dict, body: np.ndarray) -> bool:
    height, width = body.shape
    cx = int(min(width - 1, max(0, (box["x"] + box["width"] / 2) * width)))
    cy = int(min(height - 1, max(0, (box["y"] + box["height"] / 2) * height)))
    return bool(body[cy, cx])


def run_gemma_case(case: str, case_dir: Path, repo: Path, paths: EvalPaths,
                   manifest: dict, args, workdir: Path) -> CaseResult:
    started = time.perf_counter()
    metrics: dict[str, Any] = {"case": case, "env_check": args.env_check,
                               "requests": []}
    error = None
    try:
        ct = read_volume(case_dir / "ct.nii.gz")
    except Exception as exc:  # noqa: BLE001
        return CaseResult(experiment=EXPERIMENT, case_id=f"{VLM_ENGINE}/{case}",
                          ok=False, wall_s=round(time.perf_counter() - started, 3),
                          metrics=metrics, error=f"reference unreadable: "
                          f"{type(exc).__name__}: {exc}")
    server = sampler = None
    try:
        server, sampler, ready = start_measured(VLM_ENGINE, repo, paths, manifest,
                                                workdir, args.ready_timeout)
        metrics["spawn_to_ready_s"] = ready["spawn_to_ready_s"]
        for fraction in GEMMA_SLICE_FRACTIONS:
            z = int(round(fraction * (ct.shape[0] - 1)))
            b64 = base64.b64encode(render_png(ct[z])).decode("ascii")
            body = body_mask(ct[z])
            for task in ("detect-abnormalities", "analyze"):
                status, out, ms = http_json(
                    "POST", f"{server.base}/task/{task}", server.token,
                    {"inputs": {"slice2d": b64, "text": GEMMA_PROMPT}},
                    timeout=args.request_timeout)
                outputs = (out or {}).get("outputs", {}) or {}
                boxes = [b for b in outputs.get("bbox", []) if isinstance(b, dict)]
                inside_image = [0 <= b["x"] and 0 <= b["y"]
                                and b["x"] + b["width"] <= 1.0 + 1e-9
                                and b["y"] + b["height"] <= 1.0 + 1e-9
                                for b in boxes]
                metrics["requests"].append({
                    "task": task, "z": z, "client_ms": round(ms, 1),
                    "ok": response_ok(status, out, VLM_ENGINE),
                    "http_status": status,
                    "text_chars": len(outputs.get("text") or ""),
                    "boxes": len(boxes),
                    "boxes_inside_image": int(sum(inside_image)),
                    "box_centres_on_body": int(sum(box_on_body(b, body)
                                                   for b in boxes)),
                    "body_fraction_of_image": round(float(body.mean()), 3)})
        failed = [r for r in metrics["requests"] if not r["ok"]]
        if failed:
            error = f"{len(failed)} request(s) failed; first: {failed[0]}"
    except Exception as exc:  # noqa: BLE001
        error = f"{type(exc).__name__}: {exc}"
    finally:
        if sampler is not None:
            sampler.stop()
            metrics["memory"] = memory_report(sampler)
        if server is not None:
            server.stop()
    return CaseResult(experiment=EXPERIMENT, case_id=f"{VLM_ENGINE}/{case}",
                      ok=error is None, wall_s=round(time.perf_counter() - started, 3),
                      metrics=metrics, error=error,
                      notes=["descriptive: protocol round trip and box placement "
                             "on the body; no claim about finding correctness"])


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------


def _q(values: list[float]) -> dict[str, Any]:
    if not values:
        return {"n": 0}
    values = sorted(values)
    q = statistics.quantiles(values, n=4) if len(values) > 1 else [values[0]] * 3
    return {"n": len(values), "median": round(statistics.median(values), 4),
            "q1": round(q[0], 4), "q3": round(q[2], 4),
            "min": round(values[0], 4), "max": round(values[-1], 4)}


def control_inside(rows: list[dict], data: Path) -> dict[tuple[str, str], bool]:
    """Whether each transposed control click itself lands inside the structure.

    A transposed click that still lands inside its structure (a midline
    vertebra, the liver) is not a negative control, so the control is
    summarised only where it lands outside. Recomputed from the references;
    no model is involved.
    """
    out: dict[tuple[str, str], bool] = {}
    for case in sorted({r["metrics"].get("case") for r in rows
                        if r["case_id"].split("/")[0] in SAM_ENGINES and r["ok"]}):
        _, targets = structure_targets(data / case)
        for t in targets:
            x, y = t["click"]
            h, w = t["mask"].shape
            out[(case, t["structure"])] = bool(0 <= y < w and 0 <= x < h
                                               and t["mask"][x, y])
    return out


def summarise(results: Path, data: Path | None = None) -> dict[str, Any]:
    rows = [json.loads(line) for line in results.read_text().splitlines()[1:]
            if line.strip()]
    inside = control_inside(rows, data) if data is not None else {}
    summary: dict[str, Any] = {}
    for engine in SAM_ENGINES:
        cases = [r for r in rows if r["case_id"].startswith(engine + "/")]
        if not cases:
            continue
        structures = [dict(s, case=r["metrics"].get("case"))
                      for r in cases for s in r["metrics"].get("structures", [])]
        scored = [s for s in structures if s.get("dice") is not None]
        dices = [s["dice"] for s in scored]
        controls = [s["control_transposed_dice"] for s in scored
                    if "control_transposed_dice" in s]
        large = [s["dice"] for s in scored if s["area_px"] >= 1000]
        summary[engine] = {
            "cases_ok": sum(r["ok"] for r in cases), "cases": len(cases),
            "unreadable_cases": [r["metrics"].get("case") for r in cases
                                 if (r.get("error") or "").startswith("reference unreadable")],
            "structures_attempted": len(structures),
            "structures_scored": len(scored),
            "grid_mismatches": sum(1 for s in structures if s.get("grid_matches") is False),
            "dice": _q(dices),
            "dice_area_ge_1000px": _q(large),
            "dice_ge_0_5": sum(d >= 0.5 for d in dices),
            "control_transposed_dice": _q(controls),
            "control_click_inside_structure": sum(
                1 for s in scored if inside.get((s["case"], s["structure"]))),
            "control_transposed_dice_click_outside": _q([
                s["control_transposed_dice"] for s in scored
                if "control_transposed_dice" in s and (s["case"], s["structure"]) in inside
                and not inside[(s["case"], s["structure"])]]),
            "centroid_outside_structure": sum(1 for s in scored
                                              if not s["centroid_inside"]),
            "prompt_client_ms": _q([s["client_ms"] for s in scored]),
            "peak_memory_gib": max((r["metrics"].get("memory", {})
                                    .get("tree_peak_gib", 0) for r in cases), default=None),
        }
    gemma = [r for r in rows if r["case_id"].startswith(VLM_ENGINE + "/")]
    if gemma:
        requests = [q for r in gemma for q in r["metrics"].get("requests", [])]
        boxes = sum(q["boxes"] for q in requests)
        summary[VLM_ENGINE] = {
            "cases_ok": sum(r["ok"] for r in gemma), "cases": len(gemma),
            "requests": len(requests),
            "requests_ok": sum(q["ok"] for q in requests),
            "boxes": boxes,
            "boxes_inside_image": sum(q["boxes_inside_image"] for q in requests),
            "box_centres_on_body": sum(q["box_centres_on_body"] for q in requests),
            "request_client_ms": _q([q["client_ms"] for q in requests if q["ok"]]),
            "spawn_to_ready_s": _q([r["metrics"]["spawn_to_ready_s"] for r in gemma
                                    if "spawn_to_ready_s" in r["metrics"]]),
            "peak_memory_gib": max((r["metrics"].get("memory", {})
                                    .get("tree_peak_gib", 0) for r in gemma), default=None),
        }
    out = results.with_name(results.stem + "_summary.json")
    out.write_text(json.dumps(summary, indent=2) + "\n")
    return summary


# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    repo_default = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=repo_default)
    parser.add_argument("--env-root", type=Path, default=None)
    parser.add_argument("--data", type=Path, default=None,
                        help="Reference cases (default: <repo>/.eval/data/ground_truth)")
    parser.add_argument("--cases", default="",
                        help="Comma-separated case ids (default: all)")
    parser.add_argument("--engines", default=",".join(SAM_ENGINES + (VLM_ENGINE,)))
    parser.add_argument("--ready-timeout", type=float, default=900.0)
    parser.add_argument("--request-timeout", type=float, default=600.0)
    parser.add_argument("--allow-env-drift", action="store_true")
    parser.add_argument("--results", type=Path, default=None)
    parser.add_argument("--summary-only", action="store_true")
    args = parser.parse_args(argv)

    repo = args.repo.resolve()
    profile = machine_profile()
    results = args.results or (repo / "eval/results"
                               / f"{EXPERIMENT}_{host_tag(profile)}.jsonl")
    if args.summary_only:
        data = (args.data or repo / ".eval/data/ground_truth").resolve()
        print(json.dumps(summarise(results, data), indent=2))
        return 0

    data = (args.data or repo / ".eval/data/ground_truth").resolve()
    cases = sorted(p.name for p in data.iterdir() if (p / "ct.nii.gz").is_file())
    if args.cases:
        wanted = set(args.cases.split(","))
        cases = [c for c in cases if c in wanted]
    engines = [e for e in args.engines.split(",") if e]

    manifest = load_manifest(repo)
    paths = EvalPaths((args.env_root or repo / ".eval/plugin-envs").resolve())
    workdir = repo / ".eval/exp7"
    workdir.mkdir(parents=True, exist_ok=True)
    subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())])

    recorder = Recorder(results, EXPERIMENT)
    done = recorder.done_case_ids()
    print(f"results: {results}", flush=True)

    for engine in engines:
        python, lock = engine_environment(engine, repo, paths, manifest, None)
        env_check = (check_environment(python, lock) if python is not None
                     else {"ok": False, "error": "no interpreter"})
        if not env_check["ok"] and not args.allow_env_drift:
            print(f"  [skip] {engine}: environment does not match {lock.name}",
                  flush=True)
            continue
        args.env_check = env_check
        for case in cases:
            case_id = f"{engine}/{case}"
            if case_id in done:
                continue
            print(f"{case_id} ...", flush=True)
            if engine == VLM_ENGINE:
                result = run_gemma_case(case, data / case, repo, paths, manifest,
                                        args, workdir)
            else:
                result = run_sam_case(engine, case, data / case, repo, paths,
                                      manifest, args, workdir)
            recorder.write(result)
            print(f"  ok={result.ok} {result.error or ''}"[:300], flush=True)

    print(json.dumps(summarise(results, data), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
