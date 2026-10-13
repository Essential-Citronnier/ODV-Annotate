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
    if "revision" in overrides:
        argv += ["--revision", overrides["revision"]]
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
    assert args.repo is None and args.task is None and args.revision is None


def test_revision_is_carried(tmp_path):
    args = _args(tmp_path, repo="org/model", revision="abc123")
    assert args.revision == "abc123"


def test_download_pins_the_revision_and_reports_progress(tmp_path, capsys, monkeypatch):
    """The revision reaches snapshot_download, and progress lines are emitted
    from the growing size of the destination while the download runs."""
    import time
    import types

    from _shared import weights
    from _shared.progress import ProgressReporter

    calls = {}

    def fake_snapshot_download(repo_id, revision=None, local_dir=None, allow_patterns=None):
        calls.update(repo_id=repo_id, revision=revision)
        target = Path(local_dir)
        for index in range(3):
            (target / f"part{index}").write_bytes(b"x" * 400)
            time.sleep(0.25)
        return local_dir

    hub = types.ModuleType("huggingface_hub")
    hub.snapshot_download = fake_snapshot_download
    monkeypatch.setitem(sys.modules, "huggingface_hub", hub)
    monkeypatch.setattr(weights, "_expected_repo_bytes", lambda *a: 1200)
    monkeypatch.setattr(weights._DownloadProgress, "__init__",
                        _fast_progress_init(weights._DownloadProgress.__init__))

    files = weights.download_huggingface("org/model", tmp_path, ProgressReporter(),
                                         revision="abc123")
    assert calls == {"repo_id": "org/model", "revision": "abc123"}
    assert len(files) == 3
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()
             if line.startswith("{")]
    polled = [line for line in lines if line["message"].startswith("Downloading org/model:")]
    assert polled, lines
    # Interpolated inside the download stage (0.05-0.95), and advancing.
    assert all(0.05 < line["progress"] <= 0.95 for line in polled)
    assert polled[-1]["progress"] > polled[0]["progress"] or len(polled) == 1


def _fast_progress_init(original):
    def init(self, dest, reporter, repo, expected, interval=1.0):
        original(self, dest, reporter, repo, expected, interval=0.05)
    return init


def test_directory_bytes_counts_nested_files(tmp_path):
    from _shared.weights import directory_bytes

    (tmp_path / "a").write_bytes(b"x" * 10)
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "b.incomplete").write_bytes(b"x" * 5)
    assert directory_bytes(tmp_path) == 15
    assert directory_bytes(tmp_path / "missing") == 0


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


# ---------------------------------------------------------------------------
# Section 4d: where an installed weight lives
# ---------------------------------------------------------------------------

from _shared.weights import (  # noqa: E402
    WEIGHTS_DIR_ENV,
    installed_weight_dir,
    safe_component,
)


def test_safe_component_matches_the_host_folding():
    # PluginPaths.safeComponent: keep letters, digits, '-', '_', '.'.
    assert safe_component("sam2.1-hiera-small") == "sam2.1-hiera-small"
    assert safe_component("Dataset297_TotalSegmentator_total_3mm_1559subj") == \
        "Dataset297_TotalSegmentator_total_3mm_1559subj"
    assert safe_component("a/b c") == "a-b-c"
    assert safe_component("..") == "plugin"
    assert safe_component("") == "plugin"


def test_installed_weight_dir_follows_the_host_variable(monkeypatch, tmp_path):
    monkeypatch.setenv(WEIGHTS_DIR_ENV, str(tmp_path))
    monkeypatch.delenv("ODV_TEST_OVERRIDE", raising=False)
    assert installed_weight_dir("sam2", "sam2.1-hiera-small",
                                override_env="ODV_TEST_OVERRIDE") \
        == tmp_path / "sam2.1-hiera-small"


def test_installed_weight_dir_prefers_an_explicit_override(monkeypatch, tmp_path):
    monkeypatch.setenv(WEIGHTS_DIR_ENV, str(tmp_path / "host"))
    monkeypatch.setenv("ODV_TEST_OVERRIDE", str(tmp_path / "mine"))
    assert installed_weight_dir("sam2", "w", override_env="ODV_TEST_OVERRIDE") \
        == tmp_path / "mine"


def test_installed_weight_dir_defaults_to_the_app_layout(monkeypatch):
    monkeypatch.delenv(WEIGHTS_DIR_ENV, raising=False)
    path = installed_weight_dir("gemma-4-e4b", "gemma-4-e4b-it-4bit")
    assert path.parts[-4:] == ("plugins", "gemma-4-e4b", "weights", "gemma-4-e4b-it-4bit")
    assert "OpenDicomViewer" in path.parts


