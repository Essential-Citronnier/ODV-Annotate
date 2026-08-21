# Experiment 1 — standard conformance of the plugin layer's DICOM SEG

**Claim under test.** The DICOM SEG our plugin layer writes is conformant and
readable by an *independent* implementation, not merely by our own reader.

**Answer.** Yes for the encoding, with one interoperability defect that a
receiving system will notice. An independent reference implementation — dcmqi
v1.5.7, QIICR's tooling, a different codebase and language from the highdicom
encoder we write with — decodes every segment of every SEG we produced at Dice
**1.000000**, with image geometry (size, spacing, origin, direction) preserved
exactly. No Segmentation IOD requirement is violated in any file. The defect is
semantic rather than structural: every segment is coded as a generic
"anatomical structure", so the specific anatomy survives only as free text.

---

## 1. What was run

| Stage | What it does | Cases |
|---|---|---|
| `fixture` | Encodes deterministic masks through the adapter's own `_export_dicom_seg` | 6 |
| `roundtrip` | Decodes each SEG with dcmqi `segimage2itkimage`, compares voxelwise | 6 |
| `audit` | 14 Segmentation IOD field checks per file | 6 |
| `sample` | Assembles a SEG + its source instances for manual viewer checking | 1 |
| `shipped` | Invokes the adapter's real CLI end to end | 1 (failed, §5) |

Reproduce:

```
python eval/exp1_conformance.py --stages fixture,roundtrip,audit,sample \
    --data .eval/data/tcia --work .eval/exp1raw \
    --dcmqi-bin "$(python -c 'import dcmqi,pathlib;print(pathlib.Path(dcmqi.__file__).parent/"bin")')"
```

Results: `exp1_conformance.jsonl`, `exp1_conformance_roundtrip.csv`,
`exp1_conformance_audit.csv`, `exp1_conformance.png`.

**Cohort.** Six public TCIA CT series (CT Lymph Nodes collection), 411–493
instances each, 2 731 instances total, used **unmodified** — no repair, no
subsetting. A seventh pinned series had not finished downloading and is
excluded; that exclusion is visible in the run log, not silently dropped.

## 2. Provenance — which code produced these SEGs

This matters more than the numbers, so it is recorded per row in
`metrics.provenance` rather than asserted here:

```
module           plugins/totalseg/run_segment.py
adapter_sha256   f0ba42c44b3f627c        (first 16 hex of the file's SHA-256)
export_function  run_segment._export_dicom_seg
mask_scan        run_segment._structure_masks
masks            synthetic, written on the source series grid
```

**The encoder is the shipped one.** Every SEG audited here was written by
`_export_dicom_seg` from `plugins/totalseg/run_segment.py`, called directly,
unmodified, on unmodified source series. Nothing about the DICOM encoding path
is simulated.

**The masks are synthetic, and that is deliberate.** What the mask voxels
*mean* is irrelevant to whether the resulting SEG is standard — conformance is a
property of the encoder. Two things are gained by not routing through nnU-Net.
First it runs: inference here is CPU-only (§5). Second, and more usefully, the
masks can be chosen to attack the encoder, which real TotalSegmentator output
does not — its structures are compact and disjoint. The six fixtures are a solid
ellipsoid (control), a one-voxel-thick shell (nearest-neighbour resampling), a
single-slice structure (`omit_empty_frames`), a structure overlapping another
(labelmap collapse), a structure touching the volume boundary (frame position),
and an empty structure (segment admission).

**What this does not establish.** Segmentation *accuracy* — that is the
pipeline-fidelity track's claim, not this one. And the *whole* shipped path
end to end, for the reason in §5.

## 3. dcmqi round trip

Per structure, in the source series' physical space, against two reference
points — because conflating them would misattribute a defect:

- **vs. encoded** — what the adapter actually handed to highdicom. Isolates the
  encode/decode round trip.
- **vs. intended** — the adapter's input mask. Measures the whole path.

Representative case (`tcia_1028210905866391`, 485 instances); the other five are
in `exp1_conformance_roundtrip.csv`.

| Structure | Intended | Encoded | Decoded | Dice vs encoded | Dice vs intended |
|---|---:|---:|---:|---:|---:|
| aorta | 834 200 | 834 200 | 834 200 | 1.000000 | 1.000000 |
| liver | 3 661 617 | 2 903 342 | 2 903 342 | 1.000000 | 0.884497 |
| spleen | 5 681 | 5 681 | 5 681 | 1.000000 | 1.000000 |
| stomach | 758 275 | 758 275 | 758 275 | 1.000000 | 1.000000 |
| urinary bladder | 4 365 | 4 365 | 4 365 | 1.000000 | 1.000000 |

Across all six cases: **30/30 structures decode at Dice 1.000000 vs encoded**,
zero voxel difference, geometry preserved in every case, zero structures missing
from the SEG, and the deliberately empty `gallbladder` correctly dropped before
encoding rather than emitted as an empty segment.

**The DICOM round trip is lossless.** Every voxel difference observed is
introduced before encoding, by us.

