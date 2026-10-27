<!--
Manuscript for Computer Methods and Programs in Biomedicine (CMPB, Elsevier).
Status: FULL DRAFT. §3.6 (E6) and §3.7 (E7) are filled from eval/results once their runs finish.

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

**Authors:** Daeseong Kim^1^, JoonNyung Heo^2,\*^
<!-- CONFIRM: author order and ORCID iDs. Author list settled 2026-10-18 as the two
contributors to this work; the ten-author list of the host-viewer paper [6] is not
carried over. Confirm with the co-authors of [17] before submission. -->

**Affiliations:**
^1^ <!-- CONFIRM: department, institution, city, country --> ^2^ <!-- CONFIRM:
department, institution, city, country -->

**Corresponding author (\*):** <!-- CONFIRM: name, full postal address, email -->

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

**Background and Objective:** AI in an image viewer usually means one integration per
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
declaration, which its own health report did not reveal. Evaluation found four defect
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
daily work, rather than validating them, is the reported bottleneck [3,4]. Two
integration patterns dominate. The first sends images to a remote inference service.
This is simple for the viewer, but it moves patient data off the device and makes the
viewer's behaviour depend on a network service the user does not control [5]. The second
integrates each model directly into the viewer. This keeps data local, but every new
model adds its own private integration to the viewer's core, and the cost never
amortises.

The difficulty is that models useful in an imaging workflow share almost nothing at the
level a viewer has to manage. A vision–language model is expensive to load and cheap to
query, so it should stay resident. A promptable segmenter spends most of its time
encoding an image, which is then reused by many cheap decodes, so it holds per-image
state. A whole-body segmenter runs for minutes on a full series and is used rarely, so
it should start, compute and exit. The same models differ in what they consume (a
rendered slice, a slice with clicks, a whole volume), in what they produce (text and
boxes, 2D masks, 3D DICOM Segmentation objects), in peak memory, in Python dependencies
that cannot share an environment, and in the licence terms that govern their weights
(Table 1). A contract between a viewer and its models must accommodate all of these at
once, without the viewer knowing which model it is talking to.

A clinical setting adds a constraint that changes the design. Fetching executable code
at runtime, as a conventional plugin marketplace does, is hard to justify for software
that handles patient images. We therefore fixed the set of installable plugins at build
time. The manifest ships inside the signed application, adapter code is versioned and
reviewed with the host, and the only network activity permitted is downloading model
weights and dependencies from URLs fixed before release. This choice, rather than the
user interface, is what separates the design from a conventional plugin store.

Extension mechanisms already exist in medical imaging, at three scales. Desktop research
applications are extensible by design: 3D Slicer offers a large extension ecosystem [6],
MITK composes interactive tools over VTK and ITK [7], and ITK-SNAP combines manual and
semi-automatic segmentation [8]. Web and lightweight viewers add their own extension
points, from OHIF [9] to browser-based DICOM viewers built for low-cost deployment [10].
At the infrastructure scale, XNAT [11], Orthanc [12] and the NCI Imaging Data Commons
[13] manage images and pipelines around the viewer, while MONAI supplies the model-side
framework [14], MONAI Label serves interactive models to client viewers [15], and
Kaapana orchestrates containerised analysis on a hospital platform [16]. These systems
generally assume a server, a dedicated GPU or a research workstation. Local execution
itself is not new: 3D Slicer extensions run TotalSegmentator and MONAI models on a
workstation without a server. What we have not found elsewhere are the two properties
this design turns on: a host that arbitrates admission across coexisting models against
declared memory bounds it enforces itself, and an installable set fixed at build time
rather than fetched at runtime.

This paper describes and evaluates such a plugin layer, built on an open-source macOS
DICOM viewer [17]. Its contributions are:

1. A declarative plugin contract and three execution models (resident server, session,
   one-shot) that host four heterogeneous models with no per-model changes to the viewer.
2. An evaluation on public CT that is reproducible from pinned series identifiers,
   covering standard conformance, pipeline fidelity, resource arbitration, the session
   model, deployability, end-to-end latency, and a coordinate-mapping check of the
   prompt-driven and vision–language plugins.
