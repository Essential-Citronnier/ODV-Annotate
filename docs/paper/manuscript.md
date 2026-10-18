<!--
Manuscript for Computer Methods and Programs in Biomedicine (CMPB, Elsevier).
Status: FULL DRAFT, except §3.6 (E6) and §3.7 (E7), whose experiments have not run.

Rules for this file:
- Every number is copied from a results file and carries a <!-- src: ... --> pointer.
  Never restate a number from memory; if a source changes, re-copy it.
- [REF: ...] marks a citation still to be resolved from Crossref/PubMed metadata.
  Do not fill bibliographic fields by hand.
- CONFIRM marks something only the authors or the journal's guide can settle.
- TODO(E6)/TODO(E7) marks results that depend on experiments not yet run
  (see docs/paper/PLAN.md).
-->

# Title page

**Title (working):** One contract, three execution models: integrating heterogeneous
on-device AI models into an open-source DICOM viewer

<!-- Alternative: "Auditing declared resources: a plugin architecture for local medical AI
in a DICOM viewer". Decide after E6/E7. -->

**Authors:** Daeseong Kim^1^, JoonNyung Heo^2^ <!-- CONFIRM: author list, order, affiliations, ORCID -->

**Affiliations:** <!-- CONFIRM -->

**Corresponding author:** <!-- CONFIRM: name, address, email -->

---

# Highlights

<!-- CONFIRM against the CMPB guide: typically 3–5 bullets, each ≤ 85 characters incl. spaces. -->

- One declarative contract runs three AI models with no shared execution axis
- Evaluation on public CT found four defects that code review had missed
- Declared plugin memory was 6× too low; arbitration must audit, not trust
- Plugin output is DICOM SEG, decoded losslessly by an independent reference tool
- All inference stays on a consumer Mac; no image leaves the device

---

# Abstract

<!-- CMPB uses a structured abstract. CONFIRM headings and word limit in the guide. -->

**Background and Objective:** Integrating AI models into image viewers usually means
one bespoke integration per model, or sending images to a remote service. Models differ
in process lifetime, memory footprint, input and output type, dependency stack and
licence terms. We asked whether such heterogeneous models can run locally inside a
clinical image viewer through a single declarative contract, with no per-model changes
to the viewer.

**Methods:** We extended an open-source macOS DICOM viewer with a plugin
layer: a manifest schema, three execution models (resident server, session,
one-shot), capability-based result routing, licence gates and a memory arbiter. Four
models were integrated: Gemma 4 E4B, SAM 2, SAM 3 and TotalSegmentator. We evaluated
the layer on public CT from The Cancer Imaging Archive and the TotalSegmentator
reference dataset. The evaluation covered DICOM SEG conformance, pipeline fidelity,
resource arbitration, the session model, deployability of the packaged application,
and TODO(E6) end-to-end latency on two Apple Silicon configurations.

**Results:** An independent reference decoder (dcmqi) read 30/30 exported structures
losslessly. <!-- src: EVALUATION.md §2 --> Routing through the plugin layer was lossless
across 689 per-structure comparisons on 7 series (minimum Dice 1.000000).
<!-- src: EVALUATION.md §3 --> The arbiter matched its specification in 38/38 scenarios.
<!-- src: EVALUATION.md §4 --> However, one plugin's declared memory was 5.5–6.1× below its
measured peak, which would have admitted a job larger than the target machine.
<!-- src: EVALUATION.md §4 --> In total the evaluation found four defects that had passed
code review, and all four were fixed. TODO(E6): latency per engine.

**Conclusions:** A single contract can host heterogeneous local AI models in a viewer.
The weak point is the trust the contract places in self-declared resources: a host must
audit those declarations against measurement. The software is open source (MIT).

**Keywords:** DICOM; medical image viewer; on-device inference; plugin architecture;
segmentation; software evaluation <!-- CONFIRM max keyword count -->

---

# 1. Introduction

Clinicians and researchers increasingly want AI assistance inside the image viewer they
already use, rather than in a separate application with its own export and import steps
[1,2]. Two integration patterns dominate.
The first sends images to a remote inference service. This is simple for the viewer, but
it moves patient data off the device and makes the viewer's behaviour depend on a
network service the user does not control [3]. The
second integrates each model directly into the viewer. This keeps data local, but every
new model adds its own private integration to the viewer's core, and the cost never
amortises.

