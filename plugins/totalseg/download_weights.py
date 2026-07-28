#!/usr/bin/env python3
# download_weights.py
# OpenDicomViewer
#
# Developer convenience wrapper around the section 4b weight install hook.
#
# The host never calls this. Weight acquisition is part of the adapter's entry
# point now (`run_segment.py --install-weights`, PLUGIN_PROTOCOL.md 4b), and
# that is the only implementation -- this file just spells the same call in a
# shorter form for someone installing weights by hand while developing.
#
# It exists rather than being deleted because the shorter form is genuinely
# easier to type, and because a second implementation of the download would be
# the thing worth avoiding, not a second way to invoke the first one.
# Licensed under the MIT License. See LICENSE for details.
"""Install TotalSegmentator weights from a shell, without the host."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import run_segment  # noqa: E402
from _shared.progress import emit_log  # noqa: E402
from _shared.weights import LICENSE_KEY_ENV  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Install TotalSegmentator weights (developer convenience).",
        epilog=("The host uses 'run_segment.py --install-weights ...' directly. "
                f"A licence number is read from {LICENSE_KEY_ENV} in the "
                "environment, never from the command line."),
    )
    parser.add_argument("--task", choices=list(run_segment.TASK_WEIGHTS),
                        help="Task id from the manifest")
    parser.add_argument("--dest", help="Directory the weights land in")
    parser.add_argument("--list", action="store_true", help="List task ids and exit")
    args = parser.parse_args(argv)

    if args.list:
        for task, weight_id in run_segment.TASK_WEIGHTS.items():
            gated = " (needs an academic licence)" \
                if task in run_segment.LICENSE_REQUIRED_TASKS else ""
            emit_log(f"{task}\t{weight_id}{gated}")
        return 0

    if not args.task or not args.dest:
        emit_log("ERROR: --task and --dest are both required (or use --list).")
        return 2

    return run_segment.main([
        "--install-weights",
        "--weight-id", run_segment.TASK_WEIGHTS[args.task],
        "--source", "totalseg-task",
        "--task", args.task,
        "--dest", args.dest,
    ])


if __name__ == "__main__":
    sys.exit(main())
