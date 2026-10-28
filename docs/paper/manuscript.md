<!--
Manuscript for Computer Methods and Programs in Biomedicine (CMPB, Elsevier).
Status: submission version, body cut to CMPB length 2026-10-28; detail moved verbatim to supplementary.md.

Rules for this file:
- Every number is copied from a results file and carries an HTML-comment "src:" pointer.
  Never restate a number from memory; if a source changes, re-copy it.
- Citations are keyed to docs/paper/references.md and numbered by first appearance.
  Every entry is resolved from fetched metadata; never fill bibliographic fields by hand.
  After inserting or removing a citation, renumber the whole list rather than patching it.
- CONFIRM marks something only the authors or the journal's guide can settle.
- TODO(...) marks a result still to be filled; none should remain at submission.
-->

# Title page

**Title:** Hosting heterogeneous on-device AI models in an open-source DICOM viewer:
one plugin contract and the case for auditing declared resources

<!-- CONFIRM (author decision). Alternatives kept from earlier drafts: (a) "One
contract, three execution models: integrating heterogeneous on-device AI models
     into an open-source DICOM viewer"  — names the artefact, not the finding
(b) "Auditing declared resources: a plugin architecture for local medical AI in a DICOM
     viewer" — names the finding, not the artefact
The title above carries both; (a) is the safer choice if a reviewer objects that the
auditing result is a single observation. -->

**Running title:** Auditing declared resources in a DICOM viewer plugin layer
<!-- 58 characters. CONFIRM the journal's running-title character limit. -->

**Author:** Daeseong Kim^1,2^
<!-- Sole author, settled 2026-10-27 (supersedes the two-author list of 2026-10-18).
ORCID is entered in the submission system. -->

**Affiliations:**
^1^ Division of Medical Oncology, Department of Internal Medicine, Yonsei Cancer Center,
Yonsei University College of Medicine, Seoul, Republic of Korea\
^2^ David M. Rubenstein Center for Pancreas Cancer Research, Memorial Sloan
Kettering Cancer Center, New York, NY, USA

**Corresponding author:** Daeseong Kim, Division of Medical Oncology, Department of
Internal Medicine, Yonsei Cancer Center, Yonsei University College of Medicine, 50-1
Yonsei-ro, Seodaemun-gu, Seoul 03722, Republic of Korea. Email: lemonaatree@gmail.com
<!-- Postal address is the Yonsei Cancer Center street address; swap the email for an
institutional one if preferred. -->

---

# Highlights

<!-- CONFIRM against the CMPB guide: typically 3–5 bullets, each ≤ 85 characters incl.
spaces. -->

- One declarative contract hosts four local AI models under three execution models
- Evaluation on public CT found four defects that code review had missed
- Two of three audited plugins under-declared memory; hosts must audit, not trust
- Plugin output is DICOM SEG, decoded losslessly by an independent reference tool
- All inference stays on a consumer Mac; no image leaves the device

---

# Abstract

<!-- CMPB uses a structured abstract. CONFIRM headings and word limit in the guide. -->

**Background and Objectives:** AI in an image viewer usually means one integration per
model, or a remote service. Models differ in process lifetime, memory, input and output,
dependencies and licence. We asked whether such models can run locally under one
declarative contract, and whether a host can safely admit them against declared
resources.

**Methods:** We extended an open-source macOS DICOM viewer with a plugin layer: a manifest
schema, three execution models (resident server, session, one-shot), routing by output
kind, licence gates and a memory arbiter, hosting Gemma 4 E4B, SAM 2, SAM 3 and
TotalSegmentator. We evaluated it on public CT from The Cancer Imaging Archive and the
TotalSegmentator dataset.

**Results:** An independent decoder read 30/30 exported structures losslessly, and routing
through the layer was lossless across 689 per-structure comparisons (minimum Dice
1.000000). The arbiter matched its specification in 38/38 scenarios, yet would have
admitted a job larger than the target machine: TotalSegmentator's declared memory was
5.5–6.1 times below its measured peak. The Gemma plugin peaked at 1.54 times its
declaration, unseen by its own health report; both were corrected. Evaluation found four defect
classes that code review had passed. A new process returned its first result in 1.9 s
(SAM 2) and 3.5 s (Gemma), no slower than the pre-plugin server. <!-- src: EVALUATION.md
§2–4; exp7 summary; exp6 paper.json -->

