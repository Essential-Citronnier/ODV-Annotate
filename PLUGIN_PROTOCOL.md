# ODV Plugin Protocol v1

Contract between the ODV-Annotate Swift host and a local inference plugin.

This document is normative. An adapter that satisfies it can be installed,
started, invoked, and rendered by the host without any host-side code change
specific to that adapter.

---

## 0. Invariants

These hold for every plugin. They are the reason the store can be permissive
about *what* a plugin does while staying defensible about *what it may touch*.

1. **On-device inference.** A plugin performs inference locally. It must not
   send image data, pixel data, DICOM metadata, or derived masks to any network
   destination.
2. **No remote code.** The manifest ships inside the app bundle. The store never
   fetches, evaluates, or installs executable code from the network. Adapter
   code is version-controlled in `plugins/<id>/` and reviewed like host code.
3. **Weights are the only egress.** The sole permitted network activity is
   downloading model weights and Python package dependencies, from the URLs
   declared in the manifest. This is stated in the UI at install time.
4. **Explicit resource declaration.** A plugin declares its peak resident memory
   and disk footprint in the manifest. The host's arbiter uses these numbers to
   decide what may run concurrently; a plugin that under-declares will be
   starved or refused, not silently allowed to thrash the machine.
5. **Research use.** No plugin output is a diagnosis. The host stamps every
   result surface with a research-use disclaimer; a plugin must not claim
   clinical validity in its own strings.

---

## 1. Execution models

Three, and only three. The host implements a supervisor for each; an adapter
picks one in its manifest via `execution`.

### 1.1 `resident-server`

A long-lived HTTP server on `127.0.0.1:<port>`. The host assigns the port and
passes it as `--port`. Suits models with a load cost far exceeding inference
cost, that answer independent one-shot requests.

*Example: Gemma 4 E4B via MLX (~4.5 GB resident, ~30 s load, seconds per query).*

- Host starts the process, polls `GET /health` until `status == "ready"`.
- Host sends task requests, each independent.
- Host stops the process on user request, on quit, or when the arbiter needs the
  memory.

### 1.2 `session`

A long-lived HTTP server that additionally holds **per-image state** across
requests. The distinguishing property is an expensive encode step whose result
is reused by many cheap decode steps.

*Example: SAM 2 — encoding a slice costs far more than decoding a mask from a
click, so the embedding is cached and re-prompted interactively.*

- Same lifecycle as `resident-server`, plus:
- `POST /session/open` returns a `session_id` for one image or volume.
- Task requests carry `session_id` and are expected to return at interactive
  latency.
- `POST /session/close` releases the cached state. The host closes sessions when
  the user changes series or closes the panel.
- The adapter must bound its session cache (declare `max_sessions`) and evict
  least-recently-used sessions rather than growing without limit.

### 1.3 `one-shot`

A subprocess spawned per invocation. Loads, computes, writes results, exits.
Nothing stays resident. Suits heavyweight models used rarely, where holding the
weights in memory between uses would be wasteful or would collide with a
resident engine.

*Example: TotalSegmentator — minutes per study, run once, ~2–3 GB peak.*

- Host spawns with CLI arguments, streams progress from stdout, waits for exit.
- Exit code 0 means the declared output files exist and are valid.
- Non-zero means failure; `result.json` should still be written with an `error`
  field when the adapter can manage it.

---

## 2. Data flow: paths, not payloads

| Input kind | Transport | Rationale |
|---|---|---|
| `slice2d` | base64 PNG in the request body | one rendered slice, small |
| `series3d` | **filesystem path** to the series directory | 3D geometry and full-range HU values are needed; base64-ing a volume is wasteful and lossy |
| `roi` | normalized rect `{x, y, width, height}`, 0–1 | resolution-independent |
| `points` | list of `{x, y, label}`, x/y normalized 0–1, `label` 1=foreground 0=background | SAM-style prompts |
| `box` | normalized rect | SAM-style prompt |
| `text` | UTF-8 string | prompt / clinical context |

