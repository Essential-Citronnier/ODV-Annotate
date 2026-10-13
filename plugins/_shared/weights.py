# weights.py
# OpenDicomViewer
#
# The weight acquisition hook of PLUGIN_PROTOCOL.md section 4b.
#
# Every adapter implements the same extra CLI mode, so the parsing, the
# progress reporting, and the exit convention live here and each adapter
# supplies only the part that knows its model hub.
#
# Two rules from 4b are enforced in this module rather than trusted to each
# adapter. First, exit 0 must mean the files are actually present under --dest,
# so `run_install` verifies that before reporting success -- an installer that
# silently downloaded nothing would otherwise leave the host believing a task
# is ready. Second, the licence key arrives in the environment because argv is
# world-readable through `ps`; `license_key()` is the only way this package
# reads it, and it is never logged, echoed, or written to a file.
# Licensed under the MIT License. See LICENSE for details.
"""Shared implementation of the `--install-weights` CLI mode."""

from __future__ import annotations

import argparse
import os
import sys
import threading
from pathlib import Path
from typing import Callable, Sequence

from .lifeline import start_parent_watch
from .progress import ProgressReporter, emit_log, emit_progress
from .protocol import ErrorCode, PluginError, error_payload

__all__ = [
    "LICENSE_KEY_ENV",
    "WEIGHTS_DIR_ENV",
    "installed_weight_dir",
    "safe_component",
    "install_arg_present",
    "license_key",
    "parse_install_args",
    "run_install",
    "download_huggingface",
    "hub_cache_snapshot",
    "adopt_snapshot",
    "verify_manual_checkpoint",
]

# Section 4b: the host passes a licence key here, never in argv.
LICENSE_KEY_ENV = "ODV_PLUGIN_LICENSE_KEY"

# Section 4d: the plugin's weights root. Weight <id> lives in
# $ODV_WEIGHTS_DIR/<id>/, the directory the install hook was given as --dest.
WEIGHTS_DIR_ENV = "ODV_WEIGHTS_DIR"


def safe_component(identifier: str) -> str:
    """Fold an identifier to the path component the host uses for it.

    Mirrors `PluginPaths.safeComponent` in the host: anything outside
    letters, digits, '-', '_' and '.' becomes '-'. The two must agree, or an
    adapter would look for its weights one directory away from where the host
    installed them.
    """
    folded = "".join(ch if (ch.isalnum() or ch in "-_.") else "-" for ch in identifier)
    return "plugin" if folded in ("", ".", "..") else folded


def installed_weight_dir(plugin_id: str, weight_id: str,
                         override_env: str | None = None) -> Path:
    """The directory the host installed `weight_id` into.

    Resolution order:

    1. `override_env`, when the adapter names one and it is set -- for
       running an adapter by hand against weights kept elsewhere.
    2. `$ODV_WEIGHTS_DIR/<weight_id>`, which the host always sets.
    3. The host's default layout under Application Support, so an adapter
       started standalone on a machine with the app installed still finds
       what the store downloaded.
    """
    if override_env:
        override = os.environ.get(override_env, "").strip()
        if override:
            return Path(override).expanduser()
    root = os.environ.get(WEIGHTS_DIR_ENV, "").strip()
    if root:
        return Path(root).expanduser() / safe_component(weight_id)
    return (Path.home() / "Library" / "Application Support" / "OpenDicomViewer"
            / "plugins" / safe_component(plugin_id) / "weights"
            / safe_component(weight_id))


def install_arg_present(argv: Sequence[str] | None = None) -> bool:
    """Whether this invocation is the weight-install mode.

    Checked before the adapter's normal argument parsing, because the install
    CLI shares no required flags with either the server or the one-shot CLI and
    would otherwise be rejected by them.
    """
    return "--install-weights" in (list(argv) if argv is not None else sys.argv[1:])


def license_key() -> str | None:
    """The licence key the host passed in the environment, if any.

    Returns None when unset or blank. Callers must not log the value or write
    it into any file they create.
    """
    value = os.environ.get(LICENSE_KEY_ENV, "").strip()
    return value or None


