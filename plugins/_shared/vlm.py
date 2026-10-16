# vlm.py
# OpenDicomViewer
#
# Cancellable text generation for the two Gemma servers (the built-in
# mlx-server and the Gemma plugin).
#
# mlx_vlm.generate runs to completion once started. When the viewer gives up on
# a request -- its timeout fires, or the user retries -- the abandoned
# generation would keep the model busy and the retry would queue behind it.
# Streaming instead lets the loop check a cancel flag between tokens.
# mlx_vlm is imported inside the function (see __init__.py).
# Licensed under the MIT License. See LICENSE for details.
"""Run one chat-formatted generation that stops when asked to."""

from __future__ import annotations

import threading
from typing import Any

__all__ = ["GenerationCancelled", "chat_messages", "generate_text"]


class GenerationCancelled(Exception):
    """The caller stopped waiting; whatever was generated is discarded."""


def chat_messages(system_prompt: str, prompt: str) -> list[dict]:
    """One system turn and one user turn holding the image and the prompt."""
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": [{"type": "image"}, {"type": "text", "text": prompt}]},
    ]


def generate_text(model: Any, processor: Any, system_prompt: str, prompt: str, image: Any,
                  lock: threading.Lock, cancel: threading.Event | None = None,
                  **options: Any) -> str:
    """Generate a reply to `prompt` about `image`, serialized on `lock`.

    Raises GenerationCancelled when `cancel` is set while waiting for the lock
    or between tokens.
    """
    from mlx_vlm import stream_generate

    with lock:
        if cancel is not None and cancel.is_set():
            raise GenerationCancelled()
        formatted = processor.apply_chat_template(
            chat_messages(system_prompt, prompt), add_generation_prompt=True)
        # mlx_vlm.generate resets the stopping criteria before streaming; a
        # previous cancelled run must not leave them in another state.
        tokenizer = getattr(processor, "tokenizer", processor)
        criteria = getattr(tokenizer, "stopping_criteria", None)
        eos = getattr(getattr(model, "config", None), "eos_token_id", None)
        if criteria is not None and hasattr(criteria, "reset") and eos is not None:
            criteria.reset(eos)
        pieces: list[str] = []
        for chunk in stream_generate(model, processor, formatted, image=[image], **options):
            if cancel is not None and cancel.is_set():
                raise GenerationCancelled()
            if getattr(chunk, "is_draft", False):
                continue
            pieces.append(getattr(chunk, "text", "") or "")
        return "".join(pieces)
