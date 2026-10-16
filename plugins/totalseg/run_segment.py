#!/usr/bin/env python3
# run_segment.py
# OpenDicomViewer
#
# TotalSegmentator one-shot adapter (PLUGIN_PROTOCOL.md section 1.3 and 4).
#
# DICOM series -> TotalSegmentator -> per-structure NIfTI -> one binary DICOM
# SEG referencing the source SOP instances, plus per-structure volumes.
#
# The pipeline is adapted from the validated ODV-PE seg-engine runner. Its
# RV/LV strain logic is deliberately left behind: that is a study-specific
# measurement, and this adapter is the general segmentation engine the store
# offers for any CT. What is carried over unchanged is the SEG export, which is
# the part that took real cohort work to get right -- resampling every mask
# onto the source series geometry so that SEG frames and source instances
# correspond slice for slice.
#
# Heavy imports (torch, TotalSegmentator, SimpleITK, highdicom) are made inside
# the functions that need them so `--help` and argument validation stay fast
# and work in an environment where the weights are not installed.
# Licensed under the MIT License. See LICENSE for details.
"""One-shot multi-structure CT segmentation with DICOM SEG output."""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, NamedTuple

# `_shared` lives one directory up; the host spawns this file directly, so only
# this adapter's own directory is on sys.path. See plugins/README.md.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _shared.oneshot import (  # noqa: E402
    OneShotResult,
    option_bool,
    parse_oneshot_args,
    run_oneshot,
)
from _shared.bench import bench_arg_present, run_oneshot_bench  # noqa: E402
from _shared.progress import ProgressReporter  # noqa: E402
from _shared.protocol import ErrorCode, PluginError  # noqa: E402
from _shared.weights import (  # noqa: E402
    WEIGHTS_DIR_ENV,
    install_arg_present,
    installed_weight_dir,
    license_key,
    parse_install_args,
    run_install,
)

PLUGIN_ID = "totalsegmentator"

# Task ids exactly as plugins.json declares them, mapped to the TotalSegmentator
# task they invoke. The indirection is kept because the manifest's task ids are
# part of the host contract and TotalSegmentator's are not, and because
# `total_lowmem` is the same TotalSegmentator task run with fewer workers.
TASKS: dict[str, str] = {
    "total": "total",
    "total_lowmem": "total",
    "heartchambers_highres": "heartchambers_highres",
}

# Only `total` exposes an option in the manifest. `heartchambers_highres` has
# no fast variant, and passing --opt-fast to it is ignored rather than refused.
# `total_lowmem` is always the 3 mm model: its declaration was measured there,
# and full resolution runs five models whose footprint is unmeasured.
OPTIONS = {"fast": "bool"}

SEG_FILENAME = "segmentation.dcm"


class Weight(NamedTuple):
    """One manifest weight id, resolved to the nnU-Net dataset it names.

    The download goes through dataset ids rather than TotalSegmentator's
    task-name CLI because the two are not one-to-one: the manifest's
    `Dataset297_..._total_3mm_1559subj` is the 3 mm model, but the closest CLI
    task, `total_fast`, fetches datasets 297 *and* 298. The manifest declares
    0.25 GB and the store budgets against that number, so the adapter downloads
    exactly the dataset the manifest names and nothing else.
    """

    dataset_id: int
    directory: str


WEIGHTS: dict[str, Weight] = {
    "Dataset297_TotalSegmentator_total_3mm_1559subj": Weight(
        dataset_id=297, directory="Dataset297_TotalSegmentator_total_3mm_1559subj",
    ),
    "Dataset301_heart_highres_1559subj": Weight(
        dataset_id=301, directory="Dataset301_heart_highres_1559subj",
    ),
}

# Tasks whose weights sit behind the free TotalSegmentator academic licence.
# Distinguishing these lets a missing licence surface as `license_required`,
# which the host routes to the store's gate rather than a generic failure.
LICENSE_REQUIRED_TASKS = {"heartchambers_highres"}

LICENSE_URL = "https://backend.totalsegmentator.com/license-academic/"


# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------


def _require_totalsegmentator() -> None:
    import importlib.util

    if importlib.util.find_spec("totalsegmentator") is None:
        raise PluginError(
            ErrorCode.NOT_READY,
            "TotalSegmentator is not installed in this plugin's environment. "
            "Reinstall the plugin from the store.",
        )


