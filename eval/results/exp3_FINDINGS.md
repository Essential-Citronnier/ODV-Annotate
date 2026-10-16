# Experiment 3 — resource characterisation and arbitration

Machine: Apple M5 Max, 18 cores, 128 GB. Every number below was produced by
`eval/exp3_resources.py` and is recorded in `eval/results/exp3_resources.jsonl`,
including the runs that failed. Each row carries the input it was measured on
(`metrics.input_series`), so repeated runs of the same plugin on different data
are distinguishable rather than being indistinguishable rows under one
`case_id`.

Reproduce the whole thing with:

```
PYTHONPATH=eval python eval/exp3_resources.py \
  --series .eval/data/tcia/tcia_1556218467652708 \
  --crosscheck-series .eval/data/tcia/tcia_1556218467652708 \
                      .eval/data/tcia/tcia_2121018880599426 \
  --totalseg-threads
```

## Which numbers are defensible

The evaluation sandbox reports **no GPU** to torch (`torch.backends.mps` and
`torch.backends.cuda` both unavailable; captured per run as
`machine.gpu_visible` in the JSONL header) and **denies every `bind(2)`** —
AF_UNIX and loopback TCP alike. This splits the table in two.

| Class | Numbers | Status |
|---|---|---|
| Install, weight download, disk footprint | venv creation, pip, download time and bytes | **Substitution-free.** Network and disk work; accelerator visibility is irrelevant. Two accommodations noted below affect transport, not bytes. |
| Model load, inference, encode/decode | all timings in the per-use column | **CPU-only sandbox figures.** Not laptop performance, not to be presented as such. |
| Peak RSS | `peak_rss_gb` | Real allocation, measured per-process. Unaffected by GPU absence for the CPU path, but a GPU run would move part of the footprint off the host heap. |
| TotalSegmentator wall time | 149 s segmentation | **Upper bound only.** Produced under the thread substitution described below. |

## Measured table

| Plugin | Model | Declared `ram_gb` | Measured peak | Ratio | Install | Weights |
|---|---|---|---|---|---|---|
| SAM 2 | session | 3.0 GB | **1.45 GB** | 0.48× | 69 s | 184 MB in 24 s |
| SAM 3 | session | 6.0 GB | not measured | — | 71 s | licence gate held |
| Gemma 4 E4B | resident-server | 5.0 GB | not measured | — | 60 s | 5.18 GB in 879 s |
| TotalSegmentator | one-shot | 3.5 GB → 23.5 GB → **25.5 GB** (Oct 2026) | **22.70 GB** single process; **25.41 GB** process tree (Oct 2026) | **6.5× as declared; 0.97× corrected** | 176 s | 166 MB in 52 s |

### The corrected declaration, validated end to end

After commits `de234fe` and `9a3f8f0`, TotalSegmentator completes the **whole**
pipeline for the first time in this environment — segmentation, volume
measurement, and DICOM SEG export — because the slice-thickness fix removed the
export failure that previously truncated every run:

| Stage | Time | |
|---|---|---|
| environment check | 0.001 s | |
| segmentation | 54.2 s | 80 structures |
| volume measurement | 6.1 s | |
| DICOM SEG export | 10.9 s | 314 MB written |
| **pipeline total** | **71.2 s** | sum of the adapter's own stages |
| **subprocess wall** | **76.4 s** | 412-slice CT, CPU-only, thread substitution |

The 5.2 s between the two is interpreter startup and the torch/nnU-Net import
chain, which happens before the adapter's first stage boundary and so is
outside every figure the adapter reports about itself. It is a real cost the
user pays on every one-shot invocation — a one-shot cannot amortise it the way
a resident server does — so both numbers are given rather than picking one.

Peak RSS **22.70 GB against the corrected 23.5 GB declaration — a ratio of
0.97×**. So the corrected figure is validated by an independent run that had
no part in deriving it, and it is correct in the safe direction, with about
0.8 GB of headroom. This is the check that the Finding 1 remedy actually
holds, not merely that the number was raised.

Note that the DICOM SEG export is **15% of the pipeline** (10.9 of 71.2 s) and was invisible
in every earlier measurement, since it was the stage that used to fail. A
one-shot's cost is not just its model.

Stage detail for the two plugins whose models ran:

