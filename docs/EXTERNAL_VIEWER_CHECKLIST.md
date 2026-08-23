# External viewer verification of plugin-produced DICOM SEG

Experiment 1 establishes by *automated* means that the DICOM SEG the plugin
layer writes is decoded correctly by an independent implementation: dcmqi
(QIICR) reads it back and the voxels agree. That is the strongest part of the
conformance claim, and it is machine-checkable, so it is machine-checked.

What it does **not** establish is that a clinical viewer *renders* it correctly.
A file can be standard-conformant and still be displayed on the wrong slices, or
mirrored in z, or with segments the user cannot tell apart, because rendering
depends on how a viewer interprets geometry and display attributes rather than
on whether the attributes are present. That is a question about two specific
GUI applications, and answering it requires a human at a screen.

**This procedure could not be executed as part of the evaluation.** The
measurement environment has no display and no way to drive 3D Slicer or OHIF.
The checklist below is therefore prepared for a human operator, with the results
table left blank. Any paper text describing external-viewer behaviour must be
written from a filled-in copy of this table, not from the automated results.

---

## 1. What to load

A representative SEG and its source series belong together at:

```
eval/results/external_viewer_sample/
    segmentation.dcm       the SEG produced by plugins/totalseg/run_segment.py
    source_series/         the CT instances it references
    SAMPLE.md              which case this is, and what it should look like
```

`SAMPLE.md` records the source series UID, the number of segments, the segment
labels, and the expected z extent. Read it before loading anything, so the
check is against a stated expectation rather than against whatever appears.

If that directory is absent, the evaluation run did not get far enough to
produce a SEG, and this checklist cannot be executed yet. Populate it with:

```
python eval/exp1_conformance.py --stages prepare,segment --sandbox-shim \
    --max-cases 1 --max-slices 48
python eval/exp1_conformance.py --stages sample
```

The second command copies the smallest successfully produced SEG and the exact
instances it references into the directory above and writes `SAMPLE.md`.

> **Note on the source series.** The instances in `source_series/` are a
> *prepared* copy: the public cohort omits `SliceThickness` entirely, and the
> adapter cannot currently write a SEG without it (see the findings in
> `eval/results/exp1_findings.md`). The prepared copy adds the value implied by the slice
> positions and changes nothing else. Load the copy, not the original archive
> download — the SEG references these instances.

---

## 2. 3D Slicer

Tested with 3D Slicer 5.x and the QuantitativeReporting / DCMQI extension,
which is what supplies Slicer's DICOM SEG reader.

1. Open 3D Slicer. Switch to the **DICOM** module.
2. **Import DICOM files** → select `source_series/` → wait for indexing.
3. Import the SEG the same way: **Import DICOM files** → select the directory
   containing `segmentation.dcm`.
4. In the DICOM browser, select the patient, then **load both** the CT series
   and the SEG series (the SEG appears as a separate series, series number
   9901).
5. Confirm the CT appears in the slice views and the segmentation appears in
   the **Segmentations** module's segment list.

Check, and record in the table:

| # | What to check | Why it matters |
|---|---|---|
| S1 | The SEG loads without an error dialog | A reader rejecting the file is a conformance failure regardless of what the automated audit said |
| S2 | The segment list shows the expected number of segments | Segments silently dropped on read indicate a per-frame or segment-description problem |
| S3 | Segment names match the anatomy (`liver`, `aorta`, …) and are not `Segment_1`, `Segment_2`, … | Generic names mean the viewer fell back to numbering because it could not use the labels or the codes. See the coding finding in `eval/results/exp1_findings.md` — this is the check most likely to fail |
| S4 | Each segment is a distinct colour, and two segments are not the same colour | The adapter does not set `RecommendedDisplayCIELabValue`, so colours are assigned by the viewer |
| S5 | Masks overlay the correct anatomy in the axial view | Wrong placement means a geometry or frame-position problem the automated round trip would not catch |
| S6 | Scroll from the first to the last slice: the mask follows the same structure throughout and does not appear inverted top-to-bottom relative to the CT | **z-flip.** The classic DICOM SEG defect. Compare against a structure with obvious cranio-caudal asymmetry — liver low, lungs high |
| S7 | Sagittal and coronal reformats show the mask aligned with the anatomy | Confirms the mask occupies the right physical space, not merely the right slice indices |
| S8 | In **Segmentations → Export/import models and labelmaps**, the segmentation's geometry matches the CT volume's | Catches an origin or spacing mismatch that looks correct on screen |