**Conclusions:** One contract can host heterogeneous local AI models, but an arbiter
correct against its specification is unsafe when its inputs are self-declared. Hosts
must audit declarations against measurement. The software is open source (MIT).

**Keywords:** DICOM; medical image viewer; on-device inference; plugin architecture;
segmentation; software evaluation <!-- CONFIRM max keyword count -->

---

# 1. Introduction

Clinicians and researchers increasingly want AI assistance inside the image viewer they
already use, rather than in a separate application with its own export and import steps
[1,2]. Hundreds of AI products are now marketed for radiology, yet getting them into
daily work, rather than validating them, is the reported bottleneck [3,4]. Sending images
to a remote inference service moves patient data off the device and makes the viewer
depend on a network service the user does not control [5]. Integrating each model
directly keeps data local, but every model adds its own private integration to the
viewer's core, and the cost never amortises.

Models useful in imaging share almost nothing at the level a viewer has to manage. A
vision–language model is expensive to load and cheap to query, so it should stay
resident. A promptable segmenter encodes an image once and reuses it for many cheap
decodes, so it holds per-image state. A whole-body segmenter runs for minutes on a full
series and is used rarely, so it should start, compute and exit. The models also differ
in inputs, outputs, peak memory, Python stacks that cannot share an environment, and the
licence terms on their weights (Table 1). A clinical setting adds one more constraint:
fetching executable code at runtime, as a conventional plugin marketplace does, is hard
to justify for software that handles patient images, so the installable set here is
fixed at build time.

Extension mechanisms already exist at three scales: desktop research applications such
as 3D Slicer [6], MITK [7] and ITK-SNAP [8]; web and lightweight viewers such as OHIF [9]
and browser-based DICOM viewers [10]; and infrastructure such as XNAT [11], Orthanc [12],
the NCI Imaging Data Commons [13], MONAI [14], MONAI Label [15] and Kaapana [16]. These
generally assume a server, a dedicated GPU or a research workstation, and local
execution itself is not new. What we have not found elsewhere is a host that arbitrates
admission across coexisting models against declared memory bounds it enforces itself,
with an installable set fixed at build time rather than fetched at runtime.

This paper describes and evaluates such a plugin layer, built on an open-source macOS
DICOM viewer [17]. Its contributions are:

1. A declarative plugin contract and three execution models (resident server, session,
   one-shot) that host four heterogeneous models with no per-model changes to the viewer.
2. An evaluation on public CT, reproducible from pinned series identifiers, of standard
   conformance, pipeline fidelity, resource arbitration, the session model,
   deployability, end-to-end latency and prompt-coordinate mapping.
3. Evidence that evaluation, rather than code review, found the architecture's defects,
   most clearly self-declared memory figures that an arbiter correct against its own
   specification would still have trusted.
4. Open-source code under the MIT licence.

We make no claim about the accuracy or clinical utility of any model. The models are
used unmodified, and their accuracy is reported in their original publications
[18,19,20,21,22]. How well promptable segmenters transfer to medical images is an active
question in its own right [23,24,25,26], and not the one this paper asks.

---

# 2. Methods

## 2.1 Host application

The host is OpenDicomViewer, a native macOS DICOM viewer written in Swift with Metal
rendering [17]. The published viewer integrated a single vision–language model through
a fixed local server; this work replaces that integration with a general plugin layer
and leaves rendering and DICOM handling unchanged. The application targets macOS 14 or
later on Apple Silicon and bundles a Python interpreter, with which each plugin gets its
own virtual environment. <!-- src: README.md -->

## 2.2 Plugin contract

Each plugin is an entry in a manifest that ships inside the signed application bundle
(Fig. 1).
The entry declares the execution model; the tasks; each task's input and output kinds;
peak memory (`ram_gb`, read as GiB), which a task may override, and disk footprint; the
licence state of the weights; and the URLs and checksums of the weights it may download.
<!-- src: PLUGIN_PROTOCOL.md; PLUGIN_ARCHITECTURE.md §2 --> Five invariants hold for every
plugin: (1) inference is on-device, and no image data, metadata or derived result is
transmitted; (2) the store never fetches or installs executable code, so the installable
set is fixed at build time and auditable in version control; (3) the only network
activity is downloading weights and Python dependencies from URLs the manifest declares;
(4) every plugin declares its peak memory and disk use, and the arbiter admits work
against these figures; (5) no output is a diagnosis, and every result surface is labelled
for research use. <!-- src: PLUGIN_ARCHITECTURE.md §2 --> Invariants 2 and 3 carry the
privacy argument: the only bytes that cross the network are weights, flowing in a
direction that cannot carry patient data, from destinations fixed before release.