def test_adapters_look_where_the_host_installs(monkeypatch, tmp_path):
    """Each adapter's weight lookup must land in $ODV_WEIGHTS_DIR/<weight id>.

    The weight ids are the ones plugins.json declares; a mismatch here is the
    defect this contract exists to remove.
    """
    import importlib.util

    monkeypatch.setenv(WEIGHTS_DIR_ENV, str(tmp_path))
    for env in ("ODV_SAM2_WEIGHTS", "ODV_SAM3_WEIGHTS", "ODV_GEMMA_WEIGHTS"):
        monkeypatch.delenv(env, raising=False)

    manifest = json.loads((Path(__file__).resolve().parents[3] / "Sources"
                           / "OpenDicomViewer" / "Resources" / "plugins.json").read_text())
    declared = {plugin["id"]: {w["id"] for task in plugin["tasks"] for w in task["weights"]}
                for plugin in manifest["plugins"]}

    root = Path(__file__).resolve().parents[2]

    def load(name):
        spec = importlib.util.spec_from_file_location(f"adapter_{name}", root / name / "server.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    sam2 = load("sam2")
    assert sam2.WEIGHT_ID in declared[sam2.PLUGIN_ID]
    assert sam2.weights_dir() == tmp_path / sam2.WEIGHT_ID

    sam3 = load("sam3")
    assert sam3.WEIGHT_ID in declared[sam3.PLUGIN_ID]
    # The store's manualWeightPath: <weights root>/<weight id>/<filename>.
    assert sam3.Sam3Backend().checkpoint_path() == tmp_path / sam3.WEIGHT_ID / "sam3.pt"

    gemma = load("gemma")
    assert gemma.WEIGHT_ID in declared[gemma.PLUGIN_ID]
    with pytest.raises(PluginError) as missing:
        gemma.model_source()
    assert missing.value.code == ErrorCode.NOT_READY
    installed = tmp_path / gemma.WEIGHT_ID
    installed.mkdir()
    (installed / "config.json").write_text("{}")
    assert gemma.model_source() == str(installed)


# ---------------------------------------------------------------------------
# Reusing the built-in server's hub-cache copy (one Gemma copy on disk)
# ---------------------------------------------------------------------------

REV = "475b9088d29754a3379866cf5aeb6b41acd313c2"
REPO = "mlx-community/gemma-4-E4B-it-4bit"


def _hub_snapshot(cache: Path, files: dict[str, bytes], revision: str = REV) -> Path:
    """Stage a hub-cache snapshot: content in blobs/, symlinks in snapshots/."""
    repo_dir = cache / ("models--" + REPO.replace("/", "--"))
    blobs = repo_dir / "blobs"
    snapshot = repo_dir / "snapshots" / revision
    blobs.mkdir(parents=True, exist_ok=True)
    snapshot.mkdir(parents=True, exist_ok=True)
    for index, (name, data) in enumerate(files.items()):
        blob = blobs / f"blob{index}"
        blob.write_bytes(data)
        (snapshot / name).symlink_to(blob)
    return snapshot


def test_hub_cache_snapshot_requires_a_complete_pinned_commit(tmp_path):
    from _shared.weights import hub_cache_snapshot

    assert hub_cache_snapshot(REPO, REV, cache_dir=tmp_path) is None
    _hub_snapshot(tmp_path, {"config.json": b"{}"})
    assert hub_cache_snapshot(REPO, REV, cache_dir=tmp_path) is None, "no shards yet"
    _hub_snapshot(tmp_path, {"model.safetensors": b"w" * 10})
    assert hub_cache_snapshot(REPO, REV, cache_dir=tmp_path) is not None
    # A branch name is not a pin: it may have moved since the cache was filled.
    assert hub_cache_snapshot(REPO, "main", cache_dir=tmp_path) is None
    assert hub_cache_snapshot(REPO, None, cache_dir=tmp_path) is None


def test_hub_cache_snapshot_checks_every_indexed_shard(tmp_path):
    from _shared.weights import hub_cache_snapshot

    index = json.dumps({"weight_map": {"a": "m-1.safetensors", "b": "m-2.safetensors"}})
    _hub_snapshot(tmp_path, {"config.json": b"{}", "model.safetensors.index.json": index.encode(),
                             "m-1.safetensors": b"1"})
    assert hub_cache_snapshot(REPO, REV, cache_dir=tmp_path) is None
    _hub_snapshot(tmp_path, {"m-2.safetensors": b"2"})
    assert hub_cache_snapshot(REPO, REV, cache_dir=tmp_path) is not None


def test_adopt_snapshot_links_without_a_second_copy(tmp_path):
    import os

    from _shared.progress import ProgressReporter
    from _shared.weights import adopt_snapshot

    snapshot = _hub_snapshot(tmp_path / "cache",
                             {"config.json": b"{}", "model.safetensors": b"w" * 100})
    dest = tmp_path / "weights"
    dest.mkdir()
    (dest / "model.safetensors").write_bytes(b"partial")  # a partial earlier attempt
    placed = adopt_snapshot(snapshot, dest, ProgressReporter())

    assert sorted(p.name for p in placed) == ["config.json", "model.safetensors"]
    target = dest / "model.safetensors"
    assert not target.is_symlink(), "a symlink would dangle if the hub cache is cleared"
    assert target.read_bytes() == b"w" * 100
    blob = (snapshot / "model.safetensors").resolve()
    assert os.stat(target).st_ino == os.stat(blob).st_ino, "same blocks, not a copy"


def test_gemma_install_prefers_the_hub_cache(tmp_path, monkeypatch, capsys):
    import importlib
    import types

    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "gemma"))
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "cache"))
    _hub_snapshot(tmp_path / "cache", {"config.json": b"{}", "model.safetensors": b"w"})
    gemma = importlib.import_module("server")
    try:
        def no_download(*_args, **_kwargs):
            raise AssertionError("must not download when the hub cache has the pin")

        monkeypatch.setattr(gemma, "download_huggingface", no_download)
        args = types.SimpleNamespace(source="huggingface", repo=REPO, revision=REV)
        from _shared.progress import ProgressReporter

        dest = tmp_path / "dest"
        dest.mkdir()
        expected = gemma.install_weights(args, dest, ProgressReporter())
        assert {p.name for p in expected} == {"config.json", "model.safetensors"}
        assert all(p.exists() for p in expected)
    finally:
        sys.modules.pop("server", None)
        sys.path.remove(str(Path(__file__).resolve().parents[2] / "gemma"))
