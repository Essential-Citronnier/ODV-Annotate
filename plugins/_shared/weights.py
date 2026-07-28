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
from pathlib import Path
from typing import Callable, Sequence

from .progress import ProgressReporter, emit_log, emit_progress
from .protocol import ErrorCode, PluginError, error_payload

__all__ = [
    "LICENSE_KEY_ENV",
    "install_arg_present",
    "license_key",
    "parse_install_args",
    "run_install",
    "download_huggingface",
    "verify_manual_checkpoint",
]

# Section 4b: the host passes a licence key here, never in argv.
LICENSE_KEY_ENV = "ODV_PLUGIN_LICENSE_KEY"


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

    `--weight-id`, `--source`, `--repo`, and `--task` carry manifest fields
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


def download_huggingface(repo: str, dest: Path, reporter: ProgressReporter,
                         allow_patterns: Sequence[str] | None = None) -> list[Path]:
    """Download a Hugging Face repo into `dest` and return the files fetched.

    `local_dir` is used rather than the shared hub cache so that the weights
    live under the host-owned directory the store manages and can delete when
    the user removes the plugin, instead of accumulating in a cache the host
    does not know about.
    """
    if not repo:
        raise PluginError(
            ErrorCode.BAD_INPUT,
            "--repo is required for the huggingface source",
            recoverable=False,
        )
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        raise PluginError(
            ErrorCode.NOT_READY,
            "huggingface_hub is not installed in this plugin's environment. "
            "Reinstall the plugin from the store.",
        ) from None

    reporter.stage(0.05, 0.95, f"Downloading {repo}")
    try:
        snapshot_download(
            repo_id=repo,
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
            ErrorCode.INTERNAL, f"Could not download {repo}: {text}"
        ) from None

    return [path for path in dest.rglob("*") if path.is_file()]


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
