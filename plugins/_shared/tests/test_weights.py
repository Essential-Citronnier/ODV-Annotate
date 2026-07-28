# test_weights.py
# OpenDicomViewer
#
# Covers the section 4b install hook. Two properties carry real weight: exit 0
# must mean the files are genuinely present, since the host marks a task ready
# on that alone, and a licence key must never reach stdout or any file the
# adapter writes, since argv is world-readable and the plugin log view is not
# private either.
# Licensed under the MIT License. See LICENSE for details.
"""Tests for the shared weight acquisition hook."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from _shared.protocol import ErrorCode, PluginError  # noqa: E402
from _shared.weights import (  # noqa: E402
    LICENSE_KEY_ENV,
    install_arg_present,
    license_key,
    parse_install_args,
    run_install,
    verify_manual_checkpoint,
)

SECRET = "aca_TESTKEY000000"


def _args(tmp_path, source="huggingface", **overrides):
    argv = ["--install-weights", "--weight-id", overrides.get("weight_id", "w1"),
            "--source", source, "--dest", str(tmp_path)]
    if "repo" in overrides:
        argv += ["--repo", overrides["repo"]]
    if "task" in overrides:
        argv += ["--task", overrides["task"]]
    return parse_install_args("test", argv)


# ---------------------------------------------------------------------------
# Mode detection and parsing
# ---------------------------------------------------------------------------


def test_install_mode_is_detected_from_argv():
    assert install_arg_present(["--install-weights", "--weight-id", "w"]) is True
    assert install_arg_present(["--port", "8765"]) is False
    assert install_arg_present(["--task", "total", "--out", "/tmp/x"]) is False


def test_manifest_fields_are_carried_verbatim(tmp_path):
    args = _args(tmp_path, source="huggingface", weight_id="sam2.1-hiera-small",
                 repo="facebook/sam2.1-hiera-small")
    assert args.weight_id == "sam2.1-hiera-small"
    assert args.source == "huggingface"
    assert args.repo == "facebook/sam2.1-hiera-small"
    assert args.task is None


def test_optional_manifest_fields_default_to_none(tmp_path):
    args = _args(tmp_path)
    assert args.repo is None and args.task is None


# ---------------------------------------------------------------------------
# Exit convention
# ---------------------------------------------------------------------------


def test_success_requires_the_files_to_actually_exist(tmp_path):
    def installer(args, dest, reporter):
        (dest / "model.safetensors").write_bytes(b"weights")
        return [dest / "model.safetensors"]

    assert run_install(_args(tmp_path), installer) == 0


def test_an_installer_that_downloads_nothing_does_not_exit_zero(tmp_path, capsys):
    """Exit 0 means the weights are present; the host marks a task ready on it."""
    def installer(args, dest, reporter):
        return [dest / "model.safetensors"]

    assert run_install(_args(tmp_path), installer) == 1
    assert "model.safetensors" in capsys.readouterr().err


def test_the_destination_directory_is_created(tmp_path):
    dest = tmp_path / "weights" / "sam2"
    args = parse_install_args("test", ["--install-weights", "--weight-id", "w",
                                       "--source", "manual", "--dest", str(dest)])
    run_install(args, lambda a, d, r: [])
    assert dest.is_dir()


def test_a_plugin_error_is_reported_with_its_code(tmp_path, capsys):
    def installer(args, dest, reporter):
        raise PluginError(ErrorCode.LICENSE_REQUIRED, "accept the terms first")

    assert run_install(_args(tmp_path), installer) == 1
    body = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert body["ok"] is False
    assert body["error"]["code"] == "license_required"


def test_an_unexpected_exception_becomes_internal(tmp_path, capsys):
    def installer(args, dest, reporter):
        raise RuntimeError("hub exploded")

    assert run_install(_args(tmp_path), installer) == 1
    body = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert body["error"]["code"] == "internal"
    assert "RuntimeError" in body["error"]["message"]


def test_progress_uses_the_section_4_line_format(tmp_path, capsys):
    def installer(args, dest, reporter):
        reporter.stage(0.05, 0.95, "Downloading")
        (dest / "f").write_bytes(b"x")
        return [dest / "f"]

    run_install(_args(tmp_path), installer)
    lines = [json.loads(line) for line in capsys.readouterr().out.strip().splitlines()]
    assert all({"progress", "message"} <= set(line) for line in lines)
    assert lines[-1]["progress"] == 1.0


# ---------------------------------------------------------------------------
# Licence keys come from the environment (section 4b)
# ---------------------------------------------------------------------------


def test_the_licence_key_is_read_from_the_environment(monkeypatch):
    monkeypatch.setenv(LICENSE_KEY_ENV, SECRET)
    assert license_key() == SECRET


def test_an_absent_or_blank_key_reads_as_none(monkeypatch):
    monkeypatch.delenv(LICENSE_KEY_ENV, raising=False)
    assert license_key() is None
    monkeypatch.setenv(LICENSE_KEY_ENV, "   ")
    assert license_key() is None


def test_the_key_never_reaches_stdout_or_a_written_file(tmp_path, capsys, monkeypatch):
    """argv is world-readable via ps, and the plugin log view is not private.

    An installer that reads the key must be able to use it without it leaking
    into either, so this asserts the harness itself adds no such leak.
    """
    monkeypatch.setenv(LICENSE_KEY_ENV, SECRET)

    def installer(args, dest, reporter):
        assert license_key() == SECRET
        reporter.log("Registering the academic licence number")
        (dest / "notes.txt").write_text("installed")
        (dest / "model.bin").write_bytes(b"w")
        return [dest / "model.bin"]

    assert run_install(_args(tmp_path), installer) == 0
    captured = capsys.readouterr()
    assert SECRET not in captured.out
    assert SECRET not in captured.err
    for path in tmp_path.rglob("*"):
        if path.is_file():
            assert SECRET not in path.read_text(errors="ignore")


def test_the_key_is_absent_from_the_parsed_arguments(tmp_path):
    """It must arrive in the environment, so no flag may carry it."""
    args = _args(tmp_path)
    assert not any("license" in name or "key" in name for name in vars(args))


# ---------------------------------------------------------------------------
# The manual source never downloads
# ---------------------------------------------------------------------------


def test_a_present_manual_checkpoint_verifies(tmp_path):
    (tmp_path / "sam3.pt").write_bytes(b"checkpoint")
    found = verify_manual_checkpoint(tmp_path, "sam3.pt", "https://example/terms", "msg")
    assert found == [tmp_path / "sam3.pt"]


def test_a_directory_format_checkpoint_is_accepted(tmp_path):
    """A hub snapshot download produces a directory, not a single file."""
    (tmp_path / "config.json").write_text("{}")
    (tmp_path / "model.safetensors").write_bytes(b"w")
    found = verify_manual_checkpoint(tmp_path, "sam3.pt", "https://example/terms", "msg")
    assert (tmp_path / "model.safetensors") in found


def test_an_absent_manual_checkpoint_is_license_required(tmp_path):
    with pytest.raises(PluginError) as info:
        verify_manual_checkpoint(tmp_path, "sam3.pt",
                                 "https://huggingface.co/facebook/sam3",
                                 "SAM 3 weights are gated.")
    assert info.value.code is ErrorCode.LICENSE_REQUIRED
    # The message must name both the terms URL and the exact expected path;
    # the store shows them verbatim and the user cannot act without either.
    assert "https://huggingface.co/facebook/sam3" in info.value.message
    assert str(tmp_path / "sam3.pt") in info.value.message