The difficulty is that models useful in an imaging workflow share almost nothing at the
level a viewer has to manage. A vision–language model is expensive to load and cheap to
query, so it should stay resident. A promptable segmenter spends most of its time
encoding an image, which is then reused by many cheap decodes, so it holds per-image
state. A whole-body segmenter runs for minutes on a full series and is used rarely, so it
should start, compute and exit. The same models differ in what they consume (a rendered
slice, a slice with clicks, a whole volume), in what they produce (text and boxes, 2D
masks, 3D DICOM Segmentation objects), in peak memory, in Python dependencies that cannot
share an environment, and in the licence terms that govern their weights (Table 1). A
contract between a viewer and its models must accommodate all of these at once, without
the viewer knowing which model it is talking to.

A clinical setting adds a constraint that changes the design. Fetching executable code at
runtime, as a conventional plugin marketplace does, is hard to justify for software that
handles patient images. We therefore fixed the set of installable plugins at build time.
The manifest ships inside the signed application, adapter code is versioned and reviewed
with the host, and the only network activity permitted is downloading model weights and
dependencies from URLs fixed before release. This choice, rather than the user interface,
is what separates the design from a conventional plugin store.

Plugin and extension mechanisms already exist in medical imaging. 3D Slicer offers a rich
extension ecosystem [4]; OHIF provides a web viewer with extension points
[5]; MONAI Label serves interactive models to client viewers [6];
and Kaapana orchestrates containerised analysis on a hospital platform [7].
These systems generally assume a server, a dedicated GPU or a research workstation. To
our knowledge, none targets fully local inference of several heterogeneous models on a
consumer laptop with memory bounds the host enforces. <!-- CONFIRM this claim after a
literature check. -->

This paper describes and evaluates such a plugin layer, built on an open-source macOS
DICOM viewer [8]. Its contributions are:

1. A declarative plugin contract and three execution models (resident server, session,
   one-shot) that host four heterogeneous models with no per-model changes to the viewer.
2. An evaluation on public CT that is reproducible from pinned series identifiers,
   covering standard conformance, pipeline fidelity, resource arbitration, the session
   model, deployability and TODO(E6) latency.
3. Evidence that evaluation, rather than code review, found the architecture's defects.
   The clearest case is a self-declared memory figure about six times too low, which an
   arbiter correct against its own specification would still have admitted.
4. Open-source code under the MIT licence.

We make no claim about the accuracy or clinical utility of any model. The models are
used unmodified, and their accuracy is reported in their original publications
[9,10,11,12,13].

---

# 2. Methods

## 2.1 Host application

The host is OpenDicomViewer, a native macOS DICOM viewer written in Swift with Metal
rendering, multiplanar reformation, maximum intensity projection and measurement tools
[8]. The published viewer integrated a single vision–language
model through a fixed local server, with a fixed port, fixed endpoints and one Python
environment. This work replaces that integration with a general plugin layer. The
viewer's rendering and DICOM handling are unchanged. The application targets macOS 14 or
later on Apple Silicon. It bundles a Python interpreter, and each plugin is installed into
its own virtual environment created with that interpreter. <!-- src: README.md -->

## 2.2 Plugin contract

Each plugin is described by an entry in a manifest that ships inside the application
bundle. The entry declares the plugin's execution model; its tasks; for each task, the
input and output kinds it uses; its peak memory (`ram_gb`, read by the host as GiB) and
disk footprint; the licence state of its weights; and the URLs and checksums of the
weights it may download. A task may override the plugin-level memory figure, because
tasks within one plugin can differ materially in footprint (§3.3).
<!-- src: PLUGIN_PROTOCOL.md; PLUGIN_ARCHITECTURE.md §2 -->

Five invariants hold for every plugin <!-- src: PLUGIN_ARCHITECTURE.md §2 -->:

1. **On-device inference.** A plugin must not transmit image data, DICOM metadata or
   derived results.
2. **No remote code.** The store never fetches, evaluates or installs executable code
   from the network. The installable set is fixed at build time and auditable in version
   control.
3. **Weights are the only egress.** The only permitted network activity is downloading
   weights and Python dependencies from URLs the manifest declares.
4. **Explicit resource declaration.** A plugin declares its peak memory and disk use. The
   arbiter admits work against these figures, and a plugin that under-declares is
   refused or evicted rather than allowed to exhaust the machine.
5. **Research use.** No plugin output is a diagnosis, and the host labels every result
   surface accordingly.

Invariants 2 and 3 together carry the privacy argument: the only bytes that cross the
network are weights, which flow in a direction that cannot carry patient data, from
destinations fixed before the application shipped.

## 2.3 Execution models

The contract does not admit arbitrary process behaviour. It defines three supervision
patterns, and each plugin selects one <!-- src: PLUGIN_ARCHITECTURE.md §3 -->:

- **Resident server.** A long-lived loopback HTTP server that answers independent
  requests. It suits models whose load cost far exceeds their per-request cost, such as
  Gemma 4 E4B served through MLX [14].
- **Session.** A resident server that also holds per-image state. It suits models with
  an expensive encode that many cheap decodes reuse, such as SAM 2 and SAM 3
  [10,11]: one slice is encoded, then re-prompted
  interactively with clicks and boxes. The adapter declares a maximum number of open
  sessions (`max_sessions`) and evicts the least recently used; the host releases
  sessions explicitly when the user changes series.
- **One-shot.** A subprocess per invocation that loads, computes, writes its result and
  exits. It suits heavyweight models used rarely, such as TotalSegmentator
  [9], built on nnU-Net [15].

The one-shot model is what makes coexistence possible on a laptop. If every engine were
a resident server, the machine would need the sum of their peak memory at once. Table 1
summarises how the four models differ.

**Table 1.** Heterogeneity of the integrated models. <!-- src: PLUGIN_ARCHITECTURE.md §1;
memory row: exp3_FINDINGS.md "Measured table" -->

| | Gemma 4 E4B | SAM 2 / SAM 3 | TotalSegmentator |
|---|---|---|---|
| Execution model | resident server | session | one-shot |
| Load vs. inference cost | load dominates | encode dominates; decode cheap | comparable |
| Input | one rendered slice | slice plus point/box prompts | whole series |
| Output | text, boxes | 2D masks | 3D DICOM SEG, volumes |
| Declared peak memory (`ram_gb`) | 5.0 | 3.0 / 6.0 | 25.5 (`total`), 24.0 (`total_lowmem`) |
| Weight licence gate | open | open / gated download | open; licence key for some tasks |
| Python stack | MLX | PyTorch | PyTorch + nnU-Net |

## 2.4 Result routing, licence gates and environment isolation

**Routing.** Each task declares what it consumes and produces from a closed vocabulary.
Inputs are `slice2d`, `series3d`, `roi`, `points`, `box` and `text`; outputs are `text`,
`bbox`, `mask2d`, `seg3d` and `metrics`. The host assembles inputs from the viewer state
and dispatches results on the declared output kind alone, never on plugin identity. Text
goes to the AI inspector; boxes and masks become annotations; `seg3d` results are read by
the same DICOM SEG reader the viewer uses for segmentation files on disk; metrics go to
the results panel. A new plugin that emits an existing output kind therefore needs no
host change. <!-- src: PLUGIN_ARCHITECTURE.md §4 -->

Transport follows payload size. A rendered slice travels as a base64-encoded PNG, but a
volume travels as a filesystem path, so a segmentation model reads the original geometry
and Hounsfield units rather than a windowed rendering. Two-dimensional masks use
row-major run-length encoding that begins with a background run. Because a disagreement
between the Python encoder and the Swift decoder would render an inverted mask rather than
raise an error, both sides are tested against the same fixtures.

**Licence gates.** Weight availability is modelled as one of three states: `open`
(downloadable unconditionally), `licence-key` (the user registers a key locally, which the
host passes to the adapter through the environment rather than the command line, because
process arguments are visible to other processes), and `gated-download` (the user accepts
terms with the vendor and places the checkpoint at a path the host names exactly). The host
never acquires gated weights on the user's behalf. A missing licence is a distinct install
state from missing weights, so the user is routed to the right remedy.
<!-- src: PLUGIN_ARCHITECTURE.md §5 -->

**Isolation.** Each plugin runs in its own process and virtual environment. This is
forced by the dependency stacks, since MLX and PyTorch are not co-installable in practice,
and it confines a failed install to one plugin. It is not a security sandbox: a plugin
runs with the user's privileges, and the invariants are enforced by review of in-tree
adapter code (§4.4). <!-- src: PLUGIN_ARCHITECTURE.md §7 -->

## 2.5 Memory arbitration

The arbiter admits a plugin only if two conditions hold after any evictions
<!-- src: PLUGIN_ARCHITECTURE.md §6 -->. First, the sum of declared `ram_gb` across resident
plugins must fit within 50% of physical memory; this condition is deterministic, so the
policy is reproducible and testable. Second, the incoming plugin's declared memory must fit
within the memory the machine can supply at that moment, less a safety margin. Neither
condition suffices alone: the first ignores other work on the machine, and the second
would let two models that each fit leave nothing for the viewer.

When admission fails, the arbiter returns an eviction plan, least recently used first with
deterministic tie-breaking, rather than a bare refusal. A plugin that is serving a request
or holding open sessions is never evicted; it blocks admission instead. A one-shot task
too large for half of physical memory is budgeted against 75% of it, with every evictable
plugin stopped. If live headroom is insufficient, the user may override the refusal with
"Start Anyway". <!-- src: EVALUATION.md §4; PLUGIN_ARCHITECTURE.md §6 -->