- **SAM 2**: model load 4.5 s, encode 544 ms/slice, decode 30 ms/prompt,
  RLE 5 ms. **Encode is 18.1× decode.**

  These supersede an earlier set (load 11.3 s, encode 1701 ms, decode 200 ms,
  ratio 8.5×) measured while a TotalSegmentator run was saturating the CPU.
  The contended figures were wrong in a way worth naming: contention inflated
  encode and decode unequally, so it compressed the *ratio* that justifies the
  `session` execution model — understating it by better than half. Peak RSS was
  unaffected (1.447 GB then, 1.451 GB now), which is what one would expect of
  an allocation figure, and is a small check that the two runs measured the
  same work.
- **TotalSegmentator**: environment check ~0 s, segmentation 149.2 s,
  volume measurement 14.4 s, DICOM SEG export failed (below).

Restart cost, measured by stopping a resident SAM 2 and re-serving the same
prompt: **2.9 s cold, 2.9 s warm**. That is what an eviction costs the user on
this machine, CPU-only. Cold and warm agree because the cost is dominated by
loading a 184 MB checkpoint into a torch graph rather than by reading it off
disk, so a warm filesystem cache buys almost nothing — which is itself the
useful result: the price of an eviction cannot be cached away. Supersedes
12.0 s / 8.8 s measured under CPU contention.

## Finding 1 — TotalSegmentator's declared memory is wrong by ~6×

> **RESOLVED in commit `de234fe`**: `ram_gb` raised 3.5 → 23.5, and the
> manifest schema gained an optional per-task `ram_gb`.
>
> Two notes on the number itself, so the paper does not overstate its
> provenance. First, 23.5 GB exceeds the highest figure in this experiment's
> record (23.10 GB) by 0.4 GB; the recorded measurements are 20.85, 21.40 and
> 23.10 GB. If 23.5 was taken from the superseded cross-check row described
> below, it should be re-derived — though as a *declaration* it errs toward
> safety, which is the correct direction to err. Second, it remains a
> `fast=true` figure: full resolution runs five models rather than one and is
> still unmeasured, so the per-task field is where that gap will eventually be
> closed.

`ram_gb: 3.5` against a measured peak of **20.85 GB** on a 411-slice abdominal
CT. That original bench row was superseded when the phase was re-run to record
its input series (and again after the export fix let the pipeline complete), so
the figure survives here and in the prose below rather than in the current
JSONL; the run that replaced it on the same series measured 22.70 GB, and the
cross-checks below measured 23.10 and 21.40 GB. Every one of those is ~6× the
3.5 GB that was declared at the time.

The `crosscheck` phase re-measures the same pipeline with three instruments
that share no code path — the parent's per-child accounting, the child's own
`RUSAGE_SELF` high-water mark, and a 0.3 s self-sampler inside the child — on
two different series. All rows are in the JSONL under
`crosscheck/totalsegmentator/<series>`:

| Series | Slices | Parent accounting | Child `RUSAGE_SELF` | Child sampler | Spread | Ratio |
|---|---|---|---|---|---|---|
| `tcia_1556218467652708` | 411 | 23.10 GB | 23.10 GB | 23.10 GB | 0.00 GB | **6.60×** |
| `tcia_2121018880599426` | 493 | 21.40 GB | 21.40 GB | 21.40 GB | 0.00 GB | **6.11×** |

Three instruments agreeing to the byte on two independent volumes, with the
overrun reproducing on both, is the evidence for this finding. Across every
pipeline run measured on this cohort — two cross-checks and the completed bench
run above — the peak spans **21.4–23.1 GB, i.e. 6.1× to 6.6× the 3.5 GB that
was declared**. The earlier 20.85 GB reading, taken before the export fix let
the pipeline finish, sits just below that band and does not change the
conclusion.

External sampling with `psutil` is deliberately not among the instruments:
this sandbox denies the `sysctl` it needs, so it reports zero and would look
like a disagreement rather than an unavailable instrument.

This is not an artifact of the thread substitution. For a single series nnU-Net
computes `num_processes = min(len(cases), 3) = 1`, so the substitution replaces
one worker process with one worker thread and the total allocation is unchanged.
The `rss_after_stage` trace locates the peak inside `Running segmentation`,
not in the preprocessing the shim touches.

