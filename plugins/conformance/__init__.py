# __init__.py
# OpenDicomViewer
#
# The ODV plugin conformance kit.
#
# PLUGIN_PROTOCOL.md is normative but, on its own, unenforced: a third party
# writing an adapter against it discovers whether they succeeded by installing
# it in the host and watching what breaks. This package closes that gap. It
# runs an adapter the way the host does -- spawning the process, driving the
# CLI, speaking the HTTP contract -- and reports check by check what the
# protocol requires and what the adapter actually did.
#
# Standard library only. An adapter author runs this before their plugin's
# environment exists, and a checker that first needed `pip install` would be
# assuming the thing it exists to verify.
# Licensed under the MIT License. See LICENSE for details.
"""Conformance checking for ODV Plugin Protocol v1 adapters."""

from .kit import (
    AdapterUnderTest,
    CheckResult,
    ConformanceReport,
    Status,
    find_manifest,
    run_conformance,
)
from .report import render, render_many, summary_line

__all__ = [
    "AdapterUnderTest",
    "CheckResult",
    "ConformanceReport",
    "Status",
    "find_manifest",
    "render",
    "render_many",
    "run_conformance",
    "summary_line",
]
