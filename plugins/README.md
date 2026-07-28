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

### 5. Keep heavy imports lazy

`--help` must work in an environment with no torch, and `/capabilities` and the
license-gate error path must work with no weights. Import the model stack
inside the loading function, not at module scope.

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

### The shared test suite

```bash
python -m pytest plugins/_shared/tests -q
```

These run without weights, without torch, and without MLX: the session and HTTP
tests drive a fake backend, so protocol conformance is checked on every commit
regardless of what is installed.

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

The one other geometry rule: a mask must be the same size as the image the
session encoded, not the slice the host happens to be displaying. Those differ
whenever the panel is zoomed, and `SamSessionAdapter` rejects a mismatch rather
than letting the host misregister it.

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
install to one plugin. Keep `requirements.txt` to what the adapter imports;
weights are downloaded separately by the store, never by pip.

The only network activity a plugin may perform is downloading its declared
weights and dependencies (invariant 3). Inference must not reach the network --
which is why the SAM adapters pass `local_files_only=True`, and why
`run_adapter` refuses to bind anything but loopback.
