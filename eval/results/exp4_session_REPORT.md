# Experiment 4 — Does the `session` execution model earn its complexity?

Draft section for `docs/EVALUATION.md`. Kept as a separate file because that
document is shared with the other evaluation tracks; merge from here.

Reproduce with:

```
PYTHONPATH=eval python eval/exp4_session.py \
    --slices 6 --series 3 --encode-reps 5 --prompts 12 --decode-reps 3
```

Results: `eval/results/exp4_session.jsonl`, `eval/results/exp4_session.csv`.
Figures: `eval/figures/exp4_encode_decode.png`,
`eval/figures/exp4_thread_scaling.png`.

---

## 1. The claim under test

`PLUGIN_PROTOCOL.md` §1.2 admits `session` as a third supervision pattern on a
single empirical premise, restated in `docs/PLUGIN_ARCHITECTURE.md` §3: that for
the SAM family, *encoding a slice costs roughly an order of magnitude more than
decoding a mask from a click*. If that is false — if the ratio is near 1 — then
the session lifecycle, the LRU cache, and the `max_sessions` declaration are
machinery with nothing to buy, and `session` should collapse into
`resident-server`.

Before this experiment the premise was an assumption. SAM 2 inference had never
been run against real weights; `docs/PLUGIN_ARCHITECTURE.md` §8 listed it under
"not verified".

## 2. What was run

SAM 2.1 hiera-small (`facebook/sam2.1-hiera-small`, Apache-2.0), obtained by
invoking the adapter's own §4b weight hook, loaded by
`plugins/sam2/server.py`, and driven over the protocol's HTTP surface built by
`_shared/serve.py`. Six axial slices spread through three public TCIA CT series
(CT Lymph Nodes, abdomen, 512×512), rendered to PNG in a soft-tissue window as
the host would render them. Prompts are placed deterministically on body tissue
so a rerun measures the same thing.

30 encodes and 216 decodes were recorded, plus 12 protocol round trips, an LRU
eviction case, a thread-scaling sweep, a FLOP count, and an implicit-cache
comparison.

**Case accounting.** 276 rows. One case id, `work/flops`, appears twice — a
failure followed by a success after the defect described in §9 was fixed. Both
rows are retained: deleting the failed attempt would hide that a retry was
needed. Outstanding failures, meaning case ids with no successful row, number
**zero**; the summary reports the retried case separately as
`n_failed_then_retried`. The distinction is worth stating because the
summariser did not originally draw it, and reported an outstanding failure for
a case that had in fact already succeeded on retry.

## 3. The round trip (previously unverified)

12 of 12 round trips succeeded across four prompt shapes — single click, click
with `multimask`, box, and a click paired with a background click.

| Check | Result |
|---|---|
| Mask grid equals slice grid | 12/12 |
| RLE runs sum to `width × height` | 12/12 |
| Decoded by the host's own Swift `PluginMask2D.decodeMask()` | 12/12 |
| Swift and Python agree on foreground count *and* first foreground index | 12/12 |
| Positive click falls inside its own mask | 6/6 applicable |
| `label` flip moves the mask away from the point | 3/3 |

The Swift check is not a Python re-implementation of the convention: it compiles
`Sources/OpenDicomViewer/Plugins/PluginTypes.swift` — the host's actual decoder —
and pipes the adapter's real payloads through it. This matters because §5's
phase convention has no runtime signal when it is wrong. An encoder that emitted
the opposite phase would produce a structurally valid payload that renders
inverted, and both sides would report success. Agreement on the *first
foreground index*, not just the count, is what distinguishes the correct phase
from its complement.

**A methodological note, because it changed the result.** The negative-prompt
case was first written as "the point sent with `label=0` must be absent from the
returned mask". It failed. The cause was not the adapter: SAM predicts its mask
at 256×256 and the adapter upsamples to the slice grid, so a single pixel is
below the model's resolving power, and the point-selection rule was landing on
the image border. A weaker but sound test replaced it — issue the *same two
coordinates* twice, changing only `label`, and require lower mask occupancy in a
16-px neighbourhood under `label=0` than under `label=1`. That isolates the
field: it fails if the label is dropped and it fails if it is inverted. It
passes 3/3.