## 2.6 Evaluation design

**Data.** We used 12 CT series from The Cancer Imaging Archive (TCIA) *CT Lymph Nodes*
collection, 6 abdominal and 6 mediastinal, with 148–493 slices each
<!-- src: eval/fetch_data.py PINNED_TCIA --> [16,17,18]. Series identifiers are pinned in
the acquisition script rather than discovered by query, because archive query results are
not stable across API revisions. For the hygiene check in §3.2 we also used cases from the
TotalSegmentator reference dataset (Zenodo record 10047292, CC BY 4.0)
<!-- src: eval/fetch_data.py --> [19]. TODO(E7, optional): a
few TCIA *Pancreas-CT* series, for anatomical diversity. All data are public and
de-identified, and their use required no ethics approval or data use agreement.
<!-- CONFIRM wording with the institution -->

**Experiments.** Seven experiments addressed the questions in Table 2.

**Table 2.** Evaluation questions and metrics.

| # | Question | Metric |
|---|---|---|
| E1 | Is the exported DICOM SEG read correctly by a third party? | dcmqi round-trip Dice; Segmentation IOD field audit |
| E2 | Is routing through the plugin layer lossless? | per-structure Dice against a direct model call; perturbation probes |
| E3 | Do declared resources match measured ones, and does arbitration follow the specification? | process-tree peak memory; scenario pass rate |
| E4 | Does the session model pay for itself? | encode/decode cost ratio; implicit-cache overhead |
| E5 | Does the packaged application work as shipped? | deployability checks |
| E6 | What is end-to-end latency on real hardware? | per-stage wall time, median (IQR), two machines — TODO(E6) |
| E7 | Do prompt-driven and VLM plugins return correct output on public CT? | SAM 2/3 click-prompt Dice against reference masks; Gemma round trip — TODO(E7) |

E1 tested conformance of the DICOM Segmentation objects [20] written by the TotalSegmentator adapter's shipped encoder, which uses highdicom
[21]. Six fixtures were encoded on the grids of six unmodified TCIA series.
The masks were synthetic by design: conformance is a property of the encoder, and
constructed masks could attack it with cases that real model output rarely produces (a
one-voxel shell, a single-slice structure, overlapping structures, a structure touching
the volume boundary, an empty structure). Each SEG was decoded by dcmqi
[22], an independent implementation in a different language, and
compared voxelwise with the source mask in physical space. Each file was also audited
against Segmentation IOD requirements. <!-- src: exp1_findings.md §1–2 -->

E2 compared TotalSegmentator output obtained through the plugin layer (adapter, DICOM SEG
export, host reader) with output from a direct call of the model on the same series, per
structure, on 7 TCIA series. Because a result of exactly 1.0 everywhere could mean the
comparison is blind, we first built perturbation probes and confirmed that the comparison
detects them. <!-- src: EVALUATION.md §3 -->

E3 measured peak memory and tested the arbiter. Peak memory was first measured per
process; it was then re-measured natively over the whole process tree, as the
`phys_footprint` of the adapter and all descendants summed and sampled every 0.2 s, because
nnU-Net starts worker processes. The arbiter was tested in scenarios executed against the
shipped Swift type rather than a re-implementation of its policy. <!-- src: EVALUATION.md
§1, §4 -->

E4 measured SAM 2 encode and decode times and the per-prompt overhead of an alternative
design: an implicit content-addressed embedding cache inside an ordinary resident server.
It also checked protocol round trips with real weights, decoding each returned mask with
the host's compiled Swift decoder. <!-- src: EVALUATION.md §5 -->

E5 ran nine checks on the packaged, signed application: adapters and manifest present, no
machine-specific paths, a virtual environment with pip created by the bundled
interpreter, every adapter parsing its command line under that interpreter before its
dependencies are installed, and a valid code signature. <!-- src: EVALUATION.md §6 -->

E6 measures end-to-end latency per engine and stage (cold start, warm inference, result
routing and display) through the host's own HTTP and command-line contract, on an idle
machine, on two Apple Silicon configurations. TODO(E6): describe machines, repetitions and
idle gate once run. <!-- src: eval/README.md, eval/exp6_latency.py -->

E7 places a click at the centroid of each reference structure on its central slice and
compares the SAM 2 and SAM 3 masks with the reference mask. Its purpose is to verify the
coordinate mapping between viewer, adapter and model, not to measure accuracy. For Gemma 4
E4B it checks the protocol round trip and whether returned boxes lie inside the image.
TODO(E7).

