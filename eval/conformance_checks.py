#!/usr/bin/env python3
# conformance_checks.py
# OpenDicomViewer -- plugin layer evaluation, experiment 1.
#
# A field-level audit of a produced DICOM SEG against the Segmentation IOD
# (PS3.3 A.51) and the DICOM SEG usage the plugin protocol assumes.
#
# The audit is deliberately separate from the experiment driver so it can be
# pointed at any SEG -- one produced by our adapter, one produced by
# TotalSegmentator's own writer, or one produced by a third-party plugin -- and
# will answer the same questions about all of them. That reusability is the
# point: a conformance test that only understands our own output is not a
# conformance test.
#
# Each check returns a Finding. A Finding is PASS, WARN, or FAIL:
#   FAIL  the file violates a Type 1/Type 1C requirement of the IOD, or states
#         something contradicted by its own contents. A reader is entitled to
#         reject it.
#   WARN  the file is readable and standard-legal, but a semantic expectation an
#         imaging-informatics consumer would have is not met.
#   PASS  checked and satisfied.
# Licensed under the MIT License. See LICENSE for details.
"""Segmentation IOD field audit for plugin-produced DICOM SEG files."""

from __future__ import annotations

import csv
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Iterable

# Coding scheme designators the Segmentation IOD's anatomic coding is expected
# to use. Not normative -- any registered scheme is legal -- but a segment coded
# outside these is worth surfacing.
KNOWN_SCHEMES = {"SCT", "SRT", "DCM", "FMA", "UMLS", "NCIt", "LN"}

# Codes that mean "some anatomical structure" and nothing more specific. As a
# SegmentedPropertyCategory that is correct and expected. As a
# SegmentedPropertyType it says only "this is anatomy", which is what this
# audit looks for: it is conformant, and it carries no information a consumer
# could route on. 123037004 is SCT "Body structure"; 91723000 is SCT
# "Anatomical structure", which is what highdicom's
# `codes.SCT.AnatomicalStructure` resolves to.
GENERIC_ANATOMY_CODES = {"123037004", "91723000"}
GENERIC_ANATOMY_CODE = "91723000"  # representative, for messages


@dataclass
class Finding:
    """One audited property of one file."""

    check: str
    status: str          # "PASS" | "WARN" | "FAIL"
    detail: str
    value: Any = None

    def as_dict(self) -> dict:
        return asdict(self)


def _code_tuple(seq_item) -> tuple[str | None, str | None, str | None]:
    """(scheme, value, meaning) from a code sequence item, tolerating absence."""
    if seq_item is None:
        return (None, None, None)
    return (
        getattr(seq_item, "CodingSchemeDesignator", None),
        getattr(seq_item, "CodeValue", None),
        getattr(seq_item, "CodeMeaning", None),
    )


def _first(dataset, keyword):
    seq = getattr(dataset, keyword, None)
    if not seq:
        return None
    return seq[0]


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------


def check_sop_class(seg) -> Finding:
    """The file must declare itself a Segmentation Storage instance."""
    expected = "1.2.840.10008.5.1.4.1.1.66.4"
    actual = getattr(seg, "SOPClassUID", None)
    if actual == expected:
        return Finding("sop_class", "PASS", "Segmentation Storage", str(actual))
    return Finding("sop_class", "FAIL",
                   f"expected Segmentation Storage {expected}", str(actual))


def check_modality(seg) -> Finding:
    actual = getattr(seg, "Modality", None)
    if actual == "SEG":
        return Finding("modality", "PASS", "SEG", actual)
    return Finding("modality", "FAIL", "Modality must be SEG", actual)


def check_segmentation_type(seg) -> Finding:
    """SegmentationType (0062,0001), Type 1.

    BINARY additionally constrains the pixel encoding, which the next check
    verifies rather than assuming.
    """
    actual = getattr(seg, "SegmentationType", None)
    if actual in ("BINARY", "FRACTIONAL", "LABELMAP"):
        return Finding("segmentation_type", "PASS", f"{actual}", actual)
    return Finding("segmentation_type", "FAIL",
                   "SegmentationType must be BINARY, FRACTIONAL or LABELMAP",
                   actual)


