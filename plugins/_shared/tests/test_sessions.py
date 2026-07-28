# test_sessions.py
# OpenDicomViewer
#
# The eviction bound is what keeps a session adapter inside the `ram_gb` it
# declared to the host's arbiter, so it is tested as a guarantee rather than a
# best effort -- including that eviction actually releases the cached state.
# Licensed under the MIT License. See LICENSE for details.
"""Tests for the bounded LRU session store."""

from __future__ import annotations

import sys
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from _shared.protocol import ErrorCode, PluginError  # noqa: E402
from _shared.sessions import SessionStore  # noqa: E402


def test_open_returns_a_distinct_id_each_time():
    store = SessionStore(max_sessions=4)
    ids = {store.open(object(), 512, 512).id for _ in range(8)}
    assert len(ids) == 8
    assert all(i.startswith("s-") for i in ids)


def test_store_never_exceeds_its_bound():
    store = SessionStore(max_sessions=4)
    for _ in range(20):
        store.open(object(), 512, 512)
        assert len(store) <= 4
    assert len(store) == 4


def test_eviction_is_least_recently_used_not_oldest():
    """Touching a session protects it; the untouched one goes."""
    store = SessionStore(max_sessions=2)
    first = store.open("a", 8, 8)
    second = store.open("b", 8, 8)

    store.get(first.id)          # first is now the most recently used
    third = store.open("c", 8, 8)  # evicts second

    assert store.get(first.id).state == "a"
    assert store.get(third.id).state == "c"
    with pytest.raises(PluginError):
        store.get(second.id)


def test_eviction_runs_the_release_callback():
    released: list[str] = []
    store = SessionStore(max_sessions=1, on_evict=lambda s: released.append(s.state))
    store.open("first", 8, 8)
    store.open("second", 8, 8)
    assert released == ["first"]


def test_a_failing_release_callback_does_not_fail_the_request():
    """Freeing cached state is best effort; a request must not die with it."""
    def explode(_session):
        raise RuntimeError("free failed")

    store = SessionStore(max_sessions=1, on_evict=explode)
    store.open("first", 8, 8)
    session = store.open("second", 8, 8)
    assert store.get(session.id).state == "second"


def test_missing_session_is_not_ready_with_a_recoverable_hint():
    """Eviction is the usual cause, and reopening is the fix, so it is recoverable."""
    store = SessionStore(max_sessions=2)
    with pytest.raises(PluginError) as info:
        store.get("s-does-not-exist")
    assert info.value.code is ErrorCode.NOT_READY
    assert info.value.recoverable is True


def test_absent_session_id_is_bad_input_not_not_ready():
    """A request with no session_id is malformed, not a lost session."""
    store = SessionStore(max_sessions=2)
    with pytest.raises(PluginError) as info:
        store.get(None)
    assert info.value.code is ErrorCode.BAD_INPUT


def test_close_is_idempotent():
    store = SessionStore(max_sessions=2)
    session = store.open("a", 8, 8)
    assert store.close(session.id) is True
    assert store.close(session.id) is False


def test_close_all_releases_everything():
    released: list[str] = []
    store = SessionStore(max_sessions=4, on_evict=lambda s: released.append(s.state))
    for name in "abc":
        store.open(name, 8, 8)
    store.close_all()
    assert len(store) == 0
    assert sorted(released) == ["a", "b", "c"]


def test_concurrent_opens_respect_the_bound():
    """The bound holds under the threadpool the HTTP layer dispatches on."""
    store = SessionStore(max_sessions=4)
    barrier = threading.Barrier(8)

    def worker():
        barrier.wait()
        for _ in range(10):
            store.open(object(), 64, 64)

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(store) == 4


def test_max_sessions_must_be_positive():
    with pytest.raises(ValueError):
        SessionStore(max_sessions=0)
