<!--
Supplementary material for docs/paper/manuscript.md. Text here was moved verbatim from the
main manuscript when the body was cut to the journal's length (2026-10-28); numbers keep
their "src:" pointers. Bracketed numbers cite the main reference list. Section numbers
such as §3.3 refer to the main manuscript.
-->

# Supplementary Material

**Hosting heterogeneous on-device AI models in an open-source DICOM viewer: one plugin
contract and the case for auditing declared resources**

Daeseong Kim

# S1. Extended methods

## S1.1 Plugin contract details

TotalSegmentator ships a third task, `heartchambers_highres`, which declares no per-task
figure and inherits the plugin-level 25.5; its peak was not measured. <!-- src:
Sources/OpenDicomViewer/Resources/plugins.json -->

**Routing and transport.** Each task declares what it consumes and produces from a closed vocabulary.
Inputs are `slice2d`, `series3d`, `roi`, `points`, `box` and `text`; outputs are `text`,
`bbox`, `mask2d`, `seg3d` and `metrics`. The host assembles inputs from the viewer state
and dispatches results on the declared output kind alone, never on plugin identity. Text
goes to the AI inspector; boxes and masks become annotations; `seg3d` results are read
by the same DICOM SEG reader the viewer uses for segmentation files on disk; metrics go
to the results panel. A new plugin that emits an existing output kind therefore needs no
host change. <!-- src: PLUGIN_ARCHITECTURE.md §4 -->

Transport follows payload size. A rendered slice travels as a base64-encoded PNG, but a
volume travels as a filesystem path, so a segmentation model reads the original geometry
and Hounsfield units rather than a windowed rendering. Two-dimensional masks use
row-major run-length encoding that begins with a background run. Because a disagreement
between the Python encoder and the Swift decoder would render an inverted mask rather
than raise an error, both sides are tested against the same fixtures.

**Licence gates.** Licence terms and intended use travel with model weights rather than
with code, and are documented per model rather than per repository [29]. Weight
availability is modelled as one of three states: `open` (downloadable unconditionally),
`licence-key` (the user registers a key locally, which the host passes to the adapter
through the environment rather than the command line, because process arguments are
visible to other processes), and `gated-download` (the user accepts terms with the
vendor and places the checkpoint at a path the host names exactly). The host never
acquires gated weights on the user's behalf. A missing licence is a distinct install
state from missing weights, so the user is routed to the right remedy. <!-- src:
PLUGIN_ARCHITECTURE.md §5 -->

**Isolation.** Each plugin runs in its own process and virtual environment. This is
forced by the dependency stacks, since MLX and PyTorch are not co-installable in
practice, and it confines a failed install to one plugin. Containers give stronger
isolation and are the usual answer on a server [30], but a per-plugin container runtime
is a heavy dependency to impose on a laptop user. It is not a security sandbox: a plugin
runs with the user's privileges, and the invariants are enforced by review of in-tree
adapter code (§4.4). <!-- src: PLUGIN_ARCHITECTURE.md §7 -->

## S1.2 Memory arbitration

The arbiter admits a plugin only if two conditions hold after any evictions <!-- src:
PLUGIN_ARCHITECTURE.md §6 -->. First, the sum of declared `ram_gb` across resident
plugins must fit within 50% of physical memory; this condition is deterministic, so the
policy is reproducible and testable. Second, the incoming plugin's declared memory must
fit within the memory the machine can supply at that moment, less a safety margin.
Neither condition suffices alone: the first ignores other work on the machine, and the
second would let two models that each fit leave nothing for the viewer.

When admission fails, the arbiter returns an eviction plan, least recently used first
with deterministic tie-breaking, rather than a bare refusal. A plugin that is serving a
request or holding open sessions is never evicted; it blocks admission instead. A
one-shot task too large for half of physical memory is budgeted against 75% of it, with
every evictable plugin stopped. If live headroom is insufficient, the user may override
the refusal with "Start Anyway". <!-- src: EVALUATION.md §4; PLUGIN_ARCHITECTURE.md §6
-->

## S1.3 Experiment protocols