def check_bits(seg) -> Finding:
    """Pixel encoding must agree with SegmentationType.

    For BINARY the IOD fixes BitsAllocated 1, BitsStored 1, HighBit 0,
    SamplesPerPixel 1, PhotometricInterpretation MONOCHROME2, PixelRepresentation
    0. A file claiming BINARY while storing 8-bit pixels is internally
    inconsistent, and readers that trust the declaration will misparse it.
    """
    seg_type = getattr(seg, "SegmentationType", None)
    got = {
        "BitsAllocated": getattr(seg, "BitsAllocated", None),
        "BitsStored": getattr(seg, "BitsStored", None),
        "HighBit": getattr(seg, "HighBit", None),
        "SamplesPerPixel": getattr(seg, "SamplesPerPixel", None),
        "PhotometricInterpretation": getattr(seg, "PhotometricInterpretation", None),
        "PixelRepresentation": getattr(seg, "PixelRepresentation", None),
    }
    if seg_type == "BINARY":
        want = {"BitsAllocated": 1, "BitsStored": 1, "HighBit": 0,
                "SamplesPerPixel": 1, "PhotometricInterpretation": "MONOCHROME2",
                "PixelRepresentation": 0}
    elif seg_type == "FRACTIONAL":
        want = {"BitsAllocated": 8, "BitsStored": 8, "HighBit": 7,
                "SamplesPerPixel": 1, "PhotometricInterpretation": "MONOCHROME2",
                "PixelRepresentation": 0}
    else:
        return Finding("pixel_encoding", "WARN",
                       f"no encoding rule checked for SegmentationType={seg_type}",
                       got)
    bad = {k: (got[k], v) for k, v in want.items() if got[k] != v}
    if not bad:
        return Finding("pixel_encoding", "PASS",
                       f"{seg_type} encoding as required", got)
    return Finding("pixel_encoding", "FAIL",
                   "; ".join(f"{k}={g!r} expected {w!r}" for k, (g, w) in bad.items()),
                   got)


def check_number_of_frames(seg) -> Finding:
    """NumberOfFrames must equal the PerFrameFunctionalGroupsSequence length.

    The per-frame sequence is what tells a reader which segment and which
    spatial position each frame belongs to. A count mismatch means some frames
    have no description or some descriptions have no frame; either way the
    overlay a viewer draws is not the one that was encoded.
    """
    declared = int(getattr(seg, "NumberOfFrames", 0) or 0)
    perframe = len(getattr(seg, "PerFrameFunctionalGroupsSequence", []) or [])
    if declared == perframe and declared > 0:
        return Finding("frames_vs_perframe", "PASS",
                       f"{declared} frames, {perframe} per-frame items",
                       {"number_of_frames": declared, "per_frame_items": perframe})
    return Finding("frames_vs_perframe", "FAIL",
                   f"NumberOfFrames={declared} but PerFrameFunctionalGroupsSequence "
                   f"has {perframe} items",
                   {"number_of_frames": declared, "per_frame_items": perframe})


def check_segment_sequence(seg) -> Finding:
    """SegmentSequence (0062,0002), Type 1, with contiguous SegmentNumbers.

    SegmentNumber must be unique and, per the IOD, start at 1. Non-contiguity
    is legal but breaks the common reader assumption that segment N is the Nth
    item, so it is surfaced as a warning rather than passed silently.
    """
    segments = getattr(seg, "SegmentSequence", []) or []
    if not segments:
        return Finding("segment_sequence", "FAIL", "SegmentSequence is absent or empty", 0)
    numbers = [int(s.SegmentNumber) for s in segments]
    if len(set(numbers)) != len(numbers):
        return Finding("segment_sequence", "FAIL",
                       "duplicate SegmentNumber values", numbers[:20])
    if sorted(numbers) != list(range(1, len(numbers) + 1)):
        return Finding("segment_sequence", "WARN",
                       f"SegmentNumbers are not 1..{len(numbers)}",
                       {"min": min(numbers), "max": max(numbers), "count": len(numbers)})
    return Finding("segment_sequence", "PASS",
                   f"{len(numbers)} segments numbered 1..{len(numbers)}", len(numbers))


