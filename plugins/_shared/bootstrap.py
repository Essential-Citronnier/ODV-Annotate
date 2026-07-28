# bootstrap.py
# OpenDicomViewer
#
# Locates the `plugins/` directory so `_shared` is importable.
#
# The host spawns an adapter as `<venv python> plugins/<id>/<entry>`, which puts
# only `plugins/<id>/` on sys.path -- `_shared` lives one level up. Each adapter
# entry point therefore opens with three lines that prepend the parent
# directory before importing anything shared. This module exists for the code
# that already has `_shared` on the path (the tests, and any tooling that walks
# the adapter tree) and to give that convention one documented home.
# Licensed under the MIT License. See LICENSE for details.
"""Resolve the adapter tree root."""

from __future__ import annotations

import sys
from pathlib import Path

__all__ = ["plugins_root", "adapter_dir", "add_shared_to_path"]


def plugins_root() -> Path:
    """Absolute path to the `plugins/` directory containing this package."""
    return Path(__file__).resolve().parent.parent


def adapter_dir(plugin_dir_name: str) -> Path:
    """Absolute path to one adapter's directory."""
    return plugins_root() / plugin_dir_name


def add_shared_to_path() -> Path:
    """Prepend `plugins/` to sys.path, idempotently. Returns the path added."""
    root = plugins_root()
    text = str(root)
    if text not in sys.path:
        sys.path.insert(0, text)
    return root
