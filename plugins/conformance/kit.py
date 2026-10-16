# kit.py
# OpenDicomViewer
#
# The ODV plugin conformance kit: does this adapter implement PLUGIN_PROTOCOL.md?
#
# The protocol document is normative but unenforced, which means a third party
# writing an adapter against it finds out whether they succeeded by installing
# it in the host and watching what breaks. This module is the answer to that:
# it runs an adapter the way the host does and reports, check by check, what
# the protocol requires and what the adapter did.
#
# Two design rules run through everything here.
#
# Behaviour, never documentation. PluginAdapterLayoutTests.swift records what
# happens otherwise: `--install-weights` is dispatched to a separate parser
# before the main one, so it is absent from `--help` while working perfectly,
# and four checks that asserted on the help text failed against four correct
# adapters. Nothing in this file reads an adapter's source.
#
# A missing dependency is not a reason to skip. SKIP means the check does not
# apply to this adapter -- a session check on a one-shot, an RLE check on a
# plugin that emits no masks. Where the protocol says a mode must work without
# the heavy stack (section 4b), the kit blocks those imports in the child
# process and a failure there is a FAIL, not an excuse.
# Licensed under the MIT License. See LICENSE for details.
"""Protocol v1 conformance checks, executed against a running adapter."""

from __future__ import annotations

import base64
import json
import os
import shutil
import sys
import tempfile
import time
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from .probe import (
    ERROR_CODES,
    EXECUTION_MODELS,
    HEAVY_MODULES,
    INPUT_KINDS,
    NETWORK_MODULES,
    OUTPUT_KINDS,
    VIOLATION_MARKER,
    Invocation,
    ServerProcess,
    Stdout,
    classify_stdout,
    decode_rle,
    free_port,
    invoke,
    is_loopback,
    iter_masks,
    listening_addresses,
    make_png,
    non_loopback_addresses,
)

__all__ = [
    "Status",
    "CheckResult",
    "ConformanceReport",
    "AdapterUnderTest",
    "run_conformance",
    "find_manifest",
]

PROTOCOL_VERSION = 1

# A 64x64 probe slice with a bright block at pixels (8,8)-(40,40). The prompt
# point below sits at its centre, which is what makes the RLE phase check
# model-independent: whatever a segmenter returns for a click, the clicked
# pixel must come back foreground.
_PROBE_SIZE = 64
_PROMPT_XY = (0.375, 0.375)
_PROBE_BOX = {"x": 0.125, "y": 0.125, "width": 0.5, "height": 0.5}


def _probe_slice_png() -> bytes:
    def shade(x: int, y: int) -> tuple[int, int, int]:
        bright = 8 <= x < 40 and 8 <= y < 40
        return (230, 230, 230) if bright else (24, 24, 28)

    return make_png(_PROBE_SIZE, _PROBE_SIZE, shade)


class Status(str, Enum):
    """A check outcome.

    ERROR is deliberately distinct from FAIL. FAIL is a statement about the
    adapter; ERROR says the kit could not obtain the evidence -- no way to
    enumerate listening sockets, no interpreter to probe with. Both exit
    non-zero, because a check that did not run has not passed, but conflating
    them would let an environment problem read as an adapter defect.
    """

    PASS = "PASS"
    FAIL = "FAIL"
    SKIP = "SKIP"
    ERROR = "ERROR"


@dataclass
class CheckResult:
    id: str
    title: str
    section: str
    status: Status
    reason: str = ""
    detail: dict = field(default_factory=dict)

    def to_json(self) -> dict:
        payload = {"id": self.id, "title": self.title, "section": self.section,
                   "status": self.status.value, "reason": self.reason}
        if self.detail:
            payload["detail"] = self.detail
        return payload


@dataclass
class ConformanceReport:
    adapter_dir: str
    plugin_id: str | None
    execution: str | None
    manifest: str | None
    results: list[CheckResult] = field(default_factory=list)
    started_at: str = ""
    duration_s: float = 0.0

    def counts(self) -> dict[str, int]:
        out = {status.value: 0 for status in Status}
        for result in self.results:
            out[result.status.value] += 1
        return out

    @property
    def passed(self) -> bool:
        return not any(result.status in (Status.FAIL, Status.ERROR)
                       for result in self.results)

    def to_json(self) -> dict:
        return {
            "adapter_dir": self.adapter_dir,
            "plugin_id": self.plugin_id,
            "execution": self.execution,
            "manifest": self.manifest,
            "protocol": PROTOCOL_VERSION,
            "started_at": self.started_at,
            "duration_s": round(self.duration_s, 2),
            "counts": self.counts(),
            "passed": self.passed,
            "checks": [result.to_json() for result in self.results],
        }


# ---------------------------------------------------------------------------
# Manifest resolution
# ---------------------------------------------------------------------------


def find_manifest(adapter_dir: Path) -> Path | None:
    """Locate the manifest that should declare `adapter_dir`.

    The host ships one manifest inside the app bundle, so the kit looks for
    that first by walking up to the repository root. A manifest sitting beside
    the adapter tree is the fallback, which is what lets the kit's own fixture
    adapters be checked without being declared in the shipping manifest.
    """
    resolved = adapter_dir.resolve()
    beside = resolved.parent / "plugins.json"
    for parent in [resolved, *resolved.parents]:
        candidate = parent / "Sources/OpenDicomViewer/Resources/plugins.json"
        if candidate.is_file():
            # A manifest beside the adapter wins when it actually declares it:
            # fixtures live under plugins/ too and must not be looked up in the
            # shipping manifest, where they are correctly absent.
            if beside.is_file() and _declares(beside, resolved.name):
                return beside
            return candidate
    return beside if beside.is_file() else None


def _declares(manifest: Path, adapter_dir_name: str) -> bool:
    try:
        data = json.loads(manifest.read_text())
    except (OSError, ValueError):
        return False
    return any(entry.get("adapter_dir") == adapter_dir_name
               for entry in data.get("plugins", []))


# ---------------------------------------------------------------------------
# The adapter under test
# ---------------------------------------------------------------------------


@dataclass
class AdapterUnderTest:
    directory: Path
    plugins_root: Path
    manifest_path: Path
    descriptor: dict
    python: str
    bare_python: str

    @property
    def plugin_id(self) -> str:
        return str(self.descriptor.get("id", ""))

    @property
    def execution(self) -> str:
        return str(self.descriptor.get("execution", ""))

    @property
    def entry(self) -> str:
        return str(self.descriptor.get("entry", ""))

    @property
    def tasks(self) -> list[dict]:
        return [task for task in self.descriptor.get("tasks", []) if isinstance(task, dict)]

    @property
    def is_server(self) -> bool:
        return self.execution in ("resident-server", "session")

    @property
    def is_session(self) -> bool:
        return self.execution == "session"

    @property
    def is_oneshot(self) -> bool:
        return self.execution == "one-shot"

    def weights(self) -> list[dict]:
        out: list[dict] = []
        for task in self.tasks:
            for weight in task.get("weights", []) or []:
                if isinstance(weight, dict):
                    out.append({**weight, "_task": task.get("id")})
        return out

    def declares_output(self, kind: str) -> bool:
        return any(kind in (task.get("outputs") or []) for task in self.tasks)


