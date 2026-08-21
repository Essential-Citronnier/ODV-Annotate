# Experiment 2 — Pipeline fidelity

Section for `docs/EVALUATION.md`. Written as a standalone file because
`EVALUATION.md` is shared across tracks; splice this in rather than having two
tracks edit one file.

**Claim under test.** Routing a segmentation model through the ODV plugin
abstraction is lossless: the masks a user sees after
`DICOM series → adapter → DICOM SEG → host decode` are the masks
TotalSegmentator produced.

**Not claimed.** Nothing here concerns TotalSegmentator's segmentation
accuracy. That is published, it is not this paper's contribution, and no
measurement below is designed to support a statement about it.

---

## 1. Design

A single plugin-vs-native Dice cannot, by itself, attribute a disagreement to
the abstraction, so three measurements were made per case.

| # | Measurement | What it isolates |
|---|---|---|
| i | **Model determinism** — the native model run twice on byte-identical input | The noise floor. Bounds what (iii) can possibly show. |
| ii | **SEG round trip** — the same in-memory masks encoded by the adapter's own exporter, decoded by a reimplementation of the host's Swift reader | The abstraction alone. No inference runs between encode and decode, so any loss is the encoding. |
| iii | **End to end** — the adapter spawned exactly as the host spawns it (PLUGIN_PROTOCOL.md §4), against a native run on the same CT | The number a reader wants. Inherits (i)'s noise floor. |

Both paths are fed the same volume: the adapter hands TotalSegmentator a DICOM
directory and TotalSegmentator converts it internally with `dicom2nifti`, so
the native path is fed the output of that same converter. The common comparison
frame is the source DICOM grid — the frame the host renders in and the frame
the SEG references.

The decoder in (ii) and (iii) deliberately reimplements
`DICOMAnnotationObject.parseSegmentation` rather than using a library reader:
the claim is about the round trip the host actually performs, and a library
reader that silently repaired an encoder/decoder disagreement would hide
exactly the defect this experiment exists to find. It reproduces the Swift's
LSB-first bit unpacking, its `min(NumberOfFrames, len(PerFrameFunctionalGroups))`
frame count, and its placement of frames by referenced SOP Instance UID alone.

**Cohort.** 7 public TCIA CT series (`CT Lymph Nodes`, abdomen and
mediastinum), 411–493 slices. `total` task, 3 mm `fast` model.

## 2. Result

**Every per-structure comparison is exactly 1.0.** 689 structure comparisons
per measurement across 7 of 7 successful cases:

| Measurement | n | min Dice | structures < 0.999 | max voxel-count difference |
|---|---|---|---|---|
| Model determinism | 689 | 1.000000 | 0 | 0 |
| SEG round trip | 689 | 1.000000 | 0 | 0 |
| End to end | 689 | 1.000000 | 0 | 0 |

Zero frames were unplaceable by the host decoder in any case, in either the
round-trip or the end-to-end SEG (`unplaced_frames = 0` throughout). This
matters because the exporter sets `omit_empty_frames=True`: the frame list is
sparse in z, so the referenced-SOP mapping carries the entire geometry of the
result, and a frame the host cannot place is a frame the host will not draw.

The determinism control returning 1.0 is what makes the other two rows
interpretable. The noise floor is zero, so any disagreement in (iii) would have
been unambiguously attributable to the abstraction rather than to nnU-Net.

Per-case detail is in Table 1 (`exp2_tables.md`); all 2,067 per-structure rows
are in `exp2_fidelity.csv`, and the full records including per-structure arrays
are in `exp2_fidelity.jsonl`.

## 3. The measurement can detect a difference

A comparison that reports 1.0 everywhere is worthless unless it is shown to be
capable of reporting anything else. Four controlled probes
(`exp2_probes.json`), run against the adapter's real exporter and the host
reader on a synthetic 6-slice series:

| Probe | Result | Meaning |
|---|---|---|
| Comparison sensitivity | identical → 1.000; **one voxel** removed from a 432-voxel structure → 0.998841; shifted one slice → 0.667; structure dropped → 0.000 | The comparison resolves a single voxel. A Dice of 1.0 elsewhere is a measurement, not a blind spot. |
| Sparse frame reconstruction | 5 frames encoded where a dense encoding would write 18; all 3 structures reconstructed at Dice 1.0, 0 unplaced | `omit_empty_frames` does not shift anatomy in z. |
| Overlapping structures | **0.857 for the earlier-encoded structure, 256 voxels silently lost** | A real defect. See §5. |
| Missing `SliceThickness` | **Shipping adapter exits 1 with `AttributeError`** | A real defect. See §4. |

