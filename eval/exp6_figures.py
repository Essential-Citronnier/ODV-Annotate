#!/usr/bin/env python3
"""Figure 5 and the numbers §3.6 quotes, from exp6_latency_<machine>.jsonl.

    PYTHONPATH=eval python eval/exp6_figures.py [--results PATH] [--all]

Only cases whose idle gate was met are used unless --all is passed. Prints a
JSON summary (also written beside the JSONL as *_paper.json) so that every
number in the manuscript can carry a pointer to it.

Definitions, chosen to be what a user waits for:
- time to first result (server engines): spawn to ready, plus the first
  request after ready. For SAM that first request is the first session open,
  which carries the model load (the adapter reports ready before loading),
  plus the first click.
- warm request: any request after the first one of its cycle.
- one-shot: subprocess wall time per run, and the adapter's own stage times.
"""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

ENGINE_LABELS = {"gemma-builtin": "Gemma (built-in server)",
                 "gemma-4-e4b": "Gemma 4 E4B plugin",
                 "sam2": "SAM 2 plugin",
                 "sam3": "SAM 3 plugin"}


def describe(values: list[float]) -> dict:
    if not values:
        return {"n": 0}
    values = sorted(values)
    if len(values) > 1:
        q1, _, q3 = statistics.quantiles(values, n=4, method="inclusive")
    else:
        q1 = q3 = values[0]
    return {"n": len(values), "median": round(statistics.median(values), 3),
            "q1": round(q1, 3), "q3": round(q3, 3),
            "min": round(values[0], 3), "max": round(values[-1], 3)}


def load(path: Path, gated_only: bool) -> tuple[dict, list[dict]]:
    lines = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    header, rows = lines[0], lines[1:]
    rows = [r for r in rows if r.get("ok")]
    if gated_only:
        rows = [r for r in rows if r["metrics"].get("idle_gate", {}).get("met")]
    return header, rows


def server_samples(engine: str, rows: list[dict]) -> tuple[list[float], list[float], dict]:
    """(spawn-to-ready s, time-to-first-result s, warm ms by request kind).

    SAM on MPS: the adapter's encode returns once the work is queued, and the
    queue drains in the session's first click (first click ~50 ms, later
    clicks ~11 ms). So the user-facing encode is session open plus first
    click, and the decode is every later click; `server_encode_ms` is not used.
    """
    ready, first_result, warm = [], [], {}
    for r in [r for r in rows if r["case_id"].startswith(engine + "/c")]:
        m = r["metrics"]
        ready.append(m["spawn_to_ready_s"])
        reqs = m["requests"]
        if engine.startswith("sam"):
            opens = [q for q in reqs if q["kind"] == "session_open"]
            prompts = [q for q in reqs if q["kind"] == "prompt"]
            for index, opened in enumerate(opens):
                clicks = [q for q in prompts if q["slice"] == opened["slice"]]
                encode_ms = opened["client_ms"] + clicks[0]["client_ms"]
                if index == 0:
                    first_result.append(m["spawn_to_ready_s"] + encode_ms / 1000)
                else:
                    warm.setdefault("open + first click (encode)", []).append(encode_ms)
                warm.setdefault("later click (decode)", []).extend(
                    q["client_ms"] for q in clicks[1:])
        else:
            first_result.append(m["spawn_to_ready_s"] + reqs[0]["client_ms"] / 1000)
            for q in reqs[1:]:
                warm.setdefault(q["task"], []).append(q["client_ms"])
    return ready, first_result, warm


def server_summary(rows: list[dict]) -> dict:
    out: dict = {}
    for engine in ENGINE_LABELS:
        ready, first_result, warm = server_samples(engine, rows)
        if not ready:
            continue
        out[engine] = {"cycles": len(ready),
                       "spawn_to_ready_s": describe(ready),
                       "time_to_first_result_s": describe(first_result),
                       "warm_request_ms": {k: describe(v) for k, v in warm.items()}}
    return out


def oneshot_summary(rows: list[dict]) -> dict:
    out: dict = {}
    for task in ("total", "total_lowmem"):
        runs = [r for r in rows if r["case_id"].startswith(f"totalsegmentator/{task}/")]
        if not runs:
            continue
        stages: dict[str, list[float]] = {}
        gaps = []
        for r in runs:
            for k, v in (r.get("stages_s") or {}).items():
                stages.setdefault(k, []).append(v)
            adapter = r["metrics"].get("adapter_elapsed_ms")
            if adapter is not None:
                gaps.append(r["wall_s"] - adapter / 1000)
        series = sorted({r["metrics"]["series"] for r in runs})
        out[task] = {"runs": len(runs), "series": series,
                     "wall_s": describe([r["wall_s"] for r in runs]),
                     "outside_adapter_s": describe(gaps),
                     "stages_s": {k: describe(v) for k, v in stages.items()},
                     "wall_s_by_series": {s: describe([r["wall_s"] for r in runs
                                                       if r["metrics"]["series"] == s])
                                          for s in series}}
    if "total" in out and "total_lowmem" in out:
        ratios = []
        for s in out["total"]["series"]:
            a = out["total"]["wall_s_by_series"].get(s, {}).get("median")
            b = out["total_lowmem"]["wall_s_by_series"].get(s, {}).get("median")
            if a and b:
                ratios.append(round(b / a, 3))
        out["lowmem_over_total_by_series"] = ratios
    return out


