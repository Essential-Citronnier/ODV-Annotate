#!/usr/bin/env python3
"""Experiment 5 — is the packaged application actually deployable?

An architecture that only works in the developer's source tree is a proposal,
not a system. This checks the packaged `.app` on the axes that decide whether a
user can install a plugin at all:

  - the plugin adapters and the manifest are inside the bundle
  - the bundled interpreter runs and can create a virtualenv with pip, since
    every plugin install begins there
  - each adapter parses its command line under the BUNDLED interpreter, not the
    developer's, and without its own dependencies installed
  - nothing machine-specific leaked into the bundle
  - the bundle is signed and its signature verifies

The motivating defect: `PluginEnvironmentLocator` finds `plugins/` beside the
executable during development and in `Resources/` once packaged. The packaging
script copied only the older single-engine server, so the development build
worked while a packaged build would have shown an empty store — a discrepancy
that surfaces only after shipping.

Usage:
    PYTHONPATH=eval python eval/exp5_deployability.py \\
        --app OpenDicomViewer-Annotate.app --out eval/results
"""
from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
import sys
import time
from pathlib import Path

from harness import CaseResult, Recorder, machine_profile

# Adapters the store is expected to offer, with the entry point each declares.
EXPECTED_ADAPTERS = {
    "gemma": "server.py",
    "sam2": "server.py",
    "sam3": "server.py",
    "totalseg": "run_segment.py",
}


def _run(argv: list[str], cwd: Path | None = None,
         env: dict | None = None, timeout: float = 300) -> tuple[int, str]:
    """Run a command, returning (exit code, combined output).

    A failure to spawn is returned as a non-zero code rather than raised: a
    missing interpreter is exactly the deployment defect this script exists to
    detect, so it must be recorded as a failed check, not crash the run and lose
    the other results.
    """
    try:
        proc = subprocess.run(argv, cwd=str(cwd) if cwd else None, env=env,
                              capture_output=True, text=True, timeout=timeout)
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except FileNotFoundError as exc:
        return 127, f"could not execute {argv[0]}: {exc}"
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s: {' '.join(argv[:2])}"


def check_bundle_layout(app: Path) -> CaseResult:
    """The manifest and every expected adapter must be present."""
    t0 = time.perf_counter()
    resources = app / "Contents" / "Resources"
    missing: list[str] = []

    manifest = resources / "plugins.json"
    if not manifest.is_file():
        missing.append("plugins.json")

    for adapter, entry in EXPECTED_ADAPTERS.items():
        for rel in (entry, "requirements.txt"):
            path = resources / "plugins" / adapter / rel
            if not path.is_file():
                missing.append(f"plugins/{adapter}/{rel}")
    if not (resources / "plugins" / "_shared" / "serve.py").is_file():
        missing.append("plugins/_shared/serve.py")

    declared = 0
    if manifest.is_file():
        declared = len(json.loads(manifest.read_text()).get("plugins", []))

    return CaseResult(
        experiment="exp5_deployability", case_id="bundle_layout",
        ok=not missing, wall_s=time.perf_counter() - t0,
        metrics={"plugins_declared": declared,
                 "adapters_present": len(EXPECTED_ADAPTERS) - len(
                     {m.split('/')[1] for m in missing if m.startswith('plugins/')})},
        error=None if not missing else f"missing from bundle: {missing}",
        notes=["an empty store is the failure mode this check exists to catch"])


def check_no_machine_specific_leakage(app: Path) -> CaseResult:
    """A shipped bundle must not carry the developer's virtualenvs or caches."""
    t0 = time.perf_counter()
    plugins = app / "Contents" / "Resources" / "plugins"
    leaked = [str(p.relative_to(plugins))
              for pattern in (".venv", "__pycache__", "*.pyc")
              for p in plugins.rglob(pattern)]
    return CaseResult(
        experiment="exp5_deployability", case_id="no_leakage",
        ok=not leaked, wall_s=time.perf_counter() - t0,
        metrics={"leaked_count": len(leaked)},
        error=None if not leaked else f"machine-specific paths shipped: {leaked[:5]}")


def check_bundled_interpreter(app: Path) -> CaseResult:
    """The bundled interpreter must run and be able to build a venv with pip.

    Every plugin install starts by creating a virtualenv, so an interpreter that
    cannot do it makes the whole store inoperable regardless of the adapters.
    """
    t0 = time.perf_counter()
    python = app / "Contents" / "Resources" / "python" / "bin" / "python3"
    if not python.is_file():
        return CaseResult(
            experiment="exp5_deployability", case_id="bundled_interpreter",
            ok=False, wall_s=time.perf_counter() - t0,
            error="no interpreter bundled at Resources/python/bin/python3",
            notes=["the app would fall back to a system Python, which may not exist"])

    code, version = _run([str(python), "--version"])
    if code != 0:
        return CaseResult(
            experiment="exp5_deployability", case_id="bundled_interpreter",
            ok=False, wall_s=time.perf_counter() - t0,
            error=f"bundled interpreter will not run: {version.strip()}")

    probe = Path("/tmp") / f"odv_venv_probe_{int(time.time())}"
    code, out = _run([str(python), "-m", "venv", str(probe)], timeout=180)
    has_pip = (probe / "bin" / "pip").is_file()
    if probe.exists():
        subprocess.run(["rm", "-rf", str(probe)], check=False)

    ok = code == 0 and has_pip
    return CaseResult(
        experiment="exp5_deployability", case_id="bundled_interpreter",
        ok=ok, wall_s=time.perf_counter() - t0,
        metrics={"version": version.strip(), "venv_has_pip": has_pip},
        error=None if ok else f"venv creation failed (exit {code}): {out[-300:]}",
        notes=["ensurepip must survive the bundle's size trimming"])