def check_segment_coding(seg) -> Finding:
    """Per-segment anatomic coding.

    SegmentedPropertyCategoryCodeSequence and SegmentedPropertyTypeCodeSequence
    are both Type 1 in the Segment Description macro, so presence alone is a
    conformance question. Whether they say anything *specific* is a semantic
    question, and the two are reported separately: a file can be perfectly
    conformant and still be semantically useless to a consumer that routes on
    codes rather than on free-text labels.
    """
    segments = getattr(seg, "SegmentSequence", []) or []
    missing_category, missing_type, generic_type, unknown_scheme = [], [], [], []
    distinct_types = set()

    for s in segments:
        label = getattr(s, "SegmentLabel", f"segment {getattr(s, 'SegmentNumber', '?')}")
        cat = _code_tuple(_first(s, "SegmentedPropertyCategoryCodeSequence"))
        typ = _code_tuple(_first(s, "SegmentedPropertyTypeCodeSequence"))
        if cat[1] is None:
            missing_category.append(label)
        if typ[1] is None:
            missing_type.append(label)
        else:
            distinct_types.add((typ[0], typ[1]))
            if typ[1] in GENERIC_ANATOMY_CODES:
                generic_type.append(label)
        for scheme in (cat[0], typ[0]):
            if scheme is not None and scheme not in KNOWN_SCHEMES:
                unknown_scheme.append(f"{label}:{scheme}")

    value = {
        "segments": len(segments),
        "missing_category": len(missing_category),
        "missing_type": len(missing_type),
        "generic_type_code": len(generic_type),
        "distinct_type_codes": len(distinct_types),
        "unknown_scheme": sorted(set(unknown_scheme))[:5],
    }

    if missing_category or missing_type:
        return Finding("segment_coding", "FAIL",
                       f"{len(missing_category)} segments without a category code, "
                       f"{len(missing_type)} without a type code (both Type 1)",
                       value)
    if generic_type:
        return Finding(
            "segment_coding", "WARN",
            f"{len(generic_type)}/{len(segments)} segments carry a generic "
            f"'anatomical structure' code as their SegmentedPropertyType; only "
            f"{len(distinct_types)} distinct type code(s) across the file, so the "
            f"specific anatomy is recoverable only from the free-text SegmentLabel",
            value)
    return Finding("segment_coding", "PASS",
                   f"{len(segments)} segments, {len(distinct_types)} distinct "
                   f"specific type codes", value)


def check_segment_algorithm(seg) -> Finding:
    """SegmentAlgorithmType is Type 1; AUTOMATIC/SEMIAUTOMATIC require an
    AlgorithmIdentification, which is what attributes a mask to a model."""
    segments = getattr(seg, "SegmentSequence", []) or []
    missing_type, missing_ident = [], []
    for s in segments:
        label = getattr(s, "SegmentLabel", "?")
        algo = getattr(s, "SegmentAlgorithmType", None)
        if algo is None:
            missing_type.append(label)
        elif algo in ("AUTOMATIC", "SEMIAUTOMATIC"):
            if not getattr(s, "SegmentationAlgorithmIdentificationSequence", None) \
                    and not getattr(s, "SegmentAlgorithmName", None):
                missing_ident.append(label)
    if missing_type:
        return Finding("segment_algorithm", "FAIL",
                       f"{len(missing_type)} segments without SegmentAlgorithmType",
                       len(missing_type))
    if missing_ident:
        return Finding("segment_algorithm", "WARN",
                       f"{len(missing_ident)} automatic segments with no algorithm "
                       f"identification", len(missing_ident))
    return Finding("segment_algorithm", "PASS",
                   "every segment declares its algorithm type and identification",
                   len(segments))


def check_referenced_series(seg, source_sop_uids: set[str] | None) -> Finding:
    """ReferencedSeriesSequence completeness against the source series.

    The protocol's seg3d contract is a SEG "referencing source SOP instances",
    and a viewer aligns the overlay by matching those references. A SEG that
    references only the slices it happened to write frames for is still legal,
    but it loses the statement "this segmentation was computed over that
    series", which is what a downstream consumer needs in order to know the
    unreferenced slices were considered and found empty rather than skipped.
    """
    refs: set[str] = set()
    series_uids: set[str] = set()
    for series in getattr(seg, "ReferencedSeriesSequence", []) or []:
        series_uids.add(getattr(series, "SeriesInstanceUID", None))
        for inst in getattr(series, "ReferencedInstanceSequence", []) or []:
            uid = getattr(inst, "ReferencedSOPInstanceUID", None)
            if uid:
                refs.add(uid)

    value = {"referenced_instances": len(refs), "referenced_series": len(series_uids)}
    if not refs:
        return Finding("referenced_series", "FAIL",
                       "ReferencedSeriesSequence carries no instance references", value)
    if len(series_uids) != 1:
        return Finding("referenced_series", "WARN",
                       f"{len(series_uids)} referenced series", value)
    if source_sop_uids is None:
        return Finding("referenced_series", "PASS",
                       f"{len(refs)} instances referenced (source not supplied "
                       f"for comparison)", value)

    missing = source_sop_uids - refs
    extra = refs - source_sop_uids
    value.update({"source_instances": len(source_sop_uids),
                  "unreferenced_source_instances": len(missing),
                  "references_not_in_source": len(extra)})
    if extra:
        return Finding("referenced_series", "FAIL",
                       f"{len(extra)} referenced SOP instances are not in the "
                       f"source series", value)
    if missing:
        return Finding("referenced_series", "WARN",
                       f"{len(missing)}/{len(source_sop_uids)} source instances are "
                       f"not referenced", value)
    return Finding("referenced_series", "PASS",
                   f"all {len(source_sop_uids)} source instances referenced", value)


