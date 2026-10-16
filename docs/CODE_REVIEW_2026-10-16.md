# Code review for the JIIM follow-up paper — 2026-10-16

Scope: master @ f0a4a4f, everything except `libs/`. Six areas reviewed in
parallel (arbiter/runtime, SEG export, eval vs claims, Python adapters, viewer
core, installer/packaging). Items marked ✔ were re-checked by reading the code
directly; the rest come from the area reviews and were traced, not re-run.

Severity: **P0** = contradicts a headline claim of the paper as written;
**P1** = a reviewer would catch it / the claim must be reworded; **P2** = a real
bug that does not touch a paper claim.

---

## P0 — headline claims the code contradicts

### 1. "What remains fetchable is weights alone" is false (core framing, §2)
- ✔ All five lock files (`plugins/{gemma,sam2,sam3,totalseg}/requirements.txt`,
  `mlx-server/requirements.txt`) have exact `==` pins but **zero hashes**. Install
  runs `pip install -r` with no `--require-hashes`, `--only-binary=:all:` or
  `--no-index` (`PluginInstaller.swift:845`, `AIServerManager.swift:857`). PyPI
  wheels — and sdists built via `setup.py` where no wheel exists — are fetched and
  executed on the user's machine.
- ✔ `pip install --upgrade pip` runs unpinned first; its exit code and output are
  discarded (`PluginInstaller.swift:839-844`, `AIServerManager.swift:843`).
- ✔ TotalSegmentator "weights" are pickles: nnunetv2 2.8.1 loads them with
  `torch.load(..., weights_only=False)` (`predict_from_raw_data.py:88`), from an
  unhashed GitHub/backend zip.
- `scripts/Python.entitlements` gives the bundled interpreter (and thus every
  plugin venv) `disable-library-validation`, so the notarised signature covers
  none of the code plugins run.
- Venvs are only rebuilt `--clear` when unusable; a changed lock is installed
  over the old env, so removed packages linger while the marker says "matches"
  (`PluginInstaller.swift:764,804-856`).

**Paper:** Either make it true (hashed lock + `--only-binary` or a hashed bundled
wheelhouse, pinned pip, per-file sha256 for weights in `plugins.json`, rebuild on
lock change, state that TotalSeg weights are executable) or reframe as "code is
pinned and fixed at build time; it is fetched at install time from PyPI".

### 2. Network egress outside declared weight URLs (invariant 3, "on-device")
- ✔ `heartchambers_highres` has `crop:["heart"]`; TotalSegmentator first runs a
  crop model (dataset 298, or 297 with robust crop) via
  `download_pretrained_weights()` from GitHub at **run time**. `_weights_present`
  checks only dataset 301 (`run_segment.py:142-160`), and per-weight
  `TOTALSEG_HOME_DIR` means it re-fetches even when `total` is installed.
  `total` with `fast=false` (offered in the manifest) needs datasets 291–295,
  likewise fetched at run time — and its memory is unmeasured but declared 25.5.
- ✔ TotalSegmentator POSTs usage stats to `stats.totalsegmentator.com` after every
  run (`config.py:67` default `send_usage_stats: True`, called from
  `python_api.py:477`); the adapter never disables it, and `HF_HUB_OFFLINE` does
  not block it. Eval env config shows `prediction_counter: 64`. Payload includes
  the licence number; no patient data.

### 3. Exp 2 "689 comparisons, min Dice 1.000000, 0 unplaced frames" is near-circular
- The reference is built by `exp2_fidelity.py:364-404` with the exporter's own
  GDCM file order, `sitk.Resample`, nearest neighbour. Any geometry/resampling
  error appears on both sides and still gives Dice 1.0. What it actually tests:
  highdicom bit-packing + a Python decoder reproduce the exporter's input.
- "0 unplaced frames" holds by construction: `uid_to_index` comes from the same
  file list passed to highdicom as `source_images` (`exp2_fidelity.py:364-388`).