E1 tested conformance of the DICOM Segmentation objects [35,36] written by the
TotalSegmentator adapter's shipped encoder, which uses highdicom [37]. Encoding derived
results as standard objects rather than as a private format is what lets an independent
tool read them at all [38]. Six fixtures were encoded on the grids of six unmodified
TCIA series. The masks were synthetic by design: conformance is a property of the
encoder, and constructed masks could attack it with cases that real model output rarely
produces (a one-voxel shell, a single-slice structure, overlapping structures, a
structure touching the volume boundary, an empty structure). Each SEG was decoded by
dcmqi [39], an independent implementation in a different language, and compared
voxelwise with the source mask in physical space. Each file was also audited against
Segmentation IOD requirements. <!-- src: exp1_findings.md §1–2 -->

E2 compared TotalSegmentator output obtained through the plugin layer (adapter, DICOM
SEG export, host reader) with output from a direct call of the model on the same series,
per structure, on 7 TCIA series. Because a result of exactly 1.0 everywhere could mean
the comparison is blind, we first built perturbation probes and confirmed that the
comparison detects them. <!-- src: EVALUATION.md §3 -->

E3 measured peak memory and tested the arbiter. Peak memory was first measured per
process; it was then re-measured natively over the whole process tree, as the
`phys_footprint` of the adapter and all descendants summed and sampled every 0.2 s,
because nnU-Net starts worker processes. The arbiter was tested in scenarios executed
against the shipped Swift type rather than a re-implementation of its policy. <!-- src:
EVALUATION.md §1, §4 -->

E4 measured SAM 2 encode and decode times and the per-prompt overhead of an alternative
design: an implicit content-addressed embedding cache inside an ordinary resident
server. It also checked protocol round trips with real weights, decoding each returned
mask with the host's compiled Swift decoder. <!-- src: EVALUATION.md §5 -->

E5 ran nine checks on the packaged, signed application: adapters and manifest present,
no machine-specific paths, a virtual environment with pip created by the bundled
interpreter, every adapter parsing its command line under that interpreter before its
dependencies are installed, and a valid code signature. <!-- src: EVALUATION.md §6 -->

E6 measured end-to-end latency through the host's own contract: loopback HTTP for the
resident and session engines, and the command line for the one-shot engine, timed from
outside each process so that interpreter start-up, imports, model loading and
serialisation are all included. Four engines were measured: the Gemma 4 E4B plugin; the
viewer's earlier built-in Gemma server, which serves the same weights and is included as
the pre-plugin baseline; SAM 2; and TotalSegmentator's `total` and `total_lowmem` tasks.
Each resident or session engine was cold-started 10 times; each start was followed by
requests on 9 slices (3 positions in each of 3 pinned TCIA series), all three Gemma
tasks, or for SAM a session opened on each slice and 5 clicks per session.
TotalSegmentator ran 5 times per task on each of the 3 series. "Cold" here means a new
process; the operating system's file cache was not flushed, so weights may have been
read from memory. Before each case the harness waited (up to 10 or 30 min) for the 1-minute
load average to fall to 2.0 or below, and recorded whether it did; only cases that met
this idle gate are summarised. Every engine's environment was checked against its
dependency lock before it ran, and engines that differed would have been skipped. E6 ran
natively on one machine, an Apple M5 Max MacBook Pro with 128 GB of memory. <!-- src:
eval/README.md "Experiment 6"; eval/exp6_latency.py; .eval/exp6_run.log invocation -->

E7 checked that prompts and results keep their geometry through the protocol. For SAM 2,
each reference structure in the TotalSegmentator cases was located on its central axial
slice (weighted by voxel count), the slice was rendered in a soft-tissue window and sent
to open a session, and one foreground click was sent at the interior pixel farthest from
the structure's boundary. We did not click at the centroid, as first planned, because the
centroid of a non-convex structure such as the colon can lie outside it, which would test
click placement rather than mapping. Structures smaller than 100 pixels on their slice
were skipped. The returned run-length mask was decoded and compared with the reference
by Dice. A transposed click, with x and y exchanged as a transposed mapping would send
it, served as a negative control for every structure: the check is meaningful only if
the control scores clearly lower. For Gemma 4 E4B, the detection and analysis tasks were
sent on 3 slices of each case, and we recorded whether each request completed, whether
each returned box lay inside the image, and whether its centre lay on the body rather
than on air (body: the largest connected region above −500 HU, holes filled). Every
server in E7 ran under the same process-tree memory sampler as E3, which gives a measured
peak for the two plugins whose declarations E3 could not audit. E7 did not run at the
same time as E6. Neither part of E7 measures accuracy. <!-- src: eval/exp7_prompt_vlm.py
-->