## 4. Defect found: the shipping adapter cannot segment this public collection

`_export_dicom_seg` raises `AttributeError: 'FileDataset' object has no
attribute 'SliceThickness'` on every series in the cohort.

**Mechanism.** highdicom's `_Image._get_pixel_measures_sequence` reads
`source_image.SliceThickness` by attribute access while reading the optional
`SpacingBetweenSlices` with `.get()`. `SliceThickness` (0018,0050) is Type 2 —
a conformant CT series may leave it empty — and all 411 instances of the first
cohort series omit it entirely. The exception is raised inside the
`hd.seg.Segmentation` constructor, so the adapter produces no SEG at all.

**Reachability: immediate and total.** This is not a corner case. It affects
every series in the `CT Lymph Nodes` collection, so as shipped the adapter
cannot process this public TCIA collection, and will fail on any scanner or
anonymisation pipeline that drops the tag.

**Confirmed by construction.** Probe 4 strips `SliceThickness` from a
controlled series and runs the exporter twice as child processes, with and
without a fallback: exit 1 with the `AttributeError` without it, exit 0 with
it. The failure is attributable to the tag and nothing else.

**Fix.** `SliceThickness` is itself optional within the Pixel Measures
Sequence, so passing `slice_thickness=None` produces a conformant SEG. The
evaluation applies this as a runtime fallback in order to measure anything at
all; the fallback is recorded in the `notes` of every affected result row. **The
fix belongs in `plugins/totalseg/run_segment.py`, which is not my file** — the
adapter should construct an explicit `PixelMeasuresSequence` and pass it to
`hd.seg.Segmentation` as `pixel_measures=`, deriving slice spacing from
`ImagePositionPatient` when `SliceThickness` is absent. Reported for the track
that owns that file.

## 5. Defect found: overlapping structures are clipped — latent, not reachable

`_export_dicom_seg` accumulates all structures into **one** `uint8` labelmap
with `label[array] = index`. Where two structures share a voxel, the
later-encoded index overwrites the earlier one, and the earlier structure comes
back short with no error raised. Probe 3 measures the loss directly: the
earlier structure returns at Dice 0.857, having silently lost all 256 voxels of
the intersection.

**Is it reachable today? No — and this was checked three ways, not argued once.**

1. **By construction.** TotalSegmentator derives every per-structure file from
   one integer labelmap by equality test — `binary_img = img_data == k`
   (`totalsegmentator/nnunet.py:915`). A voxel carries exactly one label, so
   the `total` task's structures are disjoint by construction and cannot
   produce an overlap.
2. **Measured on real cohort output, including the resampling step.** The code
   reading covers the masks as produced but not as the exporter resamples them:
   nearest-neighbour resampling is applied to each structure independently, so
   two structures adjacent on the 3 mm grid could in principle both claim a
   coarse source voxel. Measured on a full cohort series (80 non-empty
   structures): **0 multiply-covered voxels natively and 0 after resampling
   onto the source grid** (`exp2_overlap_reachability.json`).
3. **Implied by the cohort result itself.** Clipping is what the defect *does*.
   Had any two structures collided anywhere in the cohort, the earlier-encoded
   one would have returned short and its round-trip Dice would be below 1.0.
   All 689 round-trip comparisons are exactly 1.0, which rules out a collision
   across the whole cohort at no extra cost.

**Therefore: a limitation to document, not a bug to fix now.** The protocol's
`seg3d` output kind does not require structures to be disjoint, so a future
adapter — an interactive segmentation tool, or a model with hierarchical labels
where `liver_segment_IV ⊂ liver` — would lose voxels silently. Two candidate
remedies for whoever owns the exporter: encode one labelmap per overlapping
group, or assert disjointness at encode time and fail loudly rather than
clipping. The second is cheap and turns silent data loss into an error.

## 6. Hygiene check against expert reference masks

Identical results from two paths is also what two equally broken paths produce.
If the abstraction fed the model a mis-scaled volume, both comparisons would
agree perfectly while the masks were nonsense. The check against that:

