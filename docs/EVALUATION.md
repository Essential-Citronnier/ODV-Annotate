# Evaluating the plugin layer

What was measured, on what data, with what result — and what could not be
measured here and why.

All data is public and requires no ethics approval or data use agreement:
de-identified CT series from The Cancer Imaging Archive, and the
TotalSegmentator reference dataset (CC BY 4.0). `eval/fetch_data.py` acquires
both and writes a data card recording provenance and licensing.
Series identifiers are pinned in that script rather than discovered at run
time, because archive query results are not stable across API revisions and a
cohort that silently changes is not reproducible.

---

## 1. What the numbers mean, and what they do not

The measuring environment reports **no GPU** to the tensor library on a machine
that has one, and **denies `bind(2)`** for both AF_UNIX and loopback TCP. Every
experiment records the machine profile and accelerator visibility with each run,
so no figure can be read without its conditions. This splits the results in two:

| Class | Status |
|---|---|
| Install time, download bytes, disk footprint, peak memory | **Substitution-free.** Network, disk and allocation all work normally. |
| Model load, inference, encode/decode latency | **CPU-only figures.** Not laptop performance and not presented as such. |
| End-to-end segmentation wall time | **Upper bound only**, and reported as one. The segmentation framework's multiprocessing needs a socket the sandbox refuses, so it ran with a serial substitution that preserves correctness but not performance. |

An earlier attempt at this table produced a segmentation time that looked
excellent and could not be defended. Recording accelerator visibility per run is
the mechanism that prevents a repeat.

## 2. Standard conformance

**Claim:** the DICOM SEG this layer writes is read correctly by an implementation
that is not ours.

dcmqi — QIICR's reference tool — decodes every segment losslessly, with
direction, spacing and origin preserved: **30/30 structures at Dice 1.000000**
across 6 cases. A field audit of 15 Segmentation IOD requirements per file passes
on every case. Our own decoder agreeing with our own encoder would prove much
less, which is why the third-party round trip is the load-bearing check.

**Two warnings stand as a reportable interoperability defect.** Every segment
carries a generic `anatomical structure` SegmentedPropertyType, so a receiving
system cannot identify our structures by code and the specific anatomy survives
only in the free-text SegmentLabel — which defeats the purpose of coded anatomy.
Descriptive fields (ContentDescription, ContentCreatorName, SeriesDescription)
are absent. Mapping the segmentation model's label names to proper SNOMED/FMA
codes is the fix, and is not yet done.

Provenance is labelled `shipped-adapter-encoder/synthetic-masks`: the encoder is
the one that ships, but the segmentation stage cannot run in this environment, so
the masks are constructed. That distinction is the difference between a claim
about the adapter and a claim about a fixture.

## 3. Pipeline fidelity

**Claim:** routing a model through the plugin abstraction is lossless.

Across 7 TCIA series and **689 per-structure comparisons, the lowest Dice
anywhere is 1.000000**, with zero voxel difference and zero unplaced frames.

A result of exactly 1.0 everywhere invites the question of whether the comparison
measures anything at all, so perturbation probes were built first: the comparison
resolves a **single voxel** out of 432 (0.9988), a one-slice shift (0.667), and a
dropped structure (0.0). The 1.0 is a measurement, not a blind spot.

**Limitation found.** The `seg3d` output kind encodes segments into a single
labelmap, which clips overlapping structures — in a constructed case the liver
lost 74,987 voxels to the stomach, a figure the conformance track reached
independently by a different route. It is **not reachable through the adapters
that ship today**: the segmentation model derives each mask from one integer
labelmap by equality test, so its structures are disjoint by construction and
remain so after resampling. This belongs in the paper as a limitation of the
output kind for future overlapping-structure adapters, not as an active bug.

## 4. Resources and arbitration

**Claim:** the memory arbiter behaves as designed. **Result:** it does — 20
scenarios, 0 mismatches, audited against the shipped Swift type rather than a
restatement of it, covering eviction order, non-evictability of busy and
session-holding plugins, the exact-budget boundary, and live-headroom refusal.

**And that is the problem.** The policy answers correctly the question it is
asked, and the question is a manifest declaration. TotalSegmentator declared
3.5 GB; measured peak was **20.9–23.1 GB** over four recorded runs (20.85,
21.40, 22.70, 23.10 GB), cross-checked three ways and reproduced on a second
series. On the 16 GB machine this policy targets, that
declaration admits a job needing more than the whole machine. A second defect
compounded it: a running one-shot never entered the runtime-state table, so the
heaviest process on the machine was invisible to admission and a resident engine
could start alongside a segmentation run.