- The "reimplementation of the host's Swift reader" is pydicom and does **not**
  reproduce the Swift reader — see P1-8 (SegmentNumber bug); the Swift decoder
  was never run on the cohort.
- All 7 series ran with an eval-side `--pixel-measures-fallback`; only 1 of 7 was
  re-run on the shipped encoder path (`exp2_REPORT.md:130-148`).
- Cohort is 7 regular axial single-frame CT. No oblique, tilt, irregular spacing
  or multi-frame.

**Paper:** reword to "the encoder and a host-equivalent decoder reproduce the
exporter's labels bit for bit on regular axial CT"; drop "0 unplaced frames" as
geometry evidence; run the Swift decoder on the cohort SEGs; rerun all 7 on the
postfix path.

### 4. Number errors in the outline / EVALUATION.md
| Claim | Where | What the files say |
|---|---|---|
| ✔ "a further 1.9 GB" under-declaration | outline table + :25, exp3_FINDINGS:456 | 25.41 **GB** − 23.5 **GiB**. Same unit: 23.66 − 23.5 = **0.16 GiB** (~11× overstated) |
| ✔ "15 IOD checks pass on 6 cases" | outline:12, EVALUATION:64-66 | 84 rows = **14** checks × 6; **72 PASS / 12 WARN** |
| ✔ liver "lost 74,987 voxels" | EVALUATION:96 | in no result file; exp1 records 758,275; exp2 probe 256. "Same number reached independently" unsupported |
| "185 host / 145 adapter tests" | outline:116 | ~418 Swift tests; 144 `_shared` unit tests; SAM2/TotalSeg have **0** adapter-specific tests |
| "61 segments, 2 080 frames, 112 instances" | outline:113 | no committed result file; 112 matches no cohort series (411–493) |
| "1.8–4.7 ms, 2–5% of a decode" | outline status | per-slice overhead 0.80/1.81/2.52 ms (n=3); 4.7 = median + PNG decode; excludes HTTP upload; denominator is CPU-only decode |
| 23.5 provenance | exp3_FINDINGS:106, :441; EVALUATION:114 | three different stories (23.10 / 23.23 / four runs incl. 20.85 not in any JSONL); committed 23.44 GB run in `exp3_resources_series2.jsonl` undocumented |
| overrun ratio | EVALUATION:115 vs FINDINGS:41,130 | 5.5–6.1× / 6.5× / 6.1–6.6× — mixed GB/GiB |

---

## P1 — a reviewer would catch it / claim needs rewording

### Arbitration (Exp 3)
5. **Exp 3 tests the pure policy, not the shipped admission path.** It compiles
   `ResourceArbiter.swift` unchanged (good), but resident sets are hand-built;
   `pluginResidents`, `applyAdmission`, `makeRoomForBuiltInServer` never run.
   The bugs below all live in that untested layer.
6. ✔ **Built-in Gemma server ignores refusals.** `makeRoomForBuiltInServer`
   (`PluginRuntime.swift:876-890`) applies evictions and drops `.refuse`; the
   docstring says it is "logged" but nothing logs. On 32 GB with `total_lowmem`
   running, the 5 GB engine loads anyway. Contradicts EVALUATION §4 "a resident
   engine could start alongside a segmentation run … fixed".
7. **Concurrent starts can both be admitted over budget** (`PluginRuntime.swift:744-754`):
   the requester becomes visible only after `await applyAdmission` (up to 3 s per
   eviction). SAM3 evicting Gemma + SAM2 starting meanwhile → 9 GiB on an 8 GiB budget.
8. **A victim can be killed mid-request** (`:669-677`): victims are stopped
   sequentially without re-checking evictability; a request started during the
   first stop is cut off by the second. Contradicts "busy plugins are non-evictable".
   Same for `openSession` not marking busy during encode (`:1059-1082`).
9. **`.error` plugins counted as resident and their "freed" memory credited**
   (`PluginRuntime.swift:595`, `ResourceArbiter.swift:323,347`) → `evictThenAdmit`
   where `refuseLiveHeadroom` is correct.