| Case | Reference structures | Native mean Dice | Plugin mean Dice | Large structures (native / plugin) | Path agreement |
|---|---|---|---|---|---|
| s0049 | 108 | 0.8545 | 0.8545 | 0.9496 / 0.9496 | 1.000000 |
| s0111 | 89 | 0.8304 | 0.8304 | 0.9495 / 0.9495 | 1.000000 |
| s0241 | 76 | 0.8160 | 0.8160 | 0.9432 / 0.9432 | 1.000000 |
| s0245 | 54 | 0.8046 | 0.8046 | 0.8623 / 0.8623 | 1.000000 |

Reference: the TotalSegmentator ground-truth release (Zenodo 10.5281/zenodo.10047292,
CC BY 4.0). The release ships NIfTI, but the plugin path consumes a DICOM
series by contract, so the reference CT is written out as a conformant DICOM
series that **both** paths then read — the conversion was verified voxel-exact
and geometry-preserving, and being common to both paths it cannot advantage
either. 327 per-structure comparisons; the two paths score identically to
6 decimal places on every one.

**This is a hygiene check, not an accuracy claim.** Wasserthal et al. report
Dice 0.943 for the full-resolution model; this runs the 3 mm `fast` model,
which trades resolution for speed and scores lower, on four cases. Large
structures at ~0.95 and an all-structure mean of ~0.83 are consistent with the
fast model and rule out a silently broken pipeline. They support no statement
about TotalSegmentator's accuracy, and the small-structure figures in
particular should not be read as one.

**2 of 6 reference cases failed** and are recorded as failures: `s0189` and
`s0193` carry non-orthonormal direction cosines, which ITK refuses to read.
That is a property of those NIfTI files, not of the plugin layer. They were not
rescued by rewriting the reference geometry — a hygiene check whose reference
was adjusted to make it pass is not a check.

## 7. What could not be measured here, and why

**Every timing in this experiment is CPU-only and is not a desktop number.**
The sandbox reports no accelerator to torch (`gpu_visible: {torch_mps: false,
torch_cuda: false}`, recorded in every result file header). Wall times of
466–988 s per case, and peak RSS of ~24 GB, characterise this measurement
environment and must not be presented as laptop performance.

**A substitution was required for nnU-Net to run at all.** The sandbox denies
the `AF_UNIX` `bind(2)` that `multiprocessing.Manager` needs — verified
directly: a bare `socket.bind` on an AF_UNIX path returns `EPERM`, while
`multiprocessing.Pool`, `Queue` and `Event` all work. nnU-Net's preprocessing
iterator is manager-backed, so it was replaced with a serial generator yielding
the identical items in the identical order. Preprocessing is deterministic, so
mask values are unaffected; decisively for this experiment, the substitution is
applied to **both** paths identically, so it cannot bias a comparison between
them. It removes the overlap of preprocessing with inference, so it preserves
correctness and **not** performance characteristics. It is named in the `notes`
of every result row.

Getting a defensible desktop timing needs the adapter run outside this sandbox
on the target hardware, with GPU visible and multiprocessing unrestricted.

## 8. Files

| File | Contents |
|---|---|
| `eval/exp2_fidelity.py` | Cohort experiment, controlled probes, reachability check |
| `eval/exp2_hygiene.py` | Reference-mask hygiene check |
| `eval/exp2_figures.py` | Figures, with programmatic text-overlap verification |
| `eval/exp2_tables.py` | Tables 1 and 2 |
| `eval/results/exp2_fidelity.jsonl` / `.csv` | 7 cases; 2,067 per-structure rows |
| `eval/results/exp2_hygiene.jsonl` / `.csv` | 6 cases (4 ok, 2 recorded failures) |
| `eval/results/exp2_probes.json` | The four controlled probes |
| `eval/results/exp2_overlap_reachability.json` | Overlap reachability on real cohort output |
| `eval/results/exp2_tables.md` | Tables 1 and 2 as markdown |
| `eval/figures/exp2_fidelity.png` | Figure: fidelity, sensitivity, defect, voxel agreement |
| `eval/figures/exp2_hygiene.png` | Figure: both paths vs. expert reference |

Reproduce:

```sh
PYTHONPATH=eval <ts-python> eval/exp2_fidelity.py --probes \
    --data-root .eval/data/tcia --out eval/results/exp2_fidelity.jsonl \
    --python <ts-python> --determinism --resume
PYTHONPATH=eval <ts-python> eval/exp2_hygiene.py \
    --ground-truth .eval/data/ground_truth --python <ts-python>
PYTHONPATH=eval <ts-python> eval/exp2_figures.py
PYTHONPATH=eval python eval/exp2_tables.py
```