**Environment and reporting.** Each case produces one JSON record. Failures are recorded
rather than dropped. Each result file carries the machine profile, accelerator visibility
and package versions. <!-- src: eval/README.md --> Experiments E1–E5 ran in August 2026
inside an evaluation sandbox on an Apple M5 Max with 128 GB of memory. The sandbox exposed
no GPU to PyTorch and refused socket binds, so nnU-Net's process pools were replaced by
threads; this preserves correctness but not performance. Sandbox timings are therefore
CPU-only figures and are not presented as laptop performance. TotalSegmentator memory and
the arbitration scenarios were re-run natively in October 2026. <!-- src: EVALUATION.md §1
--> Plugin environments for E6 are built with the bundled interpreter and checked against
the dependency locks before each run. This check was added after we found that earlier
evaluation environments had been built with a different interpreter and had drifted
30–52 packages from the locks. <!-- src: PLAN.md E6 notes --> Memory is reported in GB
(10^9 bytes); wherever it is compared with a declaration, it is also given in GiB (2^30
bytes), the unit the arbiter uses.

**Statistics.** Results are descriptive: counts, minima, and median with interquartile
range (IQR). No hypothesis tests were performed. <!-- CONFIRM for E6/E7, e.g. bootstrap CI
on Dice. -->

---

# 3. Results

## 3.1 DICOM SEG conformance (E1)

dcmqi decoded every segment of every exported SEG losslessly: 30/30 structures across
6 cases at Dice 1.000000, with image size, spacing, origin and direction preserved
exactly. Of 14 Segmentation IOD field checks per file, 12 passed and none failed in any
file; the remaining two returned the warnings described below.
<!-- src: EVALUATION.md §2; exp1_conformance_audit.csv (14 checks × 6 cases; EVALUATION.md
says 15, which is stale) -->

Two warnings remain and constitute an interoperability defect. Every segment carries the
generic code "anatomical structure" as its SegmentedPropertyType, so a receiving system
cannot identify the structures by code; the specific anatomy survives only in the
free-text SegmentLabel. Descriptive fields (ContentDescription, ContentCreatorName,
SeriesDescription) are also absent. The fix is to map the model's label names to SNOMED CT
codes; this has not yet been done. <!-- src: EVALUATION.md §2; exp1_findings.md -->
Rendering in third-party viewers was not evaluated.

## 3.2 Pipeline fidelity (E2)

Across 7 TCIA series and 689 per-structure comparisons, the lowest Dice coefficient
between plugin-layer output and direct model output was 1.000000, with zero voxel
difference and zero unplaced frames. <!-- src: EVALUATION.md §3; exp2_tables.md Table 1 -->
The comparison is sensitive: it resolved a single altered voxel in a 432-voxel structure
(Dice 0.9988), a one-slice shift (0.667) and a dropped structure (0.0)
(Fig. 3). <!-- src: EVALUATION.md §3; exp2_probes.json -->

Before these results were obtained, the SEG export failed on every series in the
collection. The encoding library read the slice-thickness attribute (0018,0050)
unconditionally, but that attribute is Type 2 in the standard and all 411 instances of the
first series omitted it, so the adapter produced no SEG at all. The adapter now handles a
missing slice thickness. <!-- src: exp2_REPORT.md "Mechanism" -->

As a hygiene check, not an accuracy result, both paths were compared with expert reference
masks from the TotalSegmentator dataset. On the 4 of 6 cases that could be read (two were
rejected by ITK because of non-orthonormal direction cosines, and are recorded as
failures), mean Dice was 0.80–0.85 overall and 0.86–0.95 on large structures, identical on
both paths. <!-- src: EVALUATION.md §8; exp2_tables.md Table 2 --> This shows only that
neither path silently broke the model.

E2 also exposed a limitation of the `seg3d` output kind. It encodes segments into a single
labelmap, which clips overlapping structures; in a constructed case the liver lost 74,987
voxels to the stomach. No shipped adapter reaches this case, because TotalSegmentator
derives each structure from one integer labelmap and its structures are disjoint by
construction. <!-- src: EVALUATION.md §3 -->

## 3.3 Resources and arbitration (E3)

The arbiter matched its specification in 38 of 38 scenarios, covering eviction order,
non-evictability of busy and session-holding plugins, the exact-budget boundary,
live-headroom refusal and its override, the 75% share for oversized one-shots, and
exclusion of the requesting plugin from its own eviction plan. <!-- src: EVALUATION.md §4 -->

