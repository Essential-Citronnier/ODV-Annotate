# sessions.py
# OpenDicomViewer
#
# Bounded per-image state for `session` adapters (PLUGIN_PROTOCOL.md 1.2).
#
# A cached SAM embedding is tens of megabytes, so an unbounded cache turns the
# adapter's declared `ram_gb` into a lie and the host's arbiter admits work it
# should have refused. The bound is therefore enforced here rather than left to
# the host closing sessions politely: the host does close them on series
# change, but a crashed panel or a lost close request must not leak.
# Licensed under the MIT License. See LICENSE for details.
"""LRU-bounded session cache shared by the SAM-family adapters."""

from __future__ import annotations

import secrets
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Any, Callable

from .protocol import ErrorCode, PluginError

__all__ = ["Session", "SessionStore"]


@dataclass
class Session:
    """One encoded image plus whatever the adapter cached alongside it."""

    id: str
    state: Any
    width: int
    height: int
    created_at: float = field(default_factory=time.monotonic)
    last_used_at: float = field(default_factory=time.monotonic)


class SessionStore:
    """Thread-safe LRU store of at most `max_sessions` sessions.

    Access is serialized because the HTTP server may run handlers on a thread
    pool while the underlying torch model is not reentrant; callers that need
    to hold the model for the duration of a decode use `lock` directly.
    """

    def __init__(
        self,
        max_sessions: int,
        on_evict: Callable[[Session], None] | None = None,
    ) -> None:
        if max_sessions < 1:
            raise ValueError("max_sessions must be at least 1")
        self.max_sessions = max_sessions
        self._on_evict = on_evict
        self._sessions: "OrderedDict[str, Session]" = OrderedDict()
        self.lock = threading.RLock()

    def __len__(self) -> int:
        with self.lock:
            return len(self._sessions)

    @property
    def ids(self) -> list[str]:
        with self.lock:
            return list(self._sessions.keys())

    def open(self, state: Any, width: int, height: int) -> Session:
        """Insert a new session, evicting the least recently used if full."""
        session = Session(id=f"s-{secrets.token_hex(8)}", state=state,
                          width=width, height=height)
        with self.lock:
            self._sessions[session.id] = session
            while len(self._sessions) > self.max_sessions:
                _, evicted = self._sessions.popitem(last=False)
                self._release(evicted)
        return session

    def get(self, session_id: str | None) -> Session:
        """Look up a session and mark it most recently used.

        A miss is `not_ready` rather than `bad_input`: the usual cause is
        eviction or a restarted adapter, and the host's recovery is to reopen
        the session, not to correct the request.
        """
        if not session_id:
            raise PluginError(
                ErrorCode.BAD_INPUT,
                "this task requires a session_id; call /session/open first",
                recoverable=False,
            )
        with self.lock:
            session = self._sessions.get(session_id)
            if session is None:
                raise PluginError(
                    ErrorCode.NOT_READY,
                    f"session {session_id} is not open; it may have been evicted "
                    f"(at most {self.max_sessions} are kept). Reopen the session.",
                )
            self._sessions.move_to_end(session_id)
            session.last_used_at = time.monotonic()
            return session

    def close(self, session_id: str) -> bool:
        """Evict one session. Returns False when it was already gone.

        Closing an unknown session is not an error: the host closes on panel
        teardown, which can race an eviction, and failing that call would
        surface a spurious error to the user.
        """
        with self.lock:
            session = self._sessions.pop(session_id, None)
        if session is None:
            return False
        self._release(session)
        return True

    def close_all(self) -> None:
        with self.lock:
            sessions = list(self._sessions.values())
            self._sessions.clear()
        for session in sessions:
            self._release(session)

    def _release(self, session: Session) -> None:
        if self._on_evict is None:
            return
        try:
            self._on_evict(session)
        except Exception:  # noqa: BLE001 - eviction must never fail a request
            pass
