# bench.py
# OpenDicomViewer
#
# Self-measurement mode for adapters (`--bench`).
#
# The numbers an evaluation reports about a plugin should come from the plugin,
# not from a stopwatch held outside it. An external timer around a whole
# process cannot separate interpreter startup from weight load from inference,
# and on a resident adapter it cannot see inside the server at all. So each
# adapter grows one extra CLI mode that runs its own pipeline once, times the
# stages from the inside, and reports them.
#
# The mode deliberately reuses two shapes the protocol already defines rather
# than inventing a third. Stage boundaries are announced as PLUGIN_PROTOCOL.md
# section 4 progress lines, so a host log of a bench run is indistinguishable
# from a log of real work. The final line is the section 3/4 result envelope
# with the timings under the `metrics` output kind, which is the vocabulary the
# protocol already has for "inline JSON object of scalar values".
#
# Peak RSS is deliberately NOT measured here. A process cannot observe its own
# high-water mark after the fact without sampling, and a sampler misses spikes;
# the caller reads it from the kernel's accounting for the exited child
# instead. What this module reports is the process's own resident size at each
# stage boundary, which is the shape of the memory curve rather than its peak.
# Licensed under the MIT License. See LICENSE for details.
"""Stage timing and metric emission for the adapters' `--bench` mode."""

from __future__ import annotations

import argparse
import json
import os
import resource
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Sequence

from .progress import ProgressReporter, emit_progress
from .protocol import ErrorCode, PluginError, TaskRequest, error_payload

__all__ = [
    "BENCH_FLAG",
    "Bench",
    "TimingReporter",
    "bench_arg_present",
    "emit_bench_failure",
    "parse_bench_args",
    "run_oneshot_bench",
    "run_resident_bench",
    "run_sam_bench",
]

BENCH_FLAG = "--bench"


def bench_arg_present(argv: Sequence[str] | None = None) -> bool:
    """Whether this invocation is the benchmark mode.

    Checked before the adapter's normal parsing, exactly like
    `--install-weights`: the bench CLI shares no required flags with the server
    or one-shot CLIs and would otherwise be rejected by them.
    """
    return BENCH_FLAG in (list(argv) if argv is not None else sys.argv[1:])