Total mask area is recorded but deliberately not asserted on. Adding a
background prompt changed the area by `+1,958`, `−86,465`, and `−4,722` pixels
across the three cases — it can grow, because excluding one region lets the
model settle on a different and larger structure. Any test asserting that a
negative prompt shrinks the mask would be wrong about the model.

## 4. The ratio

Measured at two levels. "Model" is the adapter's own `encode_ms` against the
server's `elapsed_ms`; "client" is the full round trip including JSON and
transport, which is what the host's interactive latency actually is.

| | encode | decode | ratio |
|---|---|---|---|
| Model-reported (median) | 1,580 ms | 90.5 ms | **17.5×** |
| Client round trip (median) | 1,590 ms | 92.9 ms | **17.1×** |
| Client IQR | 1,541–1,689 ms | 83.7–104.6 ms | |

Per-slice client ratios (n=6 slices): 13.7, 16.3, 16.7, 17.4, 19.6, 20.8;
median **17.0×**, range **13.7–20.8×**. The spread is narrow and no slice comes
within an order of magnitude of 1.

The design is therefore justified by this data, and the architecture document's
"roughly an order of magnitude" is accurate — if anything conservative. The
`sam2/server.py` header comment claiming "roughly two orders of magnitude" is
**not** supported and should be corrected to one (see §8).

**Cumulative cost.** Both arms were measured, not extrapolated: the session arm
opens once and issues 12 prompts; the re-encode arm — what a `resident-server`
SAM would be forced to do, having no per-image state — opens, prompts, and
closes for each. Session caching is ahead from the **second prompt** and saves
**18 s over 12 prompts** on one slice.

## 5. Would the ratio survive a GPU?

This is the honest weak point of any timing measured here: **no accelerator is
visible to this process** (`torch.backends.mps.is_available()` is False on a
machine that has a GPU), so every latency above is CPU-only and none of them is
a desktop number. The question is whether the *ratio* — not the latency — could
change direction on an accelerator. Two measurements bound it.

**Thread scaling.** Widening compute from 1 to 8 threads compresses the ratio
from 26× to 23×, a 13 % reduction for an 8× increase in parallel width. Encode
speeds up 2.05×, decode 1.78× — encode absorbs added compute slightly better, so
the compression comes from decode being partly bound by fixed costs that more
compute does not remove.

**Arithmetic work.** The decisive number, because it is device-independent: one
encode performs **269 GFLOP**, one decode **3.56 GFLOP** — a **75.7× ratio**,
counted at torch's dispatch level over the adapter's own code path. That is
4.4× *larger* than the measured latency ratio. The gap has a clear reading: on
CPU the decode is already fixed-cost-dominated rather than arithmetic-dominated,
so the latency ratio understates the arithmetic asymmetry. An accelerator
retires arithmetic faster; it does not reduce the amount. For the ratio to
approach 1, a GPU would have to make the encoder's 269 GFLOP cheaper *per
operation* than the decoder's 3.56 GFLOP, which is the opposite of how wider
parallel hardware behaves on the larger of two workloads.

Parameter counts point the same way: the vision encoder holds 34.3 M of the
model's 38.5 M parameters, the mask decoder 4.2 M, the prompt encoder 6.2 k.

The direction of the conclusion is therefore safe. The *magnitude* on GPU is
not, and should not be quoted from this experiment.

## 6. Session cache and eviction

All five protocol behaviours hold at `max_sessions = 4`:

- Opening a 5th session evicts the least recently used.
- The evicted session's id returns `not_ready` with `recoverable: true`, not
  `bad_input` — the distinction the host needs to reopen silently rather than
  show the user a failure.
- The four survivors all still answer.
- Touching the oldest survivor saves it from the next eviction (recency, not
  insertion order), and the then-oldest untouched session is the one evicted.