class Checker:
    """Runs every applicable check and accumulates results.

    Every adapter invocation goes through `self._run`, which keeps the captured
    stdout for the line-discipline check. That check is cross-cutting by
    nature: ambiguity between a progress line and an error envelope is only
    visible across everything the adapter emitted, not within one run.
    """

    def __init__(self, adapter: AdapterUnderTest, *, timeout: float = 120.0,
                 health_timeout: float = 90.0, allow_http: bool = True) -> None:
        self.adapter = adapter
        self.timeout = timeout
        self.health_timeout = health_timeout
        self.allow_http = allow_http
        self.results: list[CheckResult] = []
        self.invocations: list[tuple[str, Invocation]] = []
        self.masks: list[tuple[str, dict]] = []
        self._mask_skip_reason: str | None = None
        self._health_body: dict | None = None

    # -- bookkeeping -------------------------------------------------------

    def record(self, check_id: str, title: str, section: str, status: Status,
               reason: str = "", **detail: Any) -> CheckResult:
        result = CheckResult(id=check_id, title=title, section=section,
                             status=status, reason=reason, detail=detail)
        self.results.append(result)
        return result

    def _run(self, label: str, args: Sequence[str], *,
             python: str | None = None,
             blocked: Sequence[str] | None = None,
             deny_network: bool = False,
             extra_env: Mapping[str, str] | None = None,
             timeout: float | None = None) -> Invocation:
        result = invoke(
            python or self.adapter.python,
            self.adapter.entry,
            args,
            cwd=self.adapter.directory,
            plugins_root=self.adapter.plugins_root,
            timeout=timeout or self.timeout,
            extra_env=extra_env,
            blocked_modules=blocked,
            deny_network=deny_network,
        )
        self.invocations.append((label, result))
        return result

    # =====================================================================
    # 1. Manifest agreement
    # =====================================================================

    def check_manifest(self) -> bool:
        """Section 0/1: the manifest's strings must name real, valid things."""
        adapter = self.adapter
        descriptor = adapter.descriptor
        problems: list[str] = []

        if not adapter.plugin_id:
            problems.append("no `id`")
        declared_dir = descriptor.get("adapter_dir")
        if declared_dir != adapter.directory.name:
            problems.append(
                f"`adapter_dir` is {declared_dir!r} but the adapter lives in "
                f"{adapter.directory.name!r}")
        entry_path = adapter.directory / adapter.entry
        if not adapter.entry:
            problems.append("no `entry`")
        elif not entry_path.is_file():
            problems.append(f"`entry` does not resolve to a file: {entry_path}")
        requirements = descriptor.get("requirements")
        if not requirements:
            problems.append("no `requirements`")
        elif not (adapter.directory / str(requirements)).is_file():
            problems.append(
                f"`requirements` does not resolve to a file: "
                f"{adapter.directory / str(requirements)}")

        self.record(
            "M1", "Manifest names an adapter directory, entry, and requirements "
                  "that exist", "1",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            f"id={adapter.plugin_id!r}, entry={adapter.entry!r} resolves, "
            f"requirements present",
            entry=str(entry_path),
        )

        execution_ok = adapter.execution in EXECUTION_MODELS
        self.record(
            "M2", "Declared execution model is one of the three", "1",
            Status.PASS if execution_ok else Status.FAIL,
            f"execution={adapter.execution!r}" if execution_ok else
            f"execution={adapter.execution!r} is not one of "
            f"{', '.join(EXECUTION_MODELS)}",
        )

        kind_problems: list[str] = []
        if not adapter.tasks:
            kind_problems.append("declares no tasks")
        for task in adapter.tasks:
            task_id = task.get("id")
            if not task_id:
                kind_problems.append("a task has no `id`")
            bad_in = [k for k in (task.get("inputs") or []) if k not in INPUT_KINDS]
            bad_out = [k for k in (task.get("outputs") or []) if k not in OUTPUT_KINDS]
            if bad_in:
                kind_problems.append(f"task {task_id!r} declares unknown input kinds {bad_in}")
            if bad_out:
                kind_problems.append(f"task {task_id!r} declares unknown output kinds {bad_out}")
            if not (task.get("outputs") or []):
                kind_problems.append(f"task {task_id!r} declares no outputs")
        self.record(
            "M3", "Declared task input/output kinds are protocol kinds", "2",
            Status.PASS if not kind_problems else Status.FAIL,
            "; ".join(kind_problems) or
            f"{len(adapter.tasks)} task(s), all kinds recognised",
        )

        # Invariant 4: the arbiter decides what may run concurrently from these
        # numbers, so an absent or zero declaration is not a cosmetic omission.
        resource_problems = [
            f"`{key}` is {descriptor.get(key)!r}, expected a positive number"
            for key in ("ram_gb", "disk_gb")
            if not isinstance(descriptor.get(key), (int, float))
            or isinstance(descriptor.get(key), bool)
            or float(descriptor.get(key) or 0) <= 0
        ]
        self.record(
            "M4", "Peak memory and disk footprint are declared", "0.4",
            Status.PASS if not resource_problems else Status.FAIL,
            "; ".join(resource_problems) or
            f"ram_gb={descriptor.get('ram_gb')}, disk_gb={descriptor.get('disk_gb')}",
        )

        return execution_ok and entry_path.is_file()

    # =====================================================================
    # 2. Bare-interpreter argument parsing (section 4b)
    # =====================================================================

    def check_bare_interpreter(self) -> None:
        adapter = self.adapter
        blocked = list(HEAVY_MODULES)

        help_run = self._run("bare --help", ["--help"],
                             python=adapter.bare_python, blocked=blocked,
                             timeout=60.0)
        problems: list[str] = []
        if help_run.timed_out:
            problems.append("--help did not return within the timeout")
        elif help_run.returncode != 0:
            problems.append(
                f"--help exited {help_run.returncode} on a bare interpreter with "
                f"the heavy stack blocked: {help_run.summary()}")
        else:
            text = help_run.combined
            expected = (["--port"] if adapter.is_server else ["--task", "--out"])
            missing = [flag for flag in expected if flag not in text]
            if missing:
                problems.append(
                    f"--help does not offer {', '.join(missing)} for a "
                    f"{adapter.execution} adapter")
        self.record(
            "B1", "`--help` works on a bare interpreter, without the heavy stack",
            "4b",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            f"exit 0 with {len(blocked)} heavy modules blocked "
            f"({Path(adapter.bare_python).name})",
            blocked=blocked,
        )

        weight = (adapter.weights() or [{}])[0]
        install_run = self._run(
            "bare --install-weights",
            self._install_argv(weight_id="odv-conformance-unknown-weight",
                               source=str(weight.get("source", "huggingface")),
                               weight=weight),
            python=adapter.bare_python, blocked=blocked, timeout=90.0)

        problems = []
        if install_run.rejected_as_unknown_flag:
            problems.append(
                "the section 4b flags were rejected as unrecognized arguments: "
                + install_run.summary())
        elif install_run.timed_out:
            problems.append("--install-weights did not return within the timeout")
        else:
            stdout = classify_stdout(install_run.stdout)
            if install_run.returncode == 0:
                problems.append(
                    "exited 0 for a weight id that does not exist; exit 0 means "
                    "every file for that weight is present under --dest")
            elif stdout.envelope is None:
                problems.append(
                    "failed without an error envelope on stdout: "
                    + install_run.summary())
        self.record(
            "B2", "`--install-weights` parses and dispatches on a bare "
                  "interpreter", "4b",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            "flags accepted and reported a protocol error without the heavy stack",
        )

    def _install_argv(self, weight_id: str, source: str, weight: Mapping[str, Any],
                      dest: str | None = None) -> list[str]:
        args = ["--install-weights", "--weight-id", weight_id,
                "--source", source, "--dest", dest or tempfile.mkdtemp(
                    prefix="odv-conformance-weights-")]
        if weight.get("repo"):
            args += ["--repo", str(weight["repo"])]
        if weight.get("task"):
            args += ["--task", str(weight["task"])]
        return args

    # =====================================================================
    # 3. Weight hook (section 4b)
    # =====================================================================

    def check_weight_hook(self) -> None:
        adapter = self.adapter
        weights = adapter.weights()
        if not weights:
            reason = "the manifest declares no weights for this adapter"
            for check_id, title in (
                ("W1", "Weight hook accepts --weight-id/--source/--dest/--repo/--revision/--task"),
                ("W2", "Weight hook reports progress in the section 4 line format"),
            ):
                self.record(check_id, title, "4b", Status.SKIP, reason)
            self.record("W3", "A `manual` weight source verifies without downloading",
                        "4b", Status.SKIP, reason)
            return

        weight = weights[0]
        # Every optional flag is passed at once, including ones this adapter's
        # manifest does not use: section 4b defines the hook's signature, and an
        # adapter that only tolerates its own subset would break the moment the
        # manifest gained a `--repo`.
        dest = tempfile.mkdtemp(prefix="odv-conformance-weights-")
        argv = ["--install-weights",
                "--weight-id", str(weight.get("id", "w")),
                "--source", str(weight.get("source", "huggingface")),
                "--dest", dest,
                "--repo", str(weight.get("repo") or "odv-conformance/none"),
                # The host appends --revision whenever the manifest pins one.
                "--revision", str(weight.get("revision") or "0" * 40),
                "--task", str(weight.get("task") or "total")]
        run = self._run("weight hook (declared weight)", argv, timeout=150.0,
                        extra_env={"HF_HUB_OFFLINE": "1",
                                   "HF_HUB_DISABLE_TELEMETRY": "1",
                                   "TRANSFORMERS_OFFLINE": "1"})

        if run.rejected_as_unknown_flag:
            self.record(
                "W1", "Weight hook accepts --weight-id/--source/--dest/--repo/--revision/--task",
                "4b", Status.FAIL,
                "the hook rejected one of the section 4b flags as unrecognized: "
                + run.summary())
        elif run.timed_out:
            self.record(
                "W1", "Weight hook accepts --weight-id/--source/--dest/--repo/--revision/--task",
                "4b", Status.FAIL, "the hook did not return within the timeout")
        else:
            self.record(
                "W1", "Weight hook accepts --weight-id/--source/--dest/--repo/--revision/--task",
                "4b", Status.PASS,
                f"all six flags accepted (exit {run.returncode} offline, which "
                f"the hook reported in protocol terms)")

        # Section 4b constrains the FORMAT of progress ("the same stdout line
        # format as §4"), not that a run must reach the point of having
        # progress to report. A hook that validates its arguments and aborts --
        # unknown source, absent dependency -- correctly emits an envelope and
        # nothing else, and demanding a progress line from it would make this
        # check depend on how far the run happened to get on the machine the
        # kit is running on. Requiring one structured line, of either kind, is
        # what the protocol actually supports: a hook that says nothing on
        # stdout leaves the host with an exit code and no explanation.
        stdout = classify_stdout(run.stdout)
        if stdout.malformed_progress:
            self.record(
                "W2", "Weight hook reports progress in the section 4 line format",
                "4b", Status.FAIL,
                f"emitted {len(stdout.malformed_progress)} malformed progress "
                f"line(s); `progress` must be a number in 0-1 and `message` a "
                f"string: {stdout.malformed_progress[:2]}")
        elif stdout.progress:
            self.record(
                "W2", "Weight hook reports progress in the section 4 line format",
                "4b", Status.PASS,
                f"{len(stdout.progress)} well-formed progress line(s), "
                f"first={stdout.progress[0]}")
        elif stdout.envelopes:
            self.record(
                "W2", "Weight hook reports progress in the section 4 line format",
                "4b", Status.PASS,
                f"no progress line, but the hook aborted before doing any work "
                f"and said so in protocol terms "
                f"(code={stdout.envelope['error']['code']!r})"
                if stdout.envelope.get("ok") is False else
                "no progress line; the hook completed and reported success")
        else:
            self.record(
                "W2", "Weight hook reports progress in the section 4 line format",
                "4b", Status.FAIL,
                "the hook emitted nothing structured on stdout -- neither a "
                "progress line nor an envelope -- leaving the host an exit code "
                "and no explanation")

        self._check_manual_source(weights)

    def _check_manual_source(self, weights: Sequence[Mapping[str, Any]]) -> None:
        manual = [weight for weight in weights if weight.get("source") == "manual"]
        if not manual:
            self.record(
                "W3", "A `manual` weight source verifies without downloading",
                "4b", Status.SKIP,
                "the manifest declares no weight with source `manual`")
            return

        weight = manual[0]
        dest = tempfile.mkdtemp(prefix="odv-conformance-manual-")
        # Downloading is denied rather than merely unused: section 4b says a
        # manual source must not attempt a download, and taking away the means
        # to do one turns that from an assertion into an observation. Outbound
        # connections are blocked at the socket, which is where fetching is
        # distinguishable from serving.
        run = self._run(
            "weight hook (manual source)",
            self._install_argv(str(weight.get("id", "w")), "manual", weight, dest),
            blocked=list(NETWORK_MODULES), deny_network=True, timeout=90.0)

        stdout = classify_stdout(run.stdout)
        envelope = stdout.envelope
        problems: list[str] = []
        if run.returncode == 0:
            problems.append(
                "exited 0 although no checkpoint was placed under --dest")
        if envelope is None:
            problems.append("no error envelope on stdout: " + run.summary())
        else:
            code = (envelope.get("error") or {}).get("code")
            if code != "license_required":
                problems.append(
                    f"reported code {code!r}; a manual source with no checkpoint "
                    f"present must report `license_required` so the host routes "
                    f"it to the licence gate")
            message = str((envelope.get("error") or {}).get("message", ""))
            filename = str(weight.get("filename") or "")
            if dest not in message and not (filename and filename in message):
                problems.append(
                    "the message does not name the expected checkpoint path; the "
                    "store shows the user that exact path")
        if VIOLATION_MARKER in run.combined:
            problems.append(
                "attempted to reach the network; section 4b requires a manual "
                "source to verify a locally placed checkpoint and download nothing")

        self.record(
            "W3", "A `manual` weight source verifies without downloading", "4b",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            "reported license_required naming the expected path, with every "
            "network library blocked")

    # =====================================================================
    # 4. Error envelope discipline (sections 3, 4b, 4c)
    # =====================================================================

    def check_error_envelope(self) -> None:
        weight = (self.adapter.weights() or [{}])[0]
        # An unknown source cannot succeed for any adapter and needs no network,
        # which makes it the one failure every adapter can be made to produce.
        run = self._run(
            "weight hook (unknown source)",
            self._install_argv("odv-conformance-unknown-weight",
                               "odv-conformance-nonexistent-source", weight),
            deny_network=True, timeout=90.0)

        stdout = classify_stdout(run.stdout)
        problems: list[str] = []
        if run.returncode == 0:
            problems.append("exited 0 for an unknown weight source")
        if not stdout.envelopes:
            if stdout.malformed_envelopes:
                problems.append(
                    "emitted an object with `ok` that is not a valid envelope: "
                    f"{stdout.malformed_envelopes[0]}")
            elif _looks_like_multiline_envelope(run.stdout):
                problems.append(
                    "wrote the error envelope across several lines; section 4b "
                    "requires a single JSON line on stdout")
            elif "\"ok\"" in run.stderr or "'ok'" in run.stderr:
                problems.append(
                    "the error envelope went to stderr only; the host reads the "
                    "code from stdout and routes license_required to the licence "
                    "gate from there")
            else:
                problems.append("no error envelope on stdout: " + run.summary())
        elif len(stdout.envelopes) > 1:
            problems.append(
                f"emitted {len(stdout.envelopes)} envelopes; a run reports one "
                f"outcome")
        self.record(
            "E1", "A failing run emits one error envelope as a single stdout line",
            "3, 4b",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            f"exit {run.returncode} with "
            f"code={stdout.envelope['error']['code']!r}")

        bad_codes: list[str] = []
        seen: list[str] = []
        for label, invocation in self.invocations:
            for envelope in classify_stdout(invocation.stdout).envelopes:
                code = (envelope.get("error") or {}).get("code")
                if envelope.get("ok") is False:
                    seen.append(str(code))
                    if code not in ERROR_CODES:
                        bad_codes.append(f"{label}: {code!r}")
        for source, mapping in self._collected_result_json():
            error = (mapping.get("error") or {}) if isinstance(mapping, dict) else {}
            if mapping.get("ok") is False:
                code = error.get("code")
                seen.append(str(code))
                if code not in ERROR_CODES:
                    bad_codes.append(f"{source}: {code!r}")
        self.record(
            "E2", "Every error code is drawn from the protocol's enum", "3",
            Status.PASS if not bad_codes else Status.FAIL,
            "; ".join(bad_codes) or
            (f"codes observed: {', '.join(sorted(set(seen)))}" if seen
             else "no error codes observed"),
            valid=list(ERROR_CODES),
        )

    def _collected_result_json(self) -> list[tuple[str, dict]]:
        return getattr(self, "_result_json_files", [])

    # =====================================================================
    # 5. Stdout line discipline (section 4b)
    # =====================================================================

    def check_stdout_discipline(self) -> None:
        problems: list[str] = []
        totals = {"progress": 0, "envelopes": 0, "logs": 0}
        for label, invocation in self.invocations:
            stdout = classify_stdout(invocation.stdout)
            totals["progress"] += len(stdout.progress)
            totals["envelopes"] += len(stdout.envelopes)
            totals["logs"] += len(stdout.logs)
            if stdout.ambiguous:
                problems.append(
                    f"{label}: {len(stdout.ambiguous)} line(s) carry both `ok` and "
                    f"`progress`, so the host cannot tell an envelope from a "
                    f"progress line: {stdout.ambiguous[0]}")
            if stdout.malformed_progress:
                problems.append(
                    f"{label}: malformed progress line {stdout.malformed_progress[0]}")
            if stdout.malformed_envelopes:
                problems.append(
                    f"{label}: malformed envelope {stdout.malformed_envelopes[0]}")
            if not stdout.envelopes and _looks_like_multiline_envelope(invocation.stdout):
                problems.append(f"{label}: an envelope spans several lines")
        self.record(
            "S1", "Progress lines, envelopes, and log lines are distinguishable",
            "4, 4b",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            f"across {len(self.invocations)} run(s): {totals['progress']} progress, "
            f"{totals['envelopes']} envelope, {totals['logs']} log line(s), "
            f"none ambiguous",
        )

    # =====================================================================
    # 6/7. HTTP contract (sections 3, 6, 7)
    # =====================================================================

    def check_server(self) -> None:
        adapter = self.adapter
        if not adapter.is_server:
            for check_id, title in _SERVER_CHECKS:
                self.record(check_id, title, "3",
                            Status.SKIP,
                            f"{adapter.execution} adapters serve no HTTP endpoints")
            for check_id, title in _SESSION_CHECKS:
                self.record(check_id, title, "1.2",
                            Status.SKIP,
                            f"{adapter.execution} adapters hold no sessions")
            return

        # A short timeout, and a timeout counts as failure: an adapter that is
        # still running after being spawned with no arguments has fallen back to
        # a port of its own choosing, which is exactly the violation. Treating
        # "did not exit" as "exited non-zero" would pass it.
        no_port = self._run("no --port", [], timeout=15.0)
        if no_port.timed_out:
            status = Status.FAIL
            reason = ("started and kept running without --port; the host assigns "
                      "the port and no adapter may fall back to a fixed one of "
                      "its own")
        elif no_port.returncode == 0:
            status = Status.FAIL
            reason = "exited 0 without --port rather than requiring it"
        else:
            status = Status.PASS
            reason = f"exited {no_port.returncode} without --port"
        self.record("H4", "`--port` is required, not optional", "1.1", status, reason)

        self._check_session_declaration()

        if not self.allow_http:
            reason = ("HTTP probing is disabled (--no-http); these checks need to "
                      "spawn the adapter and connect to it")
            for check_id, title in _SERVER_CHECKS[1:]:
                self.record(check_id, title, "3", Status.ERROR, reason)
            for check_id, title in _SESSION_CHECKS[1:]:
                self.record(check_id, title, "1.2", Status.ERROR, reason)
            self._mask_skip_reason = reason
            return

        port = free_port()
        with ServerProcess(adapter.python, adapter.entry, adapter.directory,
                           adapter.plugins_root, port) as server:
            health = server.wait_for_health(self.health_timeout)
            self._check_health(server, health)
            if health.ok:
                self._check_capabilities(server)
                self._check_loopback(server)
                self._check_session(server, health)
                self._probe_task_masks(server, health)
            else:
                reason = ("the adapter never answered GET /health, so no further "
                          "HTTP check could run")
                for check_id, title in _SERVER_CHECKS[2:]:
                    self.record(check_id, title, "3", Status.ERROR, reason)
                for check_id, title in _SESSION_CHECKS[1:]:
                    self.record(check_id, title, "1.2", Status.ERROR, reason)
                self._mask_skip_reason = reason

    def _check_health(self, server: ServerProcess, health) -> None:
        adapter = self.adapter
        if not health.ok:
            self.record(
                "H1", "GET /health reports protocol 1 and the manifest plugin_id",
                "3", Status.FAIL,
                f"no usable reply from GET /health: {health.error}; "
                f"server log: {server.log()[-400:].strip() or '(empty)'}")
            return

        body = health.body if isinstance(health.body, dict) else {}
        self._health_body = body
        problems: list[str] = []
        if health.status != 200:
            problems.append(f"HTTP {health.status}")
        if body.get("protocol") != PROTOCOL_VERSION:
            problems.append(
                f"`protocol` is {body.get('protocol')!r}, must be "
                f"{PROTOCOL_VERSION}; the host refuses to route to any other")
        if body.get("plugin_id") != adapter.plugin_id:
            problems.append(
                f"`plugin_id` is {body.get('plugin_id')!r} but the manifest "
                f"declares {adapter.plugin_id!r}")
        if body.get("status") not in ("loading", "ready", "error"):
            problems.append(
                f"`status` is {body.get('status')!r}, must be loading, ready, or error")
        self.record(
            "H1", "GET /health reports protocol 1 and the manifest plugin_id", "3",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            f"status={body.get('status')!r}, protocol=1, plugin_id="
            f"{body.get('plugin_id')!r}",
            health=body,
        )

    def _check_capabilities(self, server: ServerProcess) -> None:
        adapter = self.adapter
        reply = server.get("/capabilities")
        if not reply.ok or not isinstance(reply.body, dict):
            self.record(
                "H2", "GET /capabilities lists declared tasks with declared kinds",
                "3", Status.FAIL,
                f"no usable reply: {reply.error or reply.raw[:200]}")
            return

        body = reply.body
        problems: list[str] = []
        if body.get("protocol") != PROTOCOL_VERSION:
            problems.append(f"`protocol` is {body.get('protocol')!r}, must be 1")
        if body.get("plugin_id") != adapter.plugin_id:
            problems.append(
                f"`plugin_id` is {body.get('plugin_id')!r} but the manifest "
                f"declares {adapter.plugin_id!r}")
        tasks = body.get("tasks")
        if not isinstance(tasks, list) or not tasks:
            problems.append("`tasks` is empty or not a list")
            tasks = []

        declared = {task.get("id"): task for task in adapter.tasks}
        for task in tasks:
            if not isinstance(task, dict):
                problems.append(f"a task entry is not an object: {task!r}")
                continue
            task_id = task.get("id")
            bad_in = [k for k in (task.get("inputs") or []) if k not in INPUT_KINDS]
            bad_out = [k for k in (task.get("outputs") or []) if k not in OUTPUT_KINDS]
            if bad_in or bad_out:
                problems.append(
                    f"task {task_id!r} declares unknown kinds "
                    f"{bad_in + bad_out}")
            if task_id not in declared:
                problems.append(
                    f"task {task_id!r} is served but absent from the manifest, so "
                    f"the store can never offer it")
                continue
            manifest_task = declared[task_id]
            for field_name, kinds in (("inputs", INPUT_KINDS), ("outputs", OUTPUT_KINDS)):
                runtime = set(task.get(field_name) or [])
                stated = set(manifest_task.get(field_name) or [])
                if runtime != stated:
                    problems.append(
                        f"task {task_id!r} {field_name}: /capabilities says "
                        f"{sorted(runtime)}, the manifest says {sorted(stated)}")

        # A task the adapter cannot currently serve may be omitted -- section 3
        # says the host trusts /capabilities and logs the discrepancy -- so a
        # missing task is reported, not failed.
        missing = [task_id for task_id in declared
                   if task_id not in {t.get("id") for t in tasks if isinstance(t, dict)}]
        self.record(
            "H2", "GET /capabilities lists declared tasks with declared kinds", "3",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            f"{len(tasks)} task(s) agree with the manifest"
            + (f" (manifest tasks not served right now: {missing})" if missing else ""),
            tasks=[t.get("id") for t in tasks if isinstance(t, dict)],
        )

    def _check_loopback(self, server: ServerProcess) -> None:
        """Invariant 1 and section 3: loopback only, and non-loopback refused."""
        evidence: list[str] = []
        problems: list[str] = []

        addresses, enumeration_error = listening_addresses(server.process.pid)
        if enumeration_error is None:
            offenders = sorted(a for a in addresses if not is_loopback(a))
            if offenders:
                problems.append(
                    f"listening on non-loopback address(es) {offenders}; invariant 1 "
                    f"forbids the adapter being reachable from the network")
            elif addresses:
                evidence.append(f"listening only on {sorted(addresses)}")
            else:
                evidence.append("no listening socket found for the adapter process")
        else:
            evidence.append(f"socket enumeration unavailable ({enumeration_error})")

        for address in non_loopback_addresses()[:2]:
            reply = server.get("/health", host=address, timeout=4.0)
            if reply.ok:
                problems.append(
                    f"answered GET /health on non-loopback address {address}")
            else:
                evidence.append(f"unreachable on {address}")

        refusal = self._run("--host 0.0.0.0", ["--port", str(free_port()),
                                               "--host", "0.0.0.0"], timeout=30.0)
        if refusal.rejected_as_unknown_flag:
            evidence.append("offers no --host flag to misconfigure")
        elif refusal.timed_out:
            problems.append(
                "accepted --host 0.0.0.0 and kept running; a non-loopback bind "
                "must be refused")
        elif refusal.returncode == 0:
            problems.append("exited 0 for --host 0.0.0.0 rather than refusing it")
        else:
            evidence.append(
                f"refused --host 0.0.0.0 (exit {refusal.returncode})")

        conclusive = any(
            text.startswith(("listening only on", "unreachable on", "refused --host"))
            for text in evidence)
        if problems:
            status, reason = Status.FAIL, "; ".join(problems)
        elif conclusive:
            status, reason = Status.PASS, "; ".join(evidence)
        else:
            status, reason = Status.ERROR, (
                "no evidence obtainable about which addresses the adapter bound: "
                + "; ".join(evidence))
        self.record("H3", "The server binds loopback only", "0.1, 3", status, reason)

    def _check_session_declaration(self) -> None:
        if not self.adapter.is_session:
            self.record(
                "X3", "`max_sessions` is declared and bounded", "1.2", Status.SKIP,
                f"only `session` adapters cache per-image state; this is "
                f"{self.adapter.execution}")
            return
        value = self.adapter.descriptor.get("max_sessions")
        valid = (isinstance(value, int) and not isinstance(value, bool)
                 and 1 <= value <= 64)
        self.record(
            "X3", "`max_sessions` is declared and bounded", "1.2",
            Status.PASS if valid else Status.FAIL,
            f"max_sessions={value}" if valid else
            f"max_sessions={value!r}; a session adapter must bound its cache and "
            f"evict rather than grow without limit",
        )

    def _check_session(self, server: ServerProcess, health) -> None:
        if not self.adapter.is_session:
            for check_id, title in _SESSION_CHECKS[1:]:
                self.record(check_id, title, "1.2", Status.SKIP,
                            f"{self.adapter.execution} adapters hold no sessions")
            return

        body = health.body if isinstance(health.body, dict) else {}
        ready = body.get("status") == "ready"
        payload = {"inputs": {"slice2d": base64.b64encode(_probe_slice_png()).decode()}}
        reply = server.post("/session/open", payload, timeout=180.0)

        problems: list[str] = []
        session_id: str | None = None
        if not reply.ok or not isinstance(reply.body, dict):
            problems.append(
                f"POST /session/open gave no JSON object: "
                f"{reply.error or reply.raw[:200]}")
        else:
            answer = reply.body
            if answer.get("ok") is True:
                session_id = answer.get("session_id")
                if not isinstance(session_id, str) or not session_id:
                    problems.append(
                        f"opened a session but `session_id` is {session_id!r}")
                    session_id = None
            elif answer.get("ok") is False:
                code = (answer.get("error") or {}).get("code")
                if code not in ERROR_CODES:
                    problems.append(f"refused with code {code!r}, not in the enum")
                elif ready:
                    problems.append(
                        f"reported status=ready but refused to open a session: "
                        f"{code}: {(answer.get('error') or {}).get('message')}")
            else:
                problems.append(f"reply carries no `ok`: {answer}")

        self.record(
            "X1", "POST /session/open answers in protocol terms", "1.2, 3",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            (f"opened session {session_id}" if session_id else
             f"declined with a valid envelope while status="
             f"{body.get('status')!r}"),
        )

        if session_id is None:
            self.record(
                "X2", "POST /session/close accepts the session_id", "1.2",
                Status.SKIP,
                f"no session could be opened (adapter status="
                f"{body.get('status')!r}), so there is no id to close")
            return

        close = server.post("/session/close", {"session_id": session_id}, timeout=60.0)
        problems = []
        if not close.ok or not isinstance(close.body, dict):
            problems.append(f"no JSON object: {close.error or close.raw[:200]}")
        elif close.body.get("ok") is not True:
            problems.append(f"did not accept the session_id: {close.body}")
        self.record(
            "X2", "POST /session/close accepts the session_id", "1.2",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or "closed the session it had just opened")
        self._open_session_id = session_id

    # =====================================================================
    # 8. One-shot CLI (section 4)
    # =====================================================================

    def check_oneshot(self) -> None:
        adapter = self.adapter
        self._result_json_files: list[tuple[str, dict]] = []
        if not adapter.is_oneshot:
            for check_id, title in _ONESHOT_CHECKS:
                self.record(check_id, title, "4", Status.SKIP,
                            f"{adapter.execution} adapters take no section 4 CLI")
            self.record("E3", "A failing one-shot run still writes result.json",
                        "4c", Status.SKIP,
                        f"{adapter.execution} adapters write no result.json")
            return

        task = (adapter.tasks or [{}])[0]
        task_id = str(task.get("id", "task"))
        out_dir = Path(tempfile.mkdtemp(prefix="odv-conformance-out-"))
        missing = Path(tempfile.gettempdir()) / f"odv-conformance-absent-{os.getpid()}"

        argv = ["--task", task_id, "--out", str(out_dir)]
        for kind in task.get("inputs") or []:
            argv += [f"--input-{kind}",
                     str(missing) if kind in ("series3d", "slice2d") else "probe"]
        for name, spec in (task.get("options") or {}).items():
            argv += [f"--opt-{name}", _option_probe_value(spec)]

        run = self._run("one-shot CLI", argv, timeout=180.0)
        problems: list[str] = []
        if run.rejected_as_unknown_flag:
            problems.append(
                "the section 4 CLI was rejected as unrecognized arguments: "
                + run.summary())
        elif run.timed_out:
            problems.append("did not return within the timeout")
        elif run.returncode == 0:
            problems.append(
                f"exited 0 although --input-series3d pointed at {missing}, which "
                f"does not exist")

        unknown = self._run("one-shot unknown task",
                            ["--task", "odv-conformance-no-such-task",
                             "--out", str(out_dir)], timeout=60.0)
        if unknown.returncode == 0:
            problems.append("accepted a task id the manifest does not declare")

        self.record(
            "O1", "Accepts the section 4 CLI and rejects bad input on its merits",
            "4",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            f"--task/--out/--input-* accepted; exit {run.returncode} for an "
            f"absent series and non-zero for an unknown task")

        result_path = out_dir / "result.json"
        problems = []
        payload: dict | None = None
        if not result_path.is_file():
            problems.append(
                f"no result.json under --out after a failing run; the host reads "
                f"it whenever it exists because the adapter's own message is more "
                f"actionable than an exit code")
        else:
            try:
                payload = json.loads(result_path.read_text())
            except ValueError as exc:
                problems.append(f"result.json is not valid JSON: {exc}")
            if isinstance(payload, dict):
                self._result_json_files.append(("result.json", payload))
                if payload.get("ok") is not False:
                    problems.append(
                        f"result.json says ok={payload.get('ok')!r} after a "
                        f"non-zero exit")
                else:
                    # Only presence and shape here. Whether the code is in the
                    # enum is E2's business, across every channel at once;
                    # checking it twice would report one violation as two.
                    error = payload.get("error")
                    if not isinstance(error, dict):
                        problems.append("result.json has no `error` object")
                    elif not isinstance(error.get("message"), str):
                        problems.append(
                            "result.json's error has no `message` string")
            elif payload is not None:
                problems.append("result.json is not a JSON object")
        self.record(
            "E3", "A failing one-shot run still writes result.json", "4c",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or
            f"wrote result.json with code "
            f"{(payload or {}).get('error', {}).get('code')!r}")

        self._check_oneshot_outputs(out_dir, payload, task)

    def _satisfiable_run(self, task: Mapping[str, Any]) -> tuple[Path, dict | None]:
        """Run the one-shot CLI with inputs that could plausibly succeed.

        The probe above points --input-series3d at a path that does not exist,
        which is how O1 and E3 get a guaranteed failure to inspect. That leaves
        nothing for O2, which can only judge outputs a successful run declared.
        So the CLI is run a second time against inputs the kit CAN construct:
        an existing (empty) series directory and a real PNG slice.

        Whether it succeeds is not itself a conformance question -- a real
        segmentation model will refuse an empty directory, and refusing it with
        a proper envelope is correct behaviour. The run is opportunistic: if it
        does succeed, O2 has real output paths to check.
        """
        out_dir = Path(tempfile.mkdtemp(prefix="odv-conformance-out2-"))
        series = Path(tempfile.mkdtemp(prefix="odv-conformance-series-"))
        argv = ["--task", str(task.get("id", "task")), "--out", str(out_dir)]
        for kind in task.get("inputs") or []:
            if kind == "series3d":
                argv += ["--input-series3d", str(series)]
            elif kind == "slice2d":
                slice_path = series / "slice.png"
                slice_path.write_bytes(_probe_slice_png())
                argv += ["--input-slice2d", str(slice_path)]
            elif kind == "text":
                argv += ["--input-text", "conformance probe"]
            elif kind in ("roi", "box"):
                argv += [f"--input-{kind}", json.dumps(_PROBE_BOX)]
            elif kind == "points":
                argv += ["--input-points", json.dumps(
                    [{"x": _PROMPT_XY[0], "y": _PROMPT_XY[1], "label": 1}])]
        for name, spec in (task.get("options") or {}).items():
            argv += [f"--opt-{name}", _option_probe_value(spec)]

        self._run("one-shot CLI (satisfiable inputs)", argv, timeout=self.timeout)
        result_path = out_dir / "result.json"
        if not result_path.is_file():
            return out_dir, None
        try:
            parsed = json.loads(result_path.read_text())
        except ValueError:
            return out_dir, None
        return out_dir, parsed if isinstance(parsed, dict) else None

    def _check_oneshot_outputs(self, out_dir: Path, payload: dict | None,
                               task: Mapping[str, Any]) -> None:
        """Section 4: output paths in result.json are relative to --out.

        Only a successful run can be judged, because only a successful run
        declares outputs. The kit therefore inspects any result.json it can
        obtain -- from the probe above, or from a run the operator points it at
        with --oneshot-result -- and reports when it had none.
        """
        candidates: list[tuple[Path, dict]] = []
        if isinstance(payload, dict):
            candidates.append((out_dir, payload))
        second_dir, second = self._satisfiable_run(task)
        if isinstance(second, dict):
            candidates.append((second_dir, second))
            if second.get("ok") is False:
                self._result_json_files.append(("result.json (satisfiable)", second))
        for extra in getattr(self, "extra_results", []):
            if isinstance(extra, dict):
                # An operator-supplied result.json came from a run whose --out
                # the kit never saw, so only the shape of its paths can be
                # judged, not their presence on disk.
                candidates.append((None, extra))

        successful = [(directory, item) for directory, item in candidates
                      if item.get("ok") is True]
        if not successful:
            self.record(
                "O2", "result.json output paths are relative to --out", "4",
                Status.SKIP,
                "no run of this adapter succeeded here, so it declared no output "
                "paths to check. A model that needs real DICOM input will not run "
                "under the kit; pass --oneshot-result <result.json> from a real "
                "run to check this.")
            return

        problems: list[str] = []
        for out_dir, item in successful:
            outputs = item.get("outputs")
            if not isinstance(outputs, dict):
                problems.append(f"`outputs` is not an object: {outputs!r}")
                continue
            for kind, value in outputs.items():
                if kind not in OUTPUT_KINDS:
                    problems.append(f"unknown output kind {kind!r}")
                if not isinstance(value, str):
                    continue
                if os.path.isabs(value):
                    problems.append(
                        f"{kind} is an absolute path {value!r}; section 4 requires "
                        f"paths relative to --out")
                elif ".." in Path(value).parts:
                    problems.append(f"{kind} escapes --out: {value!r}")
                elif out_dir is not None and not (out_dir / value).exists():
                    problems.append(f"{kind} -> {value} does not exist under --out")
            for mask in iter_masks(outputs.get("mask2d")):
                self.masks.append(("result.json", mask))
        self.record(
            "O2", "result.json output paths are relative to --out", "4",
            Status.PASS if not problems else Status.FAIL,
            "; ".join(problems) or "every declared output path is relative and present")

    # =====================================================================
    # 9. RLE convention (section 5)
    # =====================================================================

    def _probe_task_masks(self, server: ServerProcess, health) -> None:
        """Drive a mask-producing task so section 5 has something to judge."""
        adapter = self.adapter
        body = health.body if isinstance(health.body, dict) else {}
        mask_tasks = [task for task in adapter.tasks
                      if "mask2d" in (task.get("outputs") or [])]
        if not mask_tasks:
            return
        if body.get("status") != "ready":
            self._mask_skip_reason = (
                f"the adapter declares a mask2d task but reports "
                f"status={body.get('status')!r} "
                f"({body.get('detail') or 'no detail'}), so no mask could be "
                f"obtained on this machine")
            return

        task = mask_tasks[0]
        inputs: dict[str, Any] = {}
        for kind in task.get("inputs") or []:
            if kind == "slice2d":
                inputs["slice2d"] = base64.b64encode(_probe_slice_png()).decode()
            elif kind == "points":
                inputs["points"] = [{"x": _PROMPT_XY[0], "y": _PROMPT_XY[1], "label": 1}]
            elif kind == "box":
                inputs["box"] = dict(_PROBE_BOX)
            elif kind == "roi":
                inputs["roi"] = dict(_PROBE_BOX)
            elif kind == "text":
                inputs["text"] = "the bright square"
            elif kind == "series3d":
                self._mask_skip_reason = (
                    "the mask task needs a series3d input, which the kit cannot "
                    "synthesise")
                return

        payload: dict[str, Any] = {"inputs": inputs}
        session_id = getattr(self, "_open_session_id", None)
        if adapter.is_session:
            reopened = server.post(
                "/session/open",
                {"inputs": {"slice2d": inputs.get("slice2d")}}, timeout=180.0)
            if reopened.ok and isinstance(reopened.body, dict):
                session_id = reopened.body.get("session_id") or session_id
            if session_id:
                payload["session_id"] = session_id

        reply = server.post(f"/task/{task.get('id')}", payload, timeout=300.0)
        if not reply.ok or not isinstance(reply.body, dict):
            self._mask_skip_reason = (
                f"POST /task/{task.get('id')} gave no JSON object: "
                f"{reply.error or reply.raw[:160]}")
            return
        if reply.body.get("ok") is not True:
            self._mask_skip_reason = (
                f"the mask task declined: {json.dumps(reply.body)[:200]}")
            return
        outputs = reply.body.get("outputs") or {}
        for mask in iter_masks(outputs.get("mask2d")):
            self.masks.append((f"/task/{task.get('id')}", mask))
        if not self.masks:
            self._mask_skip_reason = (
                "the task succeeded but returned no mask2d output")

    def check_rle(self) -> None:
        adapter = self.adapter
        if not adapter.declares_output("mask2d"):
            for check_id, title in _RLE_CHECKS:
                self.record(check_id, title, "5", Status.SKIP,
                            "this adapter declares no mask2d output")
            return
        if not self.masks:
            reason = self._mask_skip_reason or "no mask2d output was obtained"
            for check_id, title in _RLE_CHECKS:
                self.record(check_id, title, "5", Status.SKIP, reason)
            return

        structure: list[str] = []
        phase: list[str] = []
        decoded: list[tuple[str, dict, list[bool]]] = []
        for source, mask in self.masks:
            width, height = mask.get("width"), mask.get("height")
            rle = mask.get("rle")
            if not _positive_int(width) or not _positive_int(height):
                structure.append(f"{source}: width/height are {width!r}x{height!r}")
                continue
            if not isinstance(rle, list) or not rle:
                structure.append(f"{source}: `rle` is not a non-empty list")
                continue
            total = sum(run for run in rle if isinstance(run, int))
            if total != width * height:
                structure.append(
                    f"{source}: runs sum to {total}, expected width*height = "
                    f"{width * height}")
                continue
            try:
                pixels = decode_rle(rle, width, height)
            except ValueError as exc:
                structure.append(f"{source}: {exc}")
                continue
            decoded.append((source, mask, pixels))

        self.record(
            "R1", "mask2d RLE is row-major and its runs sum to width*height", "5",
            Status.PASS if not structure else Status.FAIL,
            "; ".join(structure) or
            f"{len(decoded)} mask(s) decoded, e.g. "
            f"{decoded[0][1]['width']}x{decoded[0][1]['height']} with "
            f"{len(decoded[0][1]['rle'])} runs")

        if not decoded:
            self.record(
                "R2", "mask2d RLE starts with a background run", "5", Status.FAIL,
                "no mask decoded, so the run phase could not be established")
            return

        prompt_index = (int(_PROMPT_XY[1] * _PROBE_SIZE) * _PROBE_SIZE
                        + int(_PROMPT_XY[0] * _PROBE_SIZE))
        for source, mask, pixels in decoded:
            width, height = mask["width"], mask["height"]
            coverage = sum(pixels) / float(len(pixels))
            if coverage >= 0.98:
                phase.append(
                    f"{source}: {coverage:.1%} of the frame decodes as foreground, "
                    f"which is what a mask encoded without its leading background "
                    f"run looks like to the host's decoder")
                continue
            if (width, height) == (_PROBE_SIZE, _PROBE_SIZE):
                # The prompt was placed at the centre of a bright block, so
                # whatever a segmenter returns, the clicked pixel must come back
                # foreground. Under an inverted phase it comes back background,
                # which is precisely the silent failure section 5 warns about.
                if not pixels[prompt_index]:
                    phase.append(
                        f"{source}: the foreground prompt point decodes as "
                        f"background (coverage {coverage:.1%}); the runs are "
                        f"phase-inverted, so the host renders the complement of "
                        f"this mask")
        self.record(
            "R2", "mask2d RLE starts with a background run", "5",
            Status.PASS if not phase else Status.FAIL,
            "; ".join(phase) or
            f"the prompted pixel decodes as foreground in every mask "
            f"(coverage {sum(decoded[0][2]) / float(len(decoded[0][2])):.1%})")


