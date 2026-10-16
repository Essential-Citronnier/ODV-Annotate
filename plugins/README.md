# ODV plugin adapters

Python adapters implementing the plugin side of
[`PLUGIN_PROTOCOL.md`](../PLUGIN_PROTOCOL.md). Each directory here is one
plugin, listed in
[`Sources/OpenDicomViewer/Resources/plugins.json`](../Sources/OpenDicomViewer/Resources/plugins.json)
and installed into its own virtualenv by the store.

| Directory | Plugin | Execution | Entry |
|---|---|---|---|
| `gemma/` | Gemma 4 E4B (MLX) | `resident-server` | `server.py` |
| `sam2/` | SAM 2 | `session` | `server.py` |
| `sam3/` | SAM 3 (gated) | `session` | `server.py` |
| `totalseg/` | TotalSegmentator | `one-shot` | `run_segment.py` |
| `_shared/` | protocol implementation | — | not a plugin |

---

## Adding an adapter

### 1. Declare it in the manifest

`plugins.json` is the store's catalogue and is read before anything is
installed. An adapter's directory name must match `adapter_dir` and its entry
point `entry`. The manifest is fixed from an adapter author's point of view: if
it needs to change, raise it rather than editing both sides into agreement.

### 2. Lay the directory out

```
plugins/<id>/
  server.py          # or run_segment.py for one-shot; matches `entry`
  requirements.txt   # matches `requirements`
```

Nothing else is required. Weights are never committed.

### 3. Import the shared protocol module

The host spawns an adapter as `<venv python> plugins/<id>/<entry>`, so only the
adapter's own directory is on `sys.path`. `_shared` lives one level up and is
not pip-installed into each venv -- four copies would be free to drift on the
one thing the adapters must agree on. Every entry point therefore begins:

```python
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _shared.protocol import ErrorCode, PluginError, TaskRequest, TaskSpec
```

`_shared` imports nothing outside the standard library at module load; each
third-party dependency is imported inside the function that needs it. Keep it
that way, or an adapter will start paying for a package its venv does not have.

### 4. Implement the execution model

**`resident-server` and `session`** supply an object with `plugin_id`,
`tasks()`, `health()`, and `run_task()`, then hand it to
`_shared.serve.run_adapter`, which owns the routes, the error envelope, and the
loopback bind:

```python
from _shared.serve import parse_server_args, run_adapter

def main(argv=None):
    args = parse_server_args("My adapter.", argv)
    run_adapter(MyAdapter(), args)
```

A `session` adapter additionally implements `open_session()` and
`close_session()`; `build_app` mounts `/session/open` and `/session/close` only
when it sees them. For a SAM-style encode-once/prompt-many model, implement
`_shared.sam_session.SamBackend` instead and let `SamSessionAdapter` handle the
lifecycle -- that is what `sam2/` and `sam3/` do, and it is why they cannot
disagree about mask geometry.

**`one-shot`** supplies a pipeline function and lets `_shared.oneshot` handle
argument parsing, `result.json`, and failure:

```python
from _shared.oneshot import OneShotResult, parse_oneshot_args, run_oneshot

def pipeline(args, out_dir, reporter):
    reporter.stage(0.0, 0.9, "Working")
    ...
    return OneShotResult(outputs={"seg3d": "segmentation.dcm", "metrics": {...}})

def main(argv=None):
    args = parse_oneshot_args("My adapter.", tasks=["mytask"],
                              options={"fast": "bool"}, argv=argv)
    return run_oneshot(args, pipeline)
```

Paths in `outputs` are **relative to `--out`**. `run_oneshot` verifies that
declared output files exist before reporting success, because exit code 0 means
the host can open them.

### 5. Implement the weight install hook

Every adapter — resident, session, and one-shot alike — implements the section
4b CLI mode the host drives weight acquisition through:

```
<venv python> <entry> --install-weights --weight-id <id> --source <source> \
    --dest <dir> [--repo <repo>] [--task <task>]
```

Check for it before your normal argument parsing, since it shares no required
flags with either the server or the one-shot CLI:

```python
from _shared.weights import install_arg_present, parse_install_args, run_install

def main(argv=None):
    if install_arg_present(argv):
        return run_install(parse_install_args("My installer.", argv), install_weights)
    ...
```

`install_weights(args, dest, reporter)` returns the paths that must exist for
the weight id to count as installed. `run_install` verifies them, so **exit 0
means the weights are genuinely present** — the host marks a task ready on that
alone, and an installer whose download silently no-ops must not pass.

