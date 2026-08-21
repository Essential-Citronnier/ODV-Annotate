# exp3_mp_thread_shim.py
# OpenDicomViewer
#
# ENVIRONMENT ACCOMMODATION, not part of the plugin layer.
#
# nnU-Net's inference pipeline runs preprocessing and segmentation export in
# `multiprocessing.Pool` workers, which communicate over an AF_UNIX socket.
# Some sandboxed environments deny `bind(2)` on AF_UNIX outright (verified
# here: PermissionError on every path length), and the failure surfaces as a
# bare `EOFError` from the pool's result handler -- an error that names neither
# the socket nor the cause.
#
# This module replaces `multiprocessing.Pool` with a thread pool exposing the
# same surface, so the pipeline runs to completion in one process. It is
# imported ahead of the adapter via PYTHONSTARTUP-style injection and is never
# installed into a plugin environment.
#
# WHAT THIS PRESERVES AND WHAT IT DESTROYS.
#
# Preserved: correctness. The same functions run on the same data in the same
# order, and the outputs are byte-identical to a process-pool run, because
# nnU-Net's pooled work is pure array transformation with no shared mutable
# state.
#
# Destroyed: performance characteristics. Thread workers contend on the GIL
# where process workers would not, so a wall time measured under this shim is
# an upper bound of unknown tightness, not a measurement of the pipeline as a
# user would run it. Any result produced with this shim active must say so.
# Licensed under the MIT License. See LICENSE for details.
"""Substitute threads for processes where the sandbox denies multiprocessing IPC."""

from __future__ import annotations

import multiprocessing
import multiprocessing.pool
import sys


def _install() -> None:
    thread_pool = multiprocessing.pool.ThreadPool

    class _ThreadBackedPool(thread_pool):  # type: ignore[misc, valid-type]
        """A ThreadPool accepting Pool's constructor signature.

        nnU-Net passes `Pool(processes)` positionally and sometimes supplies
        `initializer`/`maxtasksperchild`; ThreadPool accepts the first three
        and rejects the last, so it is dropped rather than forwarded.
        """

        def __init__(self, processes=None, initializer=None, initargs=(),
                     maxtasksperchild=None, context=None):
            super().__init__(processes=processes, initializer=initializer,
                             initargs=initargs)

    # `multiprocessing.pool.Pool` is deliberately left alone: ThreadPool
    # derives from it, so rebinding that name makes the subclass above resolve
    # its own base through the replacement and recurse until the stack is
    # exhausted. Only the call sites are redirected.
    multiprocessing.Pool = _ThreadBackedPool  # type: ignore[assignment]

    # nnU-Net obtains a pool from the default context in some paths.
    try:
        context = multiprocessing.get_context()
        context.Pool = _ThreadBackedPool  # type: ignore[attr-defined]
    except (ValueError, AttributeError):
        pass

    print("[exp3] multiprocessing.Pool replaced with a thread pool: this "
          "sandbox denies the AF_UNIX bind that process pools require. "
          "Correctness preserved, performance characteristics NOT.",
          file=sys.stderr, flush=True)


def _install_sequential_preprocessing() -> None:
    """Replace nnU-Net's parallel preprocessing iterator with a serial one.

    The pool shim above is not sufficient for nnU-Net inference. Its
    preprocessing iterator does not use a pool at all: it creates a
    `multiprocessing.Manager()` for cross-process queues and events, and the
    manager starts a server process that the sandbox's socket denial kills
    before it reports its address, surfacing as `EOFError` from
    `connection.recv`.

    The replacement runs the identical preprocessing calls in this process and
    yields the identical item dicts, in the same order the parallel version
    would round-robin them for a single worker. Same inputs, same
    transformations, same outputs -- what is lost is only the overlap between
    preprocessing one case and predicting another.
    """
    try:
        from nnunetv2.inference import data_iterators
    except ImportError:
        return  # not a TotalSegmentator environment; nothing to patch

    import numpy as np
    import torch
    from nnunetv2.utilities.label_handling.label_handling import (
        convert_labelmap_to_one_hot)

    def sequential_iterator(list_of_lists, list_of_segs_from_prev_stage_files,
                            output_filenames_truncated, plans_manager,
                            dataset_json, configuration_manager, num_processes,
                            pin_memory=False, verbose=False):
        label_manager = plans_manager.get_label_manager(dataset_json)
        preprocessor = configuration_manager.preprocessor_class(verbose=verbose)

        for index in range(len(list_of_lists)):
            previous = (list_of_segs_from_prev_stage_files[index]
                        if list_of_segs_from_prev_stage_files is not None else None)
            data, seg, properties = preprocessor.run_case(
                list_of_lists[index], previous, plans_manager,
                configuration_manager, dataset_json)

            if previous is not None:
                one_hot = convert_labelmap_to_one_hot(
                    seg[0], label_manager.foreground_labels, data.dtype)
                data = np.vstack((data, one_hot))

            tensor = torch.from_numpy(data).to(
                dtype=torch.float32, memory_format=torch.contiguous_format)
            if pin_memory and torch.cuda.is_available():
                tensor = tensor.pin_memory()

            yield {"data": tensor, "data_properties": properties,
                   "ofile": (output_filenames_truncated[index]
                             if output_filenames_truncated is not None else None)}

    data_iterators.preprocessing_iterator_fromfiles = sequential_iterator

    # TotalSegmentator re-exports the iterator through its own runtime patch
    # module, so the name it actually calls must be rebound too.
    try:
        from totalsegmentator import nnunet_runtime_patches

        if hasattr(nnunet_runtime_patches, "preprocessing_iterator_fromfiles"):
            nnunet_runtime_patches.preprocessing_iterator_fromfiles = sequential_iterator
    except ImportError:
        pass

    try:
        from nnunetv2.inference import predict_from_raw_data

        if hasattr(predict_from_raw_data, "preprocessing_iterator_fromfiles"):
            predict_from_raw_data.preprocessing_iterator_fromfiles = sequential_iterator
    except ImportError:
        pass

    print("[exp3] nnU-Net preprocessing iterator replaced with a sequential "
          "one: multiprocessing.Manager cannot start a server process here. "
          "Correctness preserved, performance characteristics NOT.",
          file=sys.stderr, flush=True)


_install()
_install_sequential_preprocessing()