Outputs follow the same rule: small results inline, large results as files whose
paths are returned.

| Output kind | Transport | Host rendering |
|---|---|---|
| `text` | inline string | AI inspector panel |
| `bbox` | inline list of normalized rects + label + confidence | annotation overlay |
| `mask2d` | inline RLE (see §5) over the slice grid | per-panel mask overlay |
| `seg3d` | **path** to a binary DICOM SEG file referencing source SOP instances | existing DICOM SEG renderer |
| `metrics` | inline JSON object of scalar values + units | metrics panel |

A plugin declares which kinds it consumes and produces per task; the host routes
the result to the right renderer from that declaration alone.

---

## 3. HTTP contract (`resident-server`, `session`)

All endpoints are on `http://127.0.0.1:<assigned port>`. Bodies are JSON.
The server must bind to loopback only.

### `GET /health`

```json
{ "status": "loading" | "ready" | "error",
  "plugin_id": "gemma-4-e4b",
  "protocol": 1,
  "detail": "optional human-readable string",
  "memory_mb": 4512.0 }
```

The host polls this after start. `protocol` must equal 1; a mismatch is a load
error reported to the user rather than an attempted call.

### `GET /capabilities`

```json
{ "plugin_id": "gemma-4-e4b",
  "protocol": 1,
  "tasks": [
    { "id": "analyze",
      "label": "Analyze Image",
      "inputs": ["slice2d", "text"],
      "outputs": ["text", "bbox"],
      "options": { "mode": { "type": "enum",
                             "values": ["clinical", "detailed"],
                             "default": "clinical" } } }
  ] }
```

This is the runtime truth. The manifest's task list is what the store shows
*before* install; `/capabilities` is what the host routes on *after* start. When
they disagree, the host trusts `/capabilities` and logs the discrepancy.

### `POST /task/<task_id>`

Request:

```json
{ "session_id": "optional, session plugins only",
  "inputs": { "slice2d": "<base64 PNG>",
              "series3d": "/path/to/series",
              "roi": {"x":0.1,"y":0.1,"width":0.2,"height":0.2},
              "points": [{"x":0.5,"y":0.4,"label":1}],
              "text": "CT, chest" },
  "options": { "mode": "clinical" } }
```

Response, on success (HTTP 200):

```json
{ "ok": true,
  "outputs": { "text": "...",
               "bbox": [{"x":0.1,"y":0.2,"width":0.3,"height":0.2,
                         "label":"...","confidence":0.85}],
               "mask2d": {"width":512,"height":512,"rle":[0,120,15,...],
                          "label":"...","confidence":0.9},
               "seg3d": "/path/to/segmentation.dcm",
               "metrics": {"rv_lv_ratio": 1.12} },
  "elapsed_ms": 1840 }
```

Only the keys the task declared need be present.

`mask2d` may be either a single object or a list of them. A list expresses
candidate masks for one prompt — SAM's `multimask` output — ordered
best-first. The host accepts both forms.

### `POST /session/open` · `POST /session/close`

```json
// open  →
{ "inputs": { "slice2d": "<base64 PNG>" } }
// ← { "ok": true, "session_id": "s-01H...", "encode_ms": 420 }

// close →
{ "session_id": "s-01H..." }
// ← { "ok": true }
```

### Errors

Any non-200, or a 200 with `"ok": false`, carries:

```json
{ "ok": false,
  "error": { "code": "not_ready" | "bad_input" | "license_required"
                   | "out_of_memory" | "internal",
             "message": "human-readable, shown to the user",
             "recoverable": true } }
```

`license_required` is special: the host routes it back to the store's license
gate UI rather than showing a generic failure.

---

## 4. CLI contract (`one-shot`)

Spawned as:

```
<venv python> <entry> --task <task_id> --out <dir> [--input-<kind> <value>]... [--opt-<name> <value>]...
```

`--input-series3d /path/to/series`, `--input-text "..."`, and so on; option flags
mirror the declared `options` keys.

**Progress** on stdout, one JSON object per line, flushed:

```json
{"progress": 0.35, "message": "Running segmentation…"}
```

Any stdout line that is not valid JSON is treated as a log line and shown in the
plugin log view. Nothing on stdout is parsed as a result.

**Result** written to `<out>/result.json`:

```json
{ "ok": true,
  "outputs": { "seg3d": "segmentation.dcm", "metrics": {"...": 0} },
  "elapsed_ms": 154000 }
```

File paths in `outputs` are relative to `<out>`. On failure, write
`{"ok": false, "error": {...}}` with the same error shape as §3 and exit
non-zero.

---

## 4b. Weight acquisition hook

Installing an environment is the host's job (§7); fetching weights is the
adapter's, because only the adapter knows its model hub, file layout, and
checksum conventions. Every adapter — resident, session, or one-shot —
therefore implements one additional CLI mode:

```
<venv python> <entry> --install-weights --weight-id <id> --source <source> \
    --dest <dir> [--repo <repo>] [--task <task>]
```

`--weight-id`, `--source`, `--repo`, and `--task` carry the corresponding
manifest fields verbatim. `--dest` is the host-owned directory the weights must
land in.

- Progress is reported with the same stdout line format as §4.
- Exit 0 means every file needed for that weight id is present under `--dest`.
- For `source: "manual"` the adapter must not attempt a download. It verifies
  the expected file exists and, if it does not, exits non-zero with a
  `license_required` error naming the terms URL and the exact expected path.

**License keys are passed in the environment, never in argv**, as
`ODV_PLUGIN_LICENSE_KEY`. Process arguments are world-readable via `ps`; the
environment of another user's process is not. An adapter that needs the key
reads it from there and must not echo it to stdout or write it into any file it
creates.

## 4c. Result on failure

§4 says a one-shot adapter *should* write `result.json` on failure. The host
reads it whenever it exists, including after a non-zero exit, because the
adapter's own error message is more actionable than an exit code. Adapters
should treat writing it as the expected behavior rather than a courtesy.

## 5. Mask RLE encoding

`mask2d.rle` is a flat array of run lengths over the mask in **row-major** order,
starting with a **background** run. Runs alternate background, foreground,
background, … Lengths are non-negative integers and sum to `width * height`; a
leading zero-length run expresses a mask that starts as foreground.

This is compact for the blob-shaped masks segmentation produces, and cheap to
decode into a Swift bitmap without a dependency.

---

## 6. Install and license gates

A task's `license` field declares how weights are obtained.

| Gate | Meaning | Store behavior |
|---|---|---|
| `open` | Downloadable without conditions | Install button proceeds directly |
| `license-key` | Requires a key the user registers locally | Store prompts for the key, passes it to the adapter's install step, never logs or persists it in plaintext next to the manifest |
| `gated-download` | Requires accepting terms on an external site and authenticating | Store shows the terms URL and the exact local path to place the checkpoint; verifies presence before marking ready |

The store must display the license identifier and, for anything other than
`open`, block the install action until the gate is satisfied. A plugin whose
weights are missing reports `not_ready`; a plugin whose *license* is missing
reports `license_required`, and these are distinct states in the UI.

---

## 7. Installation lifecycle

State machine per task, persisted by the host:

```
notInstalled → resolvingLicense → downloading → installing → ready
      ↑                                              ↓
      └──────────────── removed ←──────────────── failed
```

- `resolvingLicense` is entered only for gated tasks.
- `installing` covers venv creation and `pip install -r requirements.txt`.
- `ready` requires: venv present, all declared weight files present, license
  satisfied.
- The host re-verifies `ready` on launch; a task whose weights vanished falls
  back to `notInstalled` rather than failing at first use.

Each plugin gets its **own virtualenv**. MLX and torch are not co-installable in
practice, and independent envs mean a broken install is confined to one plugin.

---

## 8. Version compatibility

`protocol: 1` throughout. The host refuses to route to a plugin reporting a
different major protocol number. Adding an optional field to a request or
response is a compatible change; adding a required field, changing a field's
meaning, or removing an output kind is not.
