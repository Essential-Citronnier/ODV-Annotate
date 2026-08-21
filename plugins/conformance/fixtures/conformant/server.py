#!/usr/bin/env python3
# server.py
# OpenDicomViewer
#
# Conformance-kit fixture: Correct in every respect. The control: any FAIL here is the kit's bug, not an adapter's.
#
# Deliberately broken, one violation class only. Everything else about this
# adapter is conformant, so a FAIL from the kit is attributable to the
# violation and not to the fixture being a stub. Not shipped; absent from the
# app's plugins.json.
#
# Expected kit verdict: every applicable check passes
# Licensed under the MIT License. See LICENSE for details.
"""Fixture adapter: Correct in every respect. The control: any FAIL here is the kit's bug, not an adapter's."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _stub import Defects, run_install, run_oneshot, serve  # noqa: E402

PLUGIN_ID = "stub-conformant"
DEFECTS = Defects()
TASKS = [   {   'id': 'prompt-mask',
        'label': 'Prompt Segmentation',
        'inputs': ['slice2d', 'points', 'box'],
        'outputs': ['mask2d'],
        'license': {'gate': 'open', 'identifier': 'MIT'},
        'weights': [   {   'id': 'stub-weight',
                           'source': 'huggingface',
                           'repo': 'odv/stub',
                           'size_gb': 0.001}]}]


def main(argv: list[str] | None = None) -> int:
    if "--install-weights" in (argv if argv is not None else sys.argv[1:]):
        return run_install(argv if argv is not None else sys.argv[1:], DEFECTS)
    return serve(PLUGIN_ID, TASKS, DEFECTS, argv, session=True)


if __name__ == "__main__":
    sys.exit(main())