_SERVER_CHECKS = [
    ("H4", "`--port` is required, not optional"),
    ("H1", "GET /health reports protocol 1 and the manifest plugin_id"),
    ("H2", "GET /capabilities lists declared tasks with declared kinds"),
    ("H3", "The server binds loopback only"),
]

_SESSION_CHECKS = [
    ("X3", "`max_sessions` is declared and bounded"),
    ("X1", "POST /session/open answers in protocol terms"),
    ("X2", "POST /session/close accepts the session_id"),
]

_ONESHOT_CHECKS = [
    ("O1", "Accepts the section 4 CLI and rejects bad input on its merits"),
    ("O2", "result.json output paths are relative to --out"),
]

_RLE_CHECKS = [
    ("R1", "mask2d RLE is row-major and its runs sum to width*height"),
    ("R2", "mask2d RLE starts with a background run"),
]

#: Stable order for the report, independent of the order checks are produced.
CHECK_ORDER = ["M1", "M2", "M3", "M4", "B1", "B2", "W1", "W2", "W3",
               "E1", "E2", "E3", "S1", "H4", "H1", "H2", "H3",
               "X3", "X1", "X2", "O1", "O2", "R1", "R2"]


def _positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _option_probe_value(spec: Any) -> str:
    kind = spec.get("type") if isinstance(spec, Mapping) else None
    if kind == "bool":
        default = spec.get("default") if isinstance(spec, Mapping) else True
        return "true" if default in (True, "true", 1) else "false"
    if kind == "number":
        return "1"
    if kind == "enum" and isinstance(spec, Mapping) and spec.get("values"):
        return str(spec["values"][0])
    return "probe"