def _totalsegmentator_version() -> str:
    """The installed TotalSegmentator version, for the SEG's provenance fields.

    Read at runtime rather than hardcoded: these fields are what tells a reader
    months later which model produced a segmentation, and a stale literal would
    attribute one release's output to another.
    """
    import importlib.metadata

    try:
        return importlib.metadata.version("TotalSegmentator")
    except importlib.metadata.PackageNotFoundError:
        return "unknown"


# Which weight id each manifest task needs at run time. Kept beside WEIGHTS so
# the presence check and the installer cannot disagree about what "installed"
# means for a given task.
TASK_WEIGHTS: dict[str, str] = {
    "total": "Dataset297_TotalSegmentator_total_3mm_1559subj",
    "total_lowmem": "Dataset297_TotalSegmentator_total_3mm_1559subj",
    "heartchambers_highres": "Dataset301_heart_highres_1559subj",
}


def _weights_present(task_id: str) -> bool:
    """Whether this task's nnU-Net weights are already on disk.

    Checked before the run so a missing download reports `not_ready` in a
    second, rather than after TotalSegmentator has loaded torch and started
    fetching. A task with no entry is treated as present, so a task added to
    the manifest is never blocked by a stale table here.
    """
    weight = WEIGHTS.get(TASK_WEIGHTS.get(task_id, ""))
    if weight is None:
        return True
    return (_totalseg_home() / "nnunet" / "results" / weight.directory).is_dir()


def _totalseg_home(override: Path | None = None) -> Path:
    return override or Path(
        os.environ.get("TOTALSEG_HOME_DIR", Path.home() / ".totalsegmentator")
    )


def _configure_home(task_id: str) -> Path:
    """Point TotalSegmentator at the weights the store installed for this task.

    Each weight id is installed with TOTALSEG_HOME_DIR set to its own --dest
    (`install_weights`), so that directory holds both the nnU-Net results and,
    for a licensed task, the config.json carrying the licence number that
    `_register_license` wrote. At run time the same variable must name the
    same directory, or TotalSegmentator looks in ~/.totalsegmentator, finds no
    weights and no licence, and either refuses or starts a download.

    Under the host (ODV_WEIGHTS_DIR set) the installed directory always wins,
    even over a TOTALSEG_HOME_DIR inherited from the user's shell. Run by hand,
    an explicit TOTALSEG_HOME_DIR is respected, and otherwise the app's layout
    is used when the store has installed the task.
    """
    weight_id = TASK_WEIGHTS.get(task_id)
    if weight_id is not None:
        installed = installed_weight_dir(PLUGIN_ID, weight_id)
        if os.environ.get(WEIGHTS_DIR_ENV) or (
                not os.environ.get("TOTALSEG_HOME_DIR") and installed.is_dir()):
            os.environ["TOTALSEG_HOME_DIR"] = str(installed)
    return _totalseg_home()


def _require_single_series(series_dir: Path) -> None:
    """Refuse a directory that holds more than one DICOM series.

    TotalSegmentator converts a whole directory and does not say which series
    it chose, so a folder with a scout, a contrast phase, and a reformat yields
    a segmentation of whichever it picked -- and the SEG export, which picks
    independently, can reference a different one. The host stages exactly the
    selected series' files (PluginSeriesStaging); this check is what keeps a
    caller that does not from getting a silently wrong result.
    """
    import SimpleITK as sitk

    series_ids = sitk.ImageSeriesReader.GetGDCMSeriesIDs(str(series_dir))
    if len(series_ids) > 1:
        raise PluginError(
            ErrorCode.BAD_INPUT,
            f"{series_dir} contains {len(series_ids)} DICOM series; pass a "
            "directory holding only the series to segment.",
            recoverable=False,
        )


def _license_registered(home: Path | None = None) -> bool:
    """Whether a TotalSegmentator academic licence number is on this machine.

    TotalSegmentator stores it in its own config file, written by
    `totalseg_set_license`. Only presence is read here -- never the value, which
    is not copied into the app's settings, its logs, or anything this adapter
    writes.
    """
    config = _totalseg_home(home) / "config.json"
    if not config.is_file():
        return False
    try:
        import json

        return bool(json.loads(config.read_text()).get("license_number"))
    except (OSError, ValueError):
        return False


