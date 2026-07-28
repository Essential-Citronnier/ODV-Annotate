# test_adapter_cli.py
# OpenDicomViewer
#
# Every adapter must parse its arguments on a bare interpreter, before its venv
# exists. This is not tidiness: `--install-weights` is the hook the host calls
# to populate an environment, so an adapter that must import fastapi or torch
# to reach it cannot be installed or probed until the thing it installs is
# already there. For SAM 3 the point is sharper still -- verifying a manually
# placed checkpoint needs nothing but the standard library.
#
# These tests run each entry point in a subprocess with a scrubbed sys.path so
# that only the standard library and `plugins/` are importable. That makes them
# fail here for the same reason they failed on the reviewer's machine, rather
# than passing because this environment happens to have the web stack.
# Licensed under the MIT License. See LICENSE for details.
"""Adapter CLIs must work before their dependencies are installed."""

from __future__ import annotations

import json
import subprocess
import sys
import sysconfig
from pathlib import Path

import pytest

PLUGINS_ROOT = Path(__file__).resolve().parents[2]

ENTRY_POINTS = {
    "gemma": PLUGINS_ROOT / "gemma" / "server.py",
    "sam2": PLUGINS_ROOT / "sam2" / "server.py",
    "sam3": PLUGINS_ROOT / "sam3" / "server.py",
    "totalseg": PLUGINS_ROOT / "totalseg" / "run_segment.py",
}

SERVER_ADAPTERS = ("gemma", "sam2", "sam3")

# Third-party packages an adapter must not need in order to parse arguments.
HEAVY = ("fastapi", "uvicorn", "starlette", "torch", "transformers",
         "mlx", "mlx_vlm", "totalsegmentator", "huggingface_hub")


def _bare_run(entry: Path, args: list[str]) -> subprocess.CompletedProcess:
    """Run an entry point with only the standard library and `plugins/` visible.

    `-S` and `-E` drop site-packages and PYTHONPATH from the environment; the
    stdlib directories and `plugins/` are then put back explicitly. The result
    approximates a freshly created venv that pip has not run in yet.
    """
    stdlib = [sysconfig.get_path("stdlib"),
              str(Path(sysconfig.get_path("stdlib")) / "lib-dynload")]
    bootstrap = (
        "import sys; "
        f"sys.path[:] = {stdlib!r} + [{str(PLUGINS_ROOT)!r}]; "
        f"sys.argv = [{str(entry)!r}] + {args!r}; "
        f"exec(compile(open({str(entry)!r}).read(), {str(entry)!r}, 'exec'), "
        "{'__name__': '__main__', '__file__': " f"{str(entry)!r}" "})"
    )
    return subprocess.run([sys.executable, "-S", "-E", "-c", bootstrap],
                          capture_output=True, text=True, timeout=120)


def test_the_bare_interpreter_really_lacks_the_heavy_packages():
    """Guards the tests below from passing vacuously."""
    probe = _bare_run(ENTRY_POINTS["sam2"], ["--help"])
    check = subprocess.run(
        [sys.executable, "-S", "-E", "-c",
         "import sys, sysconfig;"
         f"sys.path[:] = [sysconfig.get_path('stdlib')];"
         "import importlib.util;"
         f"print([m for m in {HEAVY!r} if importlib.util.find_spec(m)])"],
        capture_output=True, text=True)
    assert check.stdout.strip() == "[]", (
        f"the scrubbed interpreter can still import {check.stdout.strip()}")
    assert probe.returncode == 0


@pytest.mark.parametrize("name", SERVER_ADAPTERS)
def test_help_works_without_the_venv(name):
    result = _bare_run(ENTRY_POINTS[name], ["--help"])
    assert result.returncode == 0, result.stderr
    assert "--port" in result.stdout


@pytest.mark.parametrize("name", SERVER_ADAPTERS)
def test_port_is_required(name):
    """The host assigns the port; no adapter may fall back to one of its own."""
    result = _bare_run(ENTRY_POINTS[name], [])
    assert result.returncode != 0
    assert "--port" in result.stderr


def test_one_shot_help_works_without_the_venv():
    result = _bare_run(ENTRY_POINTS["totalseg"], ["--help"])
    assert result.returncode == 0, result.stderr
    assert "--task" in result.stdout


def test_the_gated_install_hook_needs_only_the_standard_library(tmp_path):
    """SAM 3's whole install step is a path check; it must not need a web stack.

    This is the case that motivated the rule: the store cannot tell a user
    where to place a gated checkpoint if reaching that message first requires
    installing everything the checkpoint would have been used by.
    """
    result = _bare_run(ENTRY_POINTS["sam3"], [
        "--install-weights", "--weight-id", "sam3-checkpoint",
        "--source", "manual", "--dest", str(tmp_path),
    ])
    assert result.returncode != 0

    envelope = json.loads(result.stdout.strip().splitlines()[-1])
    assert envelope["error"]["code"] == "license_required"
    assert "huggingface.co/facebook/sam3" in envelope["error"]["message"]
    assert str(tmp_path / "sam3.pt") in envelope["error"]["message"]


def test_the_gated_install_hook_succeeds_on_a_present_checkpoint(tmp_path):
    (tmp_path / "sam3.pt").write_bytes(b"checkpoint")
    result = _bare_run(ENTRY_POINTS["sam3"], [
        "--install-weights", "--weight-id", "sam3-checkpoint",
        "--source", "manual", "--dest", str(tmp_path),
    ])
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("name", SERVER_ADAPTERS + ("totalseg",))
def test_no_heavy_package_is_imported_at_module_scope(name):
    """Fails with the offending module named, rather than a bare ImportError."""
    entry = ENTRY_POINTS[name]
    result = _bare_run(entry, ["--help"])
    for module in HEAVY:
        assert f"No module named '{module}'" not in result.stderr, (
            f"{entry.name} imports {module} before argument dispatch")
