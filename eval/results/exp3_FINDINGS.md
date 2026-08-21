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
| TotalSegmentator | one-shot | 3.5 GB | **20.85 GB** | **5.96×** | 176 s | 166 MB in 52 s |

Stage detail for the two plugins whose models ran:

- **SAM 2**: model load 11.3 s, encode 1701 ms/slice, decode 200 ms/prompt,
  RLE 13 ms. **Encode is 8.5× decode.**
- **TotalSegmentator**: environment check ~0 s, segmentation 149.2 s,
  volume measurement 14.4 s, DICOM SEG export failed (below).

Restart cost, measured by stopping a resident SAM 2 and re-serving the same
prompt: **12.0 s cold, 8.8 s warm**. That is what an eviction costs the user.

## Finding 1 — TotalSegmentator's declared memory is wrong by ~6×

`ram_gb: 3.5` against a measured peak of **20.85 GB** on a 411-slice abdominal
CT (`bench/totalsegmentator`, `input_series=tcia_1556218467652708`).

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
overrun reproducing on both, is the evidence for this finding. The bench figure
of 20.85 GB and the cross-check figure of 23.10 GB are the same pipeline on the
same series, measured with and without the adapter's DICOM SEG export stage
attached. Across the three independent pipeline runs recorded — one bench and
two cross-checks — the peak spans **20.9–23.1 GB, i.e. 5.96× to 6.60× the
declaration whichever run you take**.

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

Full resolution could not be measured here. It requires five further weight
datasets (`Dataset291`–`Dataset295`) fetched from a GitHub releases URL that
this network refuses; recorded as
`crosscheck/totalsegmentator/fullres/tcia_1556218467652708` with the
`ProxyError`, not silently omitted. Full resolution processes the same volume
at roughly 3.4× the voxel count of the 3 mm variant along the through-plane
axis, so its peak should be expected to exceed 23 GB rather than fall below it,
but that is an inference and not a measurement, and it should be measured
before it is quoted.

**Proposed correction.** Declare `ram_gb` per task and per option combination
rather than once per plugin. The measured `fast` figure alone justifies at
least `24.0` for `total`; the full-resolution figure is likely higher and
should be measured on a machine that can reach the weight host before a number
is chosen. A single scalar `ram_gb` cannot describe a plugin whose footprint
depends on options the caller selects, which is the structural version of this
finding: the protocol gives a plugin one number to describe every
configuration it can be invoked in. I did not edit the manifest or the
protocol: both are other tracks' files.

## Finding 2 — a running one-shot is invisible to the arbiter

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

## Arbitration: 17/17 scenarios match the shipped policy

Driven by compiling `ResourceArbiter.swift` and `PluginTypes.swift` into a
JSON-in/JSON-out driver, so the decisions are the shipped type's own rather
than a Python restatement of the policy. Coverage includes LRU eviction order,
multiple eviction, non-evictability of busy and session-holding plugins, the
reentrant self-start case, live-headroom refusal on a large but loaded machine,
the exact-budget boundary, and the two pairs above. Full table:
`eval/results/exp3_resources_arbitration.csv`. The existing Swift suite also
passes unchanged (60 tests, 0 failures).

Two of my initial expectations were wrong and the arbiter was right; those are
corrected in the scenario comments rather than hidden. One early scenario was
badly constructed — it landed on the budget boundary and would have been
admitted whether or not the resident was evictable — and was rebuilt so that
non-evictability is actually isolated.

## What could not be measured here, and what it would need

| Not measured | Why | To measure it |
|---|---|---|
| Gemma 4 E4B load, inference, peak | MLX requires a Metal device; the sandbox exposes none and MLX has no CPU fallback. Reported by the adapter as `not_ready`, which is correct behaviour. | Run outside the sandbox on a machine with GPU access. |
| SAM 3 anything | Weights are behind Meta's licence gate; the adapter correctly refuses to auto-download and returns `license_required`. | Accept the terms, place the checkpoint, rerun. |
| Any GPU timing | No accelerator visible. | Same run on the desktop. |
| TotalSegmentator with process pools | Sandbox denies `bind(2)`. | Same run outside the sandbox; expect the wall time to fall. |
| Concurrent-plugin contention | Sequential measurement only, so as not to contaminate timings. | Deliberate concurrency experiment with per-process sampling. |
