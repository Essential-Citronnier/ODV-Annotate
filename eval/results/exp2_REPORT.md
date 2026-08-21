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

## 4. Defect found and FIXED: SEG export on series without SliceThickness

**Status: fixed in `plugins/totalseg/run_segment.py`, commit 9a3f8f0.** Found by
this experiment, fixed by the track that owns the adapter, and re-verified here
against the shipped code. Reported because the defect and its cause are worth
the paper's space — an evaluation that finds a real blocker in its own subject
is evidence the evaluation works.

As originally found, `_export_dicom_seg` raised
`AttributeError: 'FileDataset' object has no attribute 'SliceThickness'` on
every series in the cohort.

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
controlled series and runs the exporter as a child process. Before the fix it
exited 1 with the `AttributeError`; the failure was attributable to the tag and
nothing else.

**The fix, and how it was verified here.** The adapter now derives slice
spacing from the source geometry rather than reading the absent tag: slice
positions are projected onto the slice **normal** — not differenced in z, which
on this cohort gives 224 mm because the files do not sort by position — and the
median gap is taken. Non-uniform spacing is logged rather than silently
averaged, and when the geometry needed to derive it is also missing the adapter
fails with `bad_input` naming the cause instead of raising `AttributeError`.

Probe 4 is now a **regression test** rather than a defect report. It runs the
exporter with the evaluation's own fallback switched **off**, so it exercises
the shipped derivation: `shipping_adapter: exit_code 0, "encoded"`. The
evaluation's fallback still exists behind a separate switch
(`ODV_EXP2_PIXEL_MEASURES_FALLBACK`) purely so a pre-fix adapter can still be
made to reproduce the original failure.

Note on the measured cohort. The 689-comparison result in §2 was produced with
the evaluation's fallback active, because the adapter fix did not yet exist.
Both are ways of supplying the same missing Pixel Measures element, and the
fidelity numbers do not depend on which supplies it — the round trip compares
masks, not header provenance. §2 was re-verified against the shipped encoder on
one full cohort series after the fix landed; see §4.1.

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

**This is a hygiene check, not an accuracy claim.** Wasserthal et al.
(*Radiology: Artificial Intelligence* 2023;5(5):e230024, doi:10.1148/ryai.230024)
report Dice 0.943 for the full-resolution model — verified against the
retrieved article text, not quoted from recall. That figure is a single
aggregate over the authors' own test set, not a per-structure value and not
the model run here; it is drawn as a reference line for order of magnitude,
not as a threshold either path is expected to meet. This runs the 3 mm `fast` model,
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

Note on reading `exp2_hygiene.jsonl` directly: the harness's `done_case_ids()`
reports only successes, so `--resume` retries a failed case and appends a
second row when it fails again. Both `s0189` and `s0193` therefore appear
twice. The JSONL is append-only by design and keeps every attempt as the audit
trail; `exp2_tables.py` reports each case once, and the runner now announces a
retry at the point it creates the duplicate.

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
