# lifeline.py
# OpenDicomViewer
#
# The parent-death watch of PLUGIN_PROTOCOL.md section 4d.
#
# The host stops its adapters on an orderly quit, but a crash, a force quit, or
# a debugger session ending skips that entirely. An adapter that outlives the
# host keeps its model -- several gigabytes of unified memory -- and its port
# with nobody left to talk to, and the next launch's arbiter cannot see it. So
# every adapter process watches the host and exits when it is gone.
#
# The host passes its pid in ODV_PARENT_PID. Two signals are checked: that
# pid no longer existing, and this process having been orphaned (re-parented
# to launchd, pid 1). The second catches the host's pid being reused by an
# unrelated process, which the first alone cannot. Being parented by something
# other than the host is not on its own a reason to exit: a helper an adapter
# spawns inherits the environment, and its parent is the adapter.
# Polling is used rather than a pipe or kqueue because it needs nothing from
# the host beyond an environment variable, works identically for servers,
# one-shots, and install hooks, and costs one syscall a second.
#
# Standard library only, like everything imported at package load.
# Licensed under the MIT License. See LICENSE for details.
"""Exit when the host application that spawned this adapter has gone."""

from __future__ import annotations

import os
import sys
import threading
import time

__all__ = ["PARENT_PID_ENV", "host_alive", "start_parent_watch"]

PARENT_PID_ENV = "ODV_PARENT_PID"

_started = False
_lock = threading.Lock()


def host_alive(parent_pid: int) -> bool:
    """Whether the host with pid `parent_pid` is still running."""
    if os.getppid() == 1:
        return False
    try:
        os.kill(parent_pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # The pid exists but belongs to another user: it has been reused.
        return False
    return True


def start_parent_watch(interval: float = 1.0) -> bool:
    """Start the watch thread if the host asked for one. Idempotent.

    Returns True when a watch is running. Without ODV_PARENT_PID -- an adapter
    started by hand, or by a test -- there is no host to watch and nothing
    happens, so standalone use is unaffected.
    """
    global _started
    raw = os.environ.get(PARENT_PID_ENV, "").strip()
    try:
        parent_pid = int(raw)
    except ValueError:
        return False
    if parent_pid <= 1:
        return False

    with _lock:
        if _started:
            return True
        _started = True

    def watch() -> None:
        while True:
            time.sleep(interval)
            if not host_alive(parent_pid):
                sys.stderr.write(
                    f"ODV host (pid {parent_pid}) has exited; shutting down.\n")
                sys.stderr.flush()
                # os._exit rather than sys.exit: this runs on a daemon thread,
                # where SystemExit only ends the thread, and the main thread may
                # be inside a native call that would not notice anything gentler.
                os._exit(0)

    threading.Thread(target=watch, name="odv-parent-watch", daemon=True).start()
    return True
