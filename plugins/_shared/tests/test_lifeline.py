# test_lifeline.py
# OpenDicomViewer
#
# Covers the parent-death watch of PLUGIN_PROTOCOL.md section 4d: an adapter
# whose host has gone must exit on its own, and one started by hand must not.
# Licensed under the MIT License. See LICENSE for details.
"""Tests for the adapter's host watch."""

from __future__ import annotations

import os
import subprocess
import sys
import textwrap
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from _shared import lifeline  # noqa: E402

PLUGINS_ROOT = Path(__file__).resolve().parents[2]


def test_no_watch_without_the_host_variable(monkeypatch):
    monkeypatch.delenv(lifeline.PARENT_PID_ENV, raising=False)
    assert lifeline.start_parent_watch() is False


def test_garbage_pid_is_ignored(monkeypatch):
    monkeypatch.setenv(lifeline.PARENT_PID_ENV, "not-a-pid")
    assert lifeline.start_parent_watch() is False
    monkeypatch.setenv(lifeline.PARENT_PID_ENV, "1")
    assert lifeline.start_parent_watch() is False


def test_host_alive_tracks_the_parent():
    assert lifeline.host_alive(os.getppid())
    # A pid that cannot exist.
    assert not lifeline.host_alive(2 ** 22 + 12345)


def test_adapter_exits_when_its_host_dies(tmp_path):
    """A stand-in host spawns an 'adapter' and dies; the adapter must follow."""
    pid_file = tmp_path / "adapter.pid"
    adapter = textwrap.dedent(f"""
        import sys, time
        sys.path.insert(0, {str(PLUGINS_ROOT)!r})
        from _shared.lifeline import start_parent_watch
        assert start_parent_watch(interval=0.1)
        open({str(pid_file)!r}, "w").write(str(__import__("os").getpid()))
        time.sleep(60)
    """)
    host = textwrap.dedent(f"""
        import os, subprocess, sys, time
        env = dict(os.environ, ODV_PARENT_PID=str(os.getpid()))
        subprocess.Popen([sys.executable, "-c", {adapter!r}], env=env)
        deadline = time.time() + 20
        while not os.path.exists({str(pid_file)!r}) and time.time() < deadline:
            time.sleep(0.05)
        os._exit(0)  # the host 'crashes' without stopping its adapter
    """)
    subprocess.run([sys.executable, "-c", host], check=True, timeout=30)
    adapter_pid = int(pid_file.read_text())

    deadline = time.time() + 10
    while time.time() < deadline:
        try:
            os.kill(adapter_pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    os.kill(adapter_pid, 9)
    raise AssertionError("the adapter outlived its host")