3. Evidence that evaluation, rather than code review, found the architecture's defects.
   The clearest case is a self-declared memory figure about six times too low, which an
   arbiter correct against its own specification would still have admitted; a second
   plugin's declaration was also low, and its own health report agreed with the
   declaration rather than with the measurement.
4. Open-source code under the MIT licence.

We make no claim about the accuracy or clinical utility of any model. The models are
used unmodified, and their accuracy is reported in their original publications
[18,19,20,21,22]. How well promptable segmenters transfer to medical images is an active
and contested question in its own right [23,24,25,26], and it is not the question this
paper asks.

---

# 2. Methods

## 2.1 Host application

The host is OpenDicomViewer, a native macOS DICOM viewer written in Swift with Metal
rendering, multiplanar reformation, maximum intensity projection and measurement tools
[17]. The published viewer integrated a single vision–language model through a fixed
local server, with a fixed port, fixed endpoints and one Python environment. This work
replaces that integration with a general plugin layer. The viewer's rendering and DICOM
handling are unchanged. The application targets macOS 14 or later on Apple Silicon. It
bundles a Python interpreter, and each plugin is installed into its own virtual
environment created with that interpreter. <!-- src: README.md -->

## 2.2 Plugin contract

Each plugin is described by an entry in a manifest that ships inside the application
bundle. The entry declares the plugin's execution model; its tasks; for each task, the
input and output kinds it uses; its peak memory (`ram_gb`, read by the host as GiB) and
disk footprint; the licence state of its weights; and the URLs and checksums of the
weights it may download. A task may override the plugin-level memory figure, because
tasks within one plugin can differ materially in footprint (§3.3). <!-- src:
PLUGIN_PROTOCOL.md; PLUGIN_ARCHITECTURE.md §2 -->

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
  Gemma 4 E4B served through MLX [27].
- **Session.** A resident server that also holds per-image state. It suits models with
  an expensive encode that many cheap decodes reuse, such as the SAM family
  [23,19,20]: one slice is encoded, then re-prompted
  interactively with clicks and boxes. The adapter declares a maximum number of open
  sessions (`max_sessions`) and evicts the least recently used; the host releases
  sessions explicitly when the user changes series.
- **One-shot.** A subprocess per invocation that loads, computes, writes its result and
  exits. It suits heavyweight models used rarely, such as TotalSegmentator
  [18], built on nnU-Net [28].

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

TotalSegmentator ships a third task, `heartchambers_highres`, which declares no per-task
figure and inherits the plugin-level 25.5; its peak was not measured. <!-- src:
Sources/OpenDicomViewer/Resources/plugins.json -->

## 2.4 Result routing, licence gates and environment isolation

**Routing.** Each task declares what it consumes and produces from a closed vocabulary.
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

## 2.5 Memory arbitration

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

## 2.6 Evaluation design

**Data.** We used 12 CT series from The Cancer Imaging Archive (TCIA) *CT Lymph Nodes*
collection, 6 abdominal and 6 mediastinal, with 148–493 slices each <!-- src:
eval/fetch_data.py PINNED_TCIA --> [31,32,33]. Series identifiers are pinned in the
acquisition script rather than discovered by query, because archive query results are
not stable across API revisions. For the hygiene check in §3.2 we also used cases from
the TotalSegmentator reference dataset (Zenodo record 10047292, CC BY 4.0) <!-- src:
eval/fetch_data.py --> [34], which E7 also uses. All data are public and de-identified, and their use required no
ethics approval or data use agreement. <!-- CONFIRM wording with the institution -->

**Experiments.** Seven experiments addressed the questions in Table 2.

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

**Statistics.** Results are descriptive: counts, minima, and median with interquartile
range (IQR). No hypothesis tests were performed. <!-- CONFIRM for E6/E7, e.g. bootstrap
CI on Dice. -->

---

# 3. Results

## 3.1 DICOM SEG conformance (E1)