**Why this matters beyond documentation.** The arbiter admits work by comparing
declarations against a budget of half physical memory. Two scenarios driven
through the shipped `ResourceArbiter` make the consequence concrete on the
16 GB machine the policy targets:

- `16gb/totalseg-admitted-on-its-declaration` → **admit** (3.5 fits an 8 GiB budget)
- `16gb/totalseg-refused-on-its-measurement` → **refuse** (20.9 exceeds budget and machine)

The policy is correct in both rows; it answers the question it was asked. The
divergence is entirely a consequence of which figure the manifest carries. On a
16 GB machine the declaration admits a job that will need more than the whole
machine.

**Every figure above is the `fast` (3 mm) variant.** Both the bench and the
cross-check pass `fast=true`, which is the manifest's default for the `total`
task. So the 6× overrun is not the expensive configuration overrunning its
budget — it is the *cheap* one.

Full resolution could not be measured here, and the reason is structural
rather than incidental. Where `fast` runs a single 3 mm model
(`Dataset297`), full resolution runs **five** separate models
(`Dataset291`–`Dataset295`, per `map_tasks_config.py`) over the volume at full
through-plane resolution. Its footprint is therefore not a scaled version of
the measured one, and no multiplier applied to 23 GB would be a defensible
estimate of it.

Two acquisition attempts are on the record. The adapter's own fetch is
recorded as `crosscheck/totalsegmentator/fullres/tcia_1556218467652708`
carrying the `ProxyError` from the GitHub releases host. A second attempt
through a network path that does reach that host was stopped after ~17 minutes
on the time budget allotted to this measurement, having completed **one** of
the five archives (225 MB); a second was partial and a third was a 9-byte stub
from a mis-derived filename. None of the fetched files survive in the
workspace, so the full-resolution figure has no partial result behind it
either.

**This is a gap, not an estimate.** The honest statement is that the
manifest's single figure has been shown wrong by ~6× for the default
configuration, and that the non-default configuration is unmeasured and runs
five models instead of one. Measuring it needs a machine that can reach
`github.com/wasserth/TotalSegmentator/releases` and roughly an hour of CPU
time, or minutes on a visible GPU.

**Proposed correction.** Declare `ram_gb` per task and per option combination
rather than once per plugin. The measured `fast` figure alone justifies at
least `24.0` for `total` with `fast=true`; the full-resolution figure is
unmeasured and must not be guessed from it, for the reason above. A single scalar `ram_gb` cannot describe a plugin whose footprint
depends on options the caller selects, which is the structural version of this
finding: the protocol gives a plugin one number to describe every
configuration it can be invoked in. I did not edit the manifest or the
protocol: both are other tracks' files.

## Finding 2 — a running one-shot is invisible to the arbiter

> **RESOLVED in commit `de234fe`**: `residentSet()` now includes plugins with
> in-flight one-shot invocations. The arbitration scenario pair below is
> retained deliberately — it is the measurement that established the defect,
> and after the fix the `…-unreported` row describes a state the host can no
> longer produce, which is the point.

`PluginRuntime.residentSet()` derives residency from `runtimeStates`, and a
one-shot subprocess never enters that dictionary — it is spawned, tracked in
`busy` and `activityProgress`, and reaped without ever becoming `.ready`. So
the arbiter is never told that a one-shot is holding its peak.

Driven through the real arbiter, the same instant described two ways:

- `16gb/start-server-while-oneshot-runs-reported` → **refuse** (correct: 3.5 + 5.0 > 8 GiB budget)
- `16gb/start-server-while-oneshot-runs-unreported` → **admit** (what the host actually asks)

Combined with Finding 1 the real exposure on a 16 GB machine is a ~21 GB
segmentation plus a 5 GB language model, admitted concurrently, neither visible
to the other.

**Proposed correction.** `residentSet()` should include plugins with in-flight
one-shot invocations, marked non-evictable for the duration. `PluginRuntime.swift`
is another track's file; reported, not edited.

## Finding 3 — weight download inherits an undeclared transport dependency

Recent `huggingface_hub` defaults to Hugging Face's Xet backend for large
files, which resolves to `cas-server.xethub.hf.co` and `transfer.xethub.hf.co`
— hosts distinct from `huggingface.co`. Where those are unreachable but
`huggingface.co` is not (verified here: 200 vs refused), every download fails
with `CAS Client Error … File reconstruction error`, which names neither the
blocked host nor a remedy. The failed rows are retained in the JSONL as the
evidence.