## 4. Findings

### Finding 1 — segments carry no specific anatomic code (interoperability defect)

`WARN segment_coding`, 6/6 cases. Both required code sequences are present, so
this is IOD-conformant; the problem is what they say. Every segment is coded:

```
SegmentedPropertyCategoryCodeSequence  SCT 91723000  "Anatomical Structure"
SegmentedPropertyTypeCodeSequence      SCT 91723000  "Anatomical Structure"
```

One distinct type code across the whole file. The category is correct — anatomy
*is* the right category. Used as the **type**, it says only "this is some
anatomy", and the specific structure survives only in the free-text
`SegmentLabel`.

**Consequence.** A receiving system cannot identify our structures by code,
which is the entire reason coded anatomy exists in the standard. Anything that
routes, indexes, or reasons on `SegmentedPropertyType` — a PACS query for liver
segmentations, a registry ingest, an analytics pipeline joining across sites —
sees five identical "anatomical structure" segments and must fall back to
string-matching English labels. That is precisely the interoperability the
coding is meant to remove. A viewer that displays `SegmentLabel` (Slicer, OHIF)
will look fine, which is what makes this easy to miss.

**It is entirely avoidable.** TotalSegmentator ships the mapping:
`totalsegmentator/resources/totalsegmentator_snomed_mapping.csv`, 170 rows,
covering **117/117** structures of the `total` task and **7/7** of
`heartchambers_highres` — measured, not assumed, and re-measured per run as
`snomed_coverage` (`specific_code_available_upstream: 5`,
`specific_code_emitted: 0`).

The adapter's code comment says the vocabulary "has no complete SNOMED
mapping". That was true of an earlier release and is no longer true.

**Mapping approach** (verified against highdicom 0.27.0 / pydicom in this
environment — *not applied; `plugins/totalseg/*` is not mine to edit*):

1. Load the CSV from the installed package at run time, not vendored, so the
   codes always match the release that produced the masks:
   `Path(totalsegmentator.__file__).parent / "resources" / "totalsegmentator_snomed_mapping.csv"`.
2. Per structure, build `pydicom.sr.coding.Code(CodeValue, CodingSchemeDesignator, CodeMeaning)`
   from the `SegmentedPropertyCategoryCodeSequence.*` and
   `SegmentedPropertyTypeCodeSequence.*` columns and pass both to
   `hd.seg.SegmentDescription`. Confirmed working: liver →
   `SCT 10200004 "Liver"`.
3. **Laterality.** 
   `SegmentedPropertyTypeModifierCodeSequence.*` is populated for paired organs
   (`adrenal_gland_left` → `SCT 7771000 "Left"`). highdicom has no constructor
   keyword for it; attach it after construction —
   `description.SegmentedPropertyTypeCodeSequence[0].SegmentedPropertyTypeModifierCodeSequence = [ds]`
   with a `Dataset` carrying the three code attributes. Verified.
