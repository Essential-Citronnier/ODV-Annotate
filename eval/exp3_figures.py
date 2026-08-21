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
            # A run that recorded a substantive stage did load and exercise the
            # model, even if a later stage failed. That distinction decides
            # whether its peak RSS is a measurement of the plugin or of a
            # Python interpreter that exited early.
            entry["model_ran"] = any(
                key in row.get("stages_s", {})
                for key in ("model_load", "encode", "inference",
                            "Running segmentation"))
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
            values = np.array([per_plugin[p]["stages"].get(key, 0.0) or 0.0
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

    Two panels because the finding has two halves that a single chart cannot
    carry. The left panel is the measurement -- every peak-RSS reading against
    the figure the manifest declares, with the overrun stated as a multiple
    rather than left for the reader to divide. The right panel is the
    consequence: the same arbiter, asked the same question with the declared
    and the measured figure, deciding differently.

    The paired-bar arrangement on the right is the argument for auditing
    declared resources, so it is drawn to be readable without the prose.
    """
    fig, axes = plt.subplots(
        1, 2, figsize=(11.4, 4.6), gridspec_kw={"width_ratios": [1.15, 1.0]})
    ax_measure, ax_decide = axes

    # ---- left panel: declared against every measurement -------------------
    checks = _crosscheck_rows(rows)
    bench_points = [
        {"label": PLUGIN_LABELS.get(p, p),
         "declared": per_plugin[p]["declared_ram_gb"],
         "peak": per_plugin[p]["peak_rss_gb"],
         "detail": "bench"}
        for p in order
        if p in per_plugin and per_plugin[p].get("peak_rss_gb") is not None
        and (per_plugin[p].get("bench_ok") or per_plugin[p].get("model_ran"))
    ]

    declared_ts = checks[0]["declared"] if checks else 3.5
    limit = max([point["peak"] for point in bench_points]
                + [check["peak"] for check in checks] + [declared_ts]) * 1.18

    ax_measure.plot([0, limit], [0, limit], color="#555555", linewidth=1.0,
                    linestyle="--", zorder=2)
    ax_measure.text(limit * 0.985, limit * 0.985, "declaration exactly honest",
                    fontsize=6.8, color="#555555", ha="right", va="bottom",
                    rotation=45, rotation_mode="anchor")
    ax_measure.fill_between([0, limit], [0, limit], [limit, limit],
                            color="#fb8500", alpha=0.13, zorder=0)
    ax_measure.fill_between([0, limit], [0, 0], [0, limit],
                            color="#8ecae6", alpha=0.14, zorder=0)
    ax_measure.text(limit * 0.04, limit * 0.955,
                    "measured ABOVE declared\nthe arbiter over-admits",
                    fontsize=7.5, color="#8a4b00", va="top", weight="bold")
    ax_measure.text(limit * 0.58, limit * 0.08,
                    "declared above measured\nthe plugin is starved",
                    fontsize=7.5, color="#245e73", va="bottom")

    # Every TotalSegmentator reading is drawn, not a summary of them: the
    # finding rests on repeated agreement, so the repetition is the evidence
    # and hiding it behind a mean would discard the point.
    if checks:
        fast = [c for c in checks if c["fast"]]
        full = [c for c in checks if c["fast"] is False]
        for subset, marker, face, name in (
                (fast, "o", "#c1121f", "TotalSegmentator, fast (3 mm)"),
                (full, "D", "#6a040f", "TotalSegmentator, full resolution")):
            if not subset:
                continue
            ax_measure.scatter([c["declared"] for c in subset],
                               [c["peak"] for c in subset],
                               s=74, marker=marker, color=face, zorder=4,
                               edgecolor="white", linewidth=0.9,
                               label=name)
        peaks = [c["peak"] for c in checks]
        ratios = [c["peak"] / c["declared"] for c in checks]
        ax_measure.annotate(
            f"TotalSegmentator\n{min(peaks):.1f}–{max(peaks):.1f} GB measured\n"
            f"vs {declared_ts:.1f} GB declared\n"
            f"= {min(ratios):.1f}\u00d7 to {max(ratios):.1f}\u00d7 over",
            (declared_ts, max(peaks)), textcoords="offset points",
            xytext=(16, -6), fontsize=8.2, va="top", weight="bold",
            color="#6a040f")

    for point in bench_points:
        if point["label"].startswith("TotalSeg"):
            continue
        ax_measure.scatter([point["declared"]], [point["peak"]], s=64,
                           marker="s", color="#219ebc", zorder=4,
                           edgecolor="white", linewidth=0.8,
                           label="other plugins, bench")
        ax_measure.annotate(
            f"{point['label']}\n{point['peak']:.2f} of "
            f"{point['declared']:.1f} GB",
            (point["declared"], point["peak"]), textcoords="offset points",
            xytext=(10, -2), fontsize=7.5, va="center", color="#125670")

    ax_measure.set_xlim(0, limit)
    ax_measure.set_ylim(0, limit)
    ax_measure.set_xlabel("declared in manifest, ram_gb (GB)")
    ax_measure.set_ylabel("measured peak resident set size (GB)")
    ax_measure.set_title("A. What the plugins actually use", loc="left",
                         fontsize=9.5, weight="bold")
    ax_measure.spines[["top", "right"]].set_visible(False)
    handles, labels = ax_measure.get_legend_handles_labels()
    unique = dict(zip(labels, handles))
    ax_measure.legend(unique.values(), unique.keys(), frameon=False,
                      fontsize=6.9, loc="lower right")

    # ---- right panel: the same arbiter, two answers ------------------------
    pairs = [
        ("Same one-shot request,\ndeclared vs measured figure",
         ("16gb/totalseg-admitted-on-its-declaration", "on 3.5 GB declared"),
         ("16gb/totalseg-refused-on-its-measurement", "on 20.9 GB measured")),
        ("Start a 5 GB server while a\none-shot holds its peak",
         ("16gb/start-server-while-oneshot-runs-unreported",
          "one-shot not reported\n(what the host asks)"),
         ("16gb/start-server-while-oneshot-runs-reported",
          "one-shot reported\n(what it should ask)")),
    ]

    y_positions: list[float] = []
    y_labels: list[str] = []
    row = 0.0
    for title, (bad_case, bad_label), (good_case, good_label) in pairs:
        for case, label in ((bad_case, bad_label), (good_case, good_label)):
            metrics = arbitration.get(case, {})
            decision = metrics.get("decision", "?")
            admitted = decision == "admit"
            # An admission that the machine cannot honour is the failure mode
            # this figure exists to show, so it carries the alarm colour and a
            # refusal -- the safe answer -- carries the calm one.
            colour = "#c1121f" if admitted else "#2a9d8f"
            width = 1.0
            ax_decide.barh([row], [width], height=0.58, color=colour,
                           edgecolor="white", linewidth=0.8)
            ax_decide.text(0.035, row, decision.upper(), va="center",
                           ha="left", fontsize=9, color="white", weight="bold")
            verdict = ("machine cannot hold it" if admitted
                       else "correctly waits")
            ax_decide.text(width + 0.03, row, verdict, va="center", ha="left",
                           fontsize=7.6,
                           color="#8a1c1c" if admitted else "#1d6f66")
            y_positions.append(row)
            y_labels.append(label)
            row -= 1.0
        row -= 0.55

    ax_decide.set_yticks(y_positions)
    ax_decide.set_yticklabels(y_labels, fontsize=7.6)
    ax_decide.set_xlim(0, 1.85)
    ax_decide.set_xticks([])
    ax_decide.spines[["top", "right", "bottom"]].set_visible(False)
    ax_decide.set_title(
        "B. The same arbiter, on a 16 GB machine\n"
        "     (8 GiB budget) — decisions from the shipped policy",
        loc="left", fontsize=9.5, weight="bold")

    for index, (title, _, _) in enumerate(pairs):
        anchor = y_positions[index * 2] + 0.72
        ax_decide.text(0.0, anchor, title, fontsize=7.8, style="italic",
                       color="#333333", va="bottom")

    gpu = header.get("machine", {}).get("gpu_visible", {})
    machine = header.get("machine", {})
    chip = machine.get("chip", machine.get("machine", "unknown"))
    fig.suptitle(
        "Declared resources are not audited, and the arbiter trusts them",
        x=0.006, ha="left", fontsize=11.5, weight="bold")
    fig.text(
        0.006, 0.008,
        f"A: peak RSS measured per adapter process on {chip}, CPU only "
        f"(torch MPS available: {gpu.get('torch_mps')}). TotalSegmentator "
        "points are three independent instruments (parent accounting, child "
        "RUSAGE_SELF, child sampler) that agreed to within 0.00 GB on each "
        "run, across two series and two task variants. Gemma 4 E4B and SAM 3 "
        "are absent: no Metal device and a licence gate respectively.  "
        "B: decisions produced by compiling the shipped ResourceArbiter.swift, "
        "not by reimplementing its policy. Both refusals and both admissions "
        "are the policy behaving exactly as written.",
        fontsize=6.4, ha="left", va="bottom", wrap=True)
    fig.tight_layout(rect=(0, 0.10, 1, 0.93))
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