The inputs to that specification were wrong. TotalSegmentator declared 3.5 GB; its
measured single-process peak was 20.9–23.1 GB (19.4–21.5 GiB) over four runs, 5.5–6.1×
the declaration, reproduced on a second series. <!-- src: EVALUATION.md §4 --> On the
16 GB machine the policy was designed for, the original declaration would have admitted a
job that needs more than the whole machine (Fig. 2). A second defect compounded the first:
a running one-shot never entered the runtime-state table, so the heaviest process on the
machine was invisible to admission, and a resident engine could start alongside a
segmentation run. Both defects were fixed. The manifest now carries measured figures, tasks
can declare their own memory, and in-flight one-shots are counted and never evicted.
<!-- src: EVALUATION.md §4 -->

The corrected figure was itself low. Measured natively over the whole process tree, with
nnU-Net's worker processes alive through the inference peak, the peak over 10 runs on five
series reached 25.41 GB (23.66 GiB); the per-process figure reproduced at 22.4–23.7 GB on
the same runs. The `total` declaration was raised to 25.5. Of TotalSegmentator's low-memory
settings, only a single export worker lowered the peak, to 23.78 GB (22.15 GiB); this is
shipped as a `total_lowmem` task declared at 24.0, which the 75% share admits on a 32 GB
Mac where `total` needs 34 GiB. The `total_lowmem` task was run once, so its wall-time cost
is not established. No TotalSegmentator task fits a 16 GB Mac; the peak comes from CPU
inference and did not change with thread count or grid size. <!-- src: EVALUATION.md §4;
exp3_FINDINGS.md "Low-memory settings" --> <!-- TODO(E6): re-measure under torch 2.14.1;
October runs used 2.13.0. -->

Not every declaration was low. SAM 2 declared 3.0 GB and peaked at 1.45 GB (0.48×).
<!-- src: exp3_FINDINGS.md "Measured table" --> Gemma 4 E4B and SAM 3 peaks were not
measured in E3. TODO(E6): add from E6 if measured.

One cost was invisible to the adapter's own reporting. A TotalSegmentator invocation took
76.4 s as a subprocess but 71.2 s as the sum of the adapter's stages; the 5.2 s difference
is interpreter startup and the PyTorch/nnU-Net import chain, paid on every one-shot
invocation. <!-- src: exp3_FINDINGS.md "The corrected declaration, validated end to end";
CPU-only sandbox figure -->

## 3.4 Session model (E4)

Encoding a slice with SAM 2 cost 17.1× a decode (median over 30 encodes and 216 decodes;
per-slice range 13.7–20.8×). <!-- src: EVALUATION.md §5; exp4_session.csv --> The ratio
is large, but the alternative was cheap: an implicit content-addressed cache in an
ordinary resident server cost 1.8–4.7 ms per prompt, 2–5% of a decode (Fig. 4).
<!-- src: EVALUATION.md §5 --> The ratio therefore rules out not caching, but it does not
select the session lifecycle over a resident server that caches implicitly. What the
session model does provide is lifecycle control and an enforceable memory bound: a
declared `max_sessions` the host can hold the adapter to, and explicit release when the
user changes series. We report the original performance justification as not supported.

With real weights, SAM 2 completed 12 of 12 protocol round trips. Each returned mask was
decoded by the host's compiled Swift decoder and agreed with the adapter on foreground
count and first foreground index, which distinguishes a correct mask from its complement.
<!-- src: EVALUATION.md §5 -->

## 3.5 Deployability (E5)

The packaged application initially failed in three ways. The packaging script bundled only
the earlier single-engine server, so a packaged build found no adapters; this was hidden
during development because the environment locator falls back to the source tree.
Adapters run from inside the signed bundle wrote bytecode next to their sources, which
invalidated the code signature. The bundled interpreter did the same for its own standard
library on first import, a defect that predates the plugin layer. After all three were
fixed, the packaged application passed 9/9 checks. <!-- src: EVALUATION.md §6 -->

App Sandbox is disabled by design. An application that installs and runs plugins at
runtime cannot be sandboxed as the Mac App Store requires, so this architecture and that
distribution channel are mutually exclusive. <!-- src: EVALUATION.md §6 -->

A conformance kit for third-party adapters probes an adapter by running it rather than
reading its source. Each of its checks is paired with a deliberately broken fixture (24 in
total) that it must reject. All 54 checks passed on a platform permitting loopback binds.
<!-- src: EVALUATION.md §7 -->

## 3.6 End-to-end latency (E6)

TODO(E6). Report per engine and per stage (cold start, warm inference, result routing and
display), median (IQR), on M5 Max/128 GB and a 16 GB Apple Silicon Mac, on an idle machine.
For SAM 2, report "session open + first click" as the user-facing cold figure, since the
adapter reports ready before its model is loaded; later clicks are the warm figure. For
one-shots, include the interpreter-startup gap. Fig. 5.