## 2.3 Execution models

Each plugin selects one of three supervision patterns <!-- src: PLUGIN_ARCHITECTURE.md
§3 -->. A **resident server** is a long-lived loopback HTTP server for models whose load
cost far exceeds their per-request cost, such as Gemma 4 E4B served through MLX [27]. A
**session** server also holds per-image state, for models with an expensive encode that
many cheap decodes reuse, such as the SAM family [23,19,20]; the adapter declares a
maximum number of open sessions and evicts the least recently used, and the host
releases sessions when the user changes series. A **one-shot** plugin is a subprocess
per invocation that loads, computes, writes its result and exits, for heavyweight
models used rarely, such as TotalSegmentator [18], built on nnU-Net [28]. The one-shot
model is what makes coexistence possible on a laptop: if every engine were resident,
the machine would need the sum of their peaks at once.

**Table 1.** Heterogeneity of the integrated models. <!-- src: PLUGIN_ARCHITECTURE.md §1;
memory row: exp3_FINDINGS.md "Measured table" -->

| | Gemma 4 E4B | SAM 2 / SAM 3 | TotalSegmentator |
|---|---|---|---|
| Execution model | resident server | session | one-shot |
| Load vs. inference cost | load dominates | encode dominates; decode cheap | comparable |
| Input | one rendered slice | slice plus point/box prompts | whole series |
| Output | text, boxes | 2D masks | 3D DICOM SEG, volumes |
| Declared peak memory (`ram_gb`) | 8.0 (5.0 before audit, §3.3) | 3.0 / 6.0 | 25.5 (`total`), 24.0 (`total_lowmem`) |
| Weight licence gate | open | open / gated download | open; licence key for some tasks |
| Python stack | MLX | PyTorch | PyTorch + nnU-Net |

## 2.4 Routing, licence gates and isolation

