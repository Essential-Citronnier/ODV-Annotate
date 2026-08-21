# A plugin architecture for local medical AI in a DICOM viewer

Design notes for the plugin layer added to OpenDicomViewer. This document is the
rationale; `PLUGIN_PROTOCOL.md` is the normative contract, and
`Sources/OpenDicomViewer/Resources/plugins.json` is the manifest it governs.

---

## 1. The problem

The published viewer [1] integrated one model: a Gemma vision-language model
served over MLX. That integration was direct — a fixed port, three fixed
endpoints, one virtualenv, one process. It worked, and it did not generalize.

Adding a second model exposes why. Consider three that a radiology workstation
plausibly wants:

| | Gemma 4 E4B | SAM 2 / SAM 3 | TotalSegmentator |
|---|---|---|---|
| Load cost vs. inference cost | load dominates | encode dominates, decode is cheap | comparable |
| Natural process lifetime | resident | resident, with per-image state | none: run and exit |
| Input | one rendered slice | slice plus interactive prompts | the whole series |
| Output | text, boxes | 2D masks | 3D DICOM SEG, volumes |
| Peak memory | ~5 GB | 3–6 GB | ~3.5 GB |
| Weight acquisition | unconditional | unconditional (2) / accept terms (3) | academic licence key |
| Python stack | MLX | torch | torch + nnU-Net |

No axis is shared. They differ in process model, in what they consume, in what
they produce, in what they cost, in what a user must agree to before obtaining
them, and in dependencies that cannot coexist in one environment. A viewer that
special-cases each one accretes a private integration per model; the integration
cost never amortizes, and each new model touches the viewer's core.

The contribution here is not a store UI. It is the claim that these differences
reduce to **five declared properties**, and that a host which reads those
properties can supervise, admit, invoke, and render any of them without knowing
which model it is talking to.

## 2. Design invariants

Five properties hold for every plugin, and they are what make the layer
defensible in a clinical setting rather than merely convenient.

1. **On-device inference.** A plugin runs locally. It must not transmit image
   data, DICOM metadata, or derived masks anywhere.
2. **No remote code.** The manifest ships inside the app bundle. The store never
   fetches, evaluates, or installs executable code from the network. Adapter
   code is version-controlled alongside the host and reviewed like host code.
   The set of installable plugins is therefore fixed at build time and auditable
   in version control — a property a conventional plugin marketplace gives up.
3. **Weights are the only egress.** The one permitted network activity is
   downloading model weights and Python dependencies, from URLs the manifest
   declares. The store states this at install time.
4. **Explicit resource declaration.** A plugin declares peak memory and disk
   footprint. The arbiter admits work against those numbers; a plugin that
   under-declares is refused or evicted, not silently allowed to exhaust the
   machine.
5. **Research use.** No plugin output is a diagnosis. The host stamps result
   surfaces accordingly, and a plugin may not claim clinical validity in its own
   strings.

Invariants 2 and 3 together are the substantive privacy claim: the only bytes
that cross the network are weights, in a direction that cannot carry patient
data, fetched from destinations fixed before the application shipped.

## 3. Three execution models

Rather than admit arbitrary process behavior, the contract defines exactly
three supervision patterns. Each plugin picks one.

**`resident-server`** — a long-lived loopback HTTP server answering independent
requests. For models whose load cost far exceeds inference cost. *Gemma:
approximately 30 s to load, seconds per query.*

**`session`** — the same, plus per-image state. The distinguishing property is an
expensive encode whose result many cheap decodes reuse. *SAM: encoding a slice
costs roughly an order of magnitude more than decoding a mask from a click, so
the embedding is cached and re-prompted interactively.* Adapters bound the cache
(`max_sessions`) and evict least-recently-used.

**`one-shot`** — a subprocess per invocation: load, compute, write, exit. For
heavyweight models used rarely, where staying resident would collide with an
interactive engine. *TotalSegmentator: minutes per study, run once.*

The third model is what makes coexistence possible on a laptop. A design in
which every engine is a resident server would require the union of their memory
simultaneously; §6 shows why that fails on the machines clinicians actually use.

## 4. Routing by declared capability

Each task declares what it consumes and produces from a closed vocabulary:
inputs `slice2d`, `series3d`, `roi`, `points`, `box`, `text`; outputs `text`,
`bbox`, `mask2d`, `seg3d`, `metrics`.

The host assembles inputs from panel state and dispatches results **on the
declared output kinds alone** — never on plugin identity. Text reaches the AI
inspector; boxes and masks become panel annotations; `seg3d` is parsed by the
same DICOM SEG reader the viewer already uses for segmentation files found on
disk; metrics land in the panel. A new plugin emitting an existing kind requires
no host change.

Transport follows size rather than uniformity: a rendered slice travels as
base64 PNG, but a volume travels as a **filesystem path**. Serializing a CT
series into a request body would be both wasteful and lossy, and a segmentation
model needs the original geometry and Hounsfield values, not a windowed
rendering.

Masks use run-length encoding over the slice grid, row-major, beginning with a
background run. This is compact for the blob-shaped regions segmentation
produces and decodes into a bitmap without a dependency. The convention is
load-bearing across a language boundary — the Python encoder and the Swift
decoder must agree on which run is foreground, and a disagreement would render
inverted masks rather than raise an error, so both sides are tested against the
same fixtures.