def _looks_like_multiline_envelope(text: str) -> bool:
    """Whether stdout holds an envelope that was pretty-printed across lines."""
    stripped = text.strip()
    if not stripped.startswith("{") or "\n" not in stripped:
        return False
    try:
        parsed = json.loads(stripped)
    except ValueError:
        return False
    return isinstance(parsed, dict) and "ok" in parsed


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run_conformance(
    adapter_dir: str | os.PathLike,
    manifest: str | os.PathLike | None = None,
    python: str | None = None,
    bare_python: str | None = None,
    timeout: float = 120.0,
    health_timeout: float = 90.0,
    allow_http: bool = True,
    oneshot_results: Sequence[str | os.PathLike] = (),
) -> ConformanceReport:
    """Check one adapter directory against protocol v1 and report every check."""
    started = time.perf_counter()
    directory = Path(adapter_dir).resolve()
    report = ConformanceReport(
        adapter_dir=str(directory), plugin_id=None, execution=None,
        manifest=None,
        started_at=time.strftime("%Y-%m-%dT%H:%M:%S%z"))

    if not directory.is_dir():
        report.results.append(CheckResult(
            "M1", "Manifest names an adapter directory, entry, and requirements "
                  "that exist", "1", Status.FAIL,
            f"{directory} is not a directory"))
        report.duration_s = time.perf_counter() - started
        return report

    manifest_path = Path(manifest).resolve() if manifest else find_manifest(directory)
    report.manifest = str(manifest_path) if manifest_path else None
    if manifest_path is None or not manifest_path.is_file():
        report.results.append(CheckResult(
            "M1", "Manifest names an adapter directory, entry, and requirements "
                  "that exist", "1", Status.FAIL,
            "no plugins.json was found; pass --manifest to name one"))
        report.duration_s = time.perf_counter() - started
        return report

    try:
        data = json.loads(manifest_path.read_text())
    except ValueError as exc:
        report.results.append(CheckResult(
            "M1", "Manifest names an adapter directory, entry, and requirements "
                  "that exist", "1", Status.FAIL,
            f"{manifest_path} is not valid JSON: {exc}"))
        report.duration_s = time.perf_counter() - started
        return report

    descriptor = next((entry for entry in data.get("plugins", [])
                       if entry.get("adapter_dir") == directory.name), None)
    if descriptor is None:
        report.results.append(CheckResult(
            "M1", "Manifest names an adapter directory, entry, and requirements "
                  "that exist", "1", Status.FAIL,
            f"no plugin in {manifest_path} declares adapter_dir "
            f"{directory.name!r}; the host installs adapters by that name"))
        report.duration_s = time.perf_counter() - started
        return report

    adapter = AdapterUnderTest(
        directory=directory,
        plugins_root=directory.parent,
        manifest_path=manifest_path,
        descriptor=descriptor,
        python=python or sys.executable,
        bare_python=bare_python or _default_bare_python(),
    )
    report.plugin_id = adapter.plugin_id
    report.execution = adapter.execution

    checker = Checker(adapter, timeout=timeout, health_timeout=health_timeout,
                      allow_http=allow_http)
    checker.extra_results = [
        json.loads(Path(path).read_text()) for path in oneshot_results
        if Path(path).is_file()
    ]

    usable = checker.check_manifest()
    if usable:
        checker.check_bare_interpreter()
        checker.check_weight_hook()
        checker.check_oneshot()
        checker.check_server()
        checker.check_error_envelope()
        checker.check_rle()
        checker.check_stdout_discipline()
    else:
        for check_id in CHECK_ORDER:
            if check_id in ("M1", "M2", "M3", "M4"):
                continue
            checker.record(
                check_id, _title_for(check_id), "-", Status.ERROR,
                "the manifest declaration is unusable, so the adapter could not "
                "be invoked")

    order = {check_id: index for index, check_id in enumerate(CHECK_ORDER)}
    report.results = sorted(checker.results, key=lambda r: order.get(r.id, 99))
    report.duration_s = time.perf_counter() - started
    return report