def check_frame_of_reference(seg, source_for_uid: str | None) -> Finding:
    """FrameOfReferenceUID must agree with the source series.

    Spatial alignment between the SEG and the images is asserted by this UID.
    A SEG that invents a new one is not wrong on its face, but nothing then
    guarantees a viewer will place the mask on the anatomy it came from.
    """
    seg_for = getattr(seg, "FrameOfReferenceUID", None)
    value = {"seg": seg_for, "source": source_for_uid}
    if seg_for is None:
        return Finding("frame_of_reference", "FAIL",
                       "FrameOfReferenceUID absent", value)
    if source_for_uid is None:
        return Finding("frame_of_reference", "PASS",
                       "present (source not supplied for comparison)", value)
    if seg_for == source_for_uid:
        return Finding("frame_of_reference", "PASS",
                       "matches the source series", value)
    return Finding("frame_of_reference", "FAIL",
                   "differs from the source series FrameOfReferenceUID", value)


def check_perframe_consistency(seg) -> Finding:
    """Every per-frame item must identify its segment and its position.

    SegmentIdentificationSequence is Type 1 per frame, and the referenced
    segment number must exist in SegmentSequence. PlanePositionSequence (or a
    per-frame PlaneOrientation) is what places the frame in space; without it
    a multi-frame SEG cannot be reassembled into a volume.
    """
    perframe = getattr(seg, "PerFrameFunctionalGroupsSequence", []) or []
    known = {int(s.SegmentNumber) for s in getattr(seg, "SegmentSequence", []) or []}
    no_segment_id, unknown_segment, no_position, no_derivation = 0, 0, 0, 0
    used_segments: set[int] = set()
    positions: set[tuple] = set()

    for frame in perframe:
        sid = _first(frame, "SegmentIdentificationSequence")
        if sid is None or getattr(sid, "ReferencedSegmentNumber", None) is None:
            no_segment_id += 1
        else:
            number = int(sid.ReferencedSegmentNumber)
            used_segments.add(number)
            if number not in known:
                unknown_segment += 1
        pos = _first(frame, "PlanePositionSequence")
        if pos is None or getattr(pos, "ImagePositionPatient", None) is None:
            no_position += 1
        else:
            positions.add(tuple(round(float(v), 4) for v in pos.ImagePositionPatient))
        if not getattr(frame, "DerivationImageSequence", None):
            no_derivation += 1

    value = {"frames": len(perframe), "segments_used": len(used_segments),
             "segments_declared": len(known), "distinct_positions": len(positions),
             "frames_without_derivation": no_derivation}

    if no_segment_id or unknown_segment or no_position:
        return Finding("perframe_consistency", "FAIL",
                       f"{no_segment_id} frames without a segment identification, "
                       f"{unknown_segment} referencing an undeclared segment, "
                       f"{no_position} without a plane position", value)
    unused = known - used_segments
    if unused:
        return Finding("perframe_consistency", "FAIL",
                       f"{len(unused)} declared segments have no frames: an empty "
                       f"segment cannot be rendered", value)
    return Finding("perframe_consistency", "PASS",
                   f"{len(perframe)} frames, all identified and positioned, "
                   f"covering all {len(known)} segments", value)