Each task declares what it consumes (`slice2d`, `series3d`, `roi`, `points`, `box`,
`text`) and produces (`text`, `bbox`, `mask2d`, `seg3d`, `metrics`) from a closed
vocabulary, and the host dispatches results on the declared output kind alone, never on
plugin identity, so a new plugin that emits an existing kind needs no host change. A
volume travels as a file path, so a segmenter reads original geometry and Hounsfield
units rather than a rendering. <!-- src: PLUGIN_ARCHITECTURE.md §4 --> Licence terms
travel with weights rather than code [29]. Weights are `open`, `licence-key` (a key the
host passes through the environment, not the command line) or `gated-download` (the user
accepts the vendor's terms and places the checkpoint); the host never acquires gated
weights on the user's behalf. <!-- src: PLUGIN_ARCHITECTURE.md §5 --> Each plugin runs in
its own process and environment, which the dependency stacks force (MLX and PyTorch are
not co-installable in practice). Containers would isolate more strongly [30] but are a
heavy dependency on a laptop; this is not a security sandbox (§4.4). <!-- src:
PLUGIN_ARCHITECTURE.md §7 --> Details are in Supplementary Section S1.1.

## 2.5 Memory arbitration

The arbiter admits a plugin only if, after any evictions, the sum of declared `ram_gb`
across resident plugins fits within 50% of physical memory, and the newcomer's
declaration fits within the memory the machine can supply at that moment, less a safety
margin. The first condition is deterministic and therefore testable; the second accounts
for other work on the machine. On failure the arbiter returns an eviction plan, least
recently used first; a busy or session-holding plugin is never evicted. A one-shot task
too large for half of memory is budgeted against 75% of it, and a live-headroom refusal
can be overridden by the user. <!-- src: EVALUATION.md §4; PLUGIN_ARCHITECTURE.md §6 -->

## 2.6 Evaluation design

**Data.** We used 12 CT series from The Cancer Imaging Archive (TCIA) *CT Lymph Nodes*
collection, 6 abdominal and 6 mediastinal, with 148–493 slices each <!-- src:
eval/fetch_data.py PINNED_TCIA --> [31,32,33], pinned by identifier because archive
queries are not stable across API revisions, and cases from the TotalSegmentator
reference dataset (Zenodo record 10047292, CC BY 4.0) <!-- src: eval/fetch_data.py -->
[34]. All data are public and de-identified, and their use required no ethics approval or
data use agreement.

**Experiments.** Seven experiments addressed the questions in Table 2. Full protocols are
in Supplementary Section S1.3.

**Table 2.** Evaluation questions and metrics.

| # | Question | Metric |
|---|---|---|
| E1 | Is the exported DICOM SEG read correctly by a third party? | dcmqi round-trip Dice; Segmentation IOD field audit |
| E2 | Is routing through the plugin layer lossless? | per-structure Dice against a direct model call; perturbation probes |
| E3 | Do declared resources match measured ones, and does arbitration follow the specification? | process-tree peak memory; scenario pass rate |
| E4 | Does the session model pay for itself? | encode/decode cost ratio; implicit-cache overhead |
| E5 | Does the packaged application work as shipped? | deployability checks |
| E6 | What is end-to-end latency through the host's contract? | per-stage wall time, median (IQR), idle-gated runs only |
| E7 | Do prompt-driven and VLM plugins return output where the prompt and image say they should? | per-structure Dice for one interior click, with a transposed-click control; Gemma round trip and box placement; process-tree peak memory |

E1 encoded synthetic edge-case masks on six TCIA grids as DICOM Segmentation objects
[35,36] with the adapter's highdicom-based encoder [37], since standard objects are what
let an independent tool read derived results [38], decoded them with dcmqi [39], and
audited each file against Segmentation IOD requirements. E2 compared TotalSegmentator
output through the plugin layer with a direct model call on 7 series, after confirming
with perturbation probes that the comparison could detect a difference. E3 measured peak
memory as the summed `phys_footprint` of the adapter and all descendants, sampled every
0.2 s, and ran arbiter scenarios against the shipped Swift type. E4 measured SAM 2 encode
and decode cost and the overhead of an implicit embedding cache. E5 ran nine checks on
the packaged, signed application. <!-- src: exp1_findings.md §1–2; EVALUATION.md §1,
§3–6 -->

E6 timed each engine from outside its process through the host's own contract, so
interpreter start-up, imports, model loading and serialisation are included: the Gemma
plugin, the viewer's earlier built-in Gemma server as the pre-plugin baseline, SAM 2,
and TotalSegmentator's `total` and `total_lowmem` tasks, on 3 pinned TCIA series. Each
server engine was cold-started 10 times, and each TotalSegmentator task ran 5 times per
series; only cases run with a 1-minute load average of 2.0 or below are summarised. E7
clicked once at the most interior pixel of each reference structure on its central
slice, sent the slice and click to SAM 2, and compared the returned mask with the
reference by Dice; a click with x and y exchanged served as a negative control. Gemma's
detection and analysis tasks ran on 3 slices per case, checking that each request
completed and each box lay inside the image and on the body. E7 servers ran under the E3
memory sampler. E6 and E7 ran natively on one Apple M5 Max MacBook Pro with 128 GB of
memory; neither measures accuracy. <!-- src: eval/README.md "Experiment 6";
eval/exp6_latency.py; eval/exp7_prompt_vlm.py -->

**Environment and reporting.** Each case produces one JSON record carrying the machine
profile and package versions, and failures are recorded rather than dropped. E1–E5 ran
in August 2026 in a sandbox that exposed no GPU, so their timings are CPU-only;
TotalSegmentator memory and the arbiter scenarios were re-run natively in October 2026.
<!-- src: eval/README.md; EVALUATION.md §1 --> Memory is reported in GB (10^9 bytes) and,
wherever it is compared with a declaration, in GiB (2^30 bytes), the arbiter's unit;
every declared-versus-measured ratio is computed in GiB. Results are descriptive:
counts, minima, and median with interquartile range (IQR); no hypothesis tests were
performed.

---

# 3. Results

## 3.1 DICOM SEG conformance (E1)

dcmqi decoded every segment of every exported SEG losslessly: 30/30 structures across 6
cases at Dice 1.000000, with image size, spacing, origin and direction preserved
exactly. Of 84 field checks (14 Segmentation IOD requirements over 6 cases), 72 passed,
12 returned warnings and none failed. <!-- src: EVALUATION.md §2;
exp1_conformance_audit.csv, 14 checks × 6 cases --> The warnings are an interoperability
defect: every segment carries the generic code "anatomical structure", so the specific
anatomy survives only in the free-text label, and mapping labels to SNOMED CT codes has
not yet been done (Supplementary Section S2.1). <!-- src: EVALUATION.md §2;
exp1_findings.md -->

## 3.2 Pipeline fidelity (E2)

Across 7 TCIA series and 689 per-structure comparisons, the lowest Dice coefficient
between plugin-layer output and direct model output was 1.000000, with zero voxel
difference. <!-- src: EVALUATION.md §3; exp2_tables.md Table 1 --> The comparison
resolved a single altered voxel in a 432-voxel structure (Dice 0.9988), a one-slice
shift (0.667) and a dropped structure (0.0) (Supplementary Fig. S1). <!-- src:
EVALUATION.md §3; exp2_probes.json --> Before these results, SEG export had failed on
every series in the collection, because the encoding library required slice thickness,
a Type 2 attribute that all 411 instances of the first series omitted. <!-- src:
exp2_REPORT.md "Mechanism" -->

## 3.3 Resources and arbitration (E3, E7)

The arbiter matched its specification in 38 of 38 scenarios. <!-- src: EVALUATION.md §4
--> The inputs to that specification were wrong. TotalSegmentator declared 3.5 GB; its
measured single-process peak was 20.9–23.1 GB (19.4–21.5 GiB) over four runs, 5.5–6.1×
the declaration. <!-- src: EVALUATION.md §4 --> On the 16 GB machine the policy was
designed for, the original declaration would have admitted a job that needs more than
the whole machine (Fig. 2). A second defect compounded the first: a running one-shot
never entered the runtime-state table, so a resident engine could start alongside it.
Both were fixed: the manifest now carries measured, per-task figures, and in-flight
one-shots are counted and never evicted. <!-- src: EVALUATION.md §4 -->

The corrected figure was itself low. Measured over the whole process tree, with
nnU-Net's worker processes alive, the peak over 10 runs on five series reached 25.41 GB
(23.66 GiB), and the `total` declaration was raised to 25.5. A single export worker
lowered the peak to 23.78 GB (22.15 GiB); this ships as a `total_lowmem` task declared at
24.0, which fits a 32 GB Mac's one-shot share. No TotalSegmentator task fits a 16 GB Mac.
<!-- src: EVALUATION.md §4; exp3_FINDINGS.md "Low-memory settings" --> SAM 2 declared
3.0 and peaked at 1.45 GB (1.35 GiB) on the CPU. <!-- src: exp3_FINDINGS.md "Measured
table" -->

E7 measured the remaining plugins natively, on the GPU, over the process tree. The Gemma
4 E4B plugin peaked at 7.66–7.72 GiB in each of 4 runs, 1.54 times its declared 5.0. Its
own health report gave 4,910.7 MB, because it reports the MLX allocator's peak, which
excludes the interpreter, the image pipeline and generation; it agreed with the
declaration and gave no sign of the gap. SAM 2 on the GPU peaked at 2.74 GiB, under its
declaration but twice its CPU figure. On a 16 GB machine the old declarations for Gemma
and SAM 2 summed to 8.0 GiB and were admitted together under the 8 GiB budget; their
measured peaks sum to 10.46 GiB. <!-- src: exp7 summary "peak_memory_gib" and per-case
metrics.memory; exp6 health_memory_mb; plugins.json --> The Gemma declaration was raised
to 8.0, for the plugin and the built-in server, a margin of 0.28 GiB (3.6%) over four
runs on one machine. On 16 GB, admitting Gemma now evicts a resident SAM 2 instead of
running beside it; regression tests pin both behaviours. <!-- src: plugins.json
gemma-4-e4b ram_gb; AIServerManager.declaredRamGB; ResourceArbiter.swift;
PluginResourceDeclarationTests --> SAM 3 could not be measured, because its gated weights
were not obtained (Table 4).

## 3.4 Session model (E4)

Encoding a slice with SAM 2 cost 17.1× a decode on the CPU (median over 30 encodes and
216 decodes). <!-- src: EVALUATION.md §5; exp4_session.csv --> But an implicit
content-addressed cache in an ordinary resident server cost only 1.8–4.7 ms per prompt,
2–5% of a decode (Supplementary Fig. S2). <!-- src: EVALUATION.md §5 --> The ratio rules
out not caching but does not select the session lifecycle over implicit caching, so we
report the original performance justification as not supported; what the session model
provides is a declared session bound the host can enforce and explicit release. With
real weights, SAM 2 completed 12 of 12 protocol round trips, each mask decoded by the
host's Swift decoder. <!-- src: EVALUATION.md §5 -->

## 3.5 Deployability (E5)

The packaged application initially failed in three ways: the packaging script bundled no
adapters, adapters wrote bytecode into the signed bundle, and so did the bundled
interpreter, each breaking either installation or the code signature. After the fixes it
passed 9/9 checks. <!-- src: EVALUATION.md §6 --> App Sandbox is disabled by design, so
this architecture and Mac App Store distribution are mutually exclusive. A conformance
kit for third-party adapters passed all 54 of its checks, each paired with a broken
fixture it must reject. <!-- src: EVALUATION.md §6–7 -->

## 3.6 End-to-end latency (E6)

Of the cases run, 8 of 10 cold starts for the built-in Gemma server, 5 of 10 for the
Gemma plugin, 10 of 10 for SAM 2, and 11 of 15 and 15 of 15 TotalSegmentator runs for
`total` and `total_lowmem` met the idle gate and are reported (Fig. 3). All requests in
them succeeded. <!-- src: eval/results/exp6_latency_apple-m5-max-128-gb_paper.json
(idle-gated) -->

From a new process to the first result took a median of 1.94 s (IQR 1.90–1.96) for SAM
2, 3.51 s (3.48–3.56) for the Gemma plugin and 3.52 s (3.49–3.54) for the built-in Gemma
server. SAM 2 reports ready 0.61 s after spawn but loads its model in the first session
open (1.25 s), so a client that treats "ready" as "loaded" under-reports its cold start
by about two thirds. Warm Gemma requests took 973, 876 and 1,270 ms (detection, region
description, analysis) through the plugin, against 986, 815 and 1,289 ms through the
built-in server, so the plugin layer cost nothing this measurement resolves. A SAM 2
click on an open session took 11.1 ms (IQR 10.7–11.4); encoding a new slice took 63.2 ms,
measured as session open plus first click, because on the GPU the adapter's encode
returns once the work is queued and its self-reported time of about 10 ms is not what
the user waits for. TotalSegmentator's `total` took a median of 57.5 s per run (IQR
55.6–64.8), and `total_lowmem` 90.6 s, 1.47–1.61 times `total` on the same series.
Details are in Supplementary Section S2.6.

