#!/usr/bin/env python3
# download_weights.py
# OpenDicomViewer
#
# Weight fetcher for the `totalseg-task` weight source declared in plugins.json.
#
# The store calls this during the `downloading` state of the install lifecycle
# (PLUGIN_PROTOCOL.md section 7). It is the only network activity this plugin
# performs, and it moves weights only -- invariant 3.
#
# The official `totalseg_download_weights` console script is invoked as a
# subprocess rather than importing TotalSegmentator's internals, whose module
# paths move between releases while the script's interface has not.
# Licensed under the MIT License. See LICENSE for details.
"""Download TotalSegmentator weights for one task."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _shared.progress import emit_log, emit_progress  # noqa: E402

# Task ids as the manifest declares them.
TASKS = {
    "total": "Whole-body structures at 3 mm",
    "heartchambers_highres": "Cardiac chambers and myocardium at full resolution",
}

LICENSE_REQUIRED_TASKS = {"heartchambers_highres"}
LICENSE_URL = "https://backend.totalsegmentator.com/license-academic/"


def _home() -> Path:
    return Path(os.environ.get("TOTALSEG_HOME_DIR", Path.home() / ".totalsegmentator"))


def _license_registered() -> bool:
    config = _home() / "config.json"
    if not config.is_file():
        return False
    try:
        return bool(json.loads(config.read_text()).get("license_number"))
    except (OSError, ValueError):
        return False


def _download_script() -> str | None:
    """Locate `totalseg_download_weights`, preferring this venv's copy."""
    candidate = Path(sys.executable).with_name("totalseg_download_weights")
    if candidate.exists():
        return str(candidate)
    return shutil.which("totalseg_download_weights")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Download TotalSegmentator task weights.")
    parser.add_argument("--task", choices=list(TASKS), help="Task id from the manifest")
    parser.add_argument("--list", action="store_true", help="List task ids and exit")
    parser.add_argument("--set-license", metavar="NUMBER",
                        help="Register an academic licence number with TotalSegmentator")
    args = parser.parse_args(argv)

    if args.list:
        for task, label in TASKS.items():
            emit_log(f"{task}\t{label}")
        return 0

    if args.set_license:
        # The number is handed to TotalSegmentator's own tool, which owns the
        # config file. It is never echoed here: the store treats it as a secret
        # and this process's stdout goes to the plugin log view.
        setter = Path(sys.executable).with_name("totalseg_set_license")
        exe = str(setter) if setter.exists() else shutil.which("totalseg_set_license")
        if exe is None:
            emit_log("ERROR: totalseg_set_license not found in this environment.")
            return 1
        code = subprocess.call([exe, "-l", args.set_license])
        emit_log("Licence registered." if code == 0 else
                 f"ERROR: registering the licence failed (exit {code}).")
        return code

    if not args.task:
        emit_log("ERROR: --task is required (or use --list).")
        return 2

    if args.task in LICENSE_REQUIRED_TASKS and not _license_registered():
        emit_log(f"ERROR: '{args.task}' requires a free academic licence number.")
        emit_log(f"Request one at {LICENSE_URL}, then run this with --set-license.")
        return 1

    exe = _download_script()
    if exe is None:
        emit_log("ERROR: totalseg_download_weights not found. Is TotalSegmentator "
                 "installed in this plugin's environment?")
        return 1

    emit_progress(0.05, f"Downloading weights for '{args.task}' (weights only)")
    # The downloader reports its own progress in a format the host does not
    # parse, so the bar moves on stage boundaries rather than pretending to
    # track bytes.
    code = subprocess.call([exe, "-t", args.task])
    if code != 0:
        emit_log(f"ERROR: weight download exited with code {code}.")
        if args.task in LICENSE_REQUIRED_TASKS:
            emit_log(f"If this is a licence rejection, register a number: {LICENSE_URL}")
        return code

    emit_progress(1.0, f"Weights for '{args.task}' are ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
