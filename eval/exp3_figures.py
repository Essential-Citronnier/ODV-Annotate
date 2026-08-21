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

    return header, per_plugin


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

    header, per_plugin = collect(args.results.resolve())
    order = [p.strip() for p in args.order.split(",") if p.strip()]
    args.figures.mkdir(parents=True, exist_ok=True)

    timing = args.figures / "exp3_stage_timing.png"
    memory = args.figures / "exp3_memory.png"
    figure_stage_timing(header, per_plugin, timing, order)
    figure_memory(header, per_plugin, memory, order)
    print(f"wrote {timing}")
    print(f"wrote {memory}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