## S1.4 Environment and reporting

**Environment and reporting.** Each case produces one JSON record. Failures are recorded
rather than dropped. Each result file carries the machine profile, accelerator
visibility and package versions. <!-- src: eval/README.md --> Experiments E1–E5 ran in
August 2026 inside an evaluation sandbox on an Apple M5 Max with 128 GB of memory. The
sandbox exposed no GPU to PyTorch and refused socket binds, so nnU-Net's process pools
were replaced by threads; this preserves correctness but not performance. Sandbox
timings are therefore CPU-only figures and are not presented as laptop performance.
TotalSegmentator memory and the arbitration scenarios were re-run natively in October
2026. <!-- src: EVALUATION.md §1
--> Plugin environments for E6 are built with the bundled interpreter and checked against
the dependency locks before each run. This check was added after we found that earlier
evaluation environments had been built with a different interpreter and had drifted
30–52 packages from the locks. <!-- src: PLAN.md E6 notes --> Memory is reported in GB
(10^9 bytes); wherever it is compared with a declaration, it is also given in GiB (2^30
bytes), the unit the arbiter uses. Every declared-versus-measured ratio in this paper is
computed in GiB, so dividing the GB figures by a declaration will not reproduce it.

# S2. Extended results

## S2.1 DICOM SEG conformance (E1)

Two warnings remain and constitute an interoperability defect. Every segment carries the
generic code "anatomical structure" as its SegmentedPropertyType, so a receiving system
cannot identify the structures by code; the specific anatomy survives only in the
free-text SegmentLabel. Descriptive fields (ContentDescription, ContentCreatorName,
SeriesDescription) are also absent. The fix is to map the model's label names to SNOMED
CT codes; this has not yet been done. <!-- src: EVALUATION.md §2; exp1_findings.md -->
Rendering in third-party viewers was not evaluated.

## S2.2 Pipeline fidelity (E2)

--> The comparison is sensitive: it resolved a single altered voxel in a 432-voxel
structure (Dice 0.9988), a one-slice shift (0.667) and a dropped structure (0.0) (Fig.
S1). <!-- src: EVALUATION.md §3; exp2_probes.json -->

Before these results were obtained, the SEG export failed on every series in the
collection. The encoding library read the slice-thickness attribute (0018,0050)
unconditionally, but that attribute is Type 2 in the standard and all 411 instances of
the first series omitted it, so the adapter produced no SEG at all. The adapter now
handles a missing slice thickness. <!-- src: exp2_REPORT.md "Mechanism" -->

As a hygiene check, not an accuracy result, both paths were compared with expert
reference masks from the TotalSegmentator dataset. On the 4 of 6 cases that could be
read (two were rejected by ITK because of non-orthonormal direction cosines, and are
recorded as failures), across 327 per-structure comparisons, mean Dice was 0.80–0.85
overall and 0.86–0.95 on large structures, identical on both paths to six decimal
places. <!-- src: EVALUATION.md §8; exp2_tables.md Table 2; exp2_REPORT.md
reference-mask table --> This shows only that neither path silently broke the model.

E2 also exposed a limitation of the `seg3d` output kind. It encodes segments into a
single labelmap, which clips overlapping structures; in a constructed case the liver
lost 74,987 voxels to the stomach. No shipped adapter reaches this case, because
TotalSegmentator derives each structure from one integer labelmap and its structures are
disjoint by construction. <!-- src: EVALUATION.md §3 -->

## S2.3 Resources (E3)

