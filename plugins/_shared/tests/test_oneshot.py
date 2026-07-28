# test_oneshot.py
# OpenDicomViewer
#
# The one-shot contract has two failure modes the host cannot recover from and
# cannot diagnose: a run that fails without writing result.json, and a run that
# exits 0 while its declared output file is absent. Both are covered here.
# Licensed under the MIT License. See LICENSE for details.
"""Tests for the one-shot CLI harness."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from _shared.oneshot import (  # noqa: E402
    OneShotResult,
    option_bool,
    parse_oneshot_args,
    run_oneshot,
)
from _shared.protocol import ErrorCode, PluginError  # noqa: E402


def _args(tmp_path, task="seg", extra=None):
    return parse_oneshot_args(
        "test", tasks=["seg"], options={"fast": "bool", "level": "number"},
        argv=["--task", task, "--out", str(tmp_path)] + (extra or []),
    )


def _result(tmp_path) -> dict:
    return json.loads((tmp_path / "result.json").read_text())


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def test_input_flags_follow_the_kind_names(tmp_path):
    args = _args(tmp_path, extra=["--input-series3d", "/data/series",
                                  "--input-text", "CT, chest"])
    assert args.input_series3d == "/data/series"
    assert args.input_text == "CT, chest"


def test_option_flags_are_prefixed_and_typed(tmp_path):
    args = _args(tmp_path, extra=["--opt-fast", "false", "--opt-level", "2.5"])
    assert option_bool(args, "fast", default=True) is False
    assert args.opt_level == 2.5


def test_option_bool_defaults_when_the_flag_is_absent(tmp_path):
    assert option_bool(_args(tmp_path), "fast", default=True) is True


def test_an_unknown_task_is_refused_at_parse_time(tmp_path):
    with pytest.raises(SystemExit):
        _args(tmp_path, task="nope")


# ---------------------------------------------------------------------------
# Result writing
# ---------------------------------------------------------------------------


def test_success_writes_the_result_envelope(tmp_path):
    def pipeline(args, out_dir, reporter):
        (out_dir / "segmentation.dcm").write_bytes(b"DICM")
        return OneShotResult(outputs={"seg3d": "segmentation.dcm",
                                      "metrics": {"liver_volume_ml": 1129.87}})

    assert run_oneshot(_args(tmp_path), pipeline) == 0
    body = _result(tmp_path)
    assert body["ok"] is True
    assert body["outputs"]["seg3d"] == "segmentation.dcm"
    assert body["outputs"]["metrics"]["liver_volume_ml"] == 1129.87
    assert isinstance(body["elapsed_ms"], int)


def test_a_plugin_error_still_writes_result_json(tmp_path):
    """A failed run must leave the host something to show the user."""
    def pipeline(args, out_dir, reporter):
        raise PluginError(ErrorCode.LICENSE_REQUIRED, "register a licence number")

    assert run_oneshot(_args(tmp_path), pipeline) == 1
    body = _result(tmp_path)
    assert body["ok"] is False
    assert body["error"]["code"] == "license_required"


def test_an_unexpected_exception_becomes_an_internal_envelope(tmp_path):
    def pipeline(args, out_dir, reporter):
        raise ValueError("something went sideways")

    assert run_oneshot(_args(tmp_path), pipeline) == 1
    body = _result(tmp_path)
    assert body["error"]["code"] == "internal"
    assert "ValueError" in body["error"]["message"]


def test_a_missing_declared_output_file_fails_the_run(tmp_path):
    """Exit 0 means the declared files exist; a silent non-write must not pass.

    Otherwise the host reports success and then fails to open a SEG that was
    never written, with nothing explaining why.
    """
    def pipeline(args, out_dir, reporter):
        return OneShotResult(outputs={"seg3d": "segmentation.dcm"})

    assert run_oneshot(_args(tmp_path), pipeline) == 1
    body = _result(tmp_path)
    assert body["ok"] is False
    assert "segmentation.dcm" in body["error"]["message"]


def test_an_absolute_output_path_is_rejected(tmp_path):
    """Paths in `outputs` are relative to --out (protocol section 4)."""
    target = tmp_path / "segmentation.dcm"
    target.write_bytes(b"DICM")

    def pipeline(args, out_dir, reporter):
        return OneShotResult(outputs={"seg3d": str(target)})

    assert run_oneshot(_args(tmp_path), pipeline) == 1
    assert "relative" in _result(tmp_path)["error"]["message"]


def test_the_output_directory_is_created(tmp_path):
    out = tmp_path / "nested" / "run"
    args = parse_oneshot_args("test", tasks=["seg"],
                              argv=["--task", "seg", "--out", str(out)])
    assert run_oneshot(args, lambda a, d, r: OneShotResult()) == 0
    assert (out / "result.json").is_file()


def test_interruption_is_reported_as_recoverable(tmp_path):
    def pipeline(args, out_dir, reporter):
        raise KeyboardInterrupt

    assert run_oneshot(_args(tmp_path), pipeline) == 130
    assert _result(tmp_path)["error"]["recoverable"] is True


# ---------------------------------------------------------------------------
# Progress
# ---------------------------------------------------------------------------


def test_progress_lines_are_json_objects_one_per_line(tmp_path, capsys):
    def pipeline(args, out_dir, reporter):
        reporter.stage(0.0, 0.8, "Running segmentation")
        reporter.within(0.5, "Halfway")
        reporter.log("a plain log line")
        return OneShotResult()

    run_oneshot(_args(tmp_path), pipeline)
    lines = capsys.readouterr().out.strip().splitlines()

    parsed = []
    for line in lines:
        try:
            parsed.append(json.loads(line))
        except json.JSONDecodeError:
            # Non-JSON lines are log lines by design, not a protocol violation.
            continue

    assert {"progress", "message"} <= set(parsed[0])
    assert parsed[0]["progress"] == 0.0
    # within(0.5) of the span [0.0, 0.8] is 0.4, not 0.5: stages map onto a
    # slice of the overall bar so it advances roughly with wall time.
    assert parsed[1]["progress"] == pytest.approx(0.4)
    assert parsed[-1]["progress"] == 1.0
    assert all(0.0 <= item["progress"] <= 1.0 for item in parsed)


def test_progress_is_clamped_to_the_unit_interval(tmp_path, capsys):
    def pipeline(args, out_dir, reporter):
        reporter.stage(0.0, 1.0, "Working")
        reporter.within(5.0, "Overshoot")
        return OneShotResult()

    run_oneshot(_args(tmp_path), pipeline)
    values = [json.loads(line)["progress"]
              for line in capsys.readouterr().out.strip().splitlines()
              if line.startswith("{")]
    assert max(values) == 1.0
