#!/usr/bin/env python3
# server.py
# OpenDicomViewer
#
# Conformance-kit fixture: Imports torch at module scope, so --help and --install-weights need the environment the hook is meant to populate.
#
# Deliberately broken, one violation class only. Everything else about this
# adapter is conformant, so a FAIL from the kit is attributable to the
# violation and not to the fixture being a stub. Not shipped; absent from the
# app's plugins.json.
#
# Expected kit verdict: FAIL B1 and B2 (torch at module scope)
# Licensed under the MIT License. See LICENSE for details.
"""Fixture adapter: Imports torch at module scope, so --help and --install-weights need the environment the hook is meant to populate."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# THE VIOLATION: a heavy dependency at module scope. Section 4b requires
# `--help` and `--install-weights` to work on a bare interpreter, because the
# weight hook is what populates the environment -- it cannot require that
# environment to already exist. This import runs before argument parsing, so
# both modes die on an interpreter that has no torch.
import torch  # noqa: F401,E402

from _stub import Defects, run_install, run_oneshot, serve  # noqa: E402

PLUGIN_ID = "stub-heavy-import"
DEFECTS = Defects()
TASKS = [   {   'id': 'analyze',
        'label': 'Analyze',
        'inputs': ['slice2d', 'text'],
        'outputs': ['text', 'bbox'],
        'license': {'gate': 'open', 'identifier': 'MIT'},
        'weights': [   {   'id': 'stub-weight',
                           'source': 'huggingface',
                           'repo': 'odv/stub',
                           'size_gb': 0.001}]}]


def main(argv: list[str] | None = None) -> int:
    if "--install-weights" in (argv if argv is not None else sys.argv[1:]):
        return run_install(argv if argv is not None else sys.argv[1:], DEFECTS)
    return serve(PLUGIN_ID, TASKS, DEFECTS, argv, session=False)


if __name__ == "__main__":
    sys.exit(main())
