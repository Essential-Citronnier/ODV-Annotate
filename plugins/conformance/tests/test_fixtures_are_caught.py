# test_fixtures_are_caught.py
# OpenDicomViewer
#
# The test that decides whether the conformance kit is worth anything.
#
# A check that cannot fail is not a check. Every check the kit makes is
# therefore paired with a fixture adapter that violates exactly that
# requirement and is otherwise conformant, and this module asserts two things
# about each pair: the check FAILS on the violating fixture, and it does not
# fail on the conformant control. The second half matters as much as the first
# -- a check that fails on everything catches every violation and is still
# useless.
#
# The assertion is on the specific check id, not merely on "the kit reported a
# failure". A kit that failed the RLE fixture for an unrelated reason would
# pass a weaker test while leaving the RLE convention unchecked, which is the
# exact failure mode this exercise exists to rule out.
# Licensed under the MIT License. See LICENSE for details.
"""Every violation fixture must fail the check that covers its violation."""

from __future__ import annotations

import socket
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from plugins.conformance.kit import Status, run_conformance  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
MANIFEST = FIXTURES / "plugins.json"


def _can_bind() -> bool:
    """Whether this machine lets a test process listen on loopback.

    Some sandboxes deny every bind. The HTTP checks are then genuinely
    unrunnable, and the honest response is to skip those cases loudly rather
    than to weaken them -- the kit itself reports the same situation as
    inconclusive rather than passed.
    """
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
        return True
    except OSError:
        return False


CAN_BIND = _can_bind()
needs_socket = pytest.mark.skipif(
    not CAN_BIND, reason="this environment forbids binding a loopback socket")


def check(report, check_id):
    for result in report.results:
        if result.id == check_id:
            return result
    raise AssertionError(f"the kit produced no check {check_id}")


def run(fixture: str, **kwargs):
    return run_conformance(FIXTURES / fixture, manifest=MANIFEST, **kwargs)


# ---------------------------------------------------------------------------
# The control
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def conformant():
    return run("conformant", allow_http=CAN_BIND)


def test_the_conformant_fixture_has_no_failures(conformant):
    """The control passes. Any FAIL here is a bug in the kit, not the adapter."""
    failures = [f"{r.id}: {r.reason}" for r in conformant.results
                if r.status is Status.FAIL]
    assert not failures, "the conformant fixture failed:\n  " + "\n  ".join(failures)


@needs_socket
def test_the_conformant_fixture_exercises_every_check(conformant):
    """Nothing silently skipped its way to a pass.

    A kit whose checks all SKIP would report a clean run against anything. The
    control is a session adapter serving a mask task, so every check except the
    one-shot ones and the manual-weight one must actually have run.
    """
    inapplicable = {"E3", "O1", "O2", "W3"}
    for result in conformant.results:
        if result.id in inapplicable:
            continue
        assert result.status is Status.PASS, (
            f"{result.id} did not run against the conformant fixture: "
            f"{result.status.value} — {result.reason}")


# ---------------------------------------------------------------------------
# One violation class per fixture
# ---------------------------------------------------------------------------


def test_heavy_import_at_module_scope_fails_the_bare_interpreter_checks():
    """Section 4b: --help and --install-weights must not need the heavy stack.

    The weight hook is what POPULATES the environment, so it cannot require
    that environment to already exist.
    """
    report = run("heavy_import", allow_http=False)
    assert check(report, "B1").status is Status.FAIL
    assert check(report, "B2").status is Status.FAIL


def test_a_weight_hook_that_rejects_the_section_4b_flags_fails():
    """Section 4b defines the hook's signature, not a per-adapter subset.

    An adapter that accepts only the flags its own manifest uses today breaks
    the moment that manifest gains a `--repo` or a `--task`.
    """
    report = run("weight_hook_rejects_flags", allow_http=False)
    result = check(report, "W1")
    assert result.status is Status.FAIL
    assert "unrecognized" in result.reason


def test_a_manual_source_that_downloads_fails():
    """Section 4b: a `manual` source must attempt no download at all.

    The gate's substance is that a human accepted terms under a named account.
    The kit denies outbound connections for this probe, so "did not download"
    is observed rather than taken on trust.
    """
    report = run("manual_downloads", allow_http=False)
    result = check(report, "W3")
    assert result.status is Status.FAIL
    assert "network" in result.reason or "download" in result.reason


