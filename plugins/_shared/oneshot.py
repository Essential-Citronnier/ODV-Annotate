# oneshot.py
# OpenDicomViewer
#
# The CLI surface of PLUGIN_PROTOCOL.md section 4, built once so a one-shot
# adapter only writes its pipeline.
#
# Two contract details are easy to get wrong and are handled here rather than
# per adapter: `result.json` must be written on failure as well as success, and
# paths inside `outputs` are relative to `--out`. A failed run that leaves no
# result.json gives the host an exit code and nothing to show the user.
# Licensed under the MIT License. See LICENSE for details.
"""Argument parsing, result writing, and failure handling for one-shot adapters."""

from __future__ import annotations

import argparse
import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from .progress import ProgressReporter, emit_log
from .protocol import ErrorCode, PluginError, error_payload

__all__ = ["OneShotResult", "parse_oneshot_args", "run_oneshot"]

# Input and option flags arrive as `--input-<kind>` and `--opt-<name>`, so the
# parser is built from the declared kinds rather than hand-listed per adapter.
_INPUT_KINDS = ("slice2d", "series3d", "roi", "points", "box", "text")


@dataclass
class OneShotResult:
    """What a one-shot pipeline returns.

    `outputs` file paths must be relative to `--out`; the caller writes files
    into the output directory and records the bare filename.
    """

    outputs: dict[str, Any] = field(default_factory=dict)


def parse_oneshot_args(
    description: str,
    tasks: Sequence[str],
    options: Mapping[str, str] | None = None,
    argv: Sequence[str] | None = None,
) -> argparse.Namespace:
    """Parse the CLI the host spawns a one-shot adapter with.

    `options` maps an option name to one of "bool", "number", or "string",
    mirroring the manifest's option types; each becomes `--opt-<name>`.
    """
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--task", required=True, choices=list(tasks),
                        help="Task id from the manifest")
    parser.add_argument("--out", required=True,
                        help="Output directory; result.json is written here")
    for kind in _INPUT_KINDS:
        parser.add_argument(f"--input-{kind}", dest=f"input_{kind}", default=None,
                            help=argparse.SUPPRESS)
    for name, kind in (options or {}).items():
        flag = f"--opt-{name}"
        dest = f"opt_{name.replace('-', '_')}"
        if kind == "bool":
            # Declared as a value flag, not store_true: the host passes
            # `--opt-fast true`, mirroring how it renders every other option.
            parser.add_argument(flag, dest=dest, default=None,
                                help=f"Option '{name}' (true/false)")
        elif kind == "number":
            parser.add_argument(flag, dest=dest, type=float, default=None,
                                help=f"Option '{name}' (number)")
        else:
            parser.add_argument(flag, dest=dest, default=None,
                                help=f"Option '{name}'")
    return parser.parse_args(argv)


def option_bool(args: argparse.Namespace, name: str, default: bool) -> bool:
    """Read a `--opt-<name>` flag parsed as a string."""
    raw = getattr(args, f"opt_{name.replace('-', '_')}", None)
    if raw is None:
        return default
    if isinstance(raw, bool):
        return raw
    return str(raw).strip().lower() in ("1", "true", "yes", "on")


def run_oneshot(
    args: argparse.Namespace,
    pipeline: Callable[[argparse.Namespace, Path, ProgressReporter], OneShotResult],
) -> int:
    """Run `pipeline`, write `<out>/result.json`, and return the exit code.

    The pipeline receives the parsed arguments, the resolved output directory,
    and a progress reporter. It raises `PluginError` for anything it can
    describe in protocol terms; anything else becomes `internal`.
    """
    started = time.perf_counter()
    out_dir = Path(args.out).expanduser().resolve()
    reporter = ProgressReporter()

    try:
        out_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        # No output directory means nowhere to write result.json, so this is
        # the one failure that can only be reported on stderr and the exit code.
        emit_log(f"ERROR: cannot create output directory {out_dir}: {exc}")
        return 1

    result_path = out_dir / "result.json"

    def write(payload: Mapping[str, Any]) -> None:
        result_path.write_text(json.dumps(payload, indent=2) + "\n")

    try:
        result = pipeline(args, out_dir, reporter)
    except PluginError as exc:
        emit_log(f"ERROR: {exc.message}")
        write(exc.to_payload())
        return 1
    except KeyboardInterrupt:
        emit_log("ERROR: interrupted")
        write(error_payload(ErrorCode.INTERNAL, "Interrupted", recoverable=True))
        return 130
    except BaseException as exc:  # noqa: BLE001 - the host needs a result.json
        message = f"{type(exc).__name__}: {exc}"
        emit_log(f"ERROR: {message}")
        write(error_payload(ErrorCode.INTERNAL, message, recoverable=False))
        return 1

    missing = _missing_output_files(result.outputs, out_dir)
    if missing:
        message = ("the pipeline reported success but these declared output "
                   f"files are absent: {', '.join(missing)}")
        emit_log(f"ERROR: {message}")
        write(error_payload(ErrorCode.INTERNAL, message, recoverable=False))
        return 1

    elapsed_ms = int(round((time.perf_counter() - started) * 1000.0))
    write({"ok": True, "outputs": result.outputs, "elapsed_ms": elapsed_ms})
    reporter.done("Complete")
    emit_log(f"Wrote {result_path}")
    return 0


def _missing_output_files(outputs: Mapping[str, Any], out_dir: Path) -> list[str]:
    """Check that path-valued outputs actually exist.

    Exit code 0 means the declared output files exist and are valid, so a
    pipeline that silently failed to write its SEG must not be reported as a
    success the host then fails to open.
    """
    missing: list[str] = []
    for kind, value in outputs.items():
        if kind not in ("seg3d",) or not isinstance(value, str):
            continue
        if os.path.isabs(value):
            missing.append(f"{kind} must be relative to --out, got {value}")
        elif not (out_dir / value).exists():
            missing.append(f"{kind} -> {value}")
    return missing