10. **0.75 one-shot share is non-monotonic**: on 48 GB, `total` (25.5) co-resides
    with Gemma while the lighter `total_lowmem` (24.0) evicts it
    (`ResourceArbiter.swift:382-389`).
11. **"32 GB idle: `total_lowmem` admitted"** assumes all 32 GiB free
    (`exp3_resources.py:887`, `available ?? physical`). Admission needs ≥26 GiB
    available — implausible with macOS + viewer + CT. The one realistic row
    (20 GiB) gives `refuseLiveHeadroom`. Measure `MemoryProbe.system()` on a real
    idle 32 GB Mac or reword.
12. **38/38 oracle is partly post-hoc**: expectations were corrected to match the
    arbiter ("two of my initial expectations were wrong", FINDINGS:361; October
    edits FINDINGS:488-492). Present as specification tests and report edits.
13. **"Three instruments, no shared code path"** all read the kernel's
    `ru_maxrss` (`exp3_resources.py:667-697`) — agreement is by construction.
    August used maxrss, October `phys_footprint`; FINDINGS:388 calls them "the
    same quantity".
14. **Eval envs ≠ shipped envs**: eval venvs use Homebrew Python 3.14.5
    (mlx_vlm 0.6.15; batchgenerators 0.25.3) vs the lock's bundled 3.11
    (mlx-vlm 0.6.5; 0.25.5). Fig. 2 numbers come from an env the app never
    installs. exp5 never runs `pip install -r` under bundled 3.11.
15. **October rows not self-describing**: no package versions in
    `exp3_totalseg_lowmem.jsonl`; script committed after the data; October
    arbitration rows sit under an August sandbox header.

### SEG / conformance
16. ✔ **SegmentNumber 48–57 parse as 0–9** (`DICOMAnnotationObject.swift:469`):
    `intValue` tries `stringValue` first, so US `31 00` → "1". Labels collide on
    every cohort SEG (78–107 segments). Latent only because labels are not shown.
17. ✔ **A gap in segment numbers kills the whole SEG export**
    (`run_segment.py:485-492`): `continue` on a mask emptied by resampling keeps
    `segment_number=index`; highdicom requires 1..N contiguous → `ValueError`, no SEG.
    Fix: separate counter.
18. **Host draws all segments one cyan colour**, no labels or per-segment toggle
    (`DICOMAnnotationObject.swift:93-105`, `MultiPanelContainer.swift:1963`).
    "The masks a user sees … per structure" is not what the host shows.
19. **Multi-frame source SEGs**: matched on ReferencedSOPInstanceUID only, frame
    number ignored → all z-levels drawn on every frame. Scope claims to single-frame.
20. **Exp 1 does not stress resampling**: fixtures use `CopyInformation(reference)`
    so `Resample` is identity (`exp1_conformance.py:557`). Drop "stresses
    nearest-neighbour resampling".
21. **Conformance kit is weak where it matters**: square 64×64 probe with
    on-diagonal click and square box cannot detect x/y swap or transposed mask
    (`kit.py:79-91,1350`); R1/R2/X2 SKIP (counted as pass) when weights are absent
    — SAM3 always; W1 passes on any non-argparse exit (`kit.py:505-521`);
    Gemma `/task` never called; token check and parent-death watch never exercised.
22. ✔ **Protocol spec ≠ host**: host passes `--revision` (`PluginInstaller.swift:480`),
    §4b signature omits it; kit's W1 never sends it. A spec-conformant third-party
    adapter would fail install while passing W1.
23. **SAM3 under-declares**: first-load conversion runs in-process (~7 GB by its
    own docstring) and text prompts load a second model; declared 6.0.
24. **Bench encode timing on MPS lacks `torch.mps.synchronize()`**
    (`_shared/bench.py:415-432`) → encode understated, first decode inflated.
    Affects the encode/decode ratio if MPS numbers are cited.

---

## P2 — real bugs, no direct paper claim