dcmqi decoded every segment of every exported SEG losslessly: 30/30 structures across 6
cases at Dice 1.000000, with image size, spacing, origin and direction preserved
exactly. Each file was audited against 14 Segmentation IOD field requirements, giving 84
checks over the 6 cases: 72 passed, 12 returned warnings from the two checks described
below, and none failed. <!-- src: EVALUATION.md §2; exp1_conformance_audit.csv, 14
checks × 6 cases -->

Two warnings remain and constitute an interoperability defect. Every segment carries the
generic code "anatomical structure" as its SegmentedPropertyType, so a receiving system
cannot identify the structures by code; the specific anatomy survives only in the
free-text SegmentLabel. Descriptive fields (ContentDescription, ContentCreatorName,
SeriesDescription) are also absent. The fix is to map the model's label names to SNOMED
CT codes; this has not yet been done. <!-- src: EVALUATION.md §2; exp1_findings.md -->
Rendering in third-party viewers was not evaluated.

## 3.2 Pipeline fidelity (E2)

Across 7 TCIA series and 689 per-structure comparisons, the lowest Dice coefficient
between plugin-layer output and direct model output was 1.000000, with zero voxel
difference and zero unplaced frames. <!-- src: EVALUATION.md §3; exp2_tables.md Table 1
--> The comparison is sensitive: it resolved a single altered voxel in a 432-voxel
structure (Dice 0.9988), a one-slice shift (0.667) and a dropped structure (0.0) (Fig.
3). <!-- src: EVALUATION.md §3; exp2_probes.json -->

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

## 3.3 Resources and arbitration (E3)

The arbiter matched its specification in 38 of 38 scenarios, covering eviction order,
non-evictability of busy and session-holding plugins, the exact-budget boundary,
live-headroom refusal and its override, the 75% share for oversized one-shots, and
exclusion of the requesting plugin from its own eviction plan. <!-- src: EVALUATION.md
§4 -->

The inputs to that specification were wrong. TotalSegmentator declared 3.5 GB; its
measured single-process peak was 20.9–23.1 GB (19.4–21.5 GiB) over four runs, 5.5–6.1×
the declaration, reproduced on a second series. <!-- src: EVALUATION.md §4 --> On the 16
GB machine the policy was designed for, the original declaration would have admitted a
job that needs more than the whole machine (Fig. 2). A second defect compounded the
first: a running one-shot never entered the runtime-state table, so the heaviest process
on the machine was invisible to admission, and a resident engine could start alongside a
segmentation run. Both defects were fixed. The manifest now carries measured figures,
tasks can declare their own memory, and in-flight one-shots are counted and never
evicted. <!-- src: EVALUATION.md §4 -->

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

Not every declaration was low. SAM 2 declared 3.0 and peaked at 1.45 GB (1.35 GiB),
0.45× its declaration. <!-- src: exp3_FINDINGS.md "Measured table" --> The peaks of
Gemma 4 E4B and SAM 3 were not measured, so two of the four declarations in Table 1
remain unaudited — a gap in the very property this paper argues a host must check.
E7 measured them natively, on the GPU, over the process tree. The Gemma 4 E4B plugin
peaked at 7.66–7.72 GiB in each of 4 runs, 1.54 times its declared 5.0. The plugin's own
health report gave 4,910.7 MB, because it reports the MLX allocator's peak, which covers
the model's arrays but not the interpreter, the image pipeline or generation; it
therefore agreed with the declaration and gave no sign of the gap. SAM 2 on the GPU
peaked at 2.74 GiB, under its declared 3.0 but twice its CPU figure, so a declaration
measured on one device does not carry to another. On the 16 GB machine the arbiter
targets, the declared figures for Gemma and SAM 2 sum to 8.0 GiB and are admitted
together under the 8 GiB budget; their measured peaks sum to 10.46 GiB. <!-- src: exp7
summary "peak_memory_gib" and per-case metrics.memory; exp6 health_memory_mb; plugins.json
--> SAM 3 could not be measured, because its gated weights were not obtained (Table 4).
<!-- CONFIRM: if the Gemma declaration is raised before submission, add the new figure here
and to Table 3. -->