A hospital network with a domain allowlist is exactly this environment, and the
manifest declares a repo, not the hosts a download will contact. Setting
`HF_HUB_DISABLE_XET=1` routes over the classic CDN and succeeds; the bytes are
identical, so the recorded time is a real download time on a slower transport.
Under a SOCKS proxy the hub additionally needs `httpx[socks]`, absent from every
plugin's `requirements.txt`.

**Proposed correction.** `plugins/_shared/weights.py` should either retry with
Xet disabled after a CAS failure, or surface the blocked hostname in the
`error` envelope so the store can tell the user which domain to allow. Another
track's file; reported, not edited.

## Finding 4 — DICOM SEG export requires an attribute this cohort omits

> **RESOLVED in commit `9a3f8f0`.** The adapter now derives slice spacing from
> the source geometry — slice positions projected onto the slice normal, then
> the median gap — logging non-uniform spacing rather than averaging it away,
> and failing with `bad_input` naming the cause when the geometry needed to
> derive it is also absent. Verified by the owning track at 1.000 mm derived
> from 411 instances on `tcia_1556218467652708`. The projection-onto-normal
> detail matters and is worth keeping in the paper: on this cohort the naive
> z-coordinate difference gives 224 mm, because the files do not sort by
> position. The defect is documented below as found.

Segmentation completed and produced all 117 structures, then
`_export_dicom_seg` raised `AttributeError: 'FileDataset' object has no
attribute 'SliceThickness'`. All seven TCIA series in the cohort omit
`SliceThickness` **and** `SpacingBetweenSlices`; highdicom lists
`SliceThickness` as required for a Pixel Measures Sequence. The attribute is
type 2 in the CT Image module, so an empty or absent value is standard-legal
and a viewer must cope.

Every series carries `ImagePositionPatient`, so spacing is derivable from
consecutive slice positions — which is what the native path would have to do
anyway. **Proposed correction**: derive slice thickness from
`ImagePositionPatient` when the attribute is absent, and fail with
`bad_input` naming the missing attribute rather than an `AttributeError`, if it
cannot be derived. Another track's file; reported, not edited.

## Finding 5 — the shared harness misattributes peak RSS

> **RESOLVED in commit `de234fe`**, along with Findings 1 and 2. This
> experiment keeps using its own `run_subprocess_isolated` so that the
> measurements reported here remain the ones the figures were drawn from,
> rather than being silently re-derived through a changed harness.

`harness.run_subprocess` reads `getrusage(RUSAGE_CHILDREN).ru_maxrss` around
the call and returns `max(after, before)`. That field is a high-water mark over
**every child the process has ever reaped** — it never resets and is not a
per-child figure. In a run that measures several plugins serially, every plugin
after the heaviest inherits that plugin's peak.

Demonstrated directly: a 10 MB child spawned after an 800 MB child is reported
at 850 MB. The first version of this experiment's memory figure consequently
showed SAM 3 and Gemma at exactly SAM 2's 1.43 GB peak, having never loaded a
model. Since declared-versus-measured memory is the substance of this
experiment, `exp3_resources.py` measures peak RSS itself via
`run_subprocess_isolated`, which spawns the target from a forked intermediate
whose children accounting starts empty. `eval/harness.py` is another track's
file; reported, not edited.

## Finding 6 — the corrected declaration makes the plugin inadmissible on the target machine

> **Superseded in part (October 2026)**: the arbiter now gives an oversized
> one-shot 0.75 of physical memory, and a `total_lowmem` task at 24.0 GB fits a
> 32 GB Mac. See "Arbitration re-run after the admission changes" below.

Re-running the arbitration scenarios against the corrected manifest surfaces a
consequence worth stating plainly, because it was not visible while the
declaration was wrong. At an honest `ram_gb: 23.5` against a budget of half
physical memory, the shipped policy decides:

| Machine | Budget | Decision on `total` |
|---|---|---|
| 16 GB | 8 GiB | **refuse** |
| 32 GB | 16 GiB | **refuse** |
| 48 GB | 24 GiB | admit |

TotalSegmentator becomes admissible at roughly **47 GB of physical memory**.
The 16 GB machine the design targets can no longer run it at all, and neither
can a 32 GB one.