## 3.7 Prompt-driven and VLM plugins on public CT (E7)

TODO(E7). SAM 2/3: per-structure Dice for a centroid click on the central slice, framed as
a coordinate-mapping check. Gemma 4 E4B: protocol round trip and box placement, reported
descriptively.

## 3.8 Defects found by evaluation

Table 3 summarises the defects that evaluation found after code review had passed them.
Each would have shipped.

**Table 3.** Defects found by evaluation. <!-- src: FOLLOWUP_PAPER_OUTLINE.md status
block; EVALUATION.md §4, §6; exp2_REPORT.md -->

| # | Defect | Found by | Consequence if shipped | Fix |
|---|---|---|---|---|
| 1 | TotalSegmentator declared 3.5 GB; measured peak 20.9–23.1 GB (5.5–6.1×), and 25.41 GB over the process tree | E3 | On 16 GB, admits a job larger than the machine | Measured declarations (25.5 / 24.0); per-task `ram_gb`; process-tree measurement |
| 2 | Running one-shot absent from the arbiter's runtime state | E3 | A resident engine admitted alongside the heaviest process | In-flight one-shots counted and non-evictable |
| 3 | SEG export required Type 2 SliceThickness | E2 | No SEG produced for any series in the public collection | Handle absent slice thickness |
| 4 | Packaged build: no adapters bundled; bytecode written into the signed bundle by adapters and by the bundled interpreter | E5 | Store lists nothing installable; signature broken on first launch | Bundle adapters; suppress bytecode writes in the bundle |

**Table 4.** Verification status per adapter. <!-- src: PLUGIN_ARCHITECTURE.md §8;
EVALUATION.md §5, §8 -->

| Adapter | Verified by execution | Not verified, and why |
|---|---|---|
| TotalSegmentator | End-to-end on TCIA CT (E2, 7 series); SEG conformance (E1); native process-tree memory (E3) | Accuracy (not claimed); GPU (ships CPU-only) |
| SAM 2 | 12/12 protocol round trips with real weights; mask decoded by host (E4) | Accuracy; TODO(E7) coordinate-mapping check |
| SAM 3 | Protocol conformance; licence gate | Inference: gated weights unavailable in the August campaign — TODO(E7) |
| Gemma 4 E4B | Protocol conformance | Inference: no MLX runtime in the August campaign — TODO(E6/E7) |

---

# 4. Discussion

## 4.1 Principal findings

A single declarative contract hosted four models that share no execution axis, with no
per-model code in the viewer. Results reach the user through routing by declared output
kind, and segmentation output is standard DICOM SEG that an independent implementation
decodes losslessly. The plugin layer itself introduced no loss: across 689 comparisons the
layer reproduced the model's direct output exactly, and the comparison was shown to detect
a single-voxel change.

The main lesson concerns trust rather than mechanism. The arbiter was correct against its
specification in every scenario tested, yet it would have admitted a job larger than the
target machine, because its specification takes a plugin's self-declared memory as given.
Correct policy over incorrect declarations is still unsafe. A host that admits work against
declared resources must audit those declarations against measurement, and the measurement
must match how the plugin actually runs: the corrected TotalSegmentator figure was still
1.9 GB low until worker processes were counted.

## 4.2 What review missed and evaluation found

All four defects in Table 3 passed code review, and each was found only by running the
software on public data or in its packaged form. They share a feature: each sits at a
boundary that reading one side of the code does not reveal. The memory defect lies between
a manifest figure and a process tree; the invisible one-shot between the arbiter's state
table and the process supervisor; the SEG failure between a library's assumptions and what
the standard permits real scanners to omit; the packaging defects between the development
tree and a signed bundle. The session-model experiment is a fifth case of the same kind,
where measurement weakened a design justification rather than exposing a bug.

We think systems papers in this area should report defects found by evaluation rather than
present uniformly passing checks. A table in which everything passes tells a reviewer
little about how hard the system was tested; a table of what failed, and why, does.

## 4.3 Comparison with existing integration approaches

Existing frameworks place inference on a server or platform: MONAI Label serves models to
client viewers [6], Kaapana runs containerised workflows on institutional
infrastructure [7], and OHIF and 3D Slicer extensions commonly call such services
or run on research workstations [4,5]. These designs scale to
institutions and to GPU-heavy models. The design described here targets a different point:
a single consumer laptop, no network service, and several models whose combined footprint
exceeds the machine's memory. In that setting the contract has to carry what a server
platform handles by provisioning, namely process lifetime and memory admission. Keeping
inference on the device also removes the transmission of images that remote inference
requires [3], and fixing the installable set
at build time removes the remote-code channel that a conventional marketplace opens.