def check_omit_empty_frames(seg, decoded_by_segment: dict[int, int] | None,
                            source_positions: set[tuple] | None = None) -> Finding:
    """Check what `omit_empty_frames` did to the frame set, in both directions.

    The adapter asks highdicom to omit empty frames, which is a size
    optimisation. Two things can go wrong, and they are not symmetric:

    *A frame that is entirely zero survived.* Harmless but wasteful, and a sign
    the omission did not apply. Detected directly: decode the pixel data and
    compare each segment's encoded frame count against the number of its frames
    that carry at least one set pixel.

    *A frame that had content was dropped.* This silently removes anatomy and is
    the failure that matters. It cannot be detected from the SEG alone -- a file
    with a slice missing is internally consistent, and nothing inside it records
    what the mask contained before encoding. It is detected here by geometry
    instead: a dropped interior frame leaves a gap in a segment's sequence of
    plane positions. For each segment, the frames present are located in the
    source series' ordered slice positions, and any *interior* source slice
    absent from that run is reported. Interior only, because a segment
    legitimately starting and ending partway through the volume is the normal
    case -- it is a hole in the middle of a structure that indicates loss.

    Without `source_positions` only the first direction is checked, and the
    finding says so rather than implying a clean result.
    """
    if decoded_by_segment is None:
        return Finding("omit_empty_frames", "WARN",
                       "pixel data not decoded, so frame content was not checked",
                       None)
    perframe = getattr(seg, "PerFrameFunctionalGroupsSequence", []) or []
    frames_per_segment: dict[int, int] = {}
    positions_per_segment: dict[int, set[tuple]] = {}
    for frame in perframe:
        sid = _first(frame, "SegmentIdentificationSequence")
        if sid is None:
            continue
        number = int(sid.ReferencedSegmentNumber)
        frames_per_segment[number] = frames_per_segment.get(number, 0) + 1
        pos = _first(frame, "PlanePositionSequence")
        if pos is not None and getattr(pos, "ImagePositionPatient", None) is not None:
            positions_per_segment.setdefault(number, set()).add(
                tuple(round(float(v), 2) for v in pos.ImagePositionPatient))

    empty_frames = {n: c for n, c in decoded_by_segment.items()
                    if frames_per_segment.get(n, 0) > c}

    # Interior gaps, per segment, against the source slice grid.
    gaps: dict[int, int] = {}
    checked_gaps = source_positions is not None
    if checked_gaps:
        ordered = sorted(source_positions, key=lambda p: p[::-1])
        index = {p: i for i, p in enumerate(ordered)}
        for number, seen in positions_per_segment.items():
            indices = sorted(index[p] for p in seen if p in index)
            if len(indices) < 2:
                continue
            missing = (indices[-1] - indices[0] + 1) - len(indices)
            if missing > 0:
                gaps[number] = missing

    value = {"segments": len(frames_per_segment),
             "total_frames": sum(frames_per_segment.values()),
             "segments_with_all_zero_frames": len(empty_frames),
             "interior_gaps_checked": checked_gaps,
             "segments_with_interior_gaps": len(gaps),
             "interior_frames_missing": sum(gaps.values())}

    if gaps:
        return Finding("omit_empty_frames", "FAIL",
                       f"{len(gaps)} segments have interior slices missing from "
                       f"their frame run ({sum(gaps.values())} frames): content "
                       f"may have been dropped", value)
    if empty_frames:
        return Finding("omit_empty_frames", "WARN",
                       f"{len(empty_frames)} segments carry frames whose pixel data "
                       f"is entirely zero", value)
    if not checked_gaps:
        return Finding("omit_empty_frames", "WARN",
                       "every encoded frame carries at least one set pixel; source "
                       "slice positions were not supplied, so dropped frames were "
                       "not checked", value)
    return Finding("omit_empty_frames", "PASS",
                   "every encoded frame carries content and no segment has an "
                   "interior slice missing", value)


def check_content_identification(seg) -> Finding:
    """Fields a reader shows the user or uses for provenance.

    None of these are Type 1, but a SEG whose ContentLabel is absent shows up
    unnamed in a series list, and one with no manufacturer/model cannot be
    attributed to the software that made it -- which for an AI-produced
    segmentation is the field a reviewer asks about first.
    """
    wanted = ["ContentLabel", "ContentDescription", "ContentCreatorName",
              "Manufacturer", "ManufacturerModelName", "SoftwareVersions",
              "SeriesNumber", "InstanceNumber", "SeriesDescription"]
    present = {k: getattr(seg, k, None) for k in wanted}
    absent = [k for k, v in present.items() if v in (None, "")]
    value = {k: (str(v) if v is not None else None) for k, v in present.items()}
    if not absent:
        return Finding("content_identification", "PASS",
                       "all provenance and display fields present", value)
    if "Manufacturer" in absent or "ManufacturerModelName" in absent:
        return Finding("content_identification", "WARN",
                       f"absent: {', '.join(absent)} (attribution incomplete)", value)
    return Finding("content_identification", "WARN",
                   f"absent: {', '.join(absent)}", value)


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def source_series_facts(series_dir: Path) -> dict:
    """SOP instance UIDs, FrameOfReferenceUID and series UID of a source series."""
    import pydicom

    sop_uids: set[str] = set()
    for_uids: set[str] = set()
    series_uids: set[str] = set()
    positions: set[tuple] = set()
    for path in sorted(Path(series_dir).glob("*.dcm")):
        ds = pydicom.dcmread(str(path), stop_before_pixels=True)
        if getattr(ds, "Modality", None) == "SEG":
            continue
        sop_uids.add(ds.SOPInstanceUID)
        if getattr(ds, "FrameOfReferenceUID", None):
            for_uids.add(ds.FrameOfReferenceUID)
        if getattr(ds, "SeriesInstanceUID", None):
            series_uids.add(ds.SeriesInstanceUID)
        if getattr(ds, "ImagePositionPatient", None) is not None:
            positions.add(tuple(round(float(v), 2) for v in ds.ImagePositionPatient))
    return {
        "sop_instance_uids": sop_uids,
        "frame_of_reference_uid": next(iter(for_uids)) if len(for_uids) == 1 else None,
        "frame_of_reference_count": len(for_uids),
        "series_instance_uid": next(iter(series_uids)) if len(series_uids) == 1 else None,
        "instance_count": len(sop_uids),
        "slice_positions": positions,
    }