One cost was invisible to the adapter's own reporting. A TotalSegmentator invocation
took 76.4 s as a subprocess but 71.2 s as the sum of the adapter's stages; the 5.2 s
difference is interpreter startup and the PyTorch/nnU-Net import chain, paid on every
one-shot invocation. <!-- src: exp3_FINDINGS.md "The corrected declaration, validated
end to end"; CPU-only sandbox figure -->

## 3.4 Session model (E4)

Encoding a slice with SAM 2 cost 17.1× a decode (median over 30 encodes and 216 decodes;
per-slice range 13.7–20.8×). <!-- src: EVALUATION.md §5; exp4_session.csv --> The ratio
is large, but the alternative was cheap: an implicit content-addressed cache in an
ordinary resident server cost 1.8–4.7 ms per prompt, 2–5% of a decode (Fig. 4). <!--
src: EVALUATION.md §5 --> The ratio therefore rules out not caching, but it does not
select the session lifecycle over a resident server that caches implicitly. What the
session model does provide is lifecycle control and an enforceable memory bound: a
declared `max_sessions` the host can hold the adapter to, and explicit release when the
user changes series. We report the original performance justification as not supported.

With real weights, SAM 2 completed 12 of 12 protocol round trips. Each returned mask was
decoded by the host's compiled Swift decoder and agreed with the adapter on foreground
count and first foreground index, which distinguishes a correct mask from its
complement. <!-- src: EVALUATION.md §5 -->

## 3.5 Deployability (E5)

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

## 3.6 End-to-end latency (E6)

Of the cases run, those that met the idle gate were 8 of 10 cold starts for the built-in
Gemma server, 5 of 10 for the Gemma plugin, 10 of 10 for SAM 2, and 11 of 15 and 15 of 15
TotalSegmentator runs for `total` and `total_lowmem`; only these are reported (Fig. 5). All
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

## 3.7 Prompt-driven and VLM plugins on public CT (E7)

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

## 3.8 Defects found by evaluation

Table 3 summarises the defects that evaluation found after code review had passed them.
Each would have shipped. They are counted as four classes; the packaging class (row 4)
bundles the three distinct failures described in §3.5.

**Table 3.** Defects found by evaluation, grouped into four classes. <!-- src: FOLLOWUP_PAPER_OUTLINE.md status
block; EVALUATION.md §4, §6; exp2_REPORT.md -->

| # | Defect | Found by | Consequence if shipped | Fix |
|---|---|---|---|---|
| 1 | Self-declared memory too low. TotalSegmentator declared 3.5 GB; measured peak 20.9–23.1 GB (5.5–6.1×), and 25.41 GB over the process tree. Gemma 4 E4B declared 5.0; measured 7.72 GiB (1.54×), while its health report gave 4,910.7 MB | E3, E7 | On 16 GB, admits a job larger than the machine; admits Gemma with SAM 2 at 10.46 GiB measured against an 8 GiB budget | TotalSegmentator: measured declarations (25.5 / 24.0), per-task `ram_gb`, process-tree measurement. Gemma: see §3.3 |
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
per-model code in the viewer. Results reach the user through routing by declared output
kind, and segmentation output is standard DICOM SEG that an independent implementation
decodes losslessly. The plugin layer itself introduced no loss: across 689 comparisons
the layer reproduced the model's direct output exactly, and the comparison was shown to
detect a single-voxel change.

The main lesson concerns trust rather than mechanism. The arbiter was correct against
its specification in every scenario tested, yet it would have admitted a job larger than
the target machine, because its specification takes a plugin's self-declared memory as
given. Correct policy over incorrect declarations is still unsafe. This was not one bad
number: of the three plugins whose peaks we could measure, two had declared too little.
A host that admits work against declared resources must audit those declarations against
measurement, and the measurement must match how the plugin actually runs. The corrected
TotalSegmentator figure was still 1.9 GB low until worker processes were counted; the
SAM 2 figure doubled between CPU and GPU; and the Gemma plugin's own health report,
which a host might be tempted to use as the audit, measured the model's arrays rather
than the process and agreed with the wrong declaration. The audit has to be external to
the plugin.