One cached embedding is **16.8 MB**, so the cache is bounded at **67 MB** across
four sessions. Measured peak RSS for a bare adapter process is **1.88 GB**
against the **3.0 GB** declared in `plugins.json` — the manifest over-declares,
which is the safe direction for the arbiter (invariant 4).

## 7. What the ratio does *not* justify

The measurement settles that the embedding is worth **caching**. It does not by
itself settle that caching needs an **explicit session lifecycle** —
`session_id`, `/session/open`, `/session/close`, an LRU store, a declared
`max_sessions`, and a fourth supervision path in the host.

A plain `resident-server` could reach the same cache implicitly: accept
`slice2d` with every prompt, hash it, reuse the embedding on a hit. So that
alternative's per-prompt cost was measured too. Base64 round trip plus a
BLAKE2b hash of a 200 kB slice PNG costs **1.8 ms**, or **2 % of a decode**;
including a PNG decode that a hit could skip, **4.7 ms**, or **5 % of a decode**.

That is small. The performance argument does not distinguish the two designs —
it only rules out *no caching*. The session model's remaining advantages are
real but are not about speed:

1. **Bounded memory is enforceable.** `max_sessions` is a declared number the
   host's arbiter can reason about (invariant 4). A content-addressed cache
   bounded by "some number of recent hashes" is the same LRU machinery wearing
   a different name — the complexity does not disappear, it moves.
2. **Eviction is expressible.** `not_ready` on a missing `session_id` tells the
   host precisely what happened. An implicit cache signals a miss only as
   latency, so the host cannot distinguish a slow decode from a silent
   re-encode, and cannot show the user why an interaction stalled.
3. **The host knows when to release.** `/session/close` on series change frees
   67 MB deterministically. An implicit cache must guess with a TTL.

**Conclusion.** The evidence supports keeping `session`, but the paper should
justify it on *lifecycle control and enforceable memory bounds*, not on the
encode/decode ratio alone. The ratio proves caching is necessary; it does not
prove the lifecycle is. Stating it that way is both more defensible and more
interesting than the current framing.

## 8. Discrepancy found in the source

`plugins/sam2/server.py`, module docstring:

> Encoding a slice costs roughly two orders of magnitude more than decoding a
> mask from a click

Measured: 17.1× (client), 17.5× (model-reported) — **one** order of magnitude.
`docs/PLUGIN_ARCHITECTURE.md` §3 already says "roughly an order of magnitude"
and is correct. The adapter comment should be brought into line. Not changed
here, since another track may be editing that file.

## 9. Limitations

- **All timings are CPU-only.** No accelerator is visible to this process. The
  ratio's *direction* is defended in §5 by FLOP counting; its *magnitude* on a
  GPU-backed desktop is not measured and must not be quoted from this
  experiment. Measuring it needs a run outside this sandbox, on a process that
  can see the GPU.
- **Transport substitution.** `bind(2)` is denied here — TCP and unix sockets
  alike — so the adapter could not be started as a subprocess on a loopback
  port. The identical FastAPI application, built by the same
  `_shared.serve.build_app` from the same adapter, was driven in-process over
  ASGI instead. Routing, `TaskRequest` validation, threadpool offload,
  inference, RLE emission, and error envelopes all execute unchanged; the
  kernel socket and HTTP framing on it do not. The omission is larger on the
  encode side (a ~200 kB base64 PNG upload) than on the decode side, so the
  reported ratio is a **lower bound**. `--transport subprocess` runs the real
  server where `bind` is permitted, and the transport is recorded in every row.
- **One model, one anatomy.** SAM 2.1 hiera-small on abdominal CT. Larger SAM 2
  variants have heavier encoders and a decoder of the same size, so their ratio
  should be *larger*; this is the conservative choice, but it is not measured.
  SAM 3 remains unverified — its weights are licence-gated by design.
- **Six slices, three series.** Enough to show the ratio is stable
  (13.7–20.8×), not enough to characterise its distribution.
- `work/flops` failed on its first attempt (the child's result was parsed from a
  stdout stream that torch's progress bars also write to) and succeeded after
  the child was changed to write its result to a file. Both rows are in the
  JSONL; the summary reports it under `n_failed_then_retried`.
