#!/usr/bin/env python3
# exp2_figures.py
# OpenDicomViewer -- plugin layer evaluation, Experiment 2 figures.
#
# The fidelity result is that every per-structure Dice equals exactly 1.0. That
# is the hardest kind of result to plot honestly: a histogram of a constant is a
# single bar, and a scatter of y = x is a diagonal line, and both look like a
# figure that failed to render rather than a measurement that came out clean.
#
# The figure therefore has to make three things legible at once:
#   - the agreement is exact, over a stated number of structures and cases;
#   - the measurement could have detected a disagreement (the probe panel);
#   - where the abstraction is NOT lossless (the overlapping-structure defect).
#
# A panel showing only the perfect result would be the survivorship-biased
# version of this figure.
"""Render the pipeline-fidelity figures from the recorded results."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import matplotlib as mpl
import matplotlib.pyplot as plt
import numpy as np

from harness import load_results  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent

# One hue per path, threaded across every panel that mentions that path.
PLUGIN = "#1f6feb"
NATIVE = "#8a8f98"
ALARM = "#c1440e"
NEUTRAL = "#3d4451"


def style() -> None:
    mpl.rcParams.update({
        "figure.dpi": 300, "savefig.dpi": 300,
        "font.size": 8, "axes.titlesize": 8, "axes.labelsize": 8,
        "xtick.labelsize": 6, "ytick.labelsize": 6, "legend.fontsize": 7,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.linewidth": 0.6, "xtick.major.width": 0.6,
        "ytick.major.width": 0.6, "savefig.bbox": "tight",
        "figure.facecolor": "white", "axes.facecolor": "white",
    })


def panel_letter(ax, letter: str) -> None:
    """Place the panel letter clear of a multi-line title.

    Offset left of the axes rectangle rather than above it: a title that grows
    from one line to two extends UPWARD, so a letter placed above the axes
    slides underneath it, while a letter placed to the left never can.

    The title's own pad is set through the existing artist -- calling
    `set_title` again would create a second Text artist, since matplotlib keeps
    independent left/center/right titles and the old one would still be drawn.
    """
    ax.title.set_position((0.5, 1.0))
    ax.title.set_va("bottom")
    ax.annotate(letter, xy=(0.0, 1.0), xytext=(-34, 6),
                xycoords="axes fraction", textcoords="offset points",
                fontsize=10, fontweight="bold", va="bottom", ha="left")


# ---------------------------------------------------------------------------


def collect(path: Path):
    header, rows = load_results(path)
    ok = [r for r in rows if r["ok"]]
    failed = [r for r in rows if not r["ok"]]
    return header, ok, failed


def figure_fidelity(fidelity_rows, probes, out_path: Path, failed_count: int):
    """Four panels: the exact result, its sensitivity, the defect, the volumes."""
    fig = plt.figure(figsize=(7.2, 5.9))
    grid = fig.add_gridspec(2, 2, hspace=0.72, wspace=0.34)

    # -- (a) per-structure Dice, both comparisons ---------------------------
    ax = fig.add_subplot(grid[0, 0])
    series = [
        ("SEG round trip\nencode → host decode", "per_structure_roundtrip", NATIVE),
        ("End to end\nplugin vs native", "per_structure_end_to_end", PLUGIN),
    ]
    ticks, worst = [], 1.0
    for offset, (label, key, color) in enumerate(series):
        values = np.array([e["dice"] for row in fidelity_rows
                           for e in row["metrics"].get(key) or []])
        if values.size == 0:
            ticks.append(label)
            continue
        jitter = (np.random.default_rng(0).uniform(-0.16, 0.16, values.size)
                  + offset)
        # Every point sits at exactly 1.0, so the strip collapses to a line.
        # Drawn anyway, with the count on the tick label, because the reader
        # needs to see that the mass is at 1.0 rather than infer it.
        ax.scatter(jitter, values, s=6, color=color, alpha=0.55,
                   linewidths=0, zorder=3)
        ticks.append(f"{label}\nn = {values.size}")
        worst = min(worst, float(values.min()))
    ax.axhline(1.0, color=NEUTRAL, lw=0.5, ls=(0, (4, 3)), zorder=1)
    ax.set_xticks(range(len(series)))
    ax.set_xticklabels(ticks, fontsize=6.5)
    ax.set_xlim(-0.6, len(series) - 0.4)
    # A range that would show a defect if one existed: losing a single voxel
    # from the smallest structure in the cohort lands well inside this window.
    ax.set_ylim(0.995, 1.0008)
    ax.set_yticks([0.995, 0.996, 0.997, 0.998, 0.999, 1.000])
    ax.set_ylabel("Dice vs. native masks")
    # One centred annotation, not one per column: the two columns report the
    # same value, and a per-column block collides with its neighbour. The axis
    # is deliberately expanded to a 0.005-wide window so that a reader can see
    # the points are ON 1.0 rather than merely near it -- said here, because an
    # unexplained near-empty axis reads as a plotting failure.
    ax.annotate(
        f"Every point is exactly {worst:.6f}.\n"
        "The y-axis is expanded to a 0.005-wide window\n"
        "so any departure from 1.0 would be visible.",
        xy=(0.5, 0.06), xycoords="axes fraction", ha="center", va="bottom",
        fontsize=6.5, color=NEUTRAL, linespacing=1.5)
    ax.set_title("Both paths reproduce the native masks exactly")
    panel_letter(ax, "a")

    # -- (b) the measurement can detect a difference ------------------------
    ax = fig.add_subplot(grid[0, 1])
    sensitivity = next((p for p in probes
                        if p["probe"] == "comparison_sensitivity"), None)
    if sensitivity:
        detail = sensitivity["detail"]
        labels = ["identical", "1 voxel\nremoved", "shifted\n1 slice",
                  "structure\nmissing"]
        values = [detail["identical_dice"], detail["one_voxel_removed_dice"],
                  detail["one_slice_shift_dice"], detail["structure_dropped_dice"]]
        colors = [NATIVE, ALARM, ALARM, ALARM]
        positions = np.arange(len(values))
        ax.vlines(positions, 0, values, color=colors, lw=0.8, alpha=0.6)
        ax.scatter(positions, values, s=26, color=colors, zorder=3, linewidths=0)
        for x, v in zip(positions, values):
            ax.annotate(f"{v:.3f}", (x, v), textcoords="offset points",
                        xytext=(0, 6), ha="center", fontsize=6.5, color=NEUTRAL)
        ax.set_xticks(positions)
        ax.set_xticklabels(labels, fontsize=6.5)
        ax.set_xlim(-0.55, len(values) - 0.45)
        ax.set_ylim(-0.05, 1.25)
        ax.set_ylabel("Dice reported")
        ax.set_title("Known perturbations are detected")
    panel_letter(ax, "b")

    # -- (c) where the encoder IS lossy -------------------------------------
    ax = fig.add_subplot(grid[1, 0])
    overlap = next((p for p in probes if p["probe"] == "overlapping_structures"),
                   None)
    if overlap:
        entries = overlap["detail"]["per_structure"]
        names = ["structure encoded\nfirst", "structure encoded\nsecond"]
        values = [e["dice"] for e in entries]
        lost = [-e["voxel_delta"] for e in entries]
        positions = np.arange(len(values))
        colors = [ALARM if v < 1.0 else NATIVE for v in values]
        ax.vlines(positions, 0, values, color=colors, lw=0.8, alpha=0.6)
        ax.scatter(positions, values, s=26, color=colors, zorder=3, linewidths=0)
        for x, v, l in zip(positions, values, lost):
            # Offset to the inside of the panel so a two-line note beside the
            # leftmost mark cannot run off the axes.
            note = f"{v:.3f}" + (f"\n−{l} voxels lost" if l else "")
            ax.annotate(note, (x, v), textcoords="offset points",
                        xytext=(0, 9), ha="center", va="bottom",
                        fontsize=6.5, color=ALARM if l else NEUTRAL)
        ax.set_xticks(positions)
        ax.set_xticklabels(names, fontsize=6.5)
        ax.set_xlim(-0.55, len(values) - 0.45)
        ax.set_ylim(0, 1.45)
        ax.set_ylabel("Dice after round trip")
        ax.set_title("Overlapping structures are clipped\nby single-labelmap encoding")
    panel_letter(ax, "c")

    # -- (d) voxel-count agreement ------------------------------------------
    ax = fig.add_subplot(grid[1, 1])
    reference, candidate = [], []
    for row in fidelity_rows:
        for entry in row["metrics"].get("per_structure_end_to_end") or []:
            if entry["reference_voxels"] > 0:
                reference.append(entry["reference_voxels"])
                candidate.append(entry["candidate_voxels"])
    if reference:
        reference = np.array(reference)
        candidate = np.array(candidate)
        limits = (reference.min() * 0.6, reference.max() * 1.5)
        ax.plot(limits, limits, color=NEUTRAL, lw=0.5, ls=(0, (4, 3)), zorder=1)
        ax.scatter(reference, candidate, s=6, color=PLUGIN, alpha=0.5,
                   linewidths=0, zorder=3)
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_xlim(*limits)
        ax.set_ylim(*limits)
        # Decade ticks only within the data range: matplotlib otherwise draws a
        # decade above the largest structure, which collides with the title.
        decades = 10.0 ** np.arange(np.floor(np.log10(limits[0])),
                                    np.ceil(np.log10(limits[1])))
        decades = decades[(decades >= limits[0]) & (decades <= limits[1])]
        ax.set_xticks(decades)
        ax.set_yticks(decades)
        ax.set_aspect("equal")
        ax.set_xlabel("Native mask voxels")
        ax.set_ylabel("Plugin path voxels")
        deltas = candidate - reference
        ax.set_title(f"Voxel counts agree exactly\n"
                     f"({reference.size} structures, max difference "
                     f"{np.abs(deltas).max()})")
        ax.annotate("identity line", xy=(limits[0] * 3.2, limits[0] * 3.2),
                    xytext=(6, -9), textcoords="offset points",
                    fontsize=6.5, color=NEUTRAL, rotation=45,
                    rotation_mode="anchor")
    panel_letter(ax, "d")

    if failed_count:
        fig.text(0.5, -0.02, f"{failed_count} cohort case(s) recorded as failures; "
                             "see exp2_fidelity.jsonl", ha="center",
                 fontsize=6.5, color=ALARM)
    verify(fig, out_path)
    plt.close(fig)
    return out_path


def figure_hygiene(hygiene_rows, out_path: Path):
    """Both paths against expert reference masks -- a pipeline sanity check."""
    fig, axes = plt.subplots(1, 2, figsize=(7.4, 3.3),
                             gridspec_kw={"wspace": 0.40,
                                          "width_ratios": [1.15, 1.0]})

    # -- (a) distribution per path ------------------------------------------
    ax = axes[0]
    rng = np.random.default_rng(1)
    entries = [("Native path", "per_structure_native", NATIVE),
               ("Plugin path", "per_structure_plugin", PLUGIN)]
    for offset, (label, key, color) in enumerate(entries):
        values = np.array([e["dice"] for row in hygiene_rows
                           for e in row["metrics"].get(key) or []])
        if values.size == 0:
            continue
        ax.scatter(rng.uniform(-0.17, 0.17, values.size) + offset, values,
                   s=5, color=color, alpha=0.35, linewidths=0, zorder=2)
        ax.hlines(np.median(values), offset - 0.26, offset + 0.26,
                  color=NEUTRAL if color == NATIVE else color, lw=1.8, zorder=4)
        ax.annotate(f"median {np.median(values):.3f}",
                    (offset, np.median(values)), textcoords="offset points",
                    xytext=(0, -12), ha="center", va="top", fontsize=6.5,
                    color=NEUTRAL if color == NATIVE else color)
    published = hygiene_rows[0]["metrics"]["published_dice_full_res"]
    ax.axhline(published, color=ALARM, lw=0.7, ls=(0, (3, 2)), zorder=1)
    ax.annotate(f"published full-resolution model: {published}",
                xy=(1.42, published), xytext=(0, 4), textcoords="offset points",
                ha="right", fontsize=6.5, color=ALARM)
    ax.set_xticks(range(len(entries)))
    ax.set_xticklabels([e[0] for e in entries])
    ax.set_xlim(-0.55, 1.55)
    ax.set_ylim(-0.02, 1.18)
    ax.set_ylabel("Dice vs. expert reference")
    ax.set_title("Both paths land in the same range")
    ax.annotate("3 mm fast model; pipeline check, not an accuracy claim",
                xy=(0.5, -0.20), xycoords="axes fraction", ha="center",
                fontsize=6.5, color=NEUTRAL)
    panel_letter(ax, "a")

    # -- (b) plugin vs native, per structure --------------------------------
    ax = axes[1]
    native_by_key, plugin_by_key = {}, {}
    for row in hygiene_rows:
        for entry in row["metrics"].get("per_structure_native") or []:
            native_by_key[(row["case_id"], entry["structure"])] = entry["dice"]
        for entry in row["metrics"].get("per_structure_plugin") or []:
            plugin_by_key[(row["case_id"], entry["structure"])] = entry["dice"]
    shared = sorted(set(native_by_key) & set(plugin_by_key))
    x = np.array([native_by_key[k] for k in shared])
    y = np.array([plugin_by_key[k] for k in shared])
    ax.plot([-0.02, 1.02], [-0.02, 1.02], color=NEUTRAL, lw=0.5,
            ls=(0, (4, 3)), zorder=1)
    ax.scatter(x, y, s=6, color=PLUGIN, alpha=0.45, linewidths=0, zorder=3)
    ax.set_xlim(-0.03, 1.06)
    ax.set_ylim(-0.03, 1.06)
    ax.set_xticks([0.0, 0.25, 0.5, 0.75, 1.0])
    ax.set_yticks([0.0, 0.25, 0.5, 0.75, 1.0])
    ax.set_aspect("equal")
    ax.set_xlabel("Native path Dice vs. reference")
    ax.set_ylabel("Plugin path Dice vs. reference")
    largest = float(np.abs(y - x).max()) if x.size else 0.0
    ax.set_title(f"Per structure, the two paths score identically\n"
                 f"{x.size} structures, max difference {largest:.6f}")
    panel_letter(ax, "b")

    verify(fig, out_path)
    plt.close(fig)
    return out_path


def verify(fig, path: Path, min_area_px: float = 2.0,
           min_fraction: float = 0.04) -> list[str]:
    """Fail loudly on text artists that overlap, measured on a drawn canvas.

    Run on every render rather than eyeballed once: these scripts are rerun as
    the cohort grows, and a title that fits at four cases can collide at
    twelve.

    Two thresholds, because a strict bounding-box intersection test produces
    findings a reader would never see. Glyph boxes carry padding beyond the
    inked area, so abutting labels routinely intersect by a pixel or two; a
    finding must exceed BOTH an absolute area and a fraction of the smaller
    box before it counts. A tick label sitting on its own spine is excluded
    outright -- that is where a tick label belongs.

    Canvas extents are only meaningful after a draw, so the figure is drawn
    first. Text is deliberately NOT checked against the figure rectangle:
    savefig runs with bbox="tight", which expands the canvas around exactly
    the labels a containment test would flag.
    """
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    texts = [(t, t.get_window_extent(renderer)) for t in fig.findobj(mpl.text.Text)
             if t.get_text().strip() and t.get_visible()]
    spines = [(s, s.get_window_extent(renderer)) for ax in fig.axes
              for s in ax.spines.values() if s.get_visible()]
    own_ticks = {ax: set(ax.get_xticklabels(which="both")
                         + ax.get_yticklabels(which="both")) for ax in fig.axes}

    def significant(box_a, box_b) -> float:
        if not box_a.overlaps(box_b):
            return 0.0
        width = min(box_a.x1, box_b.x1) - max(box_a.x0, box_b.x0)
        height = min(box_a.y1, box_b.y1) - max(box_a.y0, box_b.y0)
        area = max(width, 0.0) * max(height, 0.0)
        smaller = min(abs(box_a.width * box_a.height),
                      abs(box_b.width * box_b.height)) or 1.0
        return area if (area > min_area_px and area / smaller > min_fraction) else 0.0

    findings: list[str] = []
    for i, (a, box_a) in enumerate(texts):
        for b, box_b in texts[i + 1:]:
            area = significant(box_a, box_b)
            if area:
                findings.append(f"{a.get_text()[:28]!r} / {b.get_text()[:28]!r} "
                                f"({area:.0f} px²)")
    for text, box in texts:
        for spine, spine_box in spines:
            if text in own_ticks[spine.axes]:
                continue
            area = significant(box, spine_box)
            if area:
                findings.append(f"{text.get_text()[:28]!r} on spine "
                                f"({area:.0f} px²)")

    fig.savefig(path)
    status = "clean" if not findings else f"{len(findings)} OVERLAP FINDING(S)"
    print(f"  wrote {path.name} ({path.stat().st_size // 1024} kB) -- {status}",
          flush=True)
    for finding in findings:
        print(f"    {finding}", flush=True)
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fidelity", type=Path,
                        default=REPO_ROOT / "eval" / "results" / "exp2_fidelity.jsonl")
    parser.add_argument("--hygiene", type=Path,
                        default=REPO_ROOT / "eval" / "results" / "exp2_hygiene.jsonl")
    parser.add_argument("--probes", type=Path,
                        default=REPO_ROOT / "eval" / "results" / "exp2_probes.json")
    parser.add_argument("--figures", type=Path,
                        default=REPO_ROOT / "eval" / "figures")
    args = parser.parse_args(argv)

    style()
    args.figures.mkdir(parents=True, exist_ok=True)

    probes = (json.loads(args.probes.read_text())["probes"]
              if args.probes.exists() else [])

    if args.fidelity.exists():
        _, ok, failed = collect(args.fidelity)
        if ok:
            figure_fidelity(ok, probes, args.figures / "exp2_fidelity.png",
                            len(failed))
    if args.hygiene.exists():
        _, ok, _ = collect(args.hygiene)
        if ok:
            figure_hygiene(ok, args.figures / "exp2_hygiene.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