# ---------------------------------------------------------------------------
# Pipeline stages
# ---------------------------------------------------------------------------


# TotalSegmentator's worker counts, `(nr_thr_resamp, nr_thr_saving)`, per task.
#
# `nr_thr_saving` sizes two pools: nnU-Net's segmentation-export pool, which is
# spawned *before* inference and so is alive through the inference peak, and
# TotalSegmentator's own per-structure NIfTI saving pool. One series is exported
# by one worker, so on a single study the other export workers only hold memory
# -- about 1.6-2 GB at the peak -- while the saving pool roughly halves the time
# spent writing ~117 masks. `total` keeps TotalSegmentator's defaults for speed;
# `total_lowmem` runs both pools with one worker, which is what lets its
# declaration fit a 32 GB Mac's one-shot share. Measured in
# eval/exp3_totalseg_lowmem.py; see eval/results/exp3_FINDINGS.md, "Low-memory
# settings". force_split was measured too and raises the peak, so it is unused.
TASK_THREADS: dict[str, tuple[int, int]] = {
    "total": (1, 6),
    "total_lowmem": (1, 1),
}
DEFAULT_THREADS = (1, 6)  # TotalSegmentator's own defaults

# Evaluation override for the two counts above, so eval/exp3_totalseg_lowmem.py
# can measure alternatives through the adapter exactly as the host spawns it.
# The host never sets it.
THREADS_ENV = "ODV_TOTALSEG_THREADS"


def _runtime_settings(task_id: str) -> dict[str, int]:
    """Worker counts passed to TotalSegmentator, `{nr_thr_resamp, nr_thr_saving}`."""
    resamp, saving = TASK_THREADS.get(task_id, DEFAULT_THREADS)
    override = os.environ.get(THREADS_ENV, "").strip()
    if override:
        try:
            resamp, saving = (max(1, int(x)) for x in override.split(","))
        except ValueError:
            raise PluginError(
                ErrorCode.BAD_INPUT,
                f"{THREADS_ENV} must be '<nr_thr_resamp>,<nr_thr_saving>', "
                f"got '{override}'",
                recoverable=False,
            ) from None
    return {"nr_thr_resamp": resamp, "nr_thr_saving": saving}


def _run_totalsegmentator(series_dir: Path, seg_out: Path, task_id: str,
                          fast: bool, reporter: ProgressReporter) -> None:
    """Segment the series into one NIfTI mask per structure."""
    from totalsegmentator.python_api import totalsegmentator

    ts_task = TASKS[task_id]
    settings = _runtime_settings(task_id)
    reporter.log(f"TotalSegmentator task={ts_task} fast={fast} "
                 f"nr_thr_resamp={settings['nr_thr_resamp']} "
                 f"nr_thr_saving={settings['nr_thr_saving']}")
    try:
        totalsegmentator(
            input=str(series_dir),
            output=str(seg_out),
            task=ts_task,
            fast=fast,
            # One file per structure rather than a multilabel image: the SEG
            # export needs the per-structure identity anyway, and reading it
            # back from filenames avoids depending on label-index ordering.
            ml=False,
            quiet=True,
            **settings,
        )
    except SystemExit as exc:
        # TotalSegmentator exits the process on a licence rejection instead of
        # raising, which would otherwise bypass result.json entirely.
        raise PluginError(
            ErrorCode.LICENSE_REQUIRED if ts_task in LICENSE_REQUIRED_TASKS
            else ErrorCode.INTERNAL,
            f"TotalSegmentator exited during segmentation (code {exc.code}). "
            f"For {ts_task}, check that an academic licence number is registered: "
            f"{LICENSE_URL}",
        ) from None
    except MemoryError:
        raise PluginError(
            ErrorCode.OUT_OF_MEMORY,
            "Ran out of memory during segmentation. Close other plugins, or use "
            "the low-memory variant of the total task.",
        ) from None


def _structure_masks(seg_out: Path) -> list[tuple[str, Path]]:
    """Non-empty per-structure masks, sorted by structure name.

    TotalSegmentator writes a file for every structure in the task, most of
    them empty for a partial-body scan. Empty masks are dropped here: they
    would become empty SEG segments that clutter the viewer's segment list
    without describing anything.
    """
    import nibabel as nib
    import numpy as np

    found: list[tuple[str, Path]] = []
    for path in sorted(seg_out.glob("*.nii.gz")):
        name = path.name[: -len(".nii.gz")]
        image = nib.load(str(path))
        if np.any(np.asanyarray(image.dataobj) > 0):
            found.append((name, path))
    return found