def _default_bare_python() -> str:
    """An interpreter with none of an adapter's dependencies.

    /usr/bin/python3 is the host's own probe interpreter on macOS. Whichever is
    used, the kit also blocks the heavy modules by import hook, so the check
    means "does not need them" rather than "happened to run somewhere without
    them".
    """
    for candidate in ("/usr/bin/python3", shutil.which("python3")):
        if candidate and Path(candidate).exists():
            return candidate
    return sys.executable


_TITLES = dict(_SERVER_CHECKS + _SESSION_CHECKS + _ONESHOT_CHECKS + _RLE_CHECKS)
_TITLES.update({
    "M1": "Manifest names an adapter directory, entry, and requirements that exist",
    "M2": "Declared execution model is one of the three",
    "M3": "Declared task input/output kinds are protocol kinds",
    "M4": "Peak memory and disk footprint are declared",
    "B1": "`--help` works on a bare interpreter, without the heavy stack",
    "B2": "`--install-weights` parses and dispatches on a bare interpreter",
    "W1": "Weight hook accepts --weight-id/--source/--dest/--repo/--revision/--task",
    "W2": "Weight hook reports progress in the section 4 line format",
    "W3": "A `manual` weight source verifies without downloading",
    "E1": "A failing run emits one error envelope as a single stdout line",
    "E2": "Every error code is drawn from the protocol's enum",
    "E3": "A failing one-shot run still writes result.json",
    "S1": "Progress lines, envelopes, and log lines are distinguishable",
})


def _title_for(check_id: str) -> str:
    return _TITLES.get(check_id, check_id)
