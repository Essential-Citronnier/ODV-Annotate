# cli.py
# OpenDicomViewer
#
# Argument parsing for resident and session adapters, kept apart from the
# server itself so that reaching it costs nothing.
#
# This lives here rather than in `serve` because `serve` must import fastapi at
# module scope -- FastAPI resolves route annotations through module globals,
# and under `from __future__ import annotations` a function-local import is
# invisible at resolution time, which silently reinterprets request bodies as
# query parameters. That constraint is real but it should not reach the
# adapters: `--help` and `--install-weights` are the modes the host uses to
# probe an adapter and to populate its environment, so they must work on a bare
# interpreter, before the web stack exists. Splitting the parser out is what
# lets an adapter dispatch on arguments and only then import what it needs.
# Licensed under the MIT License. See LICENSE for details.
"""Stdlib-only CLI parsing for the resident and session execution models."""

from __future__ import annotations

import argparse
from typing import Sequence

__all__ = ["parse_server_args"]


def parse_server_args(description: str, argv: Sequence[str] | None = None):
    """Parse the CLI the host spawns a resident or session adapter with.

    `--port` is required: the host assigns it, and no adapter may fall back to
    a fixed port of its own.
    """
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--port", type=int, required=True,
                        help="TCP port on 127.0.0.1 assigned by the host")
    parser.add_argument("--host", default="127.0.0.1",
                        help=argparse.SUPPRESS)  # loopback only; present for tests
    parser.add_argument("--log-level", default="info")
    return parser.parse_args(argv)