def _volumes_ml(masks: list[tuple[str, Path]]) -> dict[str, float]:
    """Volume of each structure in millilitres.

    Volume is the general metric this adapter reports: it is defined for every
    structure the model produces, needs no task-specific interpretation, and is
    the number a reader most often wants next to a segmentation. It is measured
    on the native TotalSegmentator grid rather than after resampling, so it is
    unaffected by the SEG export's nearest-neighbour interpolation.
    """
    import nibabel as nib
    import numpy as np

    metrics: dict[str, float] = {}
    for name, path in masks:
        image = nib.load(str(path))
        voxel_ml = float(np.prod(image.header.get_zooms()[:3])) / 1000.0
        count = int(np.count_nonzero(np.asanyarray(image.dataobj) > 0))
        metrics[f"{name}_volume_ml"] = round(count * voxel_ml, 2)
    return metrics


def _ensure_slice_thickness(source_images: list, reporter: ProgressReporter) -> None:
    """Give the source datasets a SliceThickness when the series omits one.

    highdicom requires SliceThickness to build the Pixel Measures Sequence, but
    the attribute is type 2 in the CT Image module — an absent or empty value is
    standard-legal, and real public archives ship series without it. Every one of
    the seven TCIA series used for evaluation omits both SliceThickness and
    SpacingBetweenSlices, so refusing them would mean refusing conformant data.

    Spacing is recovered from the source geometry, which is what any consumer
    would have to do anyway: positions are projected onto the slice normal
    (correct for oblique acquisitions, unlike differencing the z coordinate) and
    the median gap is taken. Mutation is in memory only; the files on disk are
    untouched.
    """
    import numpy as np

    missing = [ds for ds in source_images
               if getattr(ds, "SliceThickness", None) in (None, "")]
    if not missing:
        return

    positions = []
    for ds in source_images:
        position = getattr(ds, "ImagePositionPatient", None)
        orientation = getattr(ds, "ImageOrientationPatient", None)
        if position is None or orientation is None:
            raise PluginError(
                ErrorCode.BAD_INPUT,
                "The series omits SliceThickness and also lacks the "
                "ImagePositionPatient/ImageOrientationPatient needed to derive "
                "it, so slice spacing cannot be established.",
                recoverable=False,
            )
        axes = np.asarray(orientation, dtype=float)
        normal = np.cross(axes[:3], axes[3:])
        positions.append(float(np.dot(np.asarray(position, dtype=float), normal)))

    if len(positions) < 2:
        raise PluginError(
            ErrorCode.BAD_INPUT,
            "The series omits SliceThickness and has fewer than two slices, "
            "so spacing cannot be derived.",
            recoverable=False,
        )

    gaps = np.diff(np.sort(np.asarray(positions)))
    spacing = float(np.median(np.abs(gaps)))
    if not spacing > 0:
        raise PluginError(
            ErrorCode.BAD_INPUT,
            "The series omits SliceThickness and its slice positions give a "
            "non-positive spacing, so the geometry is unusable.",
            recoverable=False,
        )

    # Non-uniform spacing is reported rather than silently averaged: a variable
    # gap means the derived value is wrong for some frames.
    spread = float(np.max(np.abs(gaps)) - np.min(np.abs(gaps)))
    if spread > 0.01:
        reporter.log(
            f"Warning: slice spacing varies by {spread:.3f} mm across the "
            f"series; using the median {spacing:.3f} mm."
        )

    reporter.log(
        f"SliceThickness absent from {len(missing)} of {len(source_images)} "
        f"instances; derived {spacing:.3f} mm from slice positions."
    )
    for ds in missing:
        ds.SliceThickness = spacing