## 3.7 Prompt-driven and VLM plugins on public CT (E7)

Four of the six TotalSegmentator reference cases could be read; ITK rejected the other
two. <!-- src: eval/results/exp7_prompt_vlm_apple-m5-max-128-gb_summary.json --> All
214 structures large enough to click returned a SAM 2 mask on the slice's own grid. The
median Dice against the reference was 0.79 (IQR 0.55–0.90), and 170 of 214 masks
reached 0.5. Of the 191 structures for which the transposed click fell outside the
structure, the median control Dice was 0.00 (IQR 0.00–0.01). A transposed axis, a scale
error or an inverted run-length phase would each have pushed the clicked masks toward
the control's distribution; none did. <!-- src: exp7 summary
"control_click_inside_structure", "control_transposed_dice_click_outside" --> All 24
Gemma requests completed and returned 46 boxes, all inside the image with centres on the
body. These counts show that results come back in the image's frame; they say nothing
about accuracy (Supplementary Section S2.7).

## 3.8 Defects found by evaluation

Table 3 summarises the defects that evaluation found after code review had passed them.
Each would have shipped. Table 4 gives each adapter's verification status.

**Table 3.** Defects found by evaluation, grouped into four classes. <!-- src: FOLLOWUP_PAPER_OUTLINE.md status
block; EVALUATION.md §4, §6; exp2_REPORT.md -->

