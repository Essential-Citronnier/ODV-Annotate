#!/usr/bin/env python3
# run_segment.py
# OpenDicomViewer
#
# Conformance-kit fixture: Emits progress lines whose `progress` is a percentage string, not a 0-1 number.
#
# Deliberately broken, one violation class only. Everything else about this
# adapter is conformant, so a FAIL from the kit is attributable to the
# violation and not to the fixture being a stub. Not shipped; absent from the
# app's plugins.json.
#
# Expected kit verdict: FAIL W2 (progress line is not the section 4 format)
# Licensed under the MIT License. See LICENSE for details.
"""Fixture adapter: Emits progress lines whose `progress` is a percentage string, not a 0-1 number."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _stub import Defects, run_install, run_oneshot, serve  # noqa: E402

PLUGIN_ID = "stub-bad-progress"
DEFECTS = Defects(malformed_progress=True)
TASKS = [   {   'id': 'segment',
        'label': 'Segment',
        'inputs': ['series3d'],
        'outputs': ['seg3d', 'metrics'],
        'license': {'gate': 'open', 'identifier': 'MIT'},
        'options': {   'fast': {   'type': 'bool',
                                   'default': True,
                                   'label': 'Fast'}},
        'weights': [   {   'id': 'stub-weight',
                           'source': 'huggingface',
                           'repo': 'odv/stub',
                           'size_gb': 0.001}]}]


def main(argv: list[str] | None = None) -> int:
    if "--install-weights" in (argv if argv is not None else sys.argv[1:]):
        return run_install(argv if argv is not None else sys.argv[1:], DEFECTS)
    return run_oneshot(TASKS, DEFECTS, argv)


if __name__ == "__main__":
    sys.exit(main())