def _export_dicom_seg(series_dir: Path, masks: list[tuple[str, Path]],
                      out_path: Path, ts_task: str,
                      reporter: ProgressReporter) -> None:
    """Write one multi-segment binary DICOM SEG referencing the source images.

    Each mask is resampled onto the source series geometry before encoding.
    TotalSegmentator returns masks on its own resampled grid (3 mm for the fast
    total task), so without this step the SEG frames would not correspond to
    the source instances and the viewer would overlay them on the wrong slices.
    """
    import highdicom as hd
    import numpy as np
    import pydicom
    import SimpleITK as sitk
    from pydicom.sr.codedict import codes

    reader = sitk.ImageSeriesReader()
    files = reader.GetGDCMSeriesFileNames(str(series_dir))
    if not files:
        raise PluginError(
            ErrorCode.BAD_INPUT,
            f"No readable DICOM series found in {series_dir}",
        )
    reader.SetFileNames(files)
    reference = reader.Execute()
    source_images = [pydicom.dcmread(path) for path in files]

    # Segments are numbered from 1 in the order the structures are listed, and
    # a labelmap carries them all in one array: highdicom splits it per segment.
    label = np.zeros(
        (reference.GetSize()[2], reference.GetSize()[1], reference.GetSize()[0]),
        dtype=np.uint8,
    )
    descriptions = []
    version = _totalsegmentator_version()
    algorithm = hd.AlgorithmIdentificationSequence(
        name="TotalSegmentator", version=version,
        family=codes.cid7162.ArtificialIntelligence,
    )

    # BINARY SEG segment numbers must run 1..N with no gap (highdicom refuses
    # anything else), so a structure that ends up with no voxels must not use
    # up a number. Numbers are therefore assigned only to structures that
    # survive, and compacted again after the labelmap is built.
    kept: list[str] = []
    for position, (name, path) in enumerate(masks):
        if len(kept) == 255:
            reporter.log(
                f"Truncating at 255 segments; {len(masks) - position} structures omitted."
            )
            break
        mask = sitk.ReadImage(str(path))
        mask = sitk.Resample(mask, reference, sitk.Transform(),
                             sitk.sitkNearestNeighbor, 0, mask.GetPixelID())
        array = sitk.GetArrayFromImage(mask) > 0
        if not array.any():
            # Resampling onto a coarser or differently cropped source grid can
            # empty a structure that was non-empty natively.
            reporter.log(f"Omitting {name}: no voxels on the source grid.")
            continue
        kept.append(name)
        label[array] = len(kept)

    # A structure entirely overwritten by later ones in the labelmap has no
    # voxels left either.
    present = set(np.unique(label).tolist())
    renumber = np.zeros(256, dtype=np.uint8)
    for number, name in enumerate(kept, start=1):
        if number not in present:
            reporter.log(f"Omitting {name}: fully overlapped by later structures.")
            continue
        renumber[number] = len(descriptions) + 1
        descriptions.append(
            hd.seg.SegmentDescription(
                segment_number=len(descriptions) + 1,
                segment_label=name,
                # Structure names are TotalSegmentator's own vocabulary, which
                # has no complete SNOMED mapping. The category and type are
                # therefore left generic and the specific structure is carried
                # in the segment label, which is what the viewer displays.
                segmented_property_category=codes.SCT.AnatomicalStructure,
                segmented_property_type=codes.SCT.AnatomicalStructure,
                algorithm_type=hd.seg.SegmentAlgorithmTypeValues.AUTOMATIC,
                algorithm_identification=algorithm,
            )
        )
    label = renumber[label]

    if not descriptions:
        raise PluginError(
            ErrorCode.INTERNAL,
            "Segmentation produced no structures that overlap the source series.",
        )

    _ensure_slice_thickness(source_images, reporter)

    reporter.log(f"Encoding {len(descriptions)} segments into a binary SEG")
    segmentation = hd.seg.Segmentation(
        source_images=source_images,
        pixel_array=label,
        segmentation_type=hd.seg.SegmentationTypeValues.BINARY,
        segment_descriptions=descriptions,
        series_instance_uid=hd.UID(),
        series_number=9901,
        sop_instance_uid=hd.UID(),
        instance_number=1,
        manufacturer="OpenDicomViewer",
        manufacturer_model_name=f"TotalSegmentator {ts_task}",
        software_versions=version,
        device_serial_number=PLUGIN_ID,
        # Structures are sparse in z, and keeping empty frames would multiply
        # the file size by the number of segments for no added information.
        omit_empty_frames=True,
    )
    segmentation.save_as(str(out_path))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def pipeline(args: argparse.Namespace, out_dir: Path,
             reporter: ProgressReporter) -> OneShotResult:
    ts_task = TASKS[args.task]
    if args.task == "total":
        fast = option_bool(args, "fast", default=True)
    else:
        fast = args.task == "total_lowmem"

    series = args.input_series3d
    if not series:
        raise PluginError(
            ErrorCode.BAD_INPUT, "--input-series3d is required", recoverable=False
        )
    series_dir = Path(series).expanduser()
    if not series_dir.is_dir():
        raise PluginError(ErrorCode.BAD_INPUT, f"Series directory not found: {series_dir}")

    reporter.stage(0.0, 0.05, "Checking model environment")
    _configure_home(args.task)
    _require_totalsegmentator()
    if args.task in LICENSE_REQUIRED_TASKS and not _license_registered():
        raise PluginError(
            ErrorCode.LICENSE_REQUIRED,
            "This task needs a free TotalSegmentator academic licence number. "
            f"Request one at {LICENSE_URL}, then register it in the plugin store.",
        )
    if not _weights_present(args.task):
        raise PluginError(
            ErrorCode.NOT_READY,
            f"Weights for the '{args.task}' task are not downloaded yet. "
            "Install the task from the plugin store.",
        )
    _require_single_series(series_dir)

    with tempfile.TemporaryDirectory(prefix="odv-totalseg-") as tmp:
        seg_out = Path(tmp) / "masks"
        seg_out.mkdir(parents=True, exist_ok=True)

        # Segmentation dominates the wall time by a wide margin, so it is given
        # most of the bar even though it reports nothing from inside.
        reporter.stage(0.05, 0.80, "Running segmentation")
        _run_totalsegmentator(series_dir, seg_out, args.task, fast, reporter)

        reporter.stage(0.80, 0.88, "Measuring structures")
        masks = _structure_masks(seg_out)
        if not masks:
            raise PluginError(
                ErrorCode.INTERNAL,
                "Segmentation completed but produced no non-empty structures. "
                "Check that the series is a CT covering the expected anatomy.",
            )
        reporter.log(f"{len(masks)} non-empty structures")
        metrics: dict[str, Any] = _volumes_ml(masks)
        metrics["structure_count"] = len(masks)

        reporter.stage(0.88, 0.99, "Writing DICOM SEG")
        _export_dicom_seg(series_dir, masks, out_dir / SEG_FILENAME, ts_task, reporter)

    # Paths in `outputs` are relative to --out, per section 4.
    return OneShotResult(outputs={"seg3d": SEG_FILENAME, "metrics": metrics})