| # | Defect | Found by | Consequence if shipped | Fix |
|---|---|---|---|---|
| 1 | Self-declared memory too low. TotalSegmentator declared 3.5 GB; measured peak 20.9–23.1 GB (5.5–6.1×), and 25.41 GB over the process tree. Gemma 4 E4B declared 5.0; measured 7.72 GiB (1.54×), while its health report gave 4,910.7 MB | E3, E7 | On 16 GB, admits a job larger than the machine; admits Gemma with SAM 2 at 10.46 GiB measured against an 8 GiB budget | TotalSegmentator: measured declarations (25.5 / 24.0), per-task `ram_gb`, process-tree measurement. Gemma: declared 8.0 (plugin and built-in server); on 16 GB, admitting it evicts SAM 2 |
| 2 | Running one-shot absent from the arbiter's runtime state | E3 | A resident engine admitted alongside the heaviest process | In-flight one-shots counted and non-evictable |
| 3 | SEG export required Type 2 SliceThickness | E2 | No SEG produced for any series in the public collection | Handle absent slice thickness |
| 4 | Packaged build: no adapters bundled; bytecode written into the signed bundle by adapters and by the bundled interpreter | E5 | Store lists nothing installable; signature broken on first launch | Bundle adapters; suppress bytecode writes in the bundle |