The corrected figure was itself low. Measured natively over the whole process tree, with
nnU-Net's worker processes alive through the inference peak, the peak over 10 runs on
five series reached 25.41 GB (23.66 GiB); the per-process figure reproduced at 22.4–23.7
GB on the same runs. The `total` declaration was raised to 25.5. Of TotalSegmentator's
low-memory settings, only a single export worker lowered the peak, to 23.78 GB (22.15
GiB); this is shipped as a `total_lowmem` task declared at 24.0, which the 75% share
admits on a 32 GB Mac where `total` needs 34 GiB. The saving costs wall time: over 10
runs with the worker count overridden on `total`, the single-worker configuration took
1.3–1.7× the baseline. The shipped `total_lowmem` task itself was run once, at 2.2× the
`total` median on that series, so which multiplier is typical is not established. No
TotalSegmentator task fits a 16 GB Mac; the peak comes from CPU inference and did not
change with thread count or grid size. <!-- src: EVALUATION.md §4; exp3_FINDINGS.md
"Low-memory settings" --> <!-- Memory runs used torch 2.13.0; E6 latency used the current lock, 2.14.1. Memory was not
re-measured under 2.14.1; stated in §4.4. -->

One cost was invisible to the adapter's own reporting. A TotalSegmentator invocation
took 76.4 s as a subprocess but 71.2 s as the sum of the adapter's stages; the 5.2 s
difference is interpreter startup and the PyTorch/nnU-Net import chain, paid on every
one-shot invocation. <!-- src: exp3_FINDINGS.md "The corrected declaration, validated
end to end"; CPU-only sandbox figure -->

## S2.4 Session model (E4)

Encoding a slice with SAM 2 cost 17.1× a decode (median over 30 encodes and 216 decodes;
per-slice range 13.7–20.8×). <!-- src: EVALUATION.md §5; exp4_session.csv --> The ratio
is large, but the alternative was cheap: an implicit content-addressed cache in an
ordinary resident server cost 1.8–4.7 ms per prompt, 2–5% of a decode (Fig. S2). <!--
src: EVALUATION.md §5 --> The ratio therefore rules out not caching, but it does not
select the session lifecycle over a resident server that caches implicitly. What the
session model does provide is lifecycle control and an enforceable memory bound: a
declared `max_sessions` the host can hold the adapter to, and explicit release when the
user changes series. We report the original performance justification as not supported.

With real weights, SAM 2 completed 12 of 12 protocol round trips. Each returned mask was
decoded by the host's compiled Swift decoder and agreed with the adapter on foreground
count and first foreground index, which distinguishes a correct mask from its
complement. <!-- src: EVALUATION.md §5 -->

## S2.5 Deployability (E5)

The packaged application initially failed in three ways. The packaging script bundled
only the earlier single-engine server, so a packaged build found no adapters; this was
hidden during development because the environment locator falls back to the source tree.
Adapters run from inside the signed bundle wrote bytecode next to their sources, which
invalidated the code signature. The bundled interpreter did the same for its own
standard library on first import, a defect that predates the plugin layer. After all
three were fixed, the packaged application passed 9/9 checks. <!-- src: EVALUATION.md §6
-->

App Sandbox is disabled by design. An application that installs and runs plugins at
runtime cannot be sandboxed as the Mac App Store requires, so this architecture and that
distribution channel are mutually exclusive. <!-- src: EVALUATION.md §6 -->

A conformance kit for third-party adapters probes an adapter by running it rather than
reading its source. Each of its checks is paired with a deliberately broken fixture (24
in total) that it must reject. All 54 checks passed on a platform permitting loopback
binds. <!-- src: EVALUATION.md §7 -->

## S2.6 End-to-end latency (E6)

Of the cases run, those that met the idle gate were 8 of 10 cold starts for the built-in
Gemma server, 5 of 10 for the Gemma plugin, 10 of 10 for SAM 2, and 11 of 15 and 15 of 15
TotalSegmentator runs for `total` and `total_lowmem`; only these are reported (Fig. 3). All
requests in them succeeded. <!-- src: eval/results/exp6_latency_apple-m5-max-128-gb_paper.json (idle-gated) -->

**Cold start.** From a new process to the first result took a median of 1.94 s (IQR
1.90–1.96) for SAM 2, 3.51 s (3.48–3.56) for the Gemma plugin and 3.52 s (3.49–3.54) for
the built-in Gemma server. For SAM 2 most of this is the first session open, 1.25 s,
because the adapter reports ready (0.61 s after spawn) before it loads the model; a
client that treats "ready" as "loaded" would under-report its cold start by about two
thirds. Both Gemma servers reported ready after 2.13–2.14 s.

