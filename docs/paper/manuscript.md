<!--
Manuscript skeleton for Computer Methods and Programs in Biomedicine (CMPB, Elsevier).
Status: SKELETON. Each section lists the points to make and the numbers it will carry.

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

**Methods:** We extended an open-source macOS DICOM viewer [REF: Heo et al., JIIM 2026]
with a plugin layer: a manifest schema, three execution models (resident server, session,
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

Points to make, in order:

1. **Problem.** Clinicians and researchers increasingly want AI assistance *inside* the
   viewer they already use. Today the options are cloud services, which transmit
   patient data off the device, or per-model integrations that do not scale.
   [REF: cloud AI in radiology / privacy] [REF: AI integration into PACS/viewers]
2. **Why it is hard.** Models differ on every axis at once (Table 1): process lifetime,
   memory, I/O type, dependency stack, licence. A contract must accommodate all of
   them without the viewer knowing any one model.
3. **Constraint that shapes the design.** In a clinical context, fetching executable code
   at runtime is unacceptable. The installable set must be fixed and auditable at build
   time. Only model weights may be fetched. This is what separates the design from a
   conventional plugin marketplace.
4. **Related work (short).** Plugin and extension systems exist in 3D Slicer, OHIF,
   MONAI Label and Kaapana [REF each]. They assume a server, a GPU or a research
   workstation. None targets fully local inference on a consumer laptop with enforced
   memory bounds. CONFIRM this claim after a literature check.
5. **Contributions.**
   - (i) A declarative plugin contract and three execution models that host four
     heterogeneous models without per-model viewer changes.
   - (ii) An evaluation on public data, reproducible from pinned series identifiers.
   - (iii) Evidence that evaluation, not review, found the architecture's defects. The
     clearest case is self-declared memory 6× too low, which motivates auditing
     declarations.
   - (iv) Open-source code under MIT.
6. **Explicit non-claim.** No claim is made about model accuracy or clinical utility. The
   models are used unmodified and their accuracy is published elsewhere.

---

# 2. Methods

## 2.1 Host application

- Base viewer: OpenDicomViewer (Swift, Metal; MPR, MIP, measurement tools)
  [REF: Heo et al., JIIM 2026]. State briefly what this work adds on top of it.
- Platform: macOS 14+, Apple Silicon. Python runtime bundled with the app; each plugin
  gets its own virtualenv. <!-- src: README.md -->

## 2.2 Plugin contract

- Manifest schema: capabilities, execution model, per-task declared memory (`ram_gb`,
  read as GiB), licence state, pinned weights. <!-- src: PLUGIN_PROTOCOL.md -->
- Design invariants (cite numbers from PLUGIN_ARCHITECTURE.md §2). Invariant 4: a plugin
  that under-declares is starved rather than allowed to thrash.
- No remote code: the manifest ships inside the signed app, and only weights are fetched.

## 2.3 Execution models

- `resident-server`, `session`, `one-shot`. Define each in one or two sentences.
  <!-- src: PLUGIN_ARCHITECTURE.md §3 -->
- Table 1: heterogeneity of the four models across axes.

## 2.4 Result routing, licence gates, environment isolation

- Routing by declared output kind (boxes, 2D mask, 3D SEG). <!-- src: PLUGIN_ARCHITECTURE.md §4 -->
- Licence gates as a first-class install state. <!-- src: §5 -->
- Isolation by process and virtualenv, not by sandbox. Say so here, and again in
  Limitations. <!-- src: §7 -->

## 2.5 Memory arbitration

- Admission against physical memory. Eviction order; busy and session-holding plugins
  are never evicted. A 0.75 share applies to oversized one-shots; a "Start Anyway"
  override exists. <!-- src: EVALUATION.md §4; PLUGIN_ARCHITECTURE.md §6 -->

## 2.6 Evaluation design

**Data.**
- 12 pinned CT series from the TCIA *CT Lymph Nodes* collection: 6 abdomen and
  6 mediastinum, 148–493 slices. <!-- src: eval/fetch_data.py PINNED_TCIA --> [REF: TCIA; collection DOI]
- TotalSegmentator reference dataset (Zenodo record 10047292, CC BY 4.0).
  <!-- src: eval/fetch_data.py --> [REF: Wasserthal et al.]
- TODO(E7, optional): a few TCIA *Pancreas-CT* series, for anatomical diversity.
- All data public and de-identified; no ethics approval or data use agreement needed.
  <!-- CONFIRM wording with the institution -->

**Experiments.**

| # | Question | Metric |
|---|---|---|
| E1 | Is the exported DICOM SEG read correctly by a third party? | dcmqi round-trip Dice; 15-item IOD field audit |
| E2 | Is routing through the plugin layer lossless? | per-structure Dice vs direct model call; perturbation probes |
| E3 | Do declared resources match measured ones, and does arbitration follow the spec? | process-tree peak memory; scenario pass rate |
| E4 | Does the session model pay for itself? | encode/decode cost ratio; implicit-cache overhead |
| E5 | Does the packaged app work as shipped? | 9 deployability checks |
| E6 | End-to-end latency on real hardware | per-stage wall time, median (IQR), ≥2 machines — TODO |
| E7 | Do prompt-driven and VLM plugins return correct output on public CT? | SAM 2/3 click-prompt Dice vs reference mask; Gemma round trip — TODO |

**Environment and reporting.** One JSON record per case. Failures are recorded, not
dropped. Each result file carries the machine profile, accelerator visibility and
package versions. <!-- src: eval/README.md --> Memory is reported in GB (10^9 bytes);
wherever it is compared with a declaration, it is also given in GiB.

**Statistics.** Descriptive only: median (IQR); n per cell. No hypothesis tests are
needed for E1–E5. CONFIRM for E6/E7, e.g. bootstrap CI on Dice.

---

# 3. Results

## 3.1 DICOM SEG conformance (E1)
- 30/30 structures decoded losslessly by dcmqi across 6 cases. Direction, spacing and
  origin preserved. All 15 IOD checks pass. <!-- src: EVALUATION.md §2 -->
- Two warnings: a generic SegmentedPropertyType, and missing descriptive fields. Report
  these as an interoperability defect. <!-- src: exp1_findings.md -->
- State the provenance caveat: the encoder is the shipped one, but the masks were
  synthetic in this run.

## 3.2 Pipeline fidelity (E2)
- 689 comparisons on 7 series; minimum Dice 1.000000; 0 unplaced frames.
- Perturbation probes show the measure is sensitive: a single voxel gives 0.9988, a
  one-slice shift 0.667, a dropped structure 0.0. <!-- src: EVALUATION.md §3 -->
- Hygiene check against reference masks (4/6 cases readable): mean Dice 0.80–0.85,
  identical on both paths. This is not an accuracy claim. <!-- src: EVALUATION.md §8 -->
- Fig. 3: exp2_fidelity.png

## 3.3 Resources and arbitration (E3)
- Arbiter: 38 scenarios, 0 mismatches. <!-- src: EVALUATION.md §4 -->
- Declared 3.5 GB vs measured 20.9–23.1 GB (5.5–6.1×), single process.
- Native process-tree peak: 25.41 GB = 23.66 GiB. The declaration was raised to 25.5,
  and a `total_lowmem` task was added at 24.0 (measured 23.78 GB = 22.15 GiB).
- Second defect: a running one-shot was invisible to admission.
- Interpreter startup overhead: 5.2 s per one-shot invocation (76.4 − 71.2 s).
- Fig. 2: fig_declared_vs_measured.png

## 3.4 Session model (E4)
- Encode costs 17.1× a decode (per-slice range 13.7–20.8×). An implicit cache costs
  1.8–4.7 ms per prompt (2–5% of a decode). <!-- src: EVALUATION.md §5 -->
- SAM 2 protocol round trips: 12/12, with the mask verified by the host's own decoder.
- Report the weakened claim as a result: the lifecycle is justified by control and
  memory bounds, not by speed.
- Fig. 4: exp4_encode_decode.png

## 3.5 Deployability (E5)
- Three defects fixed before passing. After the fixes, 9/9 checks pass.
  <!-- src: EVALUATION.md §6 -->
- App Sandbox is off by design. This makes the architecture incompatible with Mac App
  Store distribution.

## 3.6 End-to-end latency (E6) — TODO(E6)
- Per-engine, per-stage wall time on an idle machine. Two configurations
  (M5 Max/128 GB + a 16 GB Mac). Cold vs warm start.

## 3.7 Prompt-driven and VLM plugins on public CT (E7) — TODO(E7)
- SAM 2/3 click at the structure centroid → Dice vs reference mask, per structure.
  Purpose: verify coordinate mapping, not accuracy.
- Gemma 4 E4B: protocol round trip plus box-placement sanity check on public CT.

## 3.8 Defects found by evaluation (summary table)
- Table 3: defect · how found · consequence if shipped · fix. Four rows.
  <!-- src: FOLLOWUP_PAPER_OUTLINE.md, status block -->

---

# 4. Discussion

## 4.1 Principal findings
- The contract held across four models with no shared axis.
- The main lesson: an arbiter that is correct against its specification is still unsafe
  when the inputs to that specification are self-declared. Audit declarations.

## 4.2 What review missed and evaluation found
- Four defects, each of which would have shipped. Argue that systems papers should
  report evaluation-found defects rather than present uniformly green checks.

## 4.3 Comparison with existing integration approaches
- Server- and GPU-centred frameworks [REF: MONAI Label, Kaapana, OHIF, Slicer
  extensions] vs local inference on a laptop. Discuss the privacy argument.
  [REF: on-device / edge inference in medical imaging]

## 4.4 Limitations
Keep all of these; do not shorten.
- Isolation is by process and virtualenv, not sandbox. The invariants rely on review of
  in-tree adapters. A third-party store would need a technical boundary.
- Declared memory is a claim the host trusts. The auditing in this paper is offline.
- macOS/Apple Silicon only; MLX is platform-specific. TotalSegmentator runs on CPU.
- The evaluation ran on one machine (until E6). The August runs were done in a sandbox
  with no visible GPU.
- 2D prompt segmentation does not propagate through a volume.
- The `seg3d` labelmap encoding clips overlapping structures. No shipped adapter
  reaches this case. <!-- src: EVALUATION.md §3 -->
- No accuracy or clinical validation. Research use only.

## 4.5 Future work
- A sandbox boundary for third-party adapters, and coded anatomy (SNOMED) in SEG.
- Oncology workflows: volumetric tumour segmentation (e.g. pancreatic CT) and DICOM
  whole-slide imaging, so radiology and pathology can be read in one local viewer.
  Keep this to one or two sentences.

---

# 5. Conclusions

<!-- 3–4 sentences. Restate contribution and the audit lesson. No new numbers. -->

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

<!-- Build from Crossref/PubMed metadata only. Elsevier numbered style; CONFIRM in guide. -->

Placeholders to resolve:
- [REF: Heo et al., OpenDicomViewer, JIIM 2026]
- [REF: Wasserthal et al., TotalSegmentator]
- [REF: Ravi et al., SAM 2] · [REF: SAM 3]
- [REF: Gemma 4 technical report / model card]
- [REF: MLX]
- [REF: dcmqi, Herz et al.]
- [REF: TCIA, Clark et al.] · [REF: CT Lymph Nodes collection DOI]
- [REF: nnU-Net, Isensee et al.]
- [REF: DICOM PS3.3 Segmentation IOD]
- [REF: MONAI Label] · [REF: Kaapana] · [REF: OHIF] · [REF: 3D Slicer]

---

# Figure legends

**Figure 1.** Plugin architecture: host, contract, three execution models, adapter
families; isolation and licence layer beneath. (`docs/figures/plugin_architecture.png`)

**Figure 2.** Declared versus measured peak memory and arbiter decisions.
(`docs/figures/fig_declared_vs_measured.png`)

**Figure 3.** Pipeline fidelity and perturbation probes. (`eval/figures/exp2_fidelity.png`)

**Figure 4.** Session model: encode versus decode cost and implicit-cache overhead.
(`eval/figures/exp4_encode_decode.png`)

**Figure 5.** TODO(E6): per-stage latency by engine and machine.

<!-- CONFIRM display-item allowance; consider moving Fig. 3/4 to supplementary. -->

# Tables

**Table 1.** Heterogeneity of the four models (lifetime, memory, I/O, dependencies, licence).
**Table 2.** Verification status per adapter: verified by execution vs not, and why.
**Table 3.** Defects found by evaluation, consequence, fix.