Runtime
- **Startup crash hangs 5 min** (✔ `PluginRuntime.swift:1004` + `:846`):
  `handleExit` nils `processes[id]` during the 500 ms sleep, so the early-exit check
  never fires; real exit code replaced by "Timed out".
- Concurrent one-shots of the same plugin are charged once, at the last task's figure.

Viewer (fix before any viewer figure/measurement goes in the paper)
- ✔ **MIP slab "10" projects 11 slices** (`MPREngine.swift:881-885`, `thickness/2`
  each side) while `PanelState.swift:239` says "number of slices".
- ✔ **Double inversion on MPR/MIP**: inversion baked into pixels
  (`DICOMModel.swift:3978` etc.) *and* `CIColorInvert` (`MultiPanelContainer.swift:623`).
- **Stale PixelSpacing/IPP/IOP** carry to the next image when it lacks them
  (`resetSingleFramePixelState`, `DICOMModel.swift:4332`) → ruler in "mm" on an
  uncalibrated image.
- **Pan applied before rotate/flip** on restore (`MultiPanelContainer.swift:592`)
  while `screenToPixel` treats it as outermost → readout/ROI on the wrong pixel
  after pan + flip/rotate.
- Enhanced multi-frame rescale (functional groups 0028,9145) ignored.
- ImagerPixelSpacing used as PixelSpacing without a "detector" label.
- 8-bit render path ignores signedness; two VOI formulas (DCMTK C.11.2.1.2 vs
  plain linear); ROI SD is population SD (÷N) — state in methods if reported;
  slices forced onto median spacing up to 50% deviation.

SEG / adapters
- Encapsulated (compressed) imported SEGs unpacked as raw bits.
- Spacing written as SliceThickness in the SEG.
- SAM3 text prompt drops clicks; zero instances → non-recoverable error.
- No weight file has a client-side checksum; `ODV_MODEL_REVISION` overrides the pin.
- Child processes inherit `PIP_INDEX_URL`, `PYTHONPATH`, `HF_ENDPOINT`, pip.conf.
- Locally built `.app`/`dmg_tmp` carry the old manifest (TotalSeg 3.5, no `total_lowmem`).

---

## Checked and found correct
Arbiter units (GiB = 2^30 throughout, 0.75×32 = 24.0 admits at the boundary);
manifest matches docs; process-group SIGTERM→SIGKILL, no leaks; exp3 compiles the
shipped arbiter; SEG bit unpacking (LSB-first, no per-frame padding), row-major, no
row/col swap, frame↔instance mapping; random 2.25 UIDs; SAM prompt x/y and
normalised→pixel; RLE; inference locks; disconnect cancellation; loopback bind +
token; SAM3 converter `weights_only=True`; `zipfile` traversal-safe; bundled
Python sha256-pinned; `Process` argument arrays (no shell); pixel decode masking,
sign extension, rescale, slice ordering by normal, median IPP spacing with tilt
correction, PixelSpacing row/col order in ruler/angle.

Recomputed and matching: exp1 30/30; exp2 689 = 78+80+107+104+107+107+106; exp3
38/38 `matches_design`; exp3 Oct peaks 25.406 GB = 23.66 GiB, 23.781 GB = 22.15 GiB;
exp4 medians 1590.2 / 92.9 ms → 17.1×; exp5 9/9 (but recorded 2026-08-21, before
`total_lowmem` — re-run before submission).

---

## Suggested order before submission
1. Decide the framing for P0-1/2 (make "weights only" true vs reword). This is the
   paper's central claim, so it gates everything else.
2. Fix the number table in P0-4 across outline / EVALUATION / FINDINGS; use GiB
   for every comparison against a declaration.
3. Reword Exp 2 (P0-3) and add one non-circular check: decode the cohort SEGs with
   the Swift reader and compare physically against TotalSegmentator's NIfTI.
4. Small code fixes: P1-16, P1-17, P1-6, P1-22, P2 startup hang, P2 MIP slab.
5. Re-run exp3/exp5 in envs built by the bundled 3.11 with versions recorded.
