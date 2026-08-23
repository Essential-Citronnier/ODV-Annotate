#!/usr/bin/env python3
# exp3_figures.py
# OpenDicomViewer
#
# Figures for experiment 3, drawn from eval/results/exp3_resources.jsonl.
#
# Two figures, matching the two questions the experiment asks:
#
#   exp3_stage_timing.png   where a plugin's wall time goes, per stage
#   exp3_memory.png         declared ram_gb against measured peak RSS
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

# Declarations corrected after these measurements were taken. The figure plots
# each point against the declaration in force when it was measured -- that is
# what the arbiter was deciding on -- and marks the corrected value separately,
# so the panel neither rewrites history nor silently disagrees with the
# manifest a reader would go and check.
CORRECTED_DECLARATIONS = {
    "totalsegmentator": 23.5,  # commit de234fe, from this experiment's finding
}

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


def figure_declared_vs_measured(header: dict, per_plugin: dict,
                                rows: list[dict], arbitration: dict,
                                out_path: Path, order: list[str]) -> None:
    """The experiment's headline: a 6x overrun, and what it costs admission.

    Two panels because the finding has two halves that one chart cannot carry.
    Left is the measurement -- what each plugin declares against what it was
    measured using, with the overrun stated as a multiple rather than left for
    the reader to divide. Right is the consequence: the same shipped arbiter,
    asked the same question with the declared and the measured figure, deciding
    differently. That contrast is the argument for auditing declared
    resources, so it is drawn to be read without the prose.
    """
    checks = _crosscheck_rows(rows)
    bench_points = [
        {"label": PLUGIN_LABELS.get(p, p),
         "declared": per_plugin[p]["declared_ram_gb"],
         "peak": per_plugin[p]["peak_rss_gb"]}
        for p in order
        if p in per_plugin and per_plugin[p].get("peak_rss_gb") is not None
        and (per_plugin[p].get("bench_ok") or per_plugin[p].get("model_ran"))
    ]

    fig, axes = plt.subplots(
        1, 2, figsize=(11.6, 5.0), gridspec_kw={"width_ratios": [1.0, 1.05]})
    ax_measure, ax_decide = axes

    # ---- A: declared against measured -------------------------------------
    ts_declared = checks[0]["declared"] if checks else 3.5
    all_peaks = [c["peak"] for c in checks] + [b["peak"] for b in bench_points]
    limit = max(all_peaks + [ts_declared]) * 1.22

    ax_measure.plot([0, limit], [0, limit], color="#555555", linewidth=1.0,
                    linestyle="--", zorder=2)
    ax_measure.text(limit * 0.98, limit * 0.98, "declaration exactly honest",
                    fontsize=6.6, color="#555555", ha="right", va="bottom",
                    rotation=45, rotation_mode="anchor")
    ax_measure.fill_between([0, limit], [0, limit], [limit, limit],
                            color="#fb8500", alpha=0.13, zorder=0)
    ax_measure.fill_between([0, limit], [0, 0], [0, limit],
                            color="#8ecae6", alpha=0.14, zorder=0)
    # Kept high-left, clear of the annotated measurement cluster that sits
    # just above the declaration on the x-axis.
    ax_measure.text(limit * 0.045, limit * 0.985,
                    "measured ABOVE declared\nthe arbiter over-admits",
                    fontsize=7.6, color="#8a4b00", va="top", weight="bold")
    ax_measure.text(limit * 0.50, limit * 0.07,
                    "declared above measured\nthe plugin is starved",
                    fontsize=7.6, color="#245e73", va="bottom")

    # Every TotalSegmentator run is drawn rather than a summary of them: the
    # finding rests on repeated agreement, so the repetition is the evidence.
    for check in checks:
        ax_measure.scatter([check["declared"]], [check["peak"]], s=88,
                           marker="o", color="#c1121f", zorder=5,
                           edgecolor="white", linewidth=1.1)
    if checks:
        peaks = [c["peak"] for c in checks]
        ratios = [c["peak"] / c["declared"] for c in checks]
        # A vertical rule from the declaration to the measurements makes the
        # size of the gap the thing the eye lands on.
        ax_measure.annotate(
            "", xy=(ts_declared, max(peaks)), xytext=(ts_declared, ts_declared),
            arrowprops=dict(arrowstyle="<->", color="#6a040f", linewidth=1.4),
            zorder=4)
        ax_measure.text(
            ts_declared + limit * 0.035, (max(peaks) + ts_declared) / 2,
            f"TotalSegmentator\n{min(peaks):.1f}\u2013{max(peaks):.1f} GB measured\n"
            f"vs {ts_declared:.1f} GB declared\n"
            f"{min(ratios):.1f}\u00d7 to {max(ratios):.1f}\u00d7 over",
            fontsize=8.6, va="center", ha="left", weight="bold",
            color="#6a040f")

    # Where the declaration has since been corrected, show both: the figure
    # the measurements were taken against and the one now shipped. Without
    # this the panel silently disagrees with the manifest a reader would go
    # and check.
    corrected = CORRECTED_DECLARATIONS.get("totalsegmentator")
    if checks and corrected and abs(corrected - ts_declared) > 0.01:
        ax_measure.axvline(corrected, color="#2a9d8f", linewidth=1.2,
                           linestyle=":", zorder=2)
        ax_measure.text(corrected + limit * 0.012, limit * 0.30,
                        f"corrected to {corrected:.1f} GB\nafter this measurement",
                        fontsize=7.2, color="#1d6f66", rotation=90,
                        va="center", ha="left")

    # The completed bench run belongs on the chart too, plotted against the
    # declaration in force when it ran -- which, after commit de234fe, is the
    # corrected 23.5. It lands just below parity, and that is the point: it is
    # the run that validates the correction, measured independently of the runs
    # that motivated it.
    for point in bench_points:
        if not point["label"].startswith("TotalSeg"):
            continue
        ax_measure.scatter([point["declared"]], [point["peak"]], s=88,
                           marker="D", color="#2a9d8f", zorder=5,
                           edgecolor="white", linewidth=1.1)
        ax_measure.annotate(
            f"after correction\n{point['peak']:.2f} of {point['declared']:.1f} GB"
            f" = {point['peak'] / point['declared']:.2f}\u00d7",
            (point["declared"], point["peak"]), textcoords="offset points",
            xytext=(-8, -30), fontsize=7.6, va="center", ha="right",
            color="#1d6f66", weight="bold")

    for point in bench_points:
        if point["label"].startswith("TotalSeg"):
            continue
        ax_measure.scatter([point["declared"]], [point["peak"]], s=62,
                           marker="s", color="#219ebc", zorder=5,
                           edgecolor="white", linewidth=0.8)
        ax_measure.annotate(
            f"{point['label']}\n{point['peak']:.2f} of {point['declared']:.1f} GB",
            (point["declared"], point["peak"]), textcoords="offset points",
            xytext=(11, 1), fontsize=7.6, va="center", color="#125670")

    ax_measure.set_xlim(0, limit)
    ax_measure.set_ylim(0, limit)
    ax_measure.set_xlabel("declared in manifest, ram_gb (GB)")
    ax_measure.set_ylabel("measured peak resident set size (GB)")
    ax_measure.set_title("A. What the plugins actually use", loc="left",
                         fontsize=10, weight="bold")
    ax_measure.spines[["top", "right"]].set_visible(False)

    # ---- B: the same arbiter, two answers ----------------------------------
    pairs = [
        ("The same one-shot request, admitted against\n"
         "the declared figure and against the measured one",
         ("16gb/totalseg-admitted-on-its-declaration", "asked with 3.5 GB declared"),
         ("16gb/totalseg-refused-on-its-measurement", "asked with 20.9 GB measured")),
        ("Starting a 5 GB resident server while a\none-shot is holding its peak",
         ("16gb/start-server-while-oneshot-runs-unreported",
          "one-shot NOT reported\n(what the host asks today)"),
         ("16gb/start-server-while-oneshot-runs-reported",
          "one-shot reported\n(what it should ask)")),
    ]

    y_positions: list[float] = []
    y_labels: list[str] = []
    group_anchors: list[tuple[float, str]] = []
    row = 0.0
    for title, first, second in pairs:
        group_anchors.append((row + 0.85, title))
        for case, label in (first, second):
            metrics = arbitration.get(case, {})
            decision = metrics.get("decision", "?")
            admitted = decision == "admit"
            # An admission the machine cannot honour is the failure this
            # figure exists to show, so it takes the alarm colour; a refusal
            # is the safe answer and takes the calm one.
            colour = "#c1121f" if admitted else "#2a9d8f"
            ax_decide.barh([row], [1.0], height=0.52, color=colour,
                           edgecolor="white", linewidth=0.8, zorder=3)
            ax_decide.text(0.04, row, decision.upper(), va="center", ha="left",
                           fontsize=9.5, color="white", weight="bold", zorder=4)
            ax_decide.text(1.06, row,
                           "machine cannot hold it" if admitted
                           else "correctly waits",
                           va="center", ha="left", fontsize=7.8,
                           color="#8a1c1c" if admitted else "#1d6f66")
            y_positions.append(row)
            y_labels.append(label)
            row -= 1.0
        row -= 0.95

    ax_decide.set_yticks(y_positions)
    ax_decide.set_yticklabels(y_labels, fontsize=7.6)
    ax_decide.set_ylim(row + 0.5, 1.5)
    ax_decide.set_xlim(0, 2.05)
    ax_decide.set_xticks([])
    ax_decide.spines[["top", "right", "bottom", "left"]].set_visible(False)
    ax_decide.tick_params(axis="y", length=0)
    ax_decide.set_title(
        "B. The same arbiter on a 16 GB machine (8 GiB budget)",
        loc="left", fontsize=10, weight="bold")

    for anchor, title in group_anchors:
        ax_decide.text(0.0, anchor, title, fontsize=7.9, style="italic",
                       color="#333333", va="bottom")

    machine = header.get("machine", {})
    gpu = machine.get("gpu_visible", {})
    chip = machine.get("chip", machine.get("machine", "unknown"))
    spread = max((c["spread"] for c in checks), default=0.0)
    series_count = len({c["series"] for c in checks})
    fig.suptitle(
        "Declared resources are not audited, and the arbiter trusts them",
        x=0.006, ha="left", fontsize=12, weight="bold")
    fig.text(
        0.006, 0.008,
        f"A: peak RSS per adapter process on {chip}, CPU only (torch MPS "
        f"available: {gpu.get('torch_mps')}). Each TotalSegmentator point is "
        f"three independent instruments \u2014 parent accounting, child "
        f"RUSAGE_SELF, child self-sampler \u2014 agreeing to within "
        f"{spread:.2f} GB, across {series_count} series. All points are the "
        "fast (3 mm) variant, the manifest default; full resolution could not "
        "be fetched on this network and is expected to be higher, not lower. "
        "Gemma 4 E4B and SAM 3 are absent: no Metal device, and a licence "
        "gate.   B: decisions produced by compiling the shipped "
        "ResourceArbiter.swift rather than reimplementing its policy. All four "
        "rows are that policy behaving exactly as written; only the figure it "
        "was given differs.",
        fontsize=6.5, ha="left", va="bottom", wrap=True)
    fig.tight_layout(rect=(0, 0.11, 1, 0.94))
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
                                memory, order)
    print(f"wrote {timing}")
    print(f"wrote {memory}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