`_shared.weights` provides `download_huggingface()` and, for gated weights,
`verify_manual_checkpoint()`. For `source: "manual"`, **do not download**:
verify the file and, when it is absent, raise `license_required` naming the
terms URL and the exact expected path.

### 6. Read license keys from the environment, never argv

The host passes a key as `ODV_PLUGIN_LICENSE_KEY`, because process arguments
are world-readable through `ps`. Read it with `_shared.weights.license_key()`
and treat it as a secret: never echo it to stdout — the plugin log view is not
private either — and never write it into a file you create. If a library you
call quotes a rejected key back in its exception text, do not forward that text
into your error message.

### 7. Keep heavy imports lazy

`--help` must work in an environment with no torch, and `/capabilities`, the
install hook, and the license-gate error path must all work with no weights.
Import the model stack inside the loading function, not at module scope.

---

## Testing an adapter standalone

No Swift app required. Every adapter is a plain process.

### Resident or session

```bash
# Start it on a port you choose; the host would assign this.
python plugins/sam2/server.py --port 8765 &

curl -s localhost:8765/health
# {"status":"ready","plugin_id":"sam2","protocol":1,...}

curl -s localhost:8765/capabilities

# Session adapters: encode once...
SESSION=$(curl -s -X POST localhost:8765/session/open \
  -H 'content-type: application/json' \
  -d "{\"inputs\":{\"slice2d\":\"$(base64 -i slice.png)\"}}" \
  | python -c 'import json,sys; print(json.load(sys.stdin)["session_id"])')

# ...then prompt it as many times as you like.
curl -s -X POST localhost:8765/task/prompt-mask \
  -H 'content-type: application/json' \
  -d "{\"session_id\":\"$SESSION\",
       \"inputs\":{\"points\":[{\"x\":0.5,\"y\":0.4,\"label\":1}]}}"

curl -s -X POST localhost:8765/session/close \
  -H 'content-type: application/json' -d "{\"session_id\":\"$SESSION\"}"
```

A resident adapter is the same without the session calls:

```bash
curl -s -X POST localhost:8741/task/analyze \
  -H 'content-type: application/json' \
  -d "{\"inputs\":{\"slice2d\":\"$(base64 -i slice.png)\",\"text\":\"CT, chest\"},
       \"options\":{\"mode\":\"clinical\"}}"
```

### One-shot

```bash
python plugins/totalseg/run_segment.py \
  --task total \
  --input-series3d /path/to/dicom/series \
  --out /tmp/segout \
  --opt-fast true

cat /tmp/segout/result.json
```

Progress arrives on stdout as one JSON object per line; anything that is not
JSON is a log line. Nothing on stdout is parsed as a result -- the result is
`result.json`.

### The weight install mode

Any adapter, without the host:

```bash
python plugins/sam2/server.py --install-weights \
  --weight-id sam2.1-hiera-small --source huggingface \
  --repo facebook/sam2.1-hiera-small --dest /tmp/w/sam2
echo $?   # 0 only if the weights are actually there

# A gated plugin verifies rather than downloads, and says what to do:
python plugins/sam3/server.py --install-weights \
  --weight-id sam3-checkpoint --source manual --dest /tmp/w/sam3
# {"ok": false, "error": {"code": "license_required", "message": "... place the
#  checkpoint at /tmp/w/sam3/sam3.pt"}}
# Either the single sam3.pt file or the Hugging Face folder form (config.json +
# model.safetensors) satisfies it. A single file is converted once, on first
# load, into hf-converted/ beside it (about 3.4 GB more on disk, ~7 GB of memory
# for the conversion itself); text prompts need the folder form's tokenizer.
# `ODV_SAM3_STRUCTURAL=1 pytest plugins/sam3/tests` checks the conversion
# against Meta's model structure (needs torch, transformers and Meta's sam3).

# A licence key goes in the environment, never on the command line:
ODV_PLUGIN_LICENSE_KEY=aca_... python plugins/totalseg/run_segment.py \
  --install-weights --weight-id Dataset301_heart_highres_1559subj \
  --source totalseg-task --task heartchambers_highres --dest /tmp/w/totalseg
```

### The shared test suite

```bash
python -m pytest plugins/_shared/tests -q
```

These run without weights, without torch, and without MLX: the session and HTTP
tests drive a fake backend, so protocol conformance is checked on every commit
regardless of what is installed.

---

## The conformance kit

`plugins/_shared/tests` checks *our* adapters through the code they share. The
conformance kit checks *any* adapter, including one that shares nothing with
ours, by running it the way the host does and reporting what it did.

