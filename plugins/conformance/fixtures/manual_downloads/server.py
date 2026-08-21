#!/usr/bin/env python3
# server.py
# OpenDicomViewer
#
# Conformance-kit fixture: A `manual` weight source attempts a download instead of verifying a locally placed checkpoint.
#
# Deliberately broken, one violation class only. Everything else about this
# adapter is conformant, so a FAIL from the kit is attributable to the
# violation and not to the fixture being a stub. Not shipped; absent from the
# app's plugins.json.
#
# Expected kit verdict: FAIL W3 (a manual source attempted a download)
# Licensed under the MIT License. See LICENSE for details.
"""Fixture adapter: A `manual` weight source attempts a download instead of verifying a locally placed checkpoint."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _stub import Defects, run_install, run_oneshot, serve  # noqa: E402

PLUGIN_ID = "stub-manual-fetch"
DEFECTS = Defects(manual_downloads=True)
TASKS = [   {   'id': 'prompt-mask',
        'label': 'Prompt Segmentation',
        'inputs': ['slice2d', 'points', 'box'],
        'outputs': ['mask2d'],
        'license': {   'gate': 'gated-download',
                       'identifier': 'Stub License',
                       'terms_url': 'https://example.invalid/terms'},
        'weights': [   {   'id': 'stub-weight',
                           'source': 'manual',
                           'repo': 'odv/stub',
                           'filename': 'stub-checkpoint.pt',
                           'size_gb': 0.001}]}]


def main(argv: list[str] | None = None) -> int:
    if "--install-weights" in (argv if argv is not None else sys.argv[1:]):
        return run_install(argv if argv is not None else sys.argv[1:], DEFECTS, manual=True)
    return serve(PLUGIN_ID, TASKS, DEFECTS, argv, session=True)


if __name__ == "__main__":
    sys.exit(main())