This is not an argument for restoring 3.5. The plugin genuinely allocates that
memory; a refusal the user can see is better than an admission that drives the
machine into swap. It does mean the honest declaration converts a silent
failure mode into a visible unavailability, and that the real remedy is a
smaller working set rather than a smaller number — the per-task `ram_gb` the
schema now carries, a `--roi-subset` path, or streaming the volume rather than
holding it whole. Recorded as
`{16gb,32gb}/totalseg-refused-on-corrected-declaration` and
`48gb/totalseg-admitted-on-corrected-declaration`.

A note on the scenario suite itself: four eviction-mechanics scenarios now pin
the pre-correction 3.5 GB figure rather than reading the manifest. They
exercise LRU ordering, multi-eviction, the one-shot sibling rule and the
residency-reporting pair, and with a live 23.5 they would refuse on size
before reaching any of that — still reporting a result while testing nothing.
The scenarios that are *about* the declaration continue to read it live.

Pinning applies to **both sides** of a scenario — the request and any resident
entry for the same plugin. An earlier version pinned only the request, so
`oneshot-not-exempt-from-own-resident-sibling` described a machine on which
one plugin held two different declarations at once (resident at the live
23.5, requesting at 3.5), giving a `residentDemandGB` of 28.5 that
corresponded to no real configuration. It now reports 8.5 = 3.5 + 5.0, which
is the arithmetic the scenario claims to test.

## Arbitration: 20/20 scenarios match the shipped policy

> Historical (August 2026). Re-run in October 2026 at 38/38; see below.

Driven by compiling `ResourceArbiter.swift` and `PluginTypes.swift` into a
JSON-in/JSON-out driver, so the decisions are the shipped type's own rather
than a Python restatement of the policy. Coverage includes LRU eviction order,
multiple eviction, non-evictability of busy and session-holding plugins, the
reentrant self-start case, live-headroom refusal on a large but loaded machine,
the exact-budget boundary, the two pairs above, and the post-correction
admissibility rows of Finding 6. Full table:
`eval/results/exp3_resources_arbitration.csv`. Re-run after commits `de234fe`
and `9a3f8f0` landed: all 20 still match, and the full Swift suite passes
(201 tests, 1 skipped, 0 failures).

Two of my initial expectations were wrong and the arbiter was right; those are
corrected in the scenario comments rather than hidden. One early scenario was
badly constructed — it landed on the budget boundary and would have been
admitted whether or not the resident was evictable — and was rebuilt so that
non-evictability is actually isolated.

## Low-memory settings, and the peak with real worker processes (October 2026)

`eval/exp3_totalseg_lowmem.py`; rows in `exp3_totalseg_lowmem.jsonl`, summary in
`exp3_totalseg_lowmem.csv`. Same machine (M5 Max, 128 GB), TotalSegmentator
2.18.0, nnunetv2 2.8.1, torch 2.13.0, CPU (the adapter's `device='gpu'`
resolves to CUDA and falls back to CPU on a Mac, so this is what the shipped
plugin runs). Master's lock now pins torch 2.14.1; TotalSegmentator and
nnunetv2 are unchanged, and the next re-measurement should use the locked
environment.

**What changed in the method.** This machine permits multiprocessing, so for
the first time nnU-Net ran with its worker processes as it does under the host,
without `exp3_mp_thread_shim.py`. A per-process figure no longer describes that,
so the experiment adds a process-tree sampler: `phys_footprint` summed over the
adapter and every descendant, read via `proc_pid_rusage` every 0.2 s. exp3's
own instrument (the largest single descendant's `ru_maxrss` from a forked
intermediate) is recorded beside it on every row for comparability. Both are
per-process-tree figures, so other work on the machine does not enter them. It
does stretch wall time: 1-minute load at case start ranged 4.2-32.9 (median
9.4), with other sessions' Python jobs of up to 12 GB resident.

**Sanity check against 22.7 GB.** On the bench series the per-process instrument
reads 23.1-23.3 GB, against exp3's 22.70-23.10 GB: the same quantity, reproduced.
The *tree* figure is higher, because nnU-Net spawns its export pool
(`nr_thr_saving`, default 6) before inference, and those workers are alive
through the inference peak.

**Full adapter, as the host spawns it** (segmentation, volumes, DICOM SEG
export), 2 runs per series:

| Series | 3 mm grid (≈, from geometry) | `total` (6 workers) tree peak | wall | `nr_thr_saving=1` tree peak | wall |
|---|---|---|---|---|---|
| `tcia_1556218467652708` | 140×140×137 | 23.46-23.65 GB | 68-72 s | 23.37 GB | 116-118 s |
| `tcia_2121018880599426` | 120×120×205 | **25.40-25.41 GB** | 67-69 s | **23.77-23.78 GB** | 114-118 s |
| `tcia_7962814028413347` | 167×167×214 | 22.54-23.77 GB | 80-88 s | 22.45 GB | 122-130 s |
| `tcia_2083024417478217` | 164×164×202 | 22.68-24.97 GB | 81-101 s | 22.57 GB | 143-147 s |
| `tcia_3381330240602696` | 145×145×245 | 23.15 GB | 58 s | 23.06 GB | 69-84 s |
| **max** | | **25.41 GB** | | **23.78 GB** | |

One run of the new `total_lowmem` task itself, through the manifest with no
override, on the heaviest series: 23.78 GB, 147 s — the same configuration
measured the same way.

**Segmentation stage alone** (`totalsegmentator()` only, 3 runs per series):

| Setting | `tcia_1556…` | `tcia_2121…` | wall (median) |
|---|---|---|---|
| default | 23.46 GB | 25.17-25.18 GB | 47-59 s |
| `force_split=True` | **26.25-26.27 GB** | 25.01-25.46 GB | 61-67 s |
| `nr_thr_resamp=1, nr_thr_saving=1` | 23.18-23.19 GB | 23.54-23.56 GB | 114-118 s |
| both | 25.88 GB | 24.63-24.64 GB | 107-114 s |

What the measurements say:

- **The peak is CPU inference, not the image.** A timestamped trace puts it
  inside nnU-Net's sliding-window prediction: 2.6 GB before it, 23.0 GB during
  it, 11.9 GB after, on a 140×140×137 grid whose 118-class logits are about
  1.3 GB. It does not track the 3 mm grid size (the largest grid,
  `tcia_7962814028413347`, is among the lowest peaks) and does not track the
  torch thread count: clamping torch to 4 or 8 threads gave the same 23.09 GB
  in two exploratory runs (single runs, not in the JSONL).
- **`force_split` makes it worse**, by up to 2.8 GB. It triples the number of
  cases nnU-Net predicts without shrinking what one prediction holds at 3 mm,
  and adds the split and recombination arrays. Not used.
- **`nr_thr_saving=1` is the only lever.** It removes the idle export workers,
  lowering the worst case from 25.41 to 23.78 GB (−1.6 GB), at 1.3-1.7× the
  wall time, since TotalSegmentator's per-structure NIfTI saving becomes serial
  too. `nr_thr_resamp` is already 1 by default.
- **`fast` is not a separate low-memory mode here**: it is already the default
  and the only resolution the manifest ships weights for. `fastest` (6 mm)
  needs Dataset298, which the manifest does not declare, so it was not
  measured.

**Declared RAM, by the project's rule** (highest measured peak rounded up to the
next 0.5 GB — how 23.23 GB became 23.5 in `de234fe`):

| Task | Was | Now | From |
|---|---|---|---|
| `total` (plugin figure too) | 23.5 | **25.5** | 25.41 GB tree peak |
| `total_lowmem` (new) | — | **24.0** | 23.78 GB tree peak |

**Units.** Measured figures in this document are decimal GB (10^9 bytes); the
arbiter reads `ram_gb` as GiB (2^30 bytes, the unit it divides
`physicalMemory` into). The rule above was applied to decimal figures, so the
declarations carry extra margin when read as GiB: 25.41 GB = 23.66 GiB against
25.5 (1.84 GiB spare), 23.78 GB = 22.15 GiB against 24.0 (1.85 GiB spare).
Applied in GiB, the same rule would give 24.0 for `total` and 22.5 for
`total_lowmem`. See PLUGIN_PROTOCOL.md, invariant 4.

`total` was under-declared by about 1.9 GB for the pipeline as the host really
runs it; the 23.5 figure was correct only for the thread-shimmed single
process it was measured on. `total_lowmem` is the same TotalSegmentator task
and weights with one export worker, and its 24.0 fits exactly the one-shot
share of a 32 GB Mac (0.75 × 32 = 24 GiB), which `total` at 25.5 no longer
does. `heartchambers_highres` is licensed and was not measured; it still
inherits the plugin figure.