Both are fixed. The manifest carries measured figures, `PluginTask` gained an
optional per-task declaration because task footprints within one plugin differ
materially, and in-flight one-shots are counted and never evictable. The
scenarios that were admitted before and refused now are the paper's argument for
**auditing declared resources rather than trusting them** — invariant 4 of the
protocol says a plugin that under-declares is starved rather than allowed to
thrash, and this is what enforcing it actually requires.

One figure is worth stating separately: 71.2 s is the sum of the adapter's own
stages and 76.4 s the whole subprocess. The 5.2 s gap is interpreter startup plus
the import chain — a cost invisible to every figure the adapter reports about
itself, paid on **every** one-shot invocation where a resident server amortises
it once.

## 5. The session execution model

**Claim, as originally written:** encoding a slice costs so much more than
decoding a prompt that caching the embedding justifies a distinct execution
model. **Measured:** encode costs **17.1×** a decode (median over 30 encodes and
216 decodes; per-slice range 13.7–20.8×). The ratio is real and large.

**But the experiment measured the alternative too, and the claim does not
survive.** An implicit content-addressed cache inside an ordinary resident server
costs 1.8–4.7 ms per prompt — 2–5% of a decode. So the ratio rules out *no
caching*; it does not select the session lifecycle over a resident server that
caches implicitly. The defensible justification is **lifecycle control and
enforceable memory bounds**: a declared `max_sessions` the host can hold the
adapter to, and explicit release when the user changes series. That is both more
honest and more interesting than the performance framing.

SAM 2 inference is verified against real weights: 12 of 12 protocol round trips,
with the returned run-length mask decoded by the host's own compiled Swift
decoder and agreeing on foreground count and first foreground index — the check
that distinguishes a correct mask from its complement, which no runtime signal
would catch. This closes the project's largest verification gap.

## 6. Deployability

**Claim:** the architecture works in a shipped application, not only in a
developer's source tree. It did not, and three defects had to be fixed first.

The packaging script bundled only the older single-engine server, so a packaged
build found no adapters and the store would have listed nothing installable —
hidden because the environment locator falls back to the source tree during
development. Adapters run from inside the signed bundle, so the bytecode they
wrote next to their own sources invalidated the code signature, which is a
Gatekeeper rejection on a user's machine. The same defect existed one level
deeper and predates the plugin layer: the bundled interpreter writes bytecode for
its own standard library on first import, breaking the signature on first launch.

After fixing all three, `eval/exp5_deployability.py` passes **9/9**: adapters and
manifest present, no machine-specific leakage, the bundled interpreter creates a
virtualenv with pip, every adapter parses its command line under that interpreter
without its dependencies installed, and the signature verifies.

The script also records that App Sandbox is deliberately **off**. That is an
architectural consequence worth stating: an application that installs and
executes plugins at runtime cannot be sandboxed in the way the Mac App Store
requires, so this design and that distribution channel are mutually exclusive.

## 7. Conformance for third-party adapters

`plugins/conformance/` turns "we defined a protocol" into "a third party can
check whether they implemented it". The kit probes an adapter by **running** it
rather than reading it — grepping source would pass adapters whose flags are
handled by a shared launcher, and fail ones whose weight-hook flags never appear
in `--help` because that mode is dispatched to a separate parser. 24 deliberately
broken fixtures, one per violation class, prove each check can actually fail; a
check that cannot fail is not a check.

On this machine the kit reports 45 passed and 9 skipped, the skips being the
socket-dependent cases. Those 9 were executed on a platform that permits loopback
binds, where all 54 pass. The distinction is recorded rather than elided.

## 8. What the evaluation did not establish

- **No accuracy claim.** The models are used unmodified and their accuracy is
  published elsewhere. The hygiene check against reference masks (mean Dice
  0.80–0.85, 0.86–0.95 on large structures) exists only to show neither path
  silently broke the model, and is not an accuracy result.
- **No end-to-end timing on real hardware.** One run on an unrestricted machine
  would close this, and it is the largest remaining gap.
- **Gemma inference not run.** No MLX runtime was available here; the adapter's
  protocol conformance is verified, its inference is not.
- **No clinical validation of any output**, and none is claimed. Every result
  surface carries a research-use disclaimer.
- **No UI-driven verification.** The store's install flow — virtualenv creation,
  weight download, progress reporting — has never been exercised through the
  interface, only through the runtime beneath it.
