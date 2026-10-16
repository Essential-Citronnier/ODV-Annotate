#!/usr/bin/env python3
# exp3_figures.py
# OpenDicomViewer
#
# Figures for experiment 3, drawn from eval/results/exp3_resources.jsonl.
#
# Two figures, matching the two questions the experiment asks:
#
#   exp3_stage_timing.png        where a plugin's wall time goes, per stage
#   exp3_memory.png              declared ram_gb against measured peak, and
#                                the arbiter's decisions; also written as
#                                fig_declared_vs_measured.png (the paper's
#                                headline figure, copied to docs/figures/)
#
# The October 2026 process-tree points come from
# eval/results/exp3_totalseg_lowmem.jsonl (--tree-results).
#
# Kept separate from the measurement script so that redrawing never risks
# re-running an install, and so a figure can be regenerated from a results file
# produced on another machine.
# Licensed under the MIT License. See LICENSE for details.
"""Figures for the resource characterisation and arbitration experiment."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import matplotlib
import matplotlib.pyplot as plt
import numpy as np

from harness import load_results

matplotlib.use("Agg")

# One colour per stage, threaded across both figures. Ordered as a run
# experiences them, so the legend reads like a timeline.
STAGE_ORDER = [
    ("venv_create", "venv creation", "#8ecae6"),
    ("pip_requirements", "pip install", "#219ebc"),
    ("weights", "weight download", "#126782"),
    ("import", "interpreter import", "#ffd166"),
    ("model_load", "model load", "#fb8500"),
    ("encode", "encode", "#c1121f"),
    ("decode", "decode", "#6a040f"),
    ("inference", "inference", "#e5383b"),
    # A one-shot adapter names its stages in prose through the progress
    # reporter rather than with the short keys the server adapters use, and
    # those names are the boundaries the adapter itself defines. They are
    # listed verbatim so the measurement stays attributable to the adapter's
    # own structure. Each gets its own hue: two stages sharing a colour would
    # be indistinguishable in a stack, which is how a reader tells them apart.
    ("Checking model environment", "environment check", "#a1c181"),
    ("Running segmentation", "segmentation", "#7b2cbf"),
    ("Measuring structures", "volume measurement", "#3a0ca3"),
    ("Writing DICOM SEG", "DICOM SEG export", "#4361ee"),
]

# TotalSegmentator's declaration history, for the reader of the headline
# figure: 3.5 (shipped), 23.5 (commit de234fe, from the August single-process
# measurement), 25.5 for `total` and 24.0 for the new `total_lowmem` (October
# 2026, process-tree measurement in exp3_totalseg_lowmem.py). Each point is
# plotted against the declaration in force when it was measured.

PLUGIN_LABELS = {
    "gemma-4-e4b": "Gemma 4 E4B",
    "sam2": "SAM 2",
    "sam3": "SAM 3",
    "totalsegmentator": "TotalSegmentator",
}

EXECUTION_LABELS = {
    "resident-server": "resident-server",
    "session": "session",
    "one-shot": "one-shot",
}


def collect(results_path: Path) -> tuple[dict, dict]:
    """Fold the JSONL into per-plugin stage times and memory figures."""
    header, rows = load_results(results_path)
    per_plugin: dict[str, dict] = {}

    for row in rows:
        parts = row["case_id"].split("/")
        if len(parts) < 2:
            continue
        phase, plugin_id = parts[0], parts[1]
        entry = per_plugin.setdefault(plugin_id, {"stages": {}, "notes": set()})
        metrics = row.get("metrics", {})
        entry["notes"].update(row.get("notes", []))

        if phase == "install" and row["ok"]:
            for name, value in row.get("stages_s", {}).items():
                if name in ("venv_create", "pip_requirements"):
                    entry["stages"][name] = value
            entry["venv_gb"] = metrics.get("venv_gb")
        elif phase == "weights":
            entry["stages"]["weights"] = (
                entry["stages"].get("weights", 0.0) + row["wall_s"])
            entry["weight_gb"] = (entry.get("weight_gb", 0.0)
                                  + (metrics.get("downloaded_gb") or 0.0))
            if not row["ok"]:
                entry.setdefault("weight_errors", []).append(row.get("error"))
        elif phase == "bench":
            entry["bench_ok"] = row["ok"]
            entry["bench_error"] = row.get("error")
            # Whether the model was actually resident, which decides if the
            # peak RSS measures the plugin or a Python interpreter that exited
            # early.
            #
            # A recorded `model_load` stage is NOT sufficient evidence. Since
            # the bench mode began attaching partial timings to failures, a
            # load that raised part-way still reports the stage it died in --
            # so SAM 3 hitting its licence gate and Gemma finding no Metal
            # device both carry a `model_load` entry while never having held a
            # model. What distinguishes them is a stage that can only be
            # reached *after* weights are resident.
            stages = row.get("stages_s", {})
            entry["model_ran"] = any(
                key in stages
                for key in ("encode", "inference", "Running segmentation"))
            if not row["ok"]:
                # A bench that could not run is a stated result, not a blank.
                # The protocol error code is what distinguishes "the licence
                # gate held" from "this machine cannot run it".
                code = (row.get("error") or "").split(":", 1)[0].strip()
                entry["unmeasured_reason"] = {
                    "license_required": "not run: weights behind a licence gate",
                    "not_ready": "not run: no Metal device in this environment",
                }.get(code, f"not run: {code or 'unknown'}")
                if entry["model_ran"]:
                    entry["unmeasured_reason"] = (
                        "partial: model ran, a later stage failed")
            entry["declared_ram_gb"] = metrics.get("declared_ram_gb")
            entry["peak_rss_gb"] = metrics.get("peak_rss_gb")
            entry["device"] = metrics.get("device")
            for name, value in row.get("stages_s", {}).items():
                entry["stages"][name] = value
            for key in ("encode_ms_mean", "decode_ms_mean", "encode_decode_ratio",
                        "inference_ms_mean", "structure_count"):
                if key in metrics:
                    entry[key] = metrics[key]

    arbitration = {}
    for row in rows:
        if row["case_id"].startswith("arbitration/") and row["case_id"] != "arbitration/build":
            arbitration[row["case_id"].split("arbitration/", 1)[1]] = row.get("metrics", {})

    return header, per_plugin, rows, arbitration


def figure_stage_timing(header: dict, per_plugin: dict, out_path: Path,
                        order: list[str]) -> None:
    """Stacked stage times per plugin, install-time and run-time separated.

    Two panels rather than one stack: install is a once-per-plugin cost in the
    hundreds of seconds and run-time is a per-use cost in single seconds, and
    stacking them on one axis would render every run-time stage invisible.
    """
    install_stages = [(k, label, colour) for k, label, colour in STAGE_ORDER
                      if k in ("venv_create", "pip_requirements", "weights")]
    run_stages = [(k, label, colour) for k, label, colour in STAGE_ORDER
                  if k not in ("venv_create", "pip_requirements", "weights")]

    present = [p for p in order if p in per_plugin]
    labels = [PLUGIN_LABELS.get(p, p) for p in present]
    y = np.arange(len(present))

    fig, axes = plt.subplots(1, 2, figsize=(9.8, 0.62 * len(present) + 2.4))
    ax_install, ax_run = axes

    for ax, stages, title in (
            (ax_install, install_stages,
             "One-time install cost, paid once per plugin"),
            (ax_run, run_stages,
             "Per-use cost, paid on every invocation")):
        left = np.zeros(len(present))
        drawn = []
        for key, label, colour in stages:
            # A plugin whose model never became resident contributes nothing to
            # the per-use panel. Its recorded `model_load` is the stage a
            # failure died in, not a cost anyone pays, and drawing it as a bar
            # would present a licence refusal and an absent GPU as though they
            # were fast inference.
            values = np.array([
                (per_plugin[p]["stages"].get(key, 0.0) or 0.0)
                if (title.startswith("One-time") or per_plugin[p].get("model_ran"))
                else 0.0
                for p in present])
            if not values.any():
                continue
            ax.barh(y, values, left=left, color=colour, label=label,
                    height=0.62, edgecolor="white", linewidth=0.6)
            left += values
            drawn.append(label)
        ax.set_yticks(y)
        ax.set_yticklabels(labels)
        ax.invert_yaxis()
        ax.set_xlabel("seconds")
        ax.set_title(title, loc="left", fontsize=9)
        ax.margins(x=0.04)
        ax.spines[["top", "right"]].set_visible(False)
        if drawn:
            # Placed outside the axes: the per-use panel spans an order of
            # magnitude between plugins, so any in-axes corner is occupied by
            # some plugin's bar at some point.
            ax.legend(frameon=False, fontsize=7, loc="upper center",
                      bbox_to_anchor=(0.5, -0.22), ncol=3,
                      handlelength=1.2, columnspacing=1.0)

        # The total is the number a reader would quote, so it is the only
        # value printed on the mark. A row with no bar is annotated with why:
        # an empty slot would otherwise read as a measurement of zero.
        for index, total in enumerate(left):
            if total > 0:
                ax.text(total, y[index], f" {total:.0f}s" if total >= 10
                        else f" {total:.1f}s",
                        va="center", ha="left", fontsize=7)
            else:
                reason = per_plugin[present[index]].get("unmeasured_reason",
                                                        "not measured")
                ax.text(ax.get_xlim()[0], y[index], f"  {reason}",
                        va="center", ha="left", fontsize=7,
                        color="#8a4b00", style="italic")

    ax_run.set_yticklabels([])

    gpu = header.get("machine", {}).get("gpu_visible", {})
    chip = header.get("machine", {}).get("chip", header.get("machine", {}).get("machine"))
    fig.suptitle("Where a plugin's time goes", x=0.008, ha="left", fontsize=11)
    fig.text(0.008, 0.005,
             f"{chip}, CPU only (torch MPS available: {gpu.get('torch_mps')}). "
             "Install and download times are unaffected by accelerator "
             "visibility; model-load and inference times are CPU-only figures "
             "and are not laptop performance.",
             fontsize=6.5, ha="left", va="bottom", wrap=True)
    fig.tight_layout(rect=(0, 0.13, 1, 0.95))
    fig.savefig(out_path, dpi=300)
    plt.close(fig)


def _crosscheck_rows(rows: list[dict]) -> list[dict]:
    """The cross-check measurements, one per (task variant, series)."""
    out = []
    for row in rows:
        if not row["case_id"].startswith("crosscheck/"):
            continue
        # A run that never reached inference still reports a peak -- the
        # interpreter started and the weight fetch failed -- and admitting it
        # here would put a point on the chart that measures a download error
        # rather than a segmentation, dragging the stated overrun range with it.
        if not row["ok"]:
            continue
        metrics = row.get("metrics", {})
        readings = [metrics.get("parent_measured_peak_gb"),
                    metrics.get("getrusage_self_gb"),
                    metrics.get("sampled_self_gb")]
        present = [value for value in readings if value]
        if not present:
            continue
        out.append({
            "series": metrics.get("input_series", "?"),
            "variant": metrics.get("variant", "?"),
            "fast": metrics.get("fast"),
            "declared": metrics.get("declared_ram_gb"),
            "peak": max(present),
            "spread": round(max(present) - min(present), 3),
            "instruments": len(present),
            "pipeline_s": metrics.get("pipeline_s"),
        })
    return out


GIB = float(1 << 30)


def _gib(gb_decimal: float) -> float:
    """Decimal gigabytes (10^9 bytes, as the harness records) to GiB."""
    return gb_decimal * 1e9 / GIB


def _tree_rows(tree_results: Path | None) -> dict[str, list[dict]]:
    """October 2026 process-tree peaks from exp3_totalseg_lowmem.jsonl.

    Grouped by the declaration they are measured against: the `total` task as
    the host runs it (six export workers), and the one-export-worker
    configuration that ships as `total_lowmem` -- both the runs made with the
    worker count overridden on `total` and the run of `total_lowmem` itself.
    """
    out: dict[str, list[dict]] = {"total": [], "total_lowmem": []}
    if tree_results is None or not tree_results.exists():
        return out
    _, rows = load_results(tree_results)
    for row in rows:
        if not row.get("ok") or not row["case_id"].startswith("adapter/"):
            continue
        config = row["case_id"].split("/")[1]
        peak = row.get("peak_rss_bytes")
        if not peak:
            continue
        key = "total" if config == "total" else (
            "total_lowmem" if config in ("total_lowmem", "total+threads1-1")
            else None)
        if key:
            out[key].append({"case": row["case_id"], "peak_gib": peak / GIB,
                             "peak_gb": peak / 1e9})
    return out


def figure_declared_vs_measured(header: dict, per_plugin: dict,
                                rows: list[dict], arbitration: dict,
                                out_path: Path, order: list[str],
                                tree: dict[str, list[dict]] | None = None) -> None:
    """The experiment's headline: a 6x overrun, its correction, and admission.

    Left is the measurement: each declaration against what was measured, in
    one unit. Both axes are GiB because the arbiter compares `ram_gb` with
    `physicalMemory / 2^30`; the harness records decimal gigabytes, which are
    converted here rather than plotted against a GiB declaration.
    Right is the consequence: the shipped arbiter, compiled, deciding.
    """
    tree = tree or {"total": [], "total_lowmem": []}
    checks = _crosscheck_rows(rows)
    bench_ts = per_plugin.get("totalsegmentator", {})
    sam2 = per_plugin.get("sam2", {})

    fig, axes = plt.subplots(
        1, 2, figsize=(12.4, 5.6), gridspec_kw={"width_ratios": [1.0, 1.0]})
    ax_measure, ax_decide = axes
    limit = 29.0

    ax_measure.plot([0, limit], [0, limit], color="#555555", linewidth=1.0,
                    linestyle="--", zorder=2)
    ax_measure.text(limit * 0.6, limit * 0.6 + 0.4, "declaration exactly honest",
                    fontsize=6.6, color="#555555", ha="center", va="bottom",
                    rotation=45, rotation_mode="anchor")
    ax_measure.fill_between([0, limit], [0, limit], [limit, limit],
                            color="#fb8500", alpha=0.13, zorder=0)
    ax_measure.fill_between([0, limit], [0, 0], [0, limit],
                            color="#8ecae6", alpha=0.14, zorder=0)
    ax_measure.text(limit * 0.30, limit * 0.97,
                    "measured ABOVE declared: the arbiter over-admits",
                    fontsize=7.4, color="#8a4b00", va="top", weight="bold")
    ax_measure.text(limit * 0.97, limit * 0.03,
                    "declared above measured: held back",
                    fontsize=7.4, color="#245e73", va="bottom", ha="right")

    # August, sandbox, one process under the thread shim: 3.5 GB declared.
    if checks:
        declared = checks[0]["declared"]
        peaks = [_gib(c["peak"]) for c in checks]
        ax_measure.scatter([declared] * len(peaks), peaks, s=80, marker="o",
                           color="#c1121f", zorder=5, edgecolor="white",
                           linewidth=1.0, label="Aug: single process, sandbox")
        ax_measure.annotate(
            "", xy=(declared, max(peaks)), xytext=(declared, declared),
            arrowprops=dict(arrowstyle="<->", color="#6a040f", linewidth=1.3),
            zorder=4)
        ax_measure.text(
            declared + 0.8, (max(peaks) + declared) / 2 - 2,
            f"TotalSegmentator as first declared\n"
            f"{min(peaks):.1f}–{max(peaks):.1f} GiB measured "
            f"({min(c['peak'] for c in checks):.1f}–"
            f"{max(c['peak'] for c in checks):.1f} GB)\n"
            f"vs {declared:.1f} declared: "
            f"{min(peaks) / declared:.1f}×–{max(peaks) / declared:.1f}× over",
            fontsize=8.0, va="center", ha="left", weight="bold", color="#6a040f")

    # August bench run after the first correction (23.5).
    if bench_ts.get("peak_rss_gb") and bench_ts.get("declared_ram_gb"):
        x, y = bench_ts["declared_ram_gb"], _gib(bench_ts["peak_rss_gb"])
        ax_measure.scatter([x], [y], s=80, marker="D", color="#2a9d8f",
                           zorder=6, edgecolor="white", linewidth=1.0,
                           label="Aug: after first correction (23.5)")

    # October, native, whole process tree.
    styles = {"total": ("^", "#7b2cbf", 25.5,
                        "Oct: process tree, total (25.5)"),
              "total_lowmem": ("v", "#219ebc", 24.0,
                               "Oct: process tree, one export worker (24.0)")}
    for key, (marker, colour, declared, label) in styles.items():
        points = tree.get(key, [])
        if not points:
            continue
        ys = [p["peak_gib"] for p in points]
        ax_measure.scatter([declared] * len(ys), ys, s=46, marker=marker,
                           color=colour, zorder=6, edgecolor="white",
                           linewidth=0.7, alpha=0.9,
                           label=f"{label}, n={len(ys)}")
    summary = []
    if bench_ts.get("peak_rss_gb"):
        summary.append(f"23.5 declared: {_gib(bench_ts['peak_rss_gb']):.2f} GiB, Aug")
    for key, declared in (("total", 25.5), ("total_lowmem", 24.0)):
        points = tree.get(key, [])
        if points:
            top = max(p["peak_gib"] for p in points)
            summary.append(f"{declared:.1f} declared: max {top:.2f} GiB "
                           f"({max(p['peak_gb'] for p in points):.2f} GB), "
                           f"{declared - top:.2f} GiB spare")
    if summary:
        ax_measure.text(limit * 0.97, 5.6,
                        "TotalSegmentator, corrected\n" + "\n".join(summary),
                        fontsize=7.2, ha="right", va="center", color="#33415c")

    if sam2.get("peak_rss_gb") and sam2.get("declared_ram_gb"):
        x, y = sam2["declared_ram_gb"], _gib(sam2["peak_rss_gb"])
        ax_measure.scatter([x], [y], s=56, marker="s", color="#126782",
                           zorder=5, edgecolor="white", linewidth=0.8)
        ax_measure.annotate(f"SAM 2\n{y:.2f} of {x:.1f} GiB", (x, y),
                            textcoords="offset points", xytext=(9, 2),
                            fontsize=7.2, va="center", color="#125670")

    ax_measure.legend(loc="center left", bbox_to_anchor=(0.0, 0.52),
                      fontsize=6.6, frameon=False)
    ax_measure.set_xlim(0, limit)
    ax_measure.set_ylim(0, limit)
    ax_measure.set_xlabel("declared in manifest, ram_gb (GiB, as the arbiter reads it)")
    ax_measure.set_ylabel("measured peak (GiB)")
    ax_measure.set_title("A. Declared against measured memory", loc="left",
                         fontsize=10, weight="bold")
    ax_measure.spines[["top", "right"]].set_visible(False)

    # ---- B: the shipped arbiter, deciding -----------------------------------
    alarm, safe, fits, held = "#c1121f", "#2a9d8f", "#219ebc", "#8d99ae"
    groups = [
        ("16 GB Mac: the same one-shot, asked with the declared\n"
         "and with the measured figure (August)",
         [("16gb/totalseg-admitted-on-its-declaration",
           "asked with 3.5 declared", {"admit": (alarm, "machine cannot hold it")}),
          ("16gb/totalseg-refused-on-its-measurement",
           "asked with 20.9 measured", {"refuse": (safe, "correctly refused")})]),
        ("16 GB Mac: starting a 5 GB resident server while a\n"
         "one-shot holds its peak",
         [("16gb/start-server-while-oneshot-runs-unreported",
           "one-shot not reported\n(before the fix)",
           {"admit": (alarm, "machine cannot hold it")}),
          ("16gb/start-server-while-oneshot-runs-reported",
           "one-shot reported\n(as shipped)",
           {"refuse": (safe, "correctly waits")})]),
        ("32 GB Mac, idle: today's declarations against the\n"
         "0.75 one-shot share (24 GiB)",
         [("32gb/totalseg-total-on-current-declaration",
           "total, 25.5", {"refuse": (held, "needs a 34 GiB Mac")}),
          ("32gb/totalseg-lowmem-on-current-declaration",
           "total_lowmem, 24.0", {"admit": (fits, "fits exactly")})]),
    ]
    y_positions: list[float] = []
    y_labels: list[str] = []
    row = 0.0
    for title, cases in groups:
        ax_decide.text(0.0, row + 0.62, title, fontsize=7.6, style="italic",
                       color="#333333", va="bottom")
        for case, label, palette in cases:
            decision = arbitration.get(case, {}).get("decision", "?")
            colour, note = palette.get(decision, ("#999999", "unexpected decision"))
            ax_decide.barh([row], [1.0], height=0.5, color=colour,
                           edgecolor="white", linewidth=0.8, zorder=3)
            ax_decide.text(0.04, row, decision.upper(), va="center", ha="left",
                           fontsize=9, color="white", weight="bold", zorder=4)
            ax_decide.text(1.06, row, note, va="center", ha="left",
                           fontsize=7.6, color=colour)
            y_positions.append(row)
            y_labels.append(label)
            row -= 0.9
        row -= 1.15
    ax_decide.set_yticks(y_positions)
    ax_decide.set_yticklabels(y_labels, fontsize=7.4)
    ax_decide.set_ylim(row + 0.8, 1.6)
    ax_decide.set_xlim(0, 2.0)
    ax_decide.set_xticks([])
    ax_decide.spines[["top", "right", "bottom", "left"]].set_visible(False)
    ax_decide.tick_params(axis="y", length=0)
    ax_decide.set_title("B. The shipped arbiter, compiled and asked",
                        loc="left", fontsize=10, weight="bold")

    machine = header.get("machine", {})
    chip = machine.get("chip", machine.get("machine", "unknown"))
    fig.suptitle("A declaration can be wrong by 6×, and the arbiter trusts it",
                 x=0.006, ha="left", fontsize=12, weight="bold")
    fig.text(
        0.006, 0.008,
        f"A: {chip}, TotalSegmentator on CPU (it ships CPU-only), fast (3 mm) "
        "model. August points: evaluation sandbox, nnU-Net's process pools "
        "replaced by threads, so one process; peak RSS. October points: native "
        "run as the host spawns the adapter, phys_footprint summed over the "
        "whole process tree, five TCIA series. Measured bytes / 2^30 on both "
        "axes; the shipped declarations were rounded from decimal GB, so they "
        "read about 7% high in GiB.   B: decisions from compiling the shipped "
        "ResourceArbiter.swift (exp3 arbitration phase, 38/38 scenarios as "
        "designed).",
        fontsize=6.4, ha="left", va="bottom", wrap=True)
    fig.tight_layout(rect=(0, 0.09, 1, 0.94))
    fig.savefig(out_path, dpi=300)
    plt.close(fig)


def figure_memory(header: dict, per_plugin: dict, out_path: Path,
                  order: list[str]) -> None:
    """Declared manifest ram_gb against measured peak RSS.

    The arbiter admits work against the declaration, so a plugin whose real
    peak exceeds it is over-admitted and one well under it is starved. The
    parity line is where a declaration is exactly honest.
    """
    # A point is plotted when the plugin's model actually ran, whether or not
    # the run reached its last stage. A bench that failed before loading
    # anything -- a licence gate, an absent Metal device -- has a peak RSS
    # that measures interpreter startup rather than the plugin, and plotting
    # it would invent a comparison the run never made. A bench that segmented
    # a whole series and then failed while writing its output did measure the
    # plugin, and its peak is exactly the number the arbiter would have had to
    # budget for.
    present = [p for p in order
               if p in per_plugin
               and per_plugin[p].get("peak_rss_gb") is not None
               and (per_plugin[p].get("bench_ok")
                    or per_plugin[p].get("model_ran"))]
    missing = [p for p in order if p not in present]

    fig, ax = plt.subplots(figsize=(6.0, 4.4))

    if present:
        declared = np.array([per_plugin[p]["declared_ram_gb"] for p in present])
        measured = np.array([per_plugin[p]["peak_rss_gb"] for p in present])

        limit = max(declared.max(), measured.max()) * 1.25
        ax.plot([0, limit], [0, limit], color="#666666", linewidth=1.0,
                linestyle="--", zorder=1)
        ax.text(limit * 0.97, limit * 0.97, "declaration exactly honest",
                fontsize=7, color="#666666", ha="right", va="bottom",
                rotation=45, rotation_mode="anchor")

        # The y-axis is measured and the x-axis declared, so the region ABOVE
        # the parity line is measured > declared: the plugin uses more than the
        # arbiter budgeted for it, and admission decisions made against the
        # declaration are wrong in the dangerous direction. Below the line the
        # declaration is conservative and the plugin is merely starved.
        # The alarm hue marks the over-admission side.
        ax.fill_between([0, limit], [0, limit], [limit, limit],
                        color="#fb8500", alpha=0.15, zorder=0)
        ax.fill_between([0, limit], [0, 0], [0, limit],
                        color="#8ecae6", alpha=0.16, zorder=0)
        ax.text(limit * 0.05, limit * 0.93,
                "measured above declared\nthe arbiter over-admits",
                fontsize=7.5, color="#8a4b00", va="top")
        ax.text(limit * 0.60, limit * 0.10,
                "declared above measured\nthe plugin is starved",
                fontsize=7.5, color="#245e73", va="bottom")

        ax.scatter(declared, measured, s=64, color="#c1121f", zorder=3,
                   edgecolor="white", linewidth=0.8)
        for plugin_id, x, value in zip(present, declared, measured):
            ax.annotate(f"{PLUGIN_LABELS.get(plugin_id, plugin_id)}\n"
                        f"{value:.2f} of {x:.1f} GB declared",
                        (x, value), textcoords="offset points",
                        xytext=(9, -2), fontsize=7.5, va="center")

        ax.set_xlim(0, limit)
        ax.set_ylim(0, limit)

    ax.set_xlabel("declared in manifest, ram_gb (GB)")
    ax.set_ylabel("measured peak resident set size (GB)")
    ax.set_title("The arbiter budgets against the declaration, not the measurement",
                 loc="left", fontsize=9.5)
    ax.spines[["top", "right"]].set_visible(False)

    note = ("Peak RSS from the kernel's accounting for the exited adapter "
            "process. CPU-only: a run on a visible GPU moves part of this "
            "footprint off the host heap.")
    if missing:
        reasons = "; ".join(
            f"{PLUGIN_LABELS.get(p, p)} — "
            f"{per_plugin.get(p, {}).get('unmeasured_reason', 'not run')}"
            for p in missing)
        note += f"  Not measured: {reasons}."
    fig.text(0.01, 0.01, note, fontsize=6.5, ha="left", va="bottom", wrap=True)
    fig.tight_layout(rect=(0, 0.08, 1, 1))
    fig.savefig(out_path, dpi=300)
    plt.close(fig)


def main(argv: list[str] | None = None) -> int:
    repo_default = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path,
                        default=repo_default / "eval/results/exp3_resources.jsonl")
    parser.add_argument("--figures", type=Path,
                        default=repo_default / "eval/figures")
    parser.add_argument("--tree-results", type=Path,
                        default=repo_default / "eval/results/exp3_totalseg_lowmem.jsonl",
                        help="October 2026 process-tree measurements")
    parser.add_argument("--order", default="gemma-4-e4b,sam2,sam3,totalsegmentator",
                        help="Plugin display order")
    args = parser.parse_args(argv)

    header, per_plugin, rows, arbitration = collect(args.results.resolve())
    order = [p.strip() for p in args.order.split(",") if p.strip()]
    args.figures.mkdir(parents=True, exist_ok=True)

    timing = args.figures / "exp3_stage_timing.png"
    memory = args.figures / "exp3_memory.png"
    figure_stage_timing(header, per_plugin, timing, order)
    figure_declared_vs_measured(header, per_plugin, rows, arbitration,
                                memory, order,
                                tree=_tree_rows(args.tree_results.resolve()))
    headline = args.figures / "fig_declared_vs_measured.png"
    headline.write_bytes(memory.read_bytes())
    print(f"wrote {timing}")
    print(f"wrote {memory}")
    print(f"wrote {headline}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