A first pass of this script measured 35-44 GB and was discarded: its
segmentation driver lacked a `__main__` guard, so every `spawn` worker
re-imported it and started a TotalSegmentator run of its own. The adapter and
exp3's crosscheck driver are not affected (the adapter is guarded; the
crosscheck never spawned under the shim), but exp3's `CROSSCHECK_DRIVER` has
the same latent defect and would hit it if run without `--totalseg-threads`.

## Arbitration re-run after the admission changes (October 2026)

Three changes landed after the 20-scenario run: one-shot admission excludes the
requester from its own resident set (it used to be charged twice — 47 GB for a
23.5 GB job), a one-shot too large for half the machine is re-decided against
0.75 of it, and a refusal caused only by the live reading is now
`refuseLiveHeadroom`, which the user may override with "Start Anyway". The
driver could not report any of this: commit `2ce3a9b` had merged two `case`
labels onto one line of the generated Swift, so the phase no longer compiled,
and it mapped the new refusal to plain `refuse`. `PluginTypes.swift` also now
needs SwiftPM's `Bundle.module`, which a standalone build lacks. All three are
fixed in `exp3_resources.py`; the driver reports `overridable` and what an
override would do.

**38/38 scenarios match** (was 20/20), all decided by the compiled
`ResourceArbiter.swift`. Decisions that changed for the same scenario:

| Scenario | Old | New | Why |
|---|---|---|---|
| `32gb/totalseg-…-on-corrected-declaration` (23.5) | refuse | **admit** (renamed `…-admitted-…`) | 0.75 one-shot share: 24 GiB |
| `64gb-but-loaded/live-headroom-refuses` | refuse | **refuseLiveHeadroom**, overridable | refusal type split |
| `16gb/totalseg-refused-on-{corrected-declaration,its-measurement}` | refuse, 8 GiB available | refuse, **12 GiB** available | 0.75 share reported |

`16gb/busy-resident-is-not-evictable` now pins the request at 3.5 GB: read live
it was refused on size before reaching the busy resident it exists to test.
Rows about the 23.5 correction, the oversized share, requester exclusion and
Start Anyway pin 23.5; rows that track today's declarations read the manifest:

| Machine | `total` at 25.5 | `total_lowmem` at 24.0 |
|---|---|---|
| 16 GB (12 GiB one-shot share) | refuse | refuse |
| 24 GB (18 GiB) | refuse | refuse |
| 32 GB idle (24 GiB) | refuse | **admit** |
| 32 GB in use (20 GB available) | refuse, final | **Start Anyway offered** |
| 48 GB (36 GiB) | admit | admit |

New scenarios cover the oversized share evicting a resident Gemma, a resident
server of the same size getting no such share, the double-charge the requester
exclusion removed, a second run of the same plugin genuinely in flight (still
refused), and Start Anyway applying only the evictions the budget needs.

Finding 6's "admissible at roughly 47 GB" is superseded: with the 0.75 share,
`total` needs 34 GiB of physical memory (in practice a 36 GB Mac) and
`total_lowmem` 32 GiB.

## What could not be measured here, and what it would need

| Not measured | Why | To measure it |
|---|---|---|
| Gemma 4 E4B load, inference, peak | MLX requires a Metal device; the sandbox exposes none and MLX has no CPU fallback. Reported by the adapter as `not_ready`, which is correct behaviour. | Run outside the sandbox on a machine with GPU access. |
| SAM 3 anything | Weights are behind Meta's licence gate; the adapter correctly refuses to auto-download and returns `license_required`. | Accept the terms, place the checkpoint, rerun. |
| Any GPU timing | No accelerator visible. | Same run on the desktop. |
| ~~TotalSegmentator with process pools~~ | Measured October 2026, see "Low-memory settings" above: the tree peak is up to 2 GB above the single-process figure. | — |
| TotalSegmentator full resolution, `fastest`, `heartchambers_highres` | Weights not declared in the manifest (`fastest`), or behind the academic licence (`heartchambers_highres`); full resolution runs five models. | Licence key or manifest weights, then the same script. |
| Concurrent-plugin contention | Sequential measurement only, so as not to contaminate timings. | Deliberate concurrency experiment with per-process sampling. |