# ---------------------------------------------------------------------------
# Weight acquisition (PLUGIN_PROTOCOL.md section 4b)
# ---------------------------------------------------------------------------


def _register_license(key: str, home: Path, reporter: ProgressReporter) -> None:
    """Register an academic licence number with TotalSegmentator.

    The key arrives in `ODV_PLUGIN_LICENSE_KEY` rather than argv because
    process arguments are world-readable through `ps` (section 4b). It is
    handed to TotalSegmentator's own config writer, which owns the file it
    lives in; it is never logged, never echoed to stdout, and never written
    into anything this adapter creates.
    """
    os.environ["TOTALSEG_HOME_DIR"] = str(home)
    from totalsegmentator.config import set_license_number

    reporter.log("Registering the academic licence number")
    try:
        set_license_number(key, skip_validation=False)
    except BaseException as exc:  # noqa: BLE001
        # The exception text is deliberately not forwarded: TotalSegmentator's
        # validation errors quote the rejected number back, which would put the
        # key into the plugin log view.
        raise PluginError(
            ErrorCode.LICENSE_REQUIRED,
            f"The academic licence number was rejected ({type(exc).__name__}). "
            f"Check the number, or request one at {LICENSE_URL}.",
        ) from None


def install_weights(args, dest: Path, reporter: ProgressReporter) -> list[Path]:
    """Fetch one TotalSegmentator task's weights into the host-owned directory.

    TotalSegmentator resolves its weight directory from `TOTALSEG_HOME_DIR`
    rather than accepting a destination argument, so `--dest` is honoured by
    pointing that variable at it for the download. The weights then live where
    the store can remove them when the user uninstalls the plugin, instead of
    in a location the host does not know about.
    """
    if args.source != "totalseg-task":
        raise PluginError(
            ErrorCode.BAD_INPUT,
            f"{PLUGIN_ID} only knows the 'totalseg-task' weight source, "
            f"got '{args.source}'",
            recoverable=False,
        )
    if not args.task:
        raise PluginError(
            ErrorCode.BAD_INPUT,
            "--task is required for the totalseg-task source",
            recoverable=False,
        )

    weight = WEIGHTS.get(args.weight_id)
    if weight is None:
        raise PluginError(
            ErrorCode.BAD_INPUT,
            f"Unknown weight id '{args.weight_id}'. This adapter provides "
            f"{', '.join(sorted(WEIGHTS))}.",
            recoverable=False,
        )

    reporter.stage(0.0, 0.05, "Checking the model environment")
    _require_totalsegmentator()

    # TotalSegmentator resolves its weight directory from this variable at call
    # time, so setting it here is what makes --dest effective.
    os.environ["TOTALSEG_HOME_DIR"] = str(dest)

    key = license_key()
    if key:
        _register_license(key, dest, reporter)
    elif args.task in LICENSE_REQUIRED_TASKS and not _license_registered(dest):
        raise PluginError(
            ErrorCode.LICENSE_REQUIRED,
            f"The '{args.task}' weights need a free TotalSegmentator academic "
            f"licence number. Request one at {LICENSE_URL} and enter it in the "
            f"plugin store.",
        )

    reporter.stage(0.05, 0.95, f"Downloading weights for '{args.task}'")
    from totalsegmentator.libs import download_pretrained_weights

    try:
        download_pretrained_weights(weight.dataset_id)
    except SystemExit as exc:
        # A licence rejection exits the process rather than raising, which
        # would otherwise escape the protocol error envelope entirely.
        raise PluginError(
            ErrorCode.LICENSE_REQUIRED if args.task in LICENSE_REQUIRED_TASKS
            else ErrorCode.INTERNAL,
            f"The weight download for '{args.task}' exited (code {exc.code}). "
            + (f"This task needs an academic licence number: {LICENSE_URL}"
               if args.task in LICENSE_REQUIRED_TASKS else ""),
        ) from None
    except BaseException as exc:  # noqa: BLE001
        text = f"{type(exc).__name__}: {exc}"
        if any(token in text for token in ("401", "403", "license", "licence")):
            raise PluginError(
                ErrorCode.LICENSE_REQUIRED,
                f"The weight server refused the request for '{args.task}'. "
                f"This task needs an academic licence number: {LICENSE_URL}",
            ) from None
        raise PluginError(
            ErrorCode.INTERNAL,
            f"Could not download weights for '{args.task}': {text}",
        ) from None

    # nnU-Net loads a task from its dataset directory, so that directory is what
    # must exist for this weight id to count as installed. `run_install` checks
    # every path returned here and fails the install if any is absent, which is
    # what stops a downloader that exits 0 without writing anything from being
    # reported as success. Naming the specific directory rather than globbing
    # `Dataset*` keeps exit 0 meaning "this weight is installed" rather than
    # "some weight is".
    return [dest / "nnunet" / "results" / weight.directory]


def main(argv: list[str] | None = None) -> int:
    if install_arg_present(argv):
        return run_install(
            parse_install_args("TotalSegmentator weight installer.", argv),
            install_weights,
        )
    if bench_arg_present(argv):
        # Dispatched before the one-shot parser, like --install-weights. The
        # pipeline is the same one a real invocation runs; only the reporter
        # differs, so the stage boundaries measured are the adapter's own.
        def as_pipeline_args(bench_args):
            return parse_oneshot_args(
                "TotalSegmentator one-shot adapter for OpenDicomViewer.",
                tasks=list(TASKS),
                options=OPTIONS,
                argv=["--task", bench_args.task or "total",
                      "--out", bench_args.out or ".",
                      "--input-series3d", bench_args.input_series3d or "",
                      "--opt-fast", bench_args.opt_fast or "true"],
            )

        return run_oneshot_bench(PLUGIN_ID, pipeline, as_pipeline_args, argv)

    args = parse_oneshot_args(
        "TotalSegmentator one-shot adapter for OpenDicomViewer.",
        tasks=list(TASKS),
        options=OPTIONS,
        argv=argv,
    )
    return run_oneshot(args, pipeline)


if __name__ == "__main__":
    sys.exit(main())
