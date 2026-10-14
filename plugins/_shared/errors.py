# errors.py
# OpenDicomViewer
#
# Plain-language hints for the failures outside users actually hit: no
# network on first run, a full disk, Metal running out of memory.
# Standard library only (see __init__.py).
# Licensed under the MIT License. See LICENSE for details.
"""Turn an exception into a message a user can act on."""

from __future__ import annotations

__all__ = ["describe_failure", "failure_hint"]

_NETWORK = (
    "connecterror", "connectionerror", "connection refused", "connection reset",
    "max retries exceeded", "name or service not known", "nodename nor servname",
    "temporary failure in name resolution", "network is unreachable",
    "localentrynotfounderror", "offline mode", "readtimeout", "timed out",
    "sslerror", "certificate verify failed", "proxyerror",
)
_ACCESS = ("401 client error", "403 client error", "gatedrepoerror", "repositorynotfounderror", "unauthorized")
_DISK = ("no space left on device", "errno 28", "disk quota exceeded")
_MEMORY = ("out of memory", "metal::malloc", "insufficient memory", "memoryerror",
           "resource_exhausted", "kiogpucommandbuffercallbackerroroutofmemory")


def failure_hint(text: str) -> str | None:
    """A one-sentence remedy for a recognised failure, or None."""
    lowered = text.lower()
    if any(token in lowered for token in _DISK):
        return ("The disk is full. The Gemma model needs about 5.2 GB free; "
                "free up space and try again.")
    if any(token in lowered for token in _MEMORY):
        return ("The Mac ran out of memory for the model. Quit other apps "
                "(16 GB of RAM is recommended) and try again.")
    if any(token in lowered for token in _ACCESS):
        return ("Hugging Face refused the download. Check that huggingface.co is "
                "reachable without a login from this network, then try again.")
    if any(token in lowered for token in _NETWORK):
        return ("Could not reach Hugging Face to download the model. Check the "
                "internet connection (and any proxy or firewall), then try again; "
                "the download resumes where it stopped.")
    return None


def describe_failure(exc: BaseException) -> str:
    """`Type: message`, followed by a hint when the failure is recognised."""
    text = f"{type(exc).__name__}: {exc}"
    hint = failure_hint(text)
    return f"{text}\n{hint}" if hint else text