def figure(summary: dict, rows: list[dict], path: Path) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams.update({"font.size": 7, "axes.spines.top": False,
                         "axes.spines.right": False})
    fig = plt.figure(figsize=(7.2, 5.4), dpi=300)
    grid = fig.add_gridspec(2, 2, height_ratios=[1, 1.35], hspace=0.55, wspace=0.55)
    ax_a, ax_c, ax_b = (fig.add_subplot(grid[0, 0]), fig.add_subplot(grid[0, 1]),
                        fig.add_subplot(grid[1, :]))
    dark = "#1f3a5f"
    box = dict(orientation="horizontal", widths=0.5, medianprops={"color": dark, "linewidth": 1.2},
               flierprops={"markersize": 2})
    short = {"gemma-builtin": "Gemma, built-in server", "gemma-4-e4b": "Gemma 4 E4B plugin",
             "sam2": "SAM 2 plugin", "sam3": "SAM 3 plugin"}
    engines = [e for e in ENGINE_LABELS if e in summary["servers"]]

    # A: cold start to first result
    ax_a.boxplot([server_samples(e, rows)[1] for e in engines], **box)
    ax_a.set_yticks(range(1, len(engines) + 1), [short[e] for e in engines])
    ax_a.set_xlabel("New process to first result (s)")
    ax_a.set_xlim(left=0)
    ax_a.set_title("A  Cold start", loc="left", fontweight="bold")

    # B: warm requests
    labels, data = [], []
    for e in engines:
        for kind, values in server_samples(e, rows)[2].items():
            labels.append(f"{short[e]} · {kind}")
            data.append(values)
    ax_b.boxplot(data, **box)
    ax_b.set_xscale("log")
    ax_b.set_yticks(range(1, len(labels) + 1), labels)
    ax_b.set_xlabel("Warm request, client-side (ms, log scale)")
    ax_b.set_title("B  Warm requests", loc="left", fontweight="bold")

    # C: one-shot stages, median per task
    tasks = [t for t in ("total", "total_lowmem") if t in summary["oneshot"]]
    order = ["startup_to_first_progress", "Checking model environment",
             "Running segmentation", "Measuring structures", "Writing DICOM SEG",
             "Complete"]
    names = {"startup_to_first_progress": "start-up", "Checking model environment": "env check",
             "Running segmentation": "segmentation", "Measuring structures": "volumes",
             "Writing DICOM SEG": "SEG export", "Complete": "finish"}
    shades = ["#d0d4d9", "#b4bac2", dark, "#6b7b8f", "#4a5d75", "#e4e7ea"]
    for i, task in enumerate(tasks):
        left = 0.0
        for stage, shade in zip(order, shades):
            median = summary["oneshot"][task]["stages_s"].get(stage, {}).get("median")
            if not median:
                continue
            ax_c.barh(i, median, left=left, color=shade, edgecolor="white",
                      linewidth=0.4, label=names[stage] if i == 0 else None)
            left += median
        wall = summary["oneshot"][task]["wall_s"]["median"]
        ax_c.plot([wall], [i], marker="|", color="black", markersize=12)
    ax_c.set_yticks(range(len(tasks)), [f"TotalSegmentator\n{t}" for t in tasks])
    ax_c.set_xlabel("Median per run (s); bar = adapter stages, | = process wall")
    ax_c.legend(fontsize=6, frameon=False, ncol=3, loc="upper center",
                bbox_to_anchor=(0.5, -0.32))
    ax_c.set_title("C  One-shot segmentation", loc="left", fontweight="bold")

    fig.savefig(path, dpi=300, bbox_inches="tight")


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", type=Path,
                        default=repo / "eval/results/exp6_latency_apple-m5-max-128-gb.jsonl")
    parser.add_argument("--all", action="store_true",
                        help="Include cases whose idle gate was not met")
    parser.add_argument("--figure", type=Path,
                        default=repo / "eval/figures/exp6_latency.png")
    args = parser.parse_args()

    header, rows = load(args.results, gated_only=not args.all)
    summary = {"machine": header["machine"].get("chip") + " / "
                          + header["machine"].get("memory_reported", ""),
               "gated_only": not args.all,
               "servers": server_summary(rows),
               "oneshot": oneshot_summary(rows)}
    out = args.results.with_name(args.results.stem + "_paper.json")
    out.write_text(json.dumps(summary, indent=2) + "\n")
    figure(summary, rows, args.figure)
    print(json.dumps(summary, indent=2))
    print(f"wrote {out} and {args.figure}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
