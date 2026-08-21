#!/usr/bin/env python3
# exp2_tables.py
# OpenDicomViewer -- plugin layer evaluation, Experiment 2 tables.
#
# Two tables for the paper, generated from the recorded JSONL rather than
# transcribed, so a rerun of the experiment updates them and a number in the
# manuscript can always be traced to a row on disk.
"""Emit the pipeline-fidelity summary tables as CSV and markdown."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

import numpy as np

from harness import load_results  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent


def fidelity_table(path: Path) -> list[dict]:
    """One row per cohort case: the three comparisons, side by side.

    Failed cases are carried into the table as rows with their error rather
    than dropped, so the table's case count matches the cohort's.
    """
    _, rows = load_results(path)
    table = []
    for row in _latest_per_case(rows):
        metrics = row.get("metrics") or {}
        entry = {
            "case_id": row["case_id"],
            "ok": row["ok"],
            "slices": metrics.get("slices"),
            "structures": metrics.get("native_structures_nonempty"),
            "wall_s": row.get("wall_s"),
            "peak_rss_gb": (round(row["peak_rss_bytes"] / 1e9, 1)
                            if row.get("peak_rss_bytes") else None),
        }
        for name, key in (("determinism", "determinism"),
                          ("roundtrip", "roundtrip"),
                          ("end_to_end", "end_to_end")):
            summary = metrics.get(key) or {}
            entry[f"{name}_dice_min"] = summary.get("dice_min")
            entry[f"{name}_below_0999"] = summary.get("below_0999")
        entry["unplaced_frames"] = metrics.get("unplaced_frames_plugin")
        entry["seg_bytes"] = metrics.get("plugin_seg_bytes")
        lines = (row.get("error") or "").splitlines()
        entry["error"] = lines[-1][:120] if lines else None
        table.append(entry)
    return table


def _latest_per_case(rows: list[dict]) -> list[dict]:
    """Keep one row per case, the last recorded.

    A resumed run re-attempts cases that failed (done_case_ids() only skips
    successes), so a case that fails twice appears twice in the JSONL. The
    append-only file is the audit trail and keeps both attempts; the summary
    table reports each case once. A failure that was never overcome still
    appears -- as a failure.
    """
    latest: dict[str, dict] = {}
    for row in rows:
        latest[row["case_id"]] = row
    return list(latest.values())


def _last_line(text: str | None) -> str | None:
    lines = (text or "").splitlines()
    return lines[-1][:120] if lines else None


def hygiene_table(path: Path) -> list[dict]:
    _, rows = load_results(path)
    table = []
    for row in _latest_per_case(rows):
        metrics = row.get("metrics") or {}
        native = metrics.get("native_vs_reference") or {}
        plugin = metrics.get("plugin_vs_reference") or {}
        table.append({
            "case_id": row["case_id"],
            "ok": row["ok"],
            "reference_structures": metrics.get("reference_structures"),
            "native_dice_mean": native.get("dice_mean"),
            "plugin_dice_mean": plugin.get("dice_mean"),
            "native_dice_large_mean": native.get("dice_large_mean"),
            "plugin_dice_large_mean": plugin.get("dice_large_mean"),
            "path_agreement_min_dice": metrics.get("path_agreement_min_dice"),
            "error": _last_line(row.get("error")),
        })
    return table


def write(table: list[dict], csv_path: Path) -> None:
    if not table:
        return
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with open(csv_path, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(table[0]))
        writer.writeheader()
        writer.writerows(table)
    print(f"  {csv_path.name}: {len(table)} rows", flush=True)


def markdown(table: list[dict], columns: list[tuple[str, str]]) -> str:
    head = "| " + " | ".join(label for label, _ in columns) + " |"
    rule = "|" + "|".join("---" for _ in columns) + "|"
    lines = [head, rule]
    for row in table:
        cells = []
        for _, key in columns:
            value = row.get(key)
            cells.append("—" if value is None else str(value))
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    results = REPO_ROOT / "eval" / "results"
    parser.add_argument("--fidelity", type=Path,
                        default=results / "exp2_fidelity.jsonl")
    parser.add_argument("--hygiene", type=Path,
                        default=results / "exp2_hygiene.jsonl")
    parser.add_argument("--out-dir", type=Path, default=results)
    args = parser.parse_args(argv)

    summary_md: list[str] = []

    if args.fidelity.exists():
        table = fidelity_table(args.fidelity)
        write(table, args.out_dir / "exp2_fidelity_summary.csv")
        summary_md.append("### Table 1 — Pipeline fidelity, per cohort case\n")
        summary_md.append(markdown(table, [
            ("Case", "case_id"), ("Slices", "slices"),
            ("Structures", "structures"),
            ("Model determinism (min Dice)", "determinism_dice_min"),
            ("SEG round trip (min Dice)", "roundtrip_dice_min"),
            ("End to end (min Dice)", "end_to_end_dice_min"),
            ("Unplaced frames", "unplaced_frames"),
            ("Wall s (CPU-only)", "wall_s"),
        ]))
        ok = [r for r in table if r["ok"]]
        if ok:
            worst = min(r["end_to_end_dice_min"] for r in ok
                        if r["end_to_end_dice_min"] is not None)
            summary_md.append(
                f"\n{len(ok)} of {len(table)} cases succeeded; the lowest "
                f"per-structure Dice anywhere in the end-to-end comparison is "
                f"{worst}.\n")

    if args.hygiene.exists():
        table = hygiene_table(args.hygiene)
        write(table, args.out_dir / "exp2_hygiene_summary.csv")
        summary_md.append("\n### Table 2 — Hygiene check against expert reference masks\n")
        summary_md.append(
            "Not an accuracy claim. Evidence that neither path silently broke "
            "the model.\n")
        summary_md.append(markdown(table, [
            ("Case", "case_id"),
            ("Reference structures", "reference_structures"),
            ("Native mean Dice", "native_dice_mean"),
            ("Plugin mean Dice", "plugin_dice_mean"),
            ("Native, large structures", "native_dice_large_mean"),
            ("Plugin, large structures", "plugin_dice_large_mean"),
            ("Path agreement (min Dice)", "path_agreement_min_dice"),
        ]))

    path = args.out_dir / "exp2_tables.md"
    path.write_text("\n".join(summary_md) + "\n")
    print(f"  {path.name}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