Through the host's contract the layer was also fast enough to use interactively: a click
on an open SAM 2 session returned in about 11 ms, a Gemma request in about a second, and
a whole-body segmentation in about a minute, with no measurable difference between the
Gemma plugin and the viewer's earlier built-in server. Two timing traps mirrored the
memory finding. SAM 2 reported "ready" before loading its model, and on the GPU it
reported an encode time that excluded the work it had queued. Both are self-reports that
a host would take at face value, and both were corrected only by timing from outside the
process.

## 4.2 What review missed and evaluation found

All four defects in Table 3 passed code review, and each was found only by running the
software on public data or in its packaged form. They share a feature: each sits at a
boundary that reading one side of the code does not reveal. The memory defect lies
between a manifest figure and a process tree; the invisible one-shot between the
arbiter's state table and the process supervisor; the SEG failure between a library's
assumptions and what the standard permits real scanners to omit; the packaging defects
between the development tree and a signed bundle. The session-model experiment is a
fifth case of the same kind, where measurement weakened a design justification rather
than exposing a bug.

The practical consequence is for evaluation design rather than for reporting style.
Tests written from one side of an interface — the manifest, the arbiter's state table,
the development tree — cannot reach these defects at all, however many of them are
written. Each was reached only by exercising the boundary itself: measuring the process
tree the manifest describes, running the arbiter against a live supervisor, feeding the
encoder series that omit a Type 2 attribute, and testing the signed bundle rather than
the source tree. We report the failures alongside the passes because a table in which
everything passes does not tell a reader which of the two kinds of test was run.

## 4.3 Comparison with existing integration approaches

Existing frameworks place inference on a server or platform: MONAI Label serves models
to client viewers [15], Kaapana runs containerised workflows on institutional
infrastructure [16], and OHIF and 3D Slicer extensions commonly call such services or
run on research workstations [6,9]. These designs scale to institutions and to GPU-heavy
models. The design described here targets a different point: a single consumer laptop,
no network service, and several models whose combined footprint exceeds the machine's
memory. In that setting the contract has to carry what a server platform handles by
provisioning, namely process lifetime and memory admission. Keeping inference on the
device also removes the transmission of images that remote inference requires [5], and
fixing the installable set at build time removes the remote-code channel that a
conventional marketplace opens.

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
  pools replaced by threads, so their timings are CPU-only figures. E6 and E7 are native
  but were run on one high-end machine; the 16 GB configuration the arbiter is designed
  around was analysed through the arbiter's decisions (E3), not timed. Cold starts were
  measured without flushing the file cache. Half of the Gemma plugin's cold starts, and 4
  of 15 `total` runs, did not meet the idle gate and were excluded. TotalSegmentator's
  peak memory was measured under PyTorch 2.13.0, not under the 2.14.1 the plugin now locks.
- **SAM 3 was not executed.** Its weights are gated by the vendor and were not obtained,
  so its declaration is unaudited and its inference unverified; the contract's claim to
  host it rests on protocol conformance alone.
- **2D prompts.** Prompt-driven segmentation returns per-slice 2D masks; propagating a prompt
  through a volume is not implemented.
- **Overlapping structures.** The `seg3d` labelmap encoding clips overlapping structures.
  No shipped adapter reaches this case, but a future adapter with overlapping outputs would.
- **Coded anatomy.** Exported segments carry a generic property code, which limits
  interoperability with systems that rely on coded anatomy [38].
- **No accuracy or clinical validation.** No output of any plugin was validated clinically,
  and this work makes none of the claims a clinical AI study would have to support
  [40]. Nothing here is a regulated device, and nothing here was evaluated
  as one [41]. The software is for research use only.

## 4.5 Future work