**Warm requests.** Gemma requests took about a second: 973 ms (IQR 961–976) for
detection, 876 ms (771–937) for a region description and 1,270 ms (1,251–1,287) for a
full analysis through the plugin, against 986, 815 and 1,289 ms through the built-in
server. Routing the same model through the plugin layer therefore cost nothing that this
measurement resolves. For SAM 2, a click on an open session took 11.1 ms (10.7–11.4,
n=240). Encoding a new slice took 63.2 ms (62.8–63.6), measured as session open plus
the first click: on the GPU the adapter's encode returns once the work is queued, and
the work completes inside the first click (51.1 ms, against 11.1 ms for later clicks),
so the adapter's self-reported encode time of about 10 ms is not what the user waits
for. On the GPU encoding cost 5.7 times a decode, against 17.1 times on the CPU (§3.4).

**One-shot segmentation.** TotalSegmentator's `total` task took a median of 57.5 s per
run (IQR 55.6–64.8; 411–493-slice series), of which 42.2 s was segmentation and 10.1 s
DICOM SEG export. The `total_lowmem` task took 90.6 s (83.5–97.9), 1.47–1.61 times
`total` on the same series, almost all of it in segmentation; this settles the multiplier left
open in §3.3. Outside the adapter's own stages each invocation spent 2.5 s (2.52–2.55),
the native counterpart of the 5.2 s interpreter and import cost measured in the sandbox.
Cold starts here are of new processes with the file cache warm; a first run after
reboot would read weights from disk.

## S2.7 Prompt-driven and VLM plugins (E7)

Four of the six TotalSegmentator reference cases could be read; the other two are the
cases ITK rejected in §3.2, and are recorded as failures. <!-- src: eval/results/exp7_prompt_vlm_apple-m5-max-128-gb_summary.json -->

**SAM 2.** All 214 structures large enough to click returned a mask on the slice's own
grid (0 grid mismatches). The median Dice against the reference was 0.79 (IQR 0.55–0.90),
170 of 214 masks reached 0.5, and for structures of at least 1,000 pixels the median
was 0.84. The transposed control separated cleanly: of the 191 structures for which the
transposed click fell outside the structure, the median control Dice was 0.00 (IQR
0.00–0.01). The remaining 23 transposed clicks still landed inside their structure,
mostly midline or large structures (vertebrae, liver, lungs, bladder), and are not
informative as controls. A transposed axis, a scale error or an inverted run-length phase would each
have pushed the clicked masks toward the control's distribution; none did. Of the 27 masks below Dice 0.3, 25 were larger than their structure, 22 of them for structures under 1,000 pixels, where a single click returned a surrounding region many times the structure's size; the other 2 were smaller than it. That is what one unrefined click produces from a general-purpose model on small anatomy, not a mapping error, and it is not evaluated further. <!-- src: exp7 jsonl, structures with dice < 0.3 --> The structure centroid fell outside the structure for 58
of 214 structures, which is why clicks were placed at the most interior pixel instead.
<!-- src: exp7 summary "control_click_inside_structure",
"control_transposed_dice_click_outside", "centroid_outside_structure" -->

**Gemma 4 E4B.** All 24 requests (detection and analysis, 3 slices in each of 4 cases)
completed. They returned 46 boxes; all 46 lay inside the image and all 46 centres lay on
the body rather than on air. These counts show that boxes come back in the image's
frame. They say nothing about whether a box marks a real finding.

# Supplementary figures

![](eval/figures/exp2_fidelity.png)

**Figure S1.** Pipeline fidelity. Per-structure Dice between plugin-layer and direct model
output on 7 TCIA series, with perturbation probes (single voxel, one-slice shift,
dropped structure) showing the comparison's sensitivity.

![](eval/figures/exp4_encode_decode.png)

**Figure S2.** Session model. SAM 2 encode and decode cost, and per-prompt overhead of an
implicit embedding cache in a resident server. CPU-only sandbox figures.