## 4.4 Limitations

- **Isolation is by process and virtual environment, not by sandbox.** A plugin runs with
  the user's privileges. The invariants are enforced by review of in-tree adapters, not by
  a technical boundary. A store accepting third-party adapters would need one, and this is
  the main obstacle to an open ecosystem.
- **Declared memory is a claim the host trusts.** The arbiter enforces admission against
  declarations, not against live consumption, and the auditing reported here was done
  offline.
- **Platform.** The software runs on macOS and Apple Silicon only, and MLX is
  platform-specific. TotalSegmentator runs on the CPU, as it ships.
- **Measurement conditions.** E1–E5 ran in a sandbox with no visible GPU and with process
  pools replaced by threads, so their timings are CPU-only figures. TODO(E6): restate once
  native, idle, two-machine latency is available.
- **2D prompts.** Prompt-driven segmentation returns per-slice 2D masks; propagating a prompt
  through a volume is not implemented.
- **Overlapping structures.** The `seg3d` labelmap encoding clips overlapping structures.
  No shipped adapter reaches this case, but a future adapter with overlapping outputs would.
- **Coded anatomy.** Exported segments carry a generic property code, which limits
  interoperability with systems that rely on coded anatomy.
- **No accuracy or clinical validation.** No output of any plugin was validated clinically.
  The software is for research use only.

## 4.5 Future work

The next steps are a sandbox boundary for third-party adapters and coded anatomy (SNOMED
CT) in exported SEG. For oncology, we plan volumetric tumour segmentation on pancreatic CT
and support for DICOM whole-slide images, so that radiology and pathology images can be
read with local AI in one viewer.

---

# 5. Conclusions

A single declarative contract with three execution models can host heterogeneous AI models
locally inside a DICOM viewer, without per-model changes to the viewer and without images
leaving the device. Evaluation on public CT showed that the layer adds no loss and writes
standard segmentation objects. It also found four defects that code review had passed, the
most consequential being a self-declared memory figure that an otherwise correct arbiter
would have trusted. Hosts that arbitrate local AI models against declared resources should
audit those declarations against measurement.

---

# Declarations

**CRediT authorship contribution statement:** <!-- CONFIRM -->

**Declaration of competing interest:** <!-- CONFIRM -->

**Funding:** <!-- CONFIRM -->

**Data availability:** All data are public. Series identifiers are pinned in
`eval/fetch_data.py`, and raw results are in `eval/results/`.

**Code availability:** https://github.com/Essential-Citronnier/ODV-Annotate (MIT).
CONFIRM: archive a tagged release on Zenodo and cite the DOI.

**Declaration of generative AI use:** <!-- CONFIRM: Elsevier requires a statement if
AI tools assisted writing; state tool and purpose. -->

**Ethics:** Public de-identified data only; no human subjects research.
<!-- CONFIRM -->

---

# References

<!-- Numbered in order of first citation. Source of truth with verification notes:
docs/paper/references.md. Copy the list here at submission. -->

See `references.md` (22 entries).

---

# Figure legends

**Figure 1.** Architecture of the plugin layer. The host reads a manifest shipped in the
signed application and supervises plugins under one of three execution models (resident
server, session, one-shot). Results are routed by declared output kind. Each plugin runs in
its own process and virtual environment; licence gates and the memory arbiter sit between
the store and execution. (`docs/figures/plugin_architecture.png`)

**Figure 2.** Declared versus measured peak memory, and arbiter decisions. (A) Declared
`ram_gb` for TotalSegmentator at each stage of its declaration (3.5 → 23.5 → 25.5 / 24.0)
and for SAM 2, against measured peak, in GiB. (B) Decisions of the shipped arbiter on 16 GB
and 32 GB configurations under the original and corrected declarations.
(`docs/figures/fig_declared_vs_measured.png`)

**Figure 3.** Pipeline fidelity. Per-structure Dice between plugin-layer and direct model
output on 7 TCIA series, with perturbation probes (single voxel, one-slice shift, dropped
structure) showing the comparison's sensitivity. (`eval/figures/exp2_fidelity.png`)

**Figure 4.** Session model. SAM 2 encode and decode cost, and per-prompt overhead of an
implicit embedding cache in a resident server. CPU-only sandbox figures.
(`eval/figures/exp4_encode_decode.png`)

**Figure 5.** TODO(E6): per-stage latency by engine and machine.

<!-- CONFIRM display-item allowance; consider moving Fig. 3/4 to supplementary. -->