def parse_bench_args(description: str,
                     argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the bench CLI.

    `--input-slice2d` and `--input-series3d` are spelled as in section 4 so a
    bench invocation reads like an ordinary one-shot invocation.
    """
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(BENCH_FLAG, action="store_true", required=True,
                        help="Measure this adapter's own stage timings")
    parser.add_argument("--input-slice2d", dest="input_slice2d", default=None,
                        help="Path to a PNG slice to run inference on")
    parser.add_argument("--input-series3d", dest="input_series3d", default=None,
                        help="Path to a DICOM series directory")
    parser.add_argument("--task", default=None, help="Task id from the manifest")
    parser.add_argument("--repeat", type=int, default=1,
                        help="Inference repetitions after the first")
    parser.add_argument("--out", default=None,
                        help="Directory for any files the run produces")
    parser.add_argument("--opt-fast", dest="opt_fast", default=None,
                        help="Option 'fast' (true/false), for one-shot adapters")
    return parser.parse_args(argv)


def _self_rss_bytes() -> int:
    """This process's high-water resident size, in bytes.

    getrusage reports bytes on Darwin and kilobytes on Linux; the same
    correction the shared eval harness applies to child processes.
    """
    raw = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(raw) if sys.platform == "darwin" else int(raw) * 1024


class Bench:
    """Times named stages and emits the protocol's progress and result shapes.

    A stage is announced as a progress line when it begins, so a bench run
    streams like real work, and its duration plus the process's resident size
    at its end are accumulated for the final envelope.
    """

    def __init__(self, plugin_id: str, stream: Any = None) -> None:
        self.plugin_id = plugin_id
        self._stream = stream or sys.stdout
        self._started = time.perf_counter()
        self.stages_s: dict[str, float] = {}
        self.rss_after_stage: dict[str, int] = {}
        self.metrics: dict[str, Any] = {}
        self._order: list[str] = []
        self._announced = 0.0

    @contextmanager
    def stage(self, name: str, message: str | None = None,
              progress: float | None = None) -> Iterator[None]:
        """Time one stage, announcing it as a section 4 progress line."""
        if progress is not None:
            self._announced = max(0.0, min(1.0, progress))
        emit_progress(self._announced, message or name, self._stream)
        t0 = time.perf_counter()
        try:
            yield
        finally:
            elapsed = time.perf_counter() - t0
            self.stages_s[name] = self.stages_s.get(name, 0.0) + elapsed
            self.rss_after_stage[name] = _self_rss_bytes()
            if name not in self._order:
                self._order.append(name)

    def metric(self, name: str, value: Any) -> None:
        self.metrics[name] = value

    def envelope(self) -> dict:
        """The section 3/4 success envelope carrying the timings as metrics."""
        elapsed_ms = int(round((time.perf_counter() - self._started) * 1000.0))
        metrics: dict[str, Any] = dict(self.metrics)
        metrics["stage_order"] = list(self._order)
        for name, seconds in self.stages_s.items():
            metrics[f"stage_s.{name}"] = round(seconds, 6)
        for name, rss in self.rss_after_stage.items():
            metrics[f"rss_after_bytes.{name}"] = rss
        metrics["self_peak_rss_bytes"] = _self_rss_bytes()
        return {"ok": True, "outputs": {"metrics": metrics},
                "elapsed_ms": elapsed_ms}

    def emit(self) -> int:
        """Write the envelope as one line and return the process exit code."""
        emit_progress(1.0, "Benchmark complete", self._stream)
        self._stream.write(json.dumps(self.envelope()) + "\n")
        self._stream.flush()
        return 0


def emit_bench_failure(exc: BaseException, stream: Any = None,
                       bench: "Bench | None" = None,
                       partial: dict | None = None) -> int:
    """Write the section 3 error envelope for a bench run that could not finish.

    A bench that cannot run is a result, not an absence: an adapter whose model
    will not load in a given environment is exactly what the evaluation needs
    recorded, so the failure travels in the same envelope as a success.

    Stages that completed before the failure are attached under `partial`. A
    pipeline that segments correctly and then fails while writing its output
    has still produced a real measurement of the segmentation, and discarding
    it would throw away the expensive part of the run.
    """
    out = stream or sys.stdout
    if isinstance(exc, PluginError):
        payload = exc.to_payload()
    else:
        payload = error_payload(ErrorCode.INTERNAL,
                                f"{type(exc).__name__}: {exc}", recoverable=False)

    measured = dict(partial or {})
    if bench is not None:
        for name, seconds in bench.stages_s.items():
            measured[f"stage_s.{name}"] = round(seconds, 6)
        for name, rss in bench.rss_after_stage.items():
            measured[f"rss_after_bytes.{name}"] = rss
        measured.update(bench.metrics)
        measured["self_peak_rss_bytes"] = _self_rss_bytes()
    if measured:
        payload["partial"] = measured

    out.write(json.dumps(payload) + "\n")
    out.flush()
    return 1


class TimingReporter(ProgressReporter):
    """A `ProgressReporter` that also records how long each stage took.

    One-shot adapters already narrate themselves in stages through the
    reporter, so a bench of a one-shot pipeline needs no new instrumentation in
    the pipeline itself -- only a reporter that keeps the clock.
    """

    def __init__(self, stream: Any = None) -> None:
        super().__init__(stream)
        self.stages_s: dict[str, float] = {}
        self.rss_after_stage: dict[str, int] = {}
        self.order: list[str] = []
        self._current: str | None = None
        self._entered_at: float | None = None

    def _close_current(self) -> None:
        if self._current is not None and self._entered_at is not None:
            elapsed = time.perf_counter() - self._entered_at
            self.stages_s[self._current] = self.stages_s.get(self._current, 0.0) + elapsed
            self.rss_after_stage[self._current] = _self_rss_bytes()

    def stage(self, start: float, end: float, message: str) -> "TimingReporter":
        self._close_current()
        self._current = message
        if message not in self.order:
            self.order.append(message)
        self._entered_at = time.perf_counter()
        super().stage(start, end, message)
        return self

    def done(self, message: str = "Done") -> None:
        self._close_current()
        self._current = None
        self._entered_at = None
        super().done(message)


# ---------------------------------------------------------------------------
# one-shot bench
# ---------------------------------------------------------------------------


def run_oneshot_bench(plugin_id: str, pipeline, args_for_pipeline,
                      argv: Sequence[str] | None = None) -> int:
    """Run a one-shot pipeline once, timing the stages it already announces.

    A one-shot adapter narrates itself through a `ProgressReporter`
    (PLUGIN_PROTOCOL.md section 4), so benchmarking one needs no new
    instrumentation inside the pipeline: substituting a reporter that keeps the
    clock turns the stage boundaries the adapter already emits into
    measurements. That keeps the timings attributable to the adapter's own
    structure rather than to a decomposition invented by the evaluation.
    """
    args = parse_bench_args(f"{plugin_id} benchmark.", argv)
    bench = Bench(plugin_id)
    reporter = TimingReporter()

    try:
        out_dir = Path(args.out or ".").expanduser().resolve()
        out_dir.mkdir(parents=True, exist_ok=True)

        pipeline_args = args_for_pipeline(args)
        t0 = time.perf_counter()
        result = pipeline(pipeline_args, out_dir, reporter)
        total_s = time.perf_counter() - t0
        reporter.done("Complete")

        bench.stages_s.update(reporter.stages_s)
        bench.rss_after_stage.update(reporter.rss_after_stage)
        bench._order.extend(name for name in reporter.order
                            if name not in bench._order)
        bench.metric("pipeline_s", round(total_s, 6))
        bench.metric("task_id", getattr(pipeline_args, "task", None))

        outputs = dict(result.outputs)
        metrics = outputs.get("metrics")
        if isinstance(metrics, dict):
            for key in ("structure_count",):
                if key in metrics:
                    bench.metric(key, metrics[key])
        for kind, value in outputs.items():
            if kind == "metrics" or not isinstance(value, str):
                continue
            path = out_dir / value
            if path.exists():
                bench.metric(f"output_bytes.{kind}", path.stat().st_size)
        bench.metric("output_kinds", sorted(outputs))
    except BaseException as exc:  # noqa: BLE001 - a failed bench is a recorded result
        partial = {f"stage_s.{name}": round(value, 6)
                   for name, value in reporter.stages_s.items()}
        partial.update({f"rss_after_bytes.{name}": value
                        for name, value in reporter.rss_after_stage.items()})
        return emit_bench_failure(exc, bench=bench, partial=partial)

    return bench.emit()


# ---------------------------------------------------------------------------
# resident-server bench
# ---------------------------------------------------------------------------


def run_resident_bench(plugin_id: str, build_adapter, load,
                       argv: Sequence[str] | None = None) -> int:
    """Load a resident adapter's model and run one task through it.

    `load` is the adapter's own weight-loading entry point, kept separate from
    `build_adapter` because a `resident-server` loads on startup rather than on
    first use (PLUGIN_PROTOCOL.md section 1.1) -- and the split between load
    cost and per-request cost is precisely what distinguishes that execution
    model from the others.
    """
    import base64

    args = parse_bench_args(f"{plugin_id} benchmark.", argv)
    bench = Bench(plugin_id)

    try:
        if not args.input_slice2d:
            raise PluginError(ErrorCode.BAD_INPUT,
                              "--input-slice2d is required to benchmark this adapter",
                              recoverable=False)
        slice_path = Path(args.input_slice2d).expanduser().resolve()
        if not slice_path.is_file():
            raise PluginError(ErrorCode.BAD_INPUT,
                              f"no slice image at {slice_path}", recoverable=False)

        with bench.stage("build", "Building the adapter", 0.05):
            adapter = build_adapter()

        with bench.stage("model_load", "Loading model weights", 0.15):
            load(adapter)

        status, detail, memory_mb = adapter.health()
        bench.metric("health_status", status)
        bench.metric("health_detail", detail)
        if memory_mb is not None:
            bench.metric("health_memory_mb", round(float(memory_mb), 1))
        if status != "ready":
            raise PluginError(
                ErrorCode.NOT_READY,
                f"the adapter reported '{status}' after loading: {detail}",
                recoverable=False)

        encoded = base64.b64encode(slice_path.read_bytes()).decode("ascii")
        task_id = args.task or adapter.tasks()[0].id
        body = {"inputs": {"slice2d": encoded, "text": "CT"}}

        repeats = max(1, int(args.repeat))
        inference_ms: list[float] = []
        outputs: dict = {}
        for index in range(repeats):
            with bench.stage("inference", f"Running task '{task_id}'",
                             0.3 + 0.6 * index / repeats):
                request = TaskRequest(body)
                t0 = time.perf_counter()
                outputs = adapter.run_task(task_id, request)
                inference_ms.append((time.perf_counter() - t0) * 1000.0)

        bench.metric("task_id", task_id)
        bench.metric("repeats", repeats)
        bench.metric("inference_ms_first", round(inference_ms[0], 3))
        bench.metric("inference_ms_mean",
                     round(sum(inference_ms) / len(inference_ms), 3))
        bench.metric("output_kinds", sorted(outputs))
        if isinstance(outputs.get("text"), str):
            bench.metric("output_text_chars", len(outputs["text"]))
    except BaseException as exc:  # noqa: BLE001 - a failed bench is a recorded result
        return emit_bench_failure(exc, bench=bench)

    return bench.emit()


# ---------------------------------------------------------------------------
# SAM family bench
# ---------------------------------------------------------------------------


def run_sam_bench(plugin_id: str, build_adapter, argv: Sequence[str] | None = None) -> int:
    """Load a SAM-family backend, encode one slice, and decode prompts from it.

    Encode and decode are separated because the ratio between them is the whole
    justification for the `session` execution model (PLUGIN_PROTOCOL.md section
    1.2): if decoding were not far cheaper than encoding, caching the embedding
    would buy nothing and the plugin should be a plain resident server.
    """
    args = parse_bench_args(f"{plugin_id} benchmark.", argv)
    bench = Bench(plugin_id)

    try:
        if not args.input_slice2d:
            raise PluginError(ErrorCode.BAD_INPUT,
                              "--input-slice2d is required to benchmark this adapter",
                              recoverable=False)
        slice_path = Path(args.input_slice2d).expanduser().resolve()
        if not slice_path.is_file():
            raise PluginError(ErrorCode.BAD_INPUT,
                              f"no slice image at {slice_path}", recoverable=False)

        with bench.stage("import", "Importing the inference stack", 0.05):
            from .sam_session import decode_png, select_device

        adapter = build_adapter()

        with bench.stage("model_load", "Loading model weights", 0.15):
            adapter.backend.ensure_loaded()
        bench.metric("device", select_device())

        image_bytes = slice_path.read_bytes()
        with bench.stage("decode_input", "Decoding the input slice", 0.35):
            image = decode_png(image_bytes)
        bench.metric("image_width", image.size[0])
        bench.metric("image_height", image.size[1])

        repeats = max(1, int(args.repeat))
        encode_ms: list[float] = []
        state = None
        for index in range(repeats):
            with bench.stage("encode", "Encoding the slice", 0.4 + 0.2 * index / repeats):
                t0 = time.perf_counter()
                state = adapter.backend.encode(image)
                encode_ms.append((time.perf_counter() - t0) * 1000.0)

        # A centre click is the prompt the interactive tool issues most often,
        # and it exercises the decoder on a real embedding rather than a stub.
        width, height = image.size
        point = [(width // 2, height // 2, 1)]
        decode_ms: list[float] = []
        for index in range(repeats):
            with bench.stage("decode", "Decoding a mask from a click",
                             0.6 + 0.3 * index / repeats):
                t0 = time.perf_counter()
                candidates = adapter.backend.decode(state, point, None, None, False)
                decode_ms.append((time.perf_counter() - t0) * 1000.0)

        with bench.stage("rle", "Encoding the mask as RLE", 0.95):
            from .rle import mask2d_payload

            payload = mask2d_payload(candidates[0][0], label=None,
                                     confidence=candidates[0][1])

        bench.metric("repeats", repeats)
        bench.metric("encode_ms_first", round(encode_ms[0], 3))
        bench.metric("encode_ms_mean", round(sum(encode_ms) / len(encode_ms), 3))
        bench.metric("decode_ms_first", round(decode_ms[0], 3))
        bench.metric("decode_ms_mean", round(sum(decode_ms) / len(decode_ms), 3))
        bench.metric("encode_decode_ratio",
                     round((sum(encode_ms) / len(encode_ms))
                           / max(1e-9, sum(decode_ms) / len(decode_ms)), 3))
        bench.metric("mask_runs", len(payload["rle"]))
        bench.metric("mask_foreground_px",
                     int(sum(payload["rle"][1::2])))
        bench.metric("max_sessions", adapter.sessions.max_sessions
                     if hasattr(adapter.sessions, "max_sessions") else None)
    except BaseException as exc:  # noqa: BLE001 - a failed bench is a recorded result
        return emit_bench_failure(exc, bench=bench)

    return bench.emit()