**Table 4.** Verification status per adapter. <!-- src: PLUGIN_ARCHITECTURE.md §8;
EVALUATION.md §5, §8 -->

| Adapter | Verified by execution | Not verified, and why |
|---|---|---|
| TotalSegmentator | End-to-end on TCIA CT (E2, 7 series); SEG conformance (E1); native process-tree memory (E3) | Accuracy (not claimed); GPU (ships CPU-only) |
| SAM 2 | 12/12 protocol round trips with real weights, mask decoded by host (E4); latency (E6); coordinate mapping on 214 structures and GPU memory (E7) | Accuracy (not claimed) |
| SAM 3 | Protocol conformance; licence gate | Inference, latency and memory: its weights are gated by the vendor and were not obtained for this study |
| Gemma 4 E4B | Protocol conformance; latency against the built-in server (E6); 24/24 requests on public CT and process-tree memory (E7) | Correctness of findings (not claimed) |

---

# 4. Discussion

## 4.1 Principal findings

A single declarative contract hosted four models that share no execution axis, with no
per-model code in the viewer, and the layer itself introduced no loss: across 689
comparisons it reproduced the model's direct output exactly.

The main lesson concerns trust rather than mechanism. The arbiter was correct against
its specification in every scenario tested, yet it would have admitted a job larger than
the machine, because its specification takes a plugin's self-declared memory as given.
Correct policy over incorrect declarations is still unsafe, and this was not one bad
number: of the three plugins whose peaks we could measure, two had declared too little.
The measurement must also match how the plugin actually runs. The corrected
TotalSegmentator figure was still low until worker processes were counted; SAM 2's peak
doubled between CPU and GPU; and the Gemma plugin's own health report, which a host
might be tempted to use as the audit, measured the model's arrays rather than the
process and agreed with the wrong declaration. The audit has to be external to the
plugin. Timing showed the same pattern: SAM 2 reported "ready" before loading its model
and, on the GPU, an encode time that excluded the work it had queued. Both self-reports
were corrected only by measuring from outside the process. Measured that way, the layer
was fast enough for interactive use, with no measurable cost over the earlier built-in
server.

## 4.2 What review missed and evaluation found

All four defects in Table 3 passed code review, and each sits at a boundary that reading
one side of the code does not reveal: between a manifest figure and a process tree,
between the arbiter's state table and the process supervisor, between a library's
assumptions and what the standard lets scanners omit, and between the development tree
and a signed bundle. Tests written from one side of such an interface cannot reach these
defects, however many are written; each was reached only by exercising the boundary
itself. We report the failures alongside the passes because a table in which everything
passes does not tell a reader which kind of test was run.

## 4.3 Comparison with existing integration approaches

Existing frameworks place inference on a server or platform: MONAI Label serves models
to client viewers [15], Kaapana runs containerised workflows on institutional
infrastructure [16], and OHIF and 3D Slicer extensions commonly call such services or
run on research workstations [6,9]. The design here targets a single consumer laptop
with no network service and several models whose combined footprint exceeds its memory,
so the contract has to carry what a server platform handles by provisioning: process
lifetime and memory admission. Local inference removes the image transmission that
remote inference requires [5], and a build-time installable set removes the remote-code
channel that a marketplace opens.

## 4.4 Limitations

Isolation is by process and environment, not by sandbox: a plugin runs with the user's
privileges, and the invariants are enforced by review of in-tree adapters, which is the
main obstacle to accepting third-party adapters. The arbiter enforces declarations, not
live consumption, and the auditing reported here was offline. The software runs only on
macOS and Apple Silicon. E1–E5 timings are CPU-only sandbox figures; E6 and E7 ran on one
high-end machine without flushing the file cache, with ungated runs excluded, and the 16
GB configuration was analysed through the arbiter's decisions rather than timed.
TotalSegmentator memory was measured under PyTorch 2.13.0, not the 2.14.1 now locked.
SAM 3 was not executed, so its declaration is unaudited and its support rests on
protocol conformance. Prompts yield per-slice 2D masks; the `seg3d` labelmap clips
overlapping structures (Supplementary Section S2.2); and exported segments lack coded
anatomy [38]. No output was validated clinically, and this work makes none of the claims
a clinical AI study would have to support [40]; nothing here is, or was evaluated as, a
regulated device [41]. The software is for research use only.