def parse_install_args(description: str,
                       argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the section 4b install CLI.

    `--weight-id`, `--source`, `--repo`, `--revision`, and `--task` carry manifest fields
    verbatim; they are accepted as free strings rather than validated against a
    fixed set so that adding a weight to the manifest does not require editing
    the parser.
    """
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--install-weights", action="store_true", required=True,
                        help="Acquire weights instead of serving or segmenting")
    parser.add_argument("--weight-id", required=True,
                        help="Weight id from the manifest")
    parser.add_argument("--source", required=True,
                        help="Weight source from the manifest")
    parser.add_argument("--dest", required=True,
                        help="Host-owned directory the weights must land in")
    parser.add_argument("--repo", default=None,
                        help="Hugging Face repo id, when the manifest declares one")
    parser.add_argument("--revision", default=None,
                        help="Hugging Face commit to pin, when the manifest declares one")
    parser.add_argument("--task", default=None,
                        help="TotalSegmentator task name, when applicable")
    return parser.parse_args(argv)


def run_install(
    args: argparse.Namespace,
    installer: Callable[[argparse.Namespace, Path, ProgressReporter], Sequence[Path]],
) -> int:
    """Run `installer` and report in the section 4b convention.

    The installer receives the parsed arguments, the resolved destination, and
    a progress reporter, and returns the paths that must exist for the weight
    id to count as installed. It raises `PluginError` for anything it can
    describe in protocol terms.
    """
    # A download abandoned by a crashed host would otherwise run to completion
    # into a directory nobody will mark complete.
    start_parent_watch()
    dest = Path(args.dest).expanduser().resolve()
    reporter = ProgressReporter()

    try:
        dest.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        return _fail(PluginError(
            ErrorCode.INTERNAL,
            f"Cannot create the weight directory {dest}: {exc}",
            recoverable=False,
        ))

    try:
        expected = installer(args, dest, reporter)
    except PluginError as exc:
        return _fail(exc)
    except KeyboardInterrupt:
        return _fail(PluginError(ErrorCode.INTERNAL, "Interrupted", recoverable=True))
    except BaseException as exc:  # noqa: BLE001 - the host needs a protocol error
        return _fail(PluginError(
            ErrorCode.INTERNAL, f"{type(exc).__name__}: {exc}", recoverable=False
        ))

    # Exit 0 means every file for this weight id is present under --dest, so
    # that claim is checked rather than assumed.
    missing = [str(path) for path in expected if not Path(path).exists()]
    if missing:
        return _fail(PluginError(
            ErrorCode.INTERNAL,
            "The download reported success but these files are absent: "
            + ", ".join(missing),
            recoverable=True,
        ))

    emit_progress(1.0, f"Weights for '{args.weight_id}' are ready")
    return 0


def _fail(error: PluginError) -> int:
    """Report an install failure and return a non-zero exit code.

    The error envelope goes to stdout as a JSON line so the host can read the
    code -- `license_required` in particular must reach the store's gate rather
    than a generic failure -- and the human-readable message also goes to
    stderr, which the plugin log view shows. Section 4b specifies the code and
    the exit status but not the channel; this carries both without inventing a
    new file.
    """
    import json

    sys.stdout.write(json.dumps(
        error_payload(error.code, error.message, error.recoverable)) + "\n")
    sys.stdout.flush()
    sys.stderr.write(f"ERROR: {error.message}\n")
    sys.stderr.flush()
    return 1


# ---------------------------------------------------------------------------
# Source implementations shared by more than one adapter
# ---------------------------------------------------------------------------


def directory_bytes(path: Path) -> int:
    """Total size of the regular files beneath `path` (0 if it is absent)."""
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                continue
    return total


def _expected_repo_bytes(repo: str, revision: str | None,
                         allow_patterns: Sequence[str] | None) -> int | None:
    """Size of what `snapshot_download` will fetch, from the Hub (best effort)."""
    try:
        import fnmatch

        from huggingface_hub import HfApi

        info = HfApi().model_info(repo, revision=revision, files_metadata=True)
        total = 0
        for sibling in info.siblings or []:
            if allow_patterns and not any(fnmatch.fnmatch(sibling.rfilename, pattern)
                                          for pattern in allow_patterns):
                continue
            total += sibling.size or 0
        return total or None
    except Exception:  # noqa: BLE001 - progress is a nicety
        return None


class _DownloadProgress:
    """Reports a download's progress by polling the size of its destination.

    `snapshot_download` offers no byte-level callback that survives across
    hub versions, but it stages every file under `dest` (as
    `.cache/huggingface/download/*.incomplete` until complete), so the size of
    `dest` against the snapshot's total is an honest measure of progress.
    """

    def __init__(self, dest: Path, reporter: ProgressReporter, repo: str,
                 expected: int | None, interval: float = 1.0) -> None:
        self._dest = dest
        self._reporter = reporter
        self._repo = repo
        self._expected = expected
        self._interval = interval
        self._baseline = directory_bytes(dest)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="download-progress",
                                        daemon=True)

    def __enter__(self) -> "_DownloadProgress":
        self._thread.start()
        return self

    def __exit__(self, *_exc) -> None:
        self._stop.set()
        self._thread.join(timeout=2)

    def set_expected(self, expected: int | None) -> None:
        self._expected = expected

    def _run(self) -> None:
        last = -1
        while not self._stop.wait(self._interval):
            done = directory_bytes(self._dest)
            if done == last:
                continue
            last = done
            gb = done / 1e9
            if self._expected:
                self._reporter.within(min(0.99, done / self._expected),
                                      f"Downloading {self._repo}: {gb:.2f} of "
                                      f"{self._expected / 1e9:.2f} GB")
            else:
                self._reporter.log(f"Downloading {self._repo}: {gb:.2f} GB so far")


def download_huggingface(repo: str, dest: Path, reporter: ProgressReporter,
                         allow_patterns: Sequence[str] | None = None,
                         revision: str | None = None) -> list[Path]:
    """Download a Hugging Face repo into `dest` and return the files fetched.

    `local_dir` is used rather than the shared hub cache so that the weights
    live under the host-owned directory the store manages and can delete when
    the user removes the plugin, instead of accumulating in a cache the host
    does not know about.

    `revision` pins a commit so a re-upload cannot change the weights the
    adapter was validated against. Progress is reported while the download
    runs by polling the size of `dest`.
    """
    if not repo:
        raise PluginError(
            ErrorCode.BAD_INPUT,
            "--repo is required for the huggingface source",
            recoverable=False,
        )
    # Plain HTTP rather than Xet: Xet writes a file late, so polling `dest`
    # (the only progress measure that survives hub versions) stood still for
    # minutes. Set before huggingface_hub is first imported in this process.
    os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        raise PluginError(
            ErrorCode.NOT_READY,
            "huggingface_hub is not installed in this plugin's environment. "
            "Reinstall the plugin from the store.",
        ) from None

    label = f"{repo}@{revision[:12]}" if revision else repo
    reporter.stage(0.05, 0.95, f"Downloading {label}")
    try:
        with _DownloadProgress(dest, reporter, repo, expected=None) as progress:
            # Asked beside the download, not before it, so a slow metadata
            # call never delays the transfer itself.
            sizer = threading.Thread(
                target=lambda: progress.set_expected(
                    _expected_repo_bytes(repo, revision, allow_patterns)),
                name="snapshot-size", daemon=True)
            sizer.start()
            snapshot_download(
                repo_id=repo,
                revision=revision,
                local_dir=str(dest),
                allow_patterns=list(allow_patterns) if allow_patterns else None,
            )
    except BaseException as exc:  # noqa: BLE001 - hub errors are many and unstable
        # A gated or private repo answers 401/403. That is a licence problem,
        # not a network problem, and the host must route it to the gate.
        text = f"{type(exc).__name__}: {exc}"
        if any(token in text for token in ("401", "403", "GatedRepo", "gated")):
            raise PluginError(
                ErrorCode.LICENSE_REQUIRED,
                f"Access to {repo} was refused. The model terms must be accepted "
                f"at https://huggingface.co/{repo} before its weights can be "
                f"downloaded.",
            ) from None
        raise PluginError(
            ErrorCode.INTERNAL, f"Could not download {label}: {text}"
        ) from None

    return [path for path in dest.rglob("*") if path.is_file()]


def _hub_cache_dir() -> Path:
    """The Hugging Face hub cache, honouring HF_HUB_CACHE / HF_HOME.

    Resolved by hand rather than through huggingface_hub so that it works
    before (and without) that package being importable.
    """
    if os.environ.get("HF_HUB_CACHE"):
        return Path(os.environ["HF_HUB_CACHE"]).expanduser()
    home = os.environ.get("HF_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache", "huggingface")
    return Path(home).expanduser() / "hub"


def hub_cache_snapshot(repo: str, revision: str | None,
                       cache_dir: Path | None = None) -> Path | None:
    """A complete snapshot of `repo` at `revision` in the hub cache, or None.

    This is where the built-in mlx-server downloads the same Gemma model.
    Only an exact commit counts -- a branch name could have moved since -- and
    only a snapshot whose weights are all there: the hub links each file into
    the snapshot as it finishes, so an interrupted download can leave
    config.json behind without the shards. When the model ships a shard index,
    every shard it names must be present.
    """
    if not repo or not revision or len(revision) != 40:
        return None
    root = cache_dir if cache_dir is not None else _hub_cache_dir()
    snapshot = root / ("models--" + repo.replace("/", "--")) / "snapshots" / revision
    if not (snapshot / "config.json").is_file():
        return None
    index = snapshot / "model.safetensors.index.json"
    if index.is_file():
        import json

        try:
            shards = set(json.loads(index.read_text()).get("weight_map", {}).values())
        except (OSError, ValueError):
            return None
        if not shards or not all((snapshot / shard).is_file() for shard in shards):
            return None
    elif not any(path.is_file() for path in snapshot.glob("*.safetensors")):
        return None
    return snapshot


def _link_or_clone(source: Path, target: Path) -> None:
    """Place `source` at `target` without a second copy on disk where possible.

    A hard link first: the file then has two names and one set of blocks, and
    survives either name being deleted (the hub cache being cleared, or the
    plugin being removed). Across volumes that fails, and an APFS clone
    (`cp -c`) is the next best: copy-on-write, so still no extra space. A plain
    copy is the last resort, and still beats downloading 5 GB again.
    """
    if target.exists() or target.is_symlink():
        target.unlink()
    try:
        os.link(source, target)
        return
    except OSError:
        pass
    import shutil
    import subprocess

    if sys.platform == "darwin":
        result = subprocess.run(["/bin/cp", "-c", str(source), str(target)],
                                capture_output=True)
        if result.returncode == 0:
            return
    shutil.copy2(source, target)


def adopt_snapshot(snapshot: Path, dest: Path, reporter: ProgressReporter) -> list[Path]:
    """Populate `dest` from a hub-cache snapshot instead of downloading.

    The snapshot's entries are symlinks into the cache's blob store; each is
    resolved and linked (see `_link_or_clone`) under its file name, so `dest`
    ends up in the same flat layout `download_huggingface` produces.
    """
    reporter.stage(0.05, 0.95, f"Reusing the model already downloaded at {snapshot}")
    entries = sorted(path for path in snapshot.rglob("*")
                     if path.is_file() and not path.name.startswith("."))
    placed: list[Path] = []
    for index, entry in enumerate(entries, start=1):
        relative = entry.relative_to(snapshot)
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        _link_or_clone(entry.resolve(), target)
        placed.append(target)
        reporter.within(index / max(1, len(entries)), f"Linked {relative}")
    return placed


def verify_manual_checkpoint(dest: Path, filename: str | None, terms_url: str,
                             message: str) -> list[Path]:
    """Verify a manually placed checkpoint without downloading anything.

    Section 4b is explicit that a `manual` source must not attempt a download:
    the whole point of the gate is that a human accepted terms under a named
    account, and an adapter that fetched the file anyway would either fail or
    quietly route around that.
    """
    candidate = dest / filename if filename else None
    if candidate is not None and candidate.is_file():
        return [candidate]

    # A directory-format checkpoint is accepted too: Hugging Face's own
    # snapshot download produces one, and making the user repackage it into a
    # single file would be an obstacle with no purpose.
    config = dest / "config.json"
    if config.is_file():
        present = [dest / name for name in ("model.safetensors", "pytorch_model.bin")
                   if (dest / name).is_file()]
        if present:
            return [config, *present]

    raise PluginError(
        ErrorCode.LICENSE_REQUIRED,
        f"{message} Accept the terms at {terms_url}, then place the checkpoint at "
        f"{candidate if candidate is not None else dest}.",
    )