4. **Display colour** (fixes half of Finding 2, and the "Failed to get CIELab
   values" warning dcmqi emits on our files). The CSV's `DicomRGBColor` gives a
   per-structure RGB. Pass `display_color=hd.color.CIELabColor(L*, a*, b*)` —
   note highdicom wants *perceptual* L\*a\*b\* and does the 16-bit DICOM
   encoding itself, so do **not** feed it
   `totalsegmentator.dicom_utils.rgb_to_cielab_dicom`, which returns the
   already-encoded triple and fails highdicom's range check. Verified:
   `rgb (241,172,34)` → `Lab (75.03, 14.78, 72.70)` → encoded
   `(49171, 36694, 51581)`, matching TotalSegmentator's own encoder to 1 LSB.
5. Fall back to the current generic code for any structure absent from the CSV,
   so a future task with unmapped structures degrades rather than fails.

Re-running `--stages audit` after the change should flip `segment_coding` to
PASS and take `specific_code_emitted` to the segment count.

### Finding 2 — provenance and display fields absent

`WARN content_identification`, 6/6 cases. Absent: `ContentDescription`,
`ContentCreatorName`, `SeriesDescription`. None is Type 1, so this is
conformant. `Manufacturer`, `ManufacturerModelName`, `SoftwareVersions` and
`DeviceSerialNumber` *are* set, so the SEG is attributable to the software that
made it — the important half. The missing `SeriesDescription` means the SEG
appears unnamed in a series picker, which is a usability cost in exactly the
external viewers we ask a reader to trust. Cheap to fix alongside Finding 1.

### Finding 3 — overlapping structures are silently clipped (limitation, not an active bug)

`_export_dicom_seg` builds one `uint8` labelmap and assigns `label[array] = index`
per structure in sorted-name order, so where two structures overlap the later
index overwrites the earlier one, and those voxels are gone *before* encoding
begins. There is no warning.

Measured: liver 3 661 617 intended → 2 903 342 encoded; `overwritten_by_later_segment`
= **758 275**, exactly the stomach's voxel count. Range across the six cases:
639 205 – 770 909. The fidelity track characterised the same mechanism by a
different route and arrived at the same number — two independent confirmations.

**Framing.** Per the fidelity track, this is *not reachable* through
TotalSegmentator's `total` task on real data: its structures are disjoint by
construction. So it is a limitation of the `seg3d` output kind for future
adapters that emit overlapping structures — a prompt-driven adapter, a
multi-model ensemble, or any task with nested anatomy — rather than a live
defect in the shipped path. The DICOM Segmentation IOD represents overlapping
segments natively (one frame set per segment); the labelmap intermediate is
what discards them. Worth stating in the protocol as a constraint on `seg3d`,
and worth an explicit warning in any adapter that can produce overlaps.

### Finding 4 — SliceThickness (resolved during this experiment)

All seven cohort series omit `SliceThickness` (0018,0050) — Type 2 in the CT
Image IOD, legitimately absent from this de-identified archive export — and
highdicom reads it unconditionally, so `_export_dicom_seg` raised
`AttributeError` and the plugin produced **no output at all** for any series.

Fixed in commit `9a3f8f0`, which derives the spacing from slice positions
projected onto the slice normal. **All results in this document were produced
after that fix, on unmodified source series** — the earlier repair-then-encode
workaround was discarded rather than reported.

## 5. What could not be verified here, and why

**The shipped path end to end.** `stage_shipped` invokes the adapter exactly as
the host does — `--task total --out <dir> --input-series3d <series>`, no shim,
no repair — and is the right way to demonstrate the whole pipeline. It was run,
and it is recorded as a failure row rather than omitted:

```
case         shipped/tcia_1028210905866391      exit_code 1      40.4 s
error        internal / "EOFError: "            seg_produced false
result.json  written
```

The `EOFError` is the sandbox denial described below, surfacing from nnU-Net's
multiprocessing manager. Two things are worth taking from the row rather than
discarding it. It is an *environment* failure, not an adapter defect — the same
adapter's encoder succeeds on all six series (§2–§3). And the adapter behaved
correctly on the way down: it wrote `result.json` with a protocol §3 error
envelope despite the non-zero exit, which is exactly what §4c requires so the
host can show the user a message instead of a bare exit code.

The reasons it cannot succeed here:

- The sandbox reports **no GPU** to torch (`torch.backends.mps.is_available()`
  is False on an Apple M5 Max), so inference is CPU-only.
- The sandbox **denies the AF_UNIX `bind(2)`** that nnU-Net's multiprocessing
  data loader requires; without a substitution the predictor fails with
  `EOFError` before any inference runs.
- With the substitution in place (nnU-Net's own upstream
  `predict_from_files_sequential`, a `ThreadPool` for NIfTI writing, and a
  `torch.set_num_threads` floor — see `_SHIM_SOURCE`), inference still did not
  complete within 30 minutes per case on a machine whose load average reached
  161 on 18 cores from concurrent evaluation tracks.

So: the encoder is verified on real data; the segmentation stage preceding it
is not, here. **No timing in this experiment is a laptop number**, and none is
reported as one. `machine_profile()` records `gpu_visible` per run.

One substitution detail worth recording, because it cost real time and would
silently corrupt a timing result rather than fail loudly: TotalSegmentator
replaces `nnUNetPredictor.predict_from_files` at *its own* module import
(`totalsegmentator.nnunet_runtime_patches`), so a shim installed from an import
hook is overwritten immediately afterwards and the run proceeds on the
multiprocessing path. The shim therefore imports first, patches second, and
`verify()`s before any inference starts. Separately, TotalSegmentator passes a
`torch.device` object for CPU runs, which takes the branch written for GPU runs
and calls `torch.set_num_threads(1)` — pinning the entire forward pass to one
core on a machine with no accelerator.

**External viewer rendering.** Requires a display and a person. Prepared as
`docs/EXTERNAL_VIEWER_CHECKLIST.md` with a populated sample at
`eval/results/external_viewer_sample/` (411 source instances, 5 segments) and a
blank results table. Not executed. Any paper text about Slicer or OHIF behaviour
must come from a filled-in copy of that table.

## 6. Statement for the paper

> The segmentation output of the plugin layer was checked against the DICOM
> Segmentation IOD by an automated field audit (14 checks) and round-tripped
> through dcmqi v1.5.7, an independent reference implementation, over six public
> TCIA CT series (2 731 instances). Every segment decoded at Dice 1.000000 with
> image geometry preserved, and no IOD requirement was violated. Two conformant
> but semantically incomplete properties were identified: segments are coded with
> a generic anatomical-structure concept rather than the specific SNOMED code
> available for every structure in the model's vocabulary, and optional
> descriptive fields are unset. Rendering in third-party viewers was not
> evaluated.

Do not write "the plugin produces conformant DICOM SEG" without the coding
caveat. An imaging-informatics reviewer will query `SegmentedPropertyType`
first, and finding one generic code across every segment after reading a
conformance claim is worse than having disclosed it.