## 4.5 Future work

Next steps are a sandbox boundary for third-party adapters, coded anatomy in exported
SEG, and an MR-capable segmenter [42] to test whether a task-level declaration describes
a second modality. For oncology, we plan volumetric tumour segmentation on pancreatic CT
and DICOM whole-slide images, so that radiology and pathology can be read with local AI
in one viewer.

---

# 5. Conclusions

A single declarative contract with three execution models can host heterogeneous AI
models locally inside a DICOM viewer, without per-model changes to the viewer and
without images leaving the device. Evaluation on public CT showed that the layer adds no
loss, writes standard segmentation objects, and returns interactive results in
milliseconds to seconds. It also found four classes of defect that code review had
passed, the most consequential being self-declared memory figures, low for two of the
three plugins measured, that an otherwise correct arbiter would have trusted. Hosts that
arbitrate local AI models against declared resources should audit those declarations
against measurement.

---

# Declarations

**CRediT authorship contribution statement:**
Daeseong Kim: Conceptualization, Methodology, Software, Validation, Formal analysis,
Investigation, Data curation, Writing – original draft, Writing – review & editing,
Visualization.

**Declaration of competing interest:** The author declares no known competing
financial interests or personal relationships that could have appeared to influence the work
reported in this paper.

**Funding:** This research did not receive any specific grant from funding agencies in the
public, commercial, or not-for-profit sectors.

**Ethics:** This study used only publicly available, de-identified imaging data and
involved no human subjects research; institutional review board approval and informed
consent were therefore not required. <!-- CONFIRM this wording with the institution. -->

**Data availability:** All data are public. The exact series are pinned by
SeriesInstanceUID in `eval/fetch_data.py`; raw per-case results are in `eval/results/`.

**Supplementary material:** Extended methods and results (Sections S1–S2) and Figures
S1–S2 are provided as a separate file.

**Code availability:** https://github.com/Essential-Citronnier/ODV-Annotate (MIT licence). The
version described here is archived as release v2.0.1-cmpb [43],
https://doi.org/10.5281/zenodo.23734091.

**Declaration of generative AI and AI-assisted technologies in the writing process:**
During the preparation of this work the author used Claude (Anthropic) to draft and
revise manuscript text, to write evaluation and figure-generation scripts, and to
retrieve bibliographic metadata from Crossref and DataCite. Every number in the
manuscript was copied from the evaluation result files, and every reference was checked
against its DOI record. After using this tool, the author reviewed and edited the
content as needed and take full responsibility for the content of the published article.
<!-- CONFIRM: author to review this wording; Elsevier places it before the references. -->

---

# References

<!-- Numbered in order of first citation. Source of truth with verification notes:
docs/paper/references.md. Copy the list here at submission. -->

See `references.md` (43 entries).

---

# Figure legends

**Figure 1.** Architecture of the plugin layer. The host reads a manifest shipped in the
signed application and supervises plugins under one of three execution models (resident
server, session, one-shot). Results are routed by declared output kind. Each plugin runs
in its own process and virtual environment; licence gates and the memory arbiter sit
between the store and execution. (`docs/figures/plugin_architecture.png`)

**Figure 2.** Declared versus measured peak memory, and arbiter decisions. (A) Declared
`ram_gb` for TotalSegmentator at each stage of its declaration (3.5 → 23.5 → 25.5 /
24.0) and for SAM 2, against measured peak, in GiB. (B) Decisions of the shipped arbiter
on 16 GB and 32 GB configurations under the original and corrected declarations.
(`docs/figures/fig_declared_vs_measured.png`)

**Figure 3.** End-to-end latency through the host's contract on an Apple M5 Max (128 GB),
idle-gated runs only. (A) New process to first result for each server engine; for SAM 2
this includes the first session open and click. (B) Warm requests, log scale; SAM 2
encode is session open plus the first click. (C) TotalSegmentator per run: median
adapter stages (bars) and median process wall time (|). (`eval/figures/exp6_latency.png`)

<!-- Former Figs. 3 and 4 moved to Supplementary Figs. S1 and S2 (2026-10-28). -->