---

## 3. OHIF Viewer

Tested with OHIF Viewer v3. OHIF needs the data served by a DICOMweb endpoint;
loading local files directly is not the supported path.

1. Start a local DICOMweb server. Any of these works:
   - **Orthanc** with the DICOMweb plugin (simplest; a Docker image exists).
   - `dcmqi`'s sibling tooling, or `dicomweb-server` from the same ecosystem.
2. Upload **both** the source series and `segmentation.dcm` to it.
3. Point an OHIF instance at that server and open the study.
4. Open the study in the **Segmentation** mode (or enable the segmentation
   panel in the viewer's right-hand sidebar).

Check, and record in the table:

| # | What to check | Why it matters |
|---|---|---|
| O1 | OHIF lists the SEG as a loadable segmentation for the study | Requires `ReferencedSeriesSequence` to correctly tie the SEG to the CT |
| O2 | The segmentation loads with no console error | OHIF's SEG loader is stricter than Slicer's about some attributes; browser console errors are worth capturing verbatim |
| O3 | The segment panel shows the expected count and anatomic names | Same concern as S3 |
| O4 | Masks overlay the correct anatomy | Same concern as S5 |
| O5 | Scrolling the stack shows no z-flip relative to the CT | Same concern as S6; OHIF and Slicer have independently made this mistake historically, so both are worth checking |
| O6 | Toggling one segment's visibility affects only that segment | Confirms per-segment frames are separable, which relates directly to the `omit_empty_frames` behaviour |

---

## 4. Results

Fill in one row per check. `PASS` / `FAIL` / `N/A`, and a note for anything not
a clean pass. A `FAIL` here is a finding for the paper, not something to work
around — record what was seen, including screenshots where the defect is
visual.

**Environment**

| Field | Value |
|---|---|
| Date | |
| Operator | |
| SEG file (case id) | |
| 3D Slicer version | |
| Slicer DCMQI/QuantitativeReporting extension version | |
| OHIF version | |
| DICOMweb server and version | |

**3D Slicer**

| # | Check | Result | Notes |
|---|---|---|---|
| S1 | Loads without error | | |
| S2 | Expected segment count | | |
| S3 | Anatomic segment names | | |
| S4 | Distinct segment colours | | |
| S5 | Correct axial overlay | | |
| S6 | No z-flip | | |
| S7 | Reformats aligned | | |
| S8 | Geometry matches CT | | |

**OHIF**

| # | Check | Result | Notes |
|---|---|---|---|
| O1 | SEG listed for the study | | |
| O2 | Loads without console error | | |
| O3 | Expected segment count and names | | |
| O4 | Correct overlay | | |
| O5 | No z-flip | | |
| O6 | Per-segment visibility | | |

**Overall**

> Did an independent *viewer* render our SEG correctly?
>
> ```
> (fill in)
> ```

---

## 5. How to report a failure

If a check fails, the useful record is:

1. Which check, and what was seen instead.
2. A screenshot, for anything visual (misplacement, z-flip, colour collision).
3. The viewer's own error text, verbatim, from the Slicer Python console or the
   browser's JavaScript console.
4. Whether the automated audit for the same file flagged anything
   (`eval/results/exp1_conformance_audit.csv`, filtered to that case). A defect
   the audit missed is a gap in the audit, and worth adding as a check in
   `eval/conformance_checks.py`.