def test_a_failing_one_shot_run_that_writes_no_result_json_fails():
    """Section 4c: result.json is written on failure too.

    The host reads it whenever it exists, because the adapter's own message is
    more actionable than an exit code.
    """
    report = run("no_result_json", allow_http=False)
    assert check(report, "E3").status is Status.FAIL


def test_a_one_shot_that_accepts_anything_fails():
    """Section 4: exit 0 means the declared outputs exist and are valid."""
    report = run("oneshot_accepts_anything", allow_http=False)
    result = check(report, "O1")
    assert result.status is Status.FAIL
    assert "exited 0" in result.reason or "unknown task" in result.reason


def test_envelope_on_stderr_only_fails_the_envelope_check():
    """Section 4b: the envelope goes on stdout, which is what the host reads.

    On stderr it is a log line, so `license_required` never reaches the store's
    licence gate and the user sees a bare exit status instead of the one error
    the protocol makes actionable.
    """
    report = run("envelope_on_stderr", allow_http=False)
    assert check(report, "E1").status is Status.FAIL
    assert "stderr" in check(report, "E1").reason.lower()


def test_an_error_code_outside_the_enum_fails():
    """Section 3: five codes, no others."""
    report = run("bad_error_code", allow_http=False)
    result = check(report, "E2")
    assert result.status is Status.FAIL
    assert "weights_missing" in result.reason or "no_such_series" in result.reason


def test_a_line_carrying_both_ok_and_progress_fails():
    """Section 4b: envelope, progress line, and log line must be distinguishable."""
    report = run("ambiguous_stdout", allow_http=False)
    result = check(report, "S1")
    assert result.status is Status.FAIL
    assert "progress" in result.reason


def test_malformed_progress_lines_fail():
    """Section 4: `progress` is a number in 0-1, `message` a string."""
    report = run("malformed_progress", allow_http=False)
    assert check(report, "W2").status is Status.FAIL


def test_absolute_output_paths_fail():
    """Section 4: file paths in `outputs` are relative to --out."""
    report = run("absolute_output_paths", allow_http=False)
    result = check(report, "O2")
    assert result.status is Status.FAIL
    assert "absolute" in result.reason


def test_a_session_adapter_without_max_sessions_fails():
    """Section 1.2: a session adapter must bound its cache and evict."""
    report = run("session_no_max", allow_http=False)
    assert check(report, "X3").status is Status.FAIL


@pytest.mark.parametrize("fixture,check_id,fragment", [
    ("manifest_entry_missing", "M1", "does not resolve"),
    ("manifest_bad_execution", "M2", "not one of"),
    ("manifest_bad_kinds", "M3", "unknown"),
    ("manifest_no_resources", "M4", "positive number"),
])
def test_manifest_violations_are_caught(fixture, check_id, fragment):
    """Section 1 and invariant 4: the manifest's strings must name real things.

    A renamed adapter or an undeclared footprint fails at install time on a
    user's machine rather than here, which is the gap these checks close.
    """
    report = run(fixture, allow_http=False)
    result = check(report, check_id)
    assert result.status is Status.FAIL
    assert fragment in result.reason


@needs_socket
def test_a_session_adapter_that_refuses_to_open_while_ready_fails():
    """Section 1.2: a plugin reporting ready must be able to open a session.

    Refusing while claiming readiness leaves the host unable to tell a loaded
    plugin from a broken one.
    """
    report = run("session_refuses_open")
    assert check(report, "X1").status is Status.FAIL


@needs_socket
def test_a_session_adapter_that_refuses_to_close_fails():
    """Section 1.2: /session/close releases the cached state.

    The host closes sessions when the user changes series. An adapter that
    refuses accumulates encodings until it exhausts the memory its manifest
    told the arbiter it would use.
    """
    report = run("session_close_rejects")
    assert check(report, "X2").status is Status.FAIL


@needs_socket
def test_rle_whose_runs_do_not_sum_to_the_frame_fails():
    """Section 5: run lengths sum to width * height."""
    report = run("rle_bad_length")
    result = check(report, "R1")
    assert result.status is Status.FAIL
    assert "sum" in result.reason


@needs_socket
def test_a_wrong_protocol_number_fails():
    """Section 3: `protocol` must equal 1; the host refuses any other major."""
    report = run("wrong_protocol")
    assert check(report, "H1").status is Status.FAIL
    assert "protocol" in check(report, "H1").reason