## 5. Licence gates as a first-class state

Weight availability is not binary. The three models occupy three distinct
positions, and conflating them produces a dead end for the user:

| Gate | Meaning | Store behavior |
|---|---|---|
| `open` | downloadable unconditionally | install proceeds |
| `licence-key` | requires a key the user registers locally | prompt, validate format, pass to the adapter's install step |
| `gated-download` | requires accepting terms externally and authenticating | show terms URL and the exact local path for the checkpoint; verify presence |

*TotalSegmentator's high-resolution cardiac task requires a free academic
licence number; SAM 3's weights are distributed under a vendor-specific licence
requiring approval before download.* The host cannot and does not attempt either
acquisition on the user's behalf — it explains the requirement, and for a
manually placed checkpoint it names the destination path exactly.

Two consequences follow in the implementation. A missing **licence** is a
different state from missing **weights**: the former is `resolvingLicense` and
routes to the gate UI, the latter is `notInstalled`. And licence keys are passed
to adapters through the environment rather than argv, because process arguments
are readable by any process on the machine.

## 6. Resource arbitration

Declared memory would be decoration if nothing enforced it. The arbiter admits a
plugin only when two conditions hold after any evictions:

1. **Declared budget** — the sum of manifest `ram_gb` across resident plugins
   fits within 50 % of physical memory. Deterministic, so behavior is
   reproducible and testable.
2. **Live headroom** — the incoming plugin's declared memory fits in what the
   machine can actually supply now, less a safety margin.

Either alone is insufficient. The first would co-locate models on a machine the
user has already loaded with other work; the second would let two models that
each fit individually leave nothing for the viewer and a decompressed volume.

On refusal the arbiter returns an **eviction plan** — least-recently-used first,
ties broken deterministically — rather than a bare refusal. A plugin mid-request
or holding open sessions is non-evictable and blocks admission instead of being
stopped under the user.

The 16 GB case falls out directly. Budget 8 GB; Gemma (5.0) plus
TotalSegmentator (3.5) is 8.5, which does not fit, so Gemma stops for the
duration of the segmentation and restarts after. At 32 GB both run concurrently.
One-shot admission deliberately does not exempt a resident sibling of the same
plugin: a subprocess's peak lands on top of the server's, not inside it.

## 7. Environment isolation

Each plugin gets its own virtualenv. This is forced rather than chosen — MLX and
torch are not co-installable in practice — but it also confines a failed install
to one plugin and lets adapters pin conflicting dependency versions.

The consequence for adapters is that the weight-acquisition hook must run
*before* the environment is fully provisioned, since acquiring weights is part
of provisioning it. Adapters therefore parse their command line on a bare
interpreter and defer heavy imports until after dispatch. For a manually
supplied checkpoint the hook only checks that a path exists, which must not
require the model's inference stack to be present.

## 8. What was verified

Reported honestly, because the distinction matters for the claims:

**Verified by execution.** TotalSegmentator end to end on a 112-slice CT series:
61 non-empty structures, a valid binary DICOM SEG (61 segments, 2 080 frames,
`SegmentationType BINARY`) referencing all 112 source SOP instances, with
per-structure volumes. The SEG was re-read and validated independently of the
code that wrote it. The gated cardiac task exercised its licence path. The SAM 2
adapter's encode/decode path ran against the real SAM 2 implementation,
confirming prompt conversion, RLE emission, mask geometry, and session
eviction. Protocol conformance for all four adapters — health and capability
reporting, the weight hook, error envelopes, licence gating — was verified by
invoking them.

**Not verified.** SAM 2 inference *accuracy*, and all SAM 3 inference: pretrained
weights could not be retrieved in this environment, and SAM 3's are gated by
design. Gemma's MLX inference was not re-run, since no MLX runtime was available
here; its prompts and extraction logic were carried over unchanged from the
working implementation.

**Timing.** End-to-end segmentation time is deliberately **not** reported. The
measurement environment lacked GPU access and denied the interprocess primitives
nnU-Net requires, so the run needed a substitution that preserves correctness
but not performance characteristics. A number obtained that way would not
transfer to a clinical workstation. The DICOM SEG export stage — 0.78 s for 61
segments and 2 080 frames — is unaffected by that substitution and is reported
as measured.

## 9. Limitations

- Adapter isolation is by virtualenv and process, not by sandbox. A plugin runs
  with the user's privileges. The invariants above are enforced by review of
  in-tree adapter code, not by a technical boundary; a store admitting
  third-party adapters would need one.
- Declared memory is a manifest claim. The arbiter enforces admission against
  the declaration, not against measured consumption, so a badly declared plugin
  degrades the policy.
- The protocol has one major version and no negotiation beyond refusing a
  mismatch.
- Prompt-driven segmentation returns 2D masks per slice. The interaction is
  implemented — click and box prompts, accumulating refinement, per-slice session
  caching — but propagating one prompt through a volume is future work, and a
  per-slice mask is not a substitute for 3D segmentation.

## References

[1] Heo J, Kim D, Kim K, Oh J, Lee H, Suh PS, Kim BM, Kim DJ, Kim YD, Nam HS.
OpenDicomViewer: A Lightweight Open-Source DICOM Viewer for macOS Built with
Swift. *Journal of Imaging Informatics in Medicine*, 2026.