The next steps are a sandbox boundary for third-party adapters and coded anatomy (SNOMED
CT) in exported SEG. Adding an MR-capable segmenter [42] would also test whether a
task-level declaration is enough to describe a second modality. For oncology, we plan
volumetric tumour segmentation on pancreatic CT and support for DICOM whole-slide
images, so that radiology and pathology images can be read with local AI in one viewer.

---

# 5. Conclusions

A single declarative contract with three execution models can host heterogeneous AI
models locally inside a DICOM viewer, without per-model changes to the viewer and
without images leaving the device. Evaluation on public CT showed that the layer adds no
loss, writes standard segmentation objects, and returns interactive results in
milliseconds to seconds. It also found four classes of defect that code review had
passed, the most consequential being self-declared memory figures, low for two of the
three plugins measured, that an otherwise correct arbiter would have trusted. Hosts that arbitrate local AI models
against declared resources should audit those declarations against measurement.

---

# Declarations

**CRediT authorship contribution statement:**
<!-- CONFIRM. Template for the two-author list; delete roles that do not apply. Daeseong
Kim: Conceptualization, Methodology, Software, Validation, Formal analysis,
Investigation, Data curation, Writing – original draft, Visualization. JoonNyung Heo:
Conceptualization, Software, Resources, Writing – review & editing, Supervision, Project
administration. -->

**Declaration of competing interest:** <!-- CONFIRM. Elsevier requires an explicit
statement even when there is nothing to declare; the authors must assert this
themselves. Suggested wording if true: "The authors declare that they have no known
competing financial interests or personal relationships that could have appeared to
influence the work reported in this paper." -->

**Funding:** <!-- CONFIRM. If none: "This research did not receive any specific grant from
funding agencies in the public, commercial, or not-for-profit sectors." -->

**Ethics:** This study used only publicly available, de-identified imaging data and
involved no human subjects research; institutional review board approval and informed
consent were therefore not required. <!-- CONFIRM this wording with the institution. -->

**Data availability:** All data are public. The exact series are pinned by
SeriesInstanceUID in `eval/fetch_data.py`; raw per-case results are in `eval/results/`.

**Code availability:** https://github.com/Essential-Citronnier/ODV-Annotate (MIT licence).
<!-- CONFIRM: archive a tagged release on Zenodo and cite the DOI here and in the
reference list. Not yet done as of 2026-10-18. -->

**Declaration of generative AI and AI-assisted technologies in the writing process:**
During the preparation of this work the authors used Claude (Anthropic) to draft and
revise manuscript text, to write evaluation and figure-generation scripts, and to
retrieve bibliographic metadata from Crossref and DataCite. Every number in the
manuscript was copied from the evaluation result files, and every reference was checked
against its DOI record. After using this tool, the authors reviewed and edited the
content as needed and take full responsibility for the content of the published article.
<!-- CONFIRM: authors to review this wording; Elsevier places it before the references. -->

---

# References

<!-- Numbered in order of first citation. Source of truth with verification notes:
docs/paper/references.md. Copy the list here at submission. -->

See `references.md` (42 entries).

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

**Figure 3.** Pipeline fidelity. Per-structure Dice between plugin-layer and direct model
output on 7 TCIA series, with perturbation probes (single voxel, one-slice shift,
dropped structure) showing the comparison's sensitivity.
(`eval/figures/exp2_fidelity.png`)

**Figure 4.** Session model. SAM 2 encode and decode cost, and per-prompt overhead of an
implicit embedding cache in a resident server. CPU-only sandbox figures.
(`eval/figures/exp4_encode_decode.png`)

**Figure 5.** End-to-end latency through the host's contract on an Apple M5 Max (128 GB),
idle-gated runs only. (A) New process to first result for each server engine; for SAM 2
this includes the first session open and click. (B) Warm requests, log scale; SAM 2
encode is session open plus the first click. (C) TotalSegmentator per run: median
adapter stages (bars) and median process wall time (|). (`eval/figures/exp6_latency.png`)

<!-- CONFIRM display-item allowance; consider moving Fig. 3/4 to supplementary. -->