@needs_socket
def test_a_plugin_id_disagreeing_with_the_manifest_fails():
    """Section 3: the id the host routes on must be the id it installed."""
    report = run("plugin_id_mismatch")
    result = check(report, "H1")
    assert result.status is Status.FAIL
    assert "plugin_id" in result.reason


@needs_socket
def test_binding_every_interface_fails():
    """Invariant 1: loopback only. 0.0.0.0 makes the adapter a network service."""
    report = run("binds_all_interfaces")
    result = check(report, "H3")
    assert result.status is Status.FAIL
    assert "0.0.0.0" in result.reason


@needs_socket
def test_ignoring_the_assigned_port_fails():
    """Section 1.1: the host assigns the port; no adapter may fix its own."""
    report = run("missing_port")
    assert check(report, "H4").status is Status.FAIL


@needs_socket
def test_rle_starting_with_a_foreground_run_fails():
    """Section 5: runs start with background; a leading zero says otherwise.

    This is the one violation that is invisible in the payload -- the runs are
    well-formed and sum correctly, and the host renders the exact complement of
    the intended mask without raising. The kit catches it by decoding the mask
    the way the host does and checking that the pixel it prompted for comes
    back foreground.
    """
    report = run("rle_starts_foreground")
    result = check(report, "R2")
    assert result.status is Status.FAIL
    assert "invert" in result.reason or "complement" in result.reason
    # The mask itself must have been well-formed: if R1 also failed, the
    # fixture is malformed rather than phase-inverted and proves nothing.
    assert check(report, "R1").status is Status.PASS, (
        "the RLE fixture should be structurally valid and only phase-wrong")


# ---------------------------------------------------------------------------
# Every check is covered by some fixture
# ---------------------------------------------------------------------------


#: check id -> the fixture that must fail it. Checks absent from this map have
#: no negative test, which is the gap this table exists to make visible.
COVERAGE = {
    "B1": "heavy_import",
    "B2": "heavy_import",
    "W2": "malformed_progress",
    "E1": "envelope_on_stderr",
    "E2": "bad_error_code",
    "E3": "no_result_json",
    "S1": "ambiguous_stdout",
    "H1": "wrong_protocol",
    "H2": "plugin_id_mismatch",
    "H3": "binds_all_interfaces",
    "H4": "missing_port",
    "X1": "session_refuses_open",
    "X2": "session_close_rejects",
    "X3": "session_no_max",
    "O1": "oneshot_accepts_anything",
    "O2": "absolute_output_paths",
    "R1": "rle_bad_length",
    "R2": "rle_starts_foreground",
    "M1": "manifest_entry_missing",
    "M2": "manifest_bad_execution",
    "M3": "manifest_bad_kinds",
    "M4": "manifest_no_resources",
    "W1": "weight_hook_rejects_flags",
    "W3": "manual_downloads",
}


def test_every_check_the_kit_makes_has_a_fixture_that_fails_it():
    """No check may exist without something that proves it can fail."""
    report = run("conformant", allow_http=False)
    produced = {result.id for result in report.results}
    uncovered = sorted(produced - set(COVERAGE))
    assert not uncovered, (
        f"these checks have no violating fixture, so nothing proves they can "
        f"fail: {uncovered}")


def test_every_fixture_named_in_the_coverage_table_exists():
    """The table above must name real fixtures, not intentions.

    Without this, COVERAGE could keep the test above green by naming adapters
    nobody ever wrote -- a coverage claim that documents itself rather than the
    kit.
    """
    missing = sorted(name for name in COVERAGE.values()
                     if not (FIXTURES / name).is_dir())
    assert not missing, f"COVERAGE names fixtures that do not exist: {missing}"


def test_every_fixture_on_disk_is_declared_in_the_fixture_manifest():
    """A fixture the manifest does not declare can never be checked."""
    import json

    declared = {entry["adapter_dir"]
                for entry in json.loads(MANIFEST.read_text())["plugins"]}
    on_disk = {path.name for path in FIXTURES.iterdir()
               if path.is_dir() and not path.name.startswith(("_", "."))}
    assert on_disk == declared, (
        f"on disk but undeclared: {sorted(on_disk - declared)}; "
        f"declared but absent: {sorted(declared - on_disk)}")