def check_adapters_run_from_bundle(app: Path) -> list[CaseResult]:
    """Each adapter must parse its command line under the bundled interpreter.

    Run with the bundled Python rather than the developer's, and without the
    adapter's own dependencies: protocol section 4b requires the weight hook to
    work before the environment it populates exists.
    """
    resources = app / "Contents" / "Resources"
    python = resources / "python" / "bin" / "python3"
    results: list[CaseResult] = []

    for adapter, entry in EXPECTED_ADAPTERS.items():
        t0 = time.perf_counter()
        script = resources / "plugins" / adapter / entry
        if not python.is_file() or not script.is_file():
            results.append(CaseResult(
                experiment="exp5_deployability", case_id=f"adapter_runs/{adapter}",
                ok=False, wall_s=time.perf_counter() - t0,
                error="interpreter or entry script missing from bundle"))
            continue

        # PYTHONDONTWRITEBYTECODE mirrors what the app sets when it spawns an
        # adapter, and is load-bearing here: bytecode written into the signed
        # bundle invalidates its signature, so a check that polluted the bundle
        # would make the signature check fail as a side effect of running.
        env = {"PYTHONPATH": str(resources / "plugins"),
               "PATH": "/usr/bin:/bin",
               "PYTHONDONTWRITEBYTECODE": "1"}
        code, out = _run([str(python), str(script), "--help"],
                         cwd=resources / "plugins" / adapter, env=env, timeout=120)
        results.append(CaseResult(
            experiment="exp5_deployability", case_id=f"adapter_runs/{adapter}",
            ok=code == 0, wall_s=time.perf_counter() - t0,
            metrics={"help_bytes": len(out)},
            error=None if code == 0 else f"exit {code}: {out[-300:]}",
            notes=["bundled interpreter, adapter dependencies absent"]))
    return results


def check_signature(app: Path) -> CaseResult:
    """The bundle must carry a signature that verifies.

    Ad-hoc is acceptable for a development build; the check records which kind
    was found rather than demanding Developer ID, since notarisation is a
    release step.
    """
    t0 = time.perf_counter()
    code, out = _run(["codesign", "--verify", "--strict", str(app)], timeout=180)
    _, info = _run(["codesign", "-dv", str(app)], timeout=120)
    adhoc = "adhoc" in info.lower() or "Signature=adhoc" in info
    return CaseResult(
        experiment="exp5_deployability", case_id="signature",
        ok=code == 0, wall_s=time.perf_counter() - t0,
        metrics={"adhoc": adhoc},
        error=None if code == 0 else out[-300:],
        notes=["ad-hoc is expected for a development build; "
               "Developer ID + notarisation is the release path"])


def check_sandbox_entitlement(app: Path) -> CaseResult:
    """Record whether App Sandbox is enabled.

    This is not a pass/fail on quality but a documented architectural
    consequence: creating a virtualenv, running pip, and downloading weights at
    runtime are incompatible with App Sandbox, which rules out Mac App Store
    distribution for this design. The evaluation records it as a fact.
    """
    t0 = time.perf_counter()
    code, out = _run(["codesign", "-d", "--entitlements", ":-", str(app)], timeout=120)
    sandboxed = None
    if code == 0 and out.strip().startswith("<?xml"):
        try:
            ents = plistlib.loads(out.encode())
            sandboxed = bool(ents.get("com.apple.security.app-sandbox", False))
        except Exception:  # noqa: BLE001
            sandboxed = None
    return CaseResult(
        experiment="exp5_deployability", case_id="sandbox_entitlement",
        ok=True, wall_s=time.perf_counter() - t0,
        metrics={"app_sandbox_enabled": sandboxed},
        notes=["App Sandbox is deliberately off: runtime venv creation, pip, and "
               "weight downloads are incompatible with it, so Mac App Store "
               "distribution is not available to this architecture"])


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", required=True, type=Path)
    p.add_argument("--out", default=Path("eval/results"), type=Path)
    args = p.parse_args(argv)

    # Resolved absolutely: several checks run subprocesses with an explicit cwd,
    # and a relative bundle path would then point at the wrong place.
    app: Path = args.app.resolve()
    if not app.is_dir():
        print(f"No such app bundle: {app}", file=sys.stderr)
        return 2

    recorder = Recorder(args.out / "exp5_deployability.jsonl", "exp5_deployability")
    print(f"Machine: {machine_profile().get('chip')}")
    print(f"Bundle:  {app}")

    results = [check_bundle_layout(app),
               check_no_machine_specific_leakage(app),
               check_bundled_interpreter(app),
               *check_adapters_run_from_bundle(app),
               check_signature(app),
               check_sandbox_entitlement(app)]
    for r in results:
        recorder.write(r)

    failed = [r.case_id for r in results if not r.ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    if failed:
        print("FAILED: " + ", ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