def decode_nonzero_frames_per_segment(seg) -> dict[int, int] | None:
    """Count, per segment, how many encoded frames have at least one set pixel.

    Returns None if the pixel data cannot be decoded, which is itself reported
    by the caller rather than swallowed.
    """
    import numpy as np

    try:
        pixels = seg.pixel_array
    except Exception:  # noqa: BLE001 - inability to decode is a reportable state
        return None
    if pixels.ndim == 2:
        pixels = pixels[None, ...]
    counts: dict[int, int] = {}
    perframe = getattr(seg, "PerFrameFunctionalGroupsSequence", []) or []
    for index, frame in enumerate(perframe):
        if index >= pixels.shape[0]:
            break
        sid = _first(frame, "SegmentIdentificationSequence")
        if sid is None:
            continue
        number = int(sid.ReferencedSegmentNumber)
        if np.any(pixels[index]):
            counts[number] = counts.get(number, 0) + 1
        else:
            counts.setdefault(number, 0)
    return counts


def audit_seg(seg_path: Path, series_dir: Path | None = None) -> list[Finding]:
    """Run every check over one SEG file, optionally against its source series."""
    import pydicom

    seg = pydicom.dcmread(str(seg_path))
    facts = source_series_facts(series_dir) if series_dir else {}
    decoded = decode_nonzero_frames_per_segment(seg)

    findings = [
        check_sop_class(seg),
        check_modality(seg),
        check_segmentation_type(seg),
        check_bits(seg),
        check_number_of_frames(seg),
        check_segment_sequence(seg),
        check_segment_coding(seg),
        check_segment_algorithm(seg),
        check_referenced_series(seg, facts.get("sop_instance_uids")),
        check_frame_of_reference(seg, facts.get("frame_of_reference_uid")),
        check_perframe_consistency(seg),
        check_omit_empty_frames(seg, decoded, facts.get("slice_positions")),
        check_content_identification(seg),
    ]
    if decoded is None:
        findings.append(Finding("pixel_data_decodable", "FAIL",
                                "pixel_array could not be decoded", None))
    else:
        findings.append(Finding("pixel_data_decodable", "PASS",
                                "pixel_array decoded", sum(decoded.values())))
    return findings


def worst_status(findings: Iterable[Finding]) -> str:
    statuses = {f.status for f in findings}
    for level in ("FAIL", "WARN"):
        if level in statuses:
            return level
    return "PASS"


def snomed_reference_map(csv_path: Path | None = None) -> dict[str, dict[str, str]]:
    """TotalSegmentator's own structure -> SNOMED mapping, if it is installed.

    Loaded from the installed package rather than vendored: this audit uses it
    to answer "was a specific code available for this structure?", and a stale
    copy would answer that question about a different release than the one that
    produced the SEG.
    """
    if csv_path is None:
        try:
            import totalsegmentator  # noqa: PLC0415 - optional
        except ImportError:
            return {}
        csv_path = (Path(totalsegmentator.__file__).parent / "resources"
                    / "totalsegmentator_snomed_mapping.csv")
    if not Path(csv_path).is_file():
        return {}
    out: dict[str, dict[str, str]] = {}
    with open(csv_path, newline="") as handle:
        for row in csv.DictReader(handle):
            out[row["Structure"]] = row
    return out