```bash
python -m plugins.conformance plugins/sam2                    # one adapter
python -m plugins.conformance plugins/gemma plugins/sam2      # several
python -m plugins.conformance plugins/mine --python .venv/bin/python
python -m plugins.conformance plugins/mine --json > conformance.json
```

Exit status is 0 when every applicable check passed and 1 otherwise, so it drops
into CI as-is. Every check reports PASS, FAIL, SKIP, or an inconclusive result,
each with a reason naming the protocol section and what the adapter actually
did. It needs no network and no third-party packages: an adapter author runs it
*before* their plugin's environment exists, and a checker that first required
`pip install` would be assuming the thing it exists to verify.

### What it checks

| | Check | Section |
|---|---|---|
| M1–M4 | The manifest's `adapter_dir`, `entry`, and `requirements` resolve to real files; `execution` is one of the three; declared task kinds are protocol kinds; `ram_gb`/`disk_gb` are declared | 0.4, 1, 2 |
| B1–B2 | `--help` and `--install-weights` work on a bare interpreter with the heavy stack blocked | 4b |
| W1–W3 | The weight hook accepts every section 4b flag, reports in the section 4 line format, and a `manual` source verifies without downloading | 4b |
| E1–E3 | A failing run emits one error envelope as a single stdout line, every code is in the enum, and a one-shot writes `result.json` on failure | 3, 4b, 4c |
| S1 | Progress lines, envelopes, and log lines are distinguishable | 4, 4b |
| H1–H4 | `--port` is required; `/health` reports `protocol: 1` and the manifest's `plugin_id`; `/capabilities` agrees with the manifest; the server binds loopback only | 1.1, 3 |
| X1–X3 | `/session/open` returns a `session_id`, `/session/close` accepts it, `max_sessions` is declared and bounded | 1.2 |
| O1–O2 | The section 4 CLI is accepted and bad input rejected on its merits; `result.json` output paths are relative to `--out` | 4 |
| R1–R2 | Mask RLE is row-major and sums to `width * height`, and starts with a background run | 5 |

### Two rules it follows, and why they matter to you

**Behaviour, never documentation.** Nothing in the kit reads your source. This
is not purity: `--install-weights` is dispatched to a separate parser before the
main one, so it is absent from `--help` while working perfectly, and an earlier
generation of these checks failed four correct adapters by asserting on help
text. If the kit says a flag is unsupported, running it is what established
that.

**A missing dependency is not a reason to skip.** SKIP means the check does not
apply — a session check on a one-shot, an RLE check on an adapter that emits no
masks. Where the protocol says a mode must work without the heavy stack, the kit
blocks those imports in your process and a failure there is a FAIL. Likewise,
the `manual`-source check denies outbound connections, so "did not download" is
observed rather than taken on trust. A check the kit could not run at all is
reported as *inconclusive* and still exits non-zero: a check that did not run
has not passed.

### What it cannot check for you

The kit constructs a 64×64 probe slice and a foreground prompt at its centre, so
a mask-producing plugin gets checked end to end without any data of yours. It
cannot synthesise a DICOM series, so a one-shot adapter's *successful* output
paths go unchecked unless you hand it a real result:

```bash
python -m plugins.conformance plugins/totalseg \
  --oneshot-result /path/to/a/real/run/result.json
```

An adapter whose weights are absent reports `/health` as `error`, which is
conformant — the kit checks the envelope and skips the checks that need a loaded
model, saying so in the reason.

### Testing the kit itself

```bash
python -m pytest plugins/conformance/tests -q
```

`plugins/conformance/fixtures/` holds one conformant reference adapter and
twenty-three deliberately broken siblings — one violation class each, otherwise
identical — and the test suite asserts that each check FAILS on its own fixture
and that the conformant control passes everything. A check that cannot fail is
not a check; the coverage test refuses to pass if any check lacks a fixture that
breaks it. Tests needing a loopback socket skip on machines that forbid binding,
rather than being weakened to fit.

If you are writing an adapter, the fixtures double as worked examples of what
*not* to do, each with the consequence in its header comment.

---

## The RLE gotcha

Read this before emitting a `mask2d`.

`mask2d.rle` is a flat list of run lengths over the mask in **row-major** order.
Runs alternate **background, foreground, background, ...** and the **first run
is always background**. A mask whose first pixel is foreground therefore starts
with a zero-length run. Runs sum to `width * height`.

The trap: the host's decoder infers foreground from **run parity alone**. There
is no marker in the data saying which phase is which. An encoder that starts on
the wrong phase produces a structurally valid payload -- correct length, correct
sum, no error anywhere -- that renders **inverted**. Nothing on either side
catches it, and the mask looks plausible enough at a glance that it can survive
review.

So do not hand-roll it:

```python
from _shared.rle import mask2d_payload

return {"mask2d": mask2d_payload(mask, label="liver", confidence=0.9)}
```

`mask2d_payload` takes a numpy array or nested sequence, thresholds on
truthiness, and emits the payload. Its phase convention is pinned by
hand-computed tests in `_shared/tests/test_rle.py` and by a round trip against
a decoder written to match the Swift one. If you must encode by hand, verify
against `_shared.rle.decode_rle` and add a case there.

If your adapter does not use `_shared`, the conformance kit's R2 check is what
will catch a phase error: it prompts a known foreground point and decodes the
answer the way the host does, so an inverted mask shows up as the prompted pixel
coming back background rather than as a payload anyone can see is wrong.

The one other geometry rule: a mask must be the same size as the image the
session encoded, not the slice the host happens to be displaying. Those differ
whenever the panel is zoomed, and `SamSessionAdapter` rejects a mismatch rather
than letting the host misregister it.

`mask2d` may be a single object **or a list**, ordered best-first — that is how
SAM's `multimask` output is expressed. A `SamBackend` returns
`[(mask, score), ...]` from `decode()` and `SamSessionAdapter` picks the shape:
a bare object for one mask, a list for several. Every candidate in a list must
be independently well-formed; a malformed one behind a good first entry is
still a bug the host will hit.

---

## Errors

Raise `PluginError` with one of the five codes from section 3; the scaffolding
turns it into the protocol's envelope.

| Code | Use it when |
|---|---|
| `not_ready` | Weights missing, model still loading, session evicted |
| `bad_input` | The request is malformed or a required input is absent |
| `license_required` | A licence gate is unsatisfied |
| `out_of_memory` | Allocation failed and retrying smaller might work |
| `internal` | Anything else |

`license_required` is not interchangeable with `not_ready`: the host routes it
to the store's licence gate, and the other to a failure banner. Section 6 draws
the line -- missing *weights* are `not_ready`, a missing *licence* is
`license_required`, even though the visible symptom is the same absent file.

Set `recoverable=False` when retrying the identical request cannot succeed.

---

## Environments

Each plugin gets its own virtualenv (section 7). MLX and torch are not
co-installable in practice, and independent environments confine a broken
install to one plugin. Keep the direct requirements to what the adapter
imports; weights are downloaded separately by the store, never by pip.

`requirements.txt` is a full lock, not a list of ranges: every package,
transitive ones included, is pinned with `==`, and the direct requirements
are kept in the file's header comment. Regenerate it for the interpreter the
app bundles (CPython 3.11.17, macOS 14 arm64):

```bash
MACOSX_DEPLOYMENT_TARGET=14.0 uv pip compile direct.in \
    --python-version 3.11 --python-platform aarch64-apple-darwin \
    --no-header --annotation-style line
```

`PluginAdapterLayoutTests` fails if any manifest plugin's requirements file
has an unpinned line, or if a Hugging Face weight lacks a full 40-character
`revision`. The store reinstalls a plugin whose requirements file changed.
An adapter's `tests/` directory is not copied into the packaged app.

| Plugin | Declared `ram_gb` | Minimum Mac RAM | Locked versions of note |
|---|---|---|---|
| `gemma-4-e4b` | 5.0 | 16 GB (8 GB Macs use the built-in engine) | mlx 0.32.0, mlx-vlm 0.6.5, transformers 5.14.1 |
| `sam2` | 3.0 | 8 GB | torch 2.14.1, transformers 5.19.0 |
| `sam3` | 6.0 | 16 GB | torch 2.14.1, transformers 5.19.0 |
| `totalsegmentator` | 25.5 (`total`, `heartchambers_highres`); 24.0 (`total_lowmem`) | 36 GB; 32 GB for `total_lowmem` | TotalSegmentator 2.18.0, nnunetv2 2.8.1, torch 2.14.1 |

The minimum follows the store's rule: a plugin is offered only when its
declared memory is at most half of the Mac's RAM (three quarters for one-shot
plugins). `ram_gb` is in GiB (2^30 bytes), the unit `ProcessInfo.physicalMemory`
is divided into, so `total` at 25.5 needs 25.5 / 0.75 = 34 GiB (the smallest
such Mac has 36 GB) and `total_lowmem` at 24.0 needs exactly 32. See
PLUGIN_PROTOCOL.md for how to derive a declaration from a measurement.

The only network activity a plugin may perform is downloading its declared
weights and dependencies (invariant 3). Inference must not reach the network --
which is why the SAM adapters pass `local_files_only=True`, and why
`run_adapter` refuses to bind anything but loopback.
