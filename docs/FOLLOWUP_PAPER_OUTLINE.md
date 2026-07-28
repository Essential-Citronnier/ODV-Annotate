# Follow-up paper — working outline

Successor to Heo et al., *OpenDicomViewer: A Lightweight Open-Source DICOM
Viewer for macOS Built with Swift*, JIIM 2026.

This is planning material, not a draft. It records what the implemented work
supports, what it does not yet support, and what would have to be measured
before submission.

---

## 1. What is new relative to the prior paper

The prior paper contributed a viewer and, in the annotation fork, one integrated
vision-language model. The claim available now is different in kind:

> Heterogeneous local medical AI models — differing in process lifetime,
> resource profile, input and output type, dependency stack, and licence
> conditions — can be integrated into a clinical image viewer through a single
> declarative contract, without per-model changes to the viewer.

The evidence is that three models with no shared axis (§3 below) run under one
supervisor, one manifest schema, and one result-routing rule.

**Not a contribution, and should not be claimed as one:** the models themselves,
segmentation accuracy, or any clinical finding. The paper is a systems and
software architecture paper. Overreaching into accuracy claims would be
indefensible, since the models are used unmodified and their accuracy is
published elsewhere.

## 2. Candidate framing

The strongest framing is the negative result implicit in the design: **a plugin
marketplace for clinical AI cannot be a conventional marketplace.** Fetching
executable code at runtime is unacceptable in a device context; the manifest
must therefore ship with the application and the installable set must be fixed
and auditable at build time. What remains fetchable is weights alone. That
constraint — rather than the UI — is what shapes the architecture, and it is the
part that generalizes to other clinical software.

Secondary framing, if the venue prefers a capability story: on-device inference
removes the transmission of patient data that cloud AI integration requires, and
the plugin layer is what makes on-device practical for more than one model at a
time on consumer hardware.

## 3. Core figure and table

**Figure 1 — architecture.** Host, contract, three execution models, three
adapter families, with the isolation and licence layer beneath.
(`plugin_architecture.png`)

**Figure 2 — resources and arbitration.** Declared footprints per plugin, and
the admission outcome on a 16 GB machine showing eviction.
(`plugin_resources.png`)

**Table 1 — heterogeneity.** The axes on which the three model families differ.
This table *is* the argument: it should appear early, because a reader who
accepts that no axis is shared has already accepted why a contract is needed.

**Table 2 — verification status.** Per adapter, what was verified by execution
versus what was not, and why. Publishing this honestly is better than a table of
uniformly green checks that a reviewer would rightly distrust.

## 4. Evaluation — what exists and what is missing

**Exists.**
- End-to-end execution of the one-shot path on a real CT series, producing a
  standards-conformant binary DICOM SEG validated independently of the code that
  wrote it (61 segments, 2 080 frames, all 112 source instances referenced).
- Protocol conformance for all four adapters, verified by invocation.
- Arbitration policy exercised across budget scenarios.
- 185 host tests and 145 adapter tests.

**Missing, and needed before submission.**

1. **Timing on real hardware.** No end-to-end latency figure is currently
   defensible: the measurement environment lacked GPU access and required a
   substitution for interprocess primitives. Every model needs a clean run on
   the target machine, reported per stage. This is a short experiment, not a
   research problem, and it is the single most important gap.
2. **SAM 2 and SAM 3 inference.** Weights were not retrievable in the build
   environment. Both need a real click-prompt round trip on a clinical image,
   with the resulting mask inspected.
3. **The arbitration claim needs measurement, not just policy.** Currently the
   16 GB scenario is derived from declared figures. It should be run: does the
   machine actually stay responsive when a resident engine is evicted for a
   segmentation, and how long does the restart cost the user? Measured resident
   memory should be compared against each manifest's declaration, since the
   whole policy rests on those numbers being roughly honest. Any plugin whose
   real peak diverges materially is a finding worth reporting.
4. **A second host, ideally.** Everything so far runs on one machine. A second
   configuration with different memory would show the arbitration policy adapts
   rather than being tuned to one box.

**Optional but valuable.** An integration case study: the sibling pulmonary
embolism work uses this infrastructure for RV/LV assessment, and a short section
showing a clinical question answered through the plugin layer would ground an
otherwise architectural paper. It should be framed as a demonstration of the
infrastructure, not as a clinical validation.

## 5. Limitations to state plainly

- Isolation is by process and virtualenv, not sandbox; the invariants are
  enforced by code review of in-tree adapters, not by a technical boundary. A
  store accepting third-party adapters would need one, and this is the main
  obstacle to the architecture generalizing to an open ecosystem.
- Declared memory is a claim the host trusts.
- macOS and Apple Silicon only; one execution model (MLX) is platform-specific.
- 2D prompt-driven segmentation does not yet propagate through a volume.
- Research use only; no clinical validation of any output.

## 6. Venue

*Journal of Imaging Informatics in Medicine* is the natural home given the prior
paper, and it publishes software architecture work. The framing should lead with
the constraint (no remote code in a clinical context) rather than with the
plugin store, since the constraint is what a reviewer in this venue will find
novel.

## 7. Reproducibility

Contract, manifest, adapters, and host code are in one repository under MIT.
The verification claims in §4 are reproducible from the test suites. Model
weights are obtained from their upstream sources under their own licences;
none are redistributed.
