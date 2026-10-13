#!/usr/bin/env python3
# server.py
# OpenDicomViewer
#
# Gemma 4 E4B resident adapter (PLUGIN_PROTOCOL.md section 1.1 and 3).
#
# A port of the standalone mlx-server, which predates the plugin protocol and
# spoke its own HTTP shapes on a fixed port. The model handling, the four
# analysis modes, their prompt text, and the JSON-extraction fallback are
# carried over unchanged: that path is what the published viewer ships and a
# behavioural change here would be a regression, not a port.
#
# What is new is the envelope. The legacy routes are kept as thin aliases so an
# existing client keeps working during the transition; they delegate to the
# same handlers rather than duplicating them.
# Licensed under the MIT License. See LICENSE for details.
"""Vision-language analysis of a rendered DICOM slice, served over protocol v1."""

from __future__ import annotations

import io
import json
import logging
import os
import re
import sys
import threading
import time
from pathlib import Path
from typing import Any, Mapping

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _shared.protocol import (  # noqa: E402
    ErrorCode,
    PluginError,
    TaskRequest,
    TaskSpec,
)
from _shared.bench import bench_arg_present, run_resident_bench  # noqa: E402
from _shared.cli import parse_server_args  # noqa: E402
from _shared.lifeline import start_parent_watch  # noqa: E402
from _shared.weights import (  # noqa: E402
    WEIGHTS_DIR_ENV,
    adopt_snapshot,
    download_huggingface,
    hub_cache_snapshot,
    install_arg_present,
    installed_weight_dir,
    parse_install_args,
    run_install,
)

PLUGIN_ID = "gemma-4-e4b"
MODEL_ID = "mlx-community/gemma-4-E4B-it-4bit"
# The snapshot the built-in mlx-server pins too; plugins.json declares it as
# the weight's `revision`, and a hand-run install without one uses it.
MODEL_REVISION = "475b9088d29754a3379866cf5aeb6b41acd313c2"

# The weight id plugins.json declares for MODEL_ID. The host installs it into
# $ODV_WEIGHTS_DIR/<this id>/ (PLUGIN_PROTOCOL.md section 4d).
WEIGHT_ID = "gemma-4-e4b-it-4bit"
WEIGHTS_OVERRIDE_ENV = "ODV_GEMMA_WEIGHTS"

# Larger inputs are downsampled before the vision tower sees them; the model's
# own preprocessing would do it anyway, and doing it here bounds the memory a
# hostile or accidental 8k image could claim.
MAX_IMAGE_SIZE = 1120
# Every answer is a short JSON object. Matches mlx-server.
MAX_TOKENS = 768
# Low temperature: the same slice should give the same answer twice. Matches
# mlx-server; the port had 1.0, which made results vary run to run.
TEMPERATURE = 0.2
TOP_P = 0.95

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(PLUGIN_ID)


# ---------------------------------------------------------------------------
# Prompts, carried over from mlx-server/server.py unchanged
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = (
    "You are a medical image analysis assistant integrated into a DICOM viewer. "
    "You provide structured observations about medical images. "
    "IMPORTANT: Your analysis is for research and educational purposes only. "
    "It must NOT be used as a clinical diagnosis. "
    "Always respond in valid JSON format as specified in the user prompt."
)

ANALYZE_JSON_FORMAT = """
Respond in this exact JSON format:
{{
  "findings": ["finding 1", "finding 2"],
  "bounding_boxes": [
    {{"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.2, "label": "label", "confidence": 0.85}}
  ],
  "description": "Brief overall description of the image"
}}
Coordinates are normalized (0.0 to 1.0) relative to image dimensions."""

ANALYZE_MODES: dict[str, dict] = {
    "clinical": {
        "label": "Clinical Focus",
        "description": "Only clinically significant findings (max 3 boxes)",
        "prompt": """\
Analyze this medical image ({modality}, {description}).
Identify only the most clinically significant findings (abnormalities, lesions, or \
notable observations). Do NOT label normal anatomical structures.
Return at most 3 bounding boxes, focusing on areas that warrant clinical attention.
{json_format}
Only include findings with confidence > 0.6. If the image appears normal, return \
an empty bounding_boxes list and state so in the description.""",
    },
    "detailed": {
        "label": "Detailed Anatomy",
        "description": "All visible anatomical structures and findings",
        "prompt": """\
Analyze this medical image ({modality}, {description}).
Identify ALL visible anatomical structures and any notable findings.
You MUST return at least 3 separate bounding boxes for distinct structures.
Each structure should have its own bounding box with a specific anatomical label.
{json_format}
Only include structures you can identify with reasonable confidence (>0.5). \
Return multiple bounding_boxes, one per structure.""",
    },
    "abnormality": {
        "label": "Abnormality Only",
        "description": "Only abnormalities and pathological findings (max 2 boxes)",
        "prompt": """\
Analyze this medical image ({modality}, {description}).
Focus exclusively on abnormalities and pathological findings. Ignore all normal anatomy.
Return at most 2 bounding boxes for the most important abnormalities.
{json_format}
Only include abnormalities with confidence > 0.7. If no abnormalities are found, \
return an empty bounding_boxes list and state "No abnormalities detected" in the description.""",
    },
    "educational": {
        "label": "Educational",
        "description": "Labeled anatomy with detailed descriptions for learning",
        "prompt": """\
Analyze this medical image ({modality}, {description}) for educational purposes.
You MUST label at least 3-5 distinct anatomical structures visible in the image.
For each structure, provide a separate bounding box with a clear anatomical name.
Examples of structures to look for: ventricles, gray matter, white matter, \
cerebellum, brainstem, skull, sinuses, eyes, CSF spaces, cortex, etc.
Provide a thorough description suitable for medical students.
{json_format}
Include all identifiable structures with confidence > 0.4. \
Return multiple bounding_boxes, one per structure.""",
    },
}

DEFAULT_ANALYZE_MODE = "clinical"

DESCRIBE_ROI_PROMPT_TEMPLATE = """\
Describe the highlighted region in this medical image.
The region of interest is marked at normalized coordinates: \
x={x:.3f}, y={y:.3f}, width={w:.3f}, height={h:.3f}.
Context: {context}

Respond in this exact JSON format:
{{
  "label": "anatomical structure or finding name",
  "description": "Detailed description of what is visible in this region",
  "confidence": 0.85
}}
"""

DETECT_ABNORMALITIES_PROMPT_TEMPLATE = """\
Examine this {modality} image for potential abnormalities or notable findings.
Focus on areas that may warrant clinical attention.

Respond in this exact JSON format:
{{
  "regions": [
    {{
      "x": 0.1, "y": 0.2, "width": 0.15, "height": 0.15,
      "label": "finding name",
      "confidence": 0.8,
      "severity": "mild"
    }},
    ...
  ]
}}

Coordinates are normalized (0.0 to 1.0).
Severity must be one of: "normal", "mild", "moderate", "severe".
Only report findings with confidence > 0.5.
If no abnormalities are found, return {{"regions": []}}.
"""


# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------


def model_source() -> str:
    """What to hand `mlx_vlm.load`: the installed directory, normally.

    Loading by hub id, as the legacy server did, ignored the weights the store
    downloaded and fetched (or looked up in the shared hub cache) a second
    copy, which also broke invariant 3 at inference time. Under the host --
    ODV_WEIGHTS_DIR set -- the installed directory is the only acceptable
    source, and its absence is reported rather than papered over by a
    download. Started by hand with neither variable set and nothing installed,
    the adapter falls back to the hub id so it remains usable for development.
    """
    directory = installed_weight_dir(PLUGIN_ID, WEIGHT_ID,
                                     override_env=WEIGHTS_OVERRIDE_ENV)
    if (directory / "config.json").is_file():
        return str(directory)
    if os.environ.get(WEIGHTS_DIR_ENV) or os.environ.get(WEIGHTS_OVERRIDE_ENV):
        raise PluginError(
            ErrorCode.NOT_READY,
            f"Weights for {MODEL_ID} are not present at {directory}. "
            "Install the plugin from the store.",
            recoverable=False,
        )
    return MODEL_ID


class GemmaModel:
    """Holds the MLX model and serializes generation.

    MLX is not safe to call concurrently from several threads, and the HTTP
    layer dispatches handlers onto a threadpool, so generation is serialized
    here rather than relying on request arrival order.
    """

    def __init__(self) -> None:
        self._model = None
        self._processor = None
        self._lock = threading.Lock()
        self._load_error: str | None = None

    @property
    def is_ready(self) -> bool:
        return self._model is not None

    @property
    def load_error(self) -> str | None:
        return self._load_error

    def load(self) -> None:
        """Load weights. Failure is recorded, not raised: the host polls
        /health and needs a reachable server reporting `error` with a reason,
        not a process that exited before it could answer."""
        started = time.time()
        try:
            source = model_source()
            logger.info("Loading %s from %s", MODEL_ID, source)
            from mlx_vlm import load

            self._model, self._processor = load(source)
        except PluginError as exc:
            self._load_error = exc.message
            logger.error("Model load failed: %s", self._load_error)
            return
        except BaseException as exc:  # noqa: BLE001
            self._load_error = f"{type(exc).__name__}: {exc}"
            logger.error("Model load failed: %s", self._load_error)
            return
        logger.info("Model loaded in %.1fs", time.time() - started)

    def generate(self, image, prompt: str) -> str:
        from mlx_vlm import generate

        with self._lock:
            messages = [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user",
                 "content": [{"type": "image"}, {"type": "text", "text": prompt}]},
            ]
            formatted = self._processor.apply_chat_template(
                messages, add_generation_prompt=True
            )
            response = generate(
                self._model, self._processor, formatted, image=[image],
                max_tokens=MAX_TOKENS, temperature=TEMPERATURE, top_p=TOP_P,
            )
        return response.text if hasattr(response, "text") else str(response)

    def memory_mb(self) -> float | None:
        try:
            import mlx.core as mx

            getter = getattr(mx, "get_peak_memory", None) or mx.metal.get_peak_memory
            return getter() / (1024 * 1024)
        except Exception:  # noqa: BLE001 - a metrics read must never fail a request
            return None


def decode_image(data: bytes):
    """Decode PNG bytes to RGB, downsampling anything oversized."""
    from PIL import Image, UnidentifiedImageError

    try:
        image = Image.open(io.BytesIO(data)).convert("RGB")
    except (UnidentifiedImageError, OSError) as exc:
        raise PluginError(
            ErrorCode.BAD_INPUT, f"slice2d is not a readable image: {exc}",
            recoverable=False,
        ) from None

    width, height = image.size
    if max(width, height) > MAX_IMAGE_SIZE:
        scale = MAX_IMAGE_SIZE / max(width, height)
        image = image.resize((int(width * scale), int(height * scale)), Image.LANCZOS)
    return image


def extract_json(text: str) -> dict | None:
    """Recover a JSON object from model output.

    Carried over from mlx-server unchanged. The model usually returns bare
    JSON, sometimes fences it, and occasionally wraps it in prose; each
    fallback handles one of those and the caller degrades to raw text when all
    three miss.
    """
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    match = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(1))
        except json.JSONDecodeError:
            pass

    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            pass

    return None


def _coerce_boxes(raw: Any, with_severity: bool = False) -> list[dict]:
    """Keep only well-formed boxes.

    A malformed box among several good ones is dropped rather than failing the
    request: the model is the unreliable component here, and a partial overlay
    is more useful than an error.
    """
    boxes: list[dict] = []
    for item in raw if isinstance(raw, list) else []:
        if not isinstance(item, Mapping):
            continue
        try:
            box = {
                "x": float(item["x"]),
                "y": float(item["y"]),
                "width": float(item["width"]),
                "height": float(item["height"]),
                "label": str(item.get("label", "")),
                "confidence": float(item.get("confidence", 0.0)),
            }
        except (KeyError, TypeError, ValueError):
            continue
        if with_severity:
            severity = str(item.get("severity", "normal"))
            box["severity"] = severity if severity in (
                "normal", "mild", "moderate", "severe") else "normal"
        boxes.append(box)
    return boxes


# ---------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------


class GemmaAdapter:
    """Serves the three tasks plugins.json declares for this plugin."""

    plugin_id = PLUGIN_ID

    def __init__(self) -> None:
        self.model = GemmaModel()

    def tasks(self) -> list[TaskSpec]:
        return [
            TaskSpec(
                id="analyze",
                label="Analyze Image",
                inputs=["slice2d", "text"],
                outputs=["text", "bbox"],
                options={"mode": {"type": "enum",
                                  "values": list(ANALYZE_MODES),
                                  "default": DEFAULT_ANALYZE_MODE,
                                  "label": "Analysis mode"}},
            ),
            TaskSpec(id="describe-roi", label="Describe ROI",
                     inputs=["slice2d", "roi", "text"], outputs=["text"]),
            TaskSpec(id="detect-abnormalities", label="Detect Abnormalities",
                     inputs=["slice2d", "text"], outputs=["bbox", "text"]),
        ]

    def health(self) -> tuple[str, str | None, float | None]:
        if self.model.load_error is not None:
            return "error", self.model.load_error, None
        if not self.model.is_ready:
            return "loading", f"Loading {MODEL_ID}", None
        return "ready", None, self.model.memory_mb()

    def _require_ready(self) -> None:
        if self.model.load_error is not None:
            raise PluginError(
                ErrorCode.NOT_READY,
                f"The model failed to load: {self.model.load_error}",
                recoverable=False,
            )
        if not self.model.is_ready:
            raise PluginError(ErrorCode.NOT_READY, "The model is still loading.")

    def run_task(self, task_id: str, request: TaskRequest) -> dict:
        self._require_ready()
        if task_id == "analyze":
            return self.analyze(request)
        if task_id == "describe-roi":
            return self.describe_roi(request)
        if task_id == "detect-abnormalities":
            return self.detect_abnormalities(request)
        raise PluginError(
            ErrorCode.BAD_INPUT, f"unknown task '{task_id}'", recoverable=False
        )

    # -- tasks -------------------------------------------------------------

    def analyze(self, request: TaskRequest) -> dict:
        image = decode_image(request.slice2d_bytes())
        mode_key = request.option_enum("mode", list(ANALYZE_MODES), DEFAULT_ANALYZE_MODE)
        # `text` carries whatever clinical context the host has: modality,
        # series description, body part. The legacy server took these as
        # separate structured fields; the protocol has one text input, so the
        # host concatenates and the prompt uses it for both slots.
        context = request.text(default="medical image")
        prompt = ANALYZE_MODES[mode_key]["prompt"].format(
            modality=context or "Unknown",
            description=context or "medical image",
            json_format=ANALYZE_JSON_FORMAT,
        )

        raw = self.model.generate(image, prompt)
        parsed = extract_json(raw)
        if parsed is None:
            # The unparsed answer is still worth showing: it is usually a
            # correct description that simply was not JSON.
            return {"text": raw.strip(), "bbox": []}

        findings = parsed.get("findings")
        description = str(parsed.get("description", ""))
        if isinstance(findings, list) and findings:
            bullets = "\n".join(f"- {item}" for item in findings)
            description = f"{description}\n\n{bullets}".strip()

        return {"text": description, "bbox": _coerce_boxes(parsed.get("bounding_boxes"))}

    def describe_roi(self, request: TaskRequest) -> dict:
        image = decode_image(request.slice2d_bytes())
        roi = request.rect("roi", required=True)
        prompt = DESCRIBE_ROI_PROMPT_TEMPLATE.format(
            x=roi.x, y=roi.y, w=roi.width, h=roi.height,
            context=request.text(),
        )

        raw = self.model.generate(image, prompt)
        parsed = extract_json(raw)
        if parsed is None:
            return {"text": raw.strip()}

        label = str(parsed.get("label", "")).strip()
        description = str(parsed.get("description", "")).strip()
        return {"text": f"{label}: {description}" if label else description}

    def detect_abnormalities(self, request: TaskRequest) -> dict:
        image = decode_image(request.slice2d_bytes())
        prompt = DETECT_ABNORMALITIES_PROMPT_TEMPLATE.format(
            modality=request.text(default="Unknown") or "Unknown"
        )

        raw = self.model.generate(image, prompt)
        parsed = extract_json(raw)
        if parsed is None:
            return {"bbox": [], "text": raw.strip()}

        boxes = _coerce_boxes(parsed.get("regions"), with_severity=True)
        summary = (f"{len(boxes)} region(s) flagged for attention."
                   if boxes else "No abnormalities detected.")
        return {"bbox": boxes, "text": summary}


# ---------------------------------------------------------------------------
# Legacy routes
# ---------------------------------------------------------------------------


def attach_legacy_routes(app, adapter: GemmaAdapter) -> None:
    """Re-expose the pre-protocol mlx-server endpoints as aliases.

    Kept because they are cheap -- each one reshapes a request into the task
    envelope and calls the same handler -- and because the published viewer
    build talks to them. They are not part of protocol v1 and the host does not
    call them; they exist so an older client is not broken by the port.
    """
    from fastapi import Request
    from fastapi.responses import JSONResponse

    def _fail(exc: BaseException) -> JSONResponse:
        if isinstance(exc, PluginError):
            return JSONResponse(status_code=400 if exc.code is ErrorCode.BAD_INPUT else 503,
                                content={"detail": exc.message})
        return JSONResponse(status_code=500, content={"detail": str(exc)})

    @app.get("/modes")
    async def modes() -> dict:
        return {
            "modes": {key: {"label": value["label"], "description": value["description"]}
                      for key, value in ANALYZE_MODES.items()},
            "default": DEFAULT_ANALYZE_MODE,
        }

    @app.post("/analyze")
    async def legacy_analyze(request: Request):
        body = await request.json()
        info = body.get("window_info") or {}
        context = ", ".join(
            str(info.get(key)) for key in ("modality", "description", "body_part")
            if info.get(key)
        )
        envelope = TaskRequest({
            "inputs": {"slice2d": body.get("image"), "text": context},
            "options": {"mode": body.get("mode", DEFAULT_ANALYZE_MODE)},
        })
        try:
            adapter._require_ready()
            outputs = adapter.analyze(envelope)
        except BaseException as exc:  # noqa: BLE001
            return _fail(exc)
        return {"findings": [], "bounding_boxes": outputs["bbox"],
                "description": outputs["text"]}

    @app.post("/describe-roi")
    async def legacy_describe_roi(request: Request):
        body = await request.json()
        envelope = TaskRequest({"inputs": {"slice2d": body.get("image"),
                                           "roi": body.get("roi"),
                                           "text": body.get("context", "")}})
        try:
            adapter._require_ready()
            outputs = adapter.describe_roi(envelope)
        except BaseException as exc:  # noqa: BLE001
            return _fail(exc)
        return {"label": "", "description": outputs["text"], "confidence": 0.0}

    @app.post("/detect-abnormalities")
    async def legacy_detect(request: Request):
        body = await request.json()
        envelope = TaskRequest({"inputs": {"slice2d": body.get("image"),
                                           "text": body.get("modality", "Unknown")}})
        try:
            adapter._require_ready()
            outputs = adapter.detect_abnormalities(envelope)
        except BaseException as exc:  # noqa: BLE001
            return _fail(exc)
        return {"regions": outputs["bbox"]}


# ---------------------------------------------------------------------------
# Weight acquisition (PLUGIN_PROTOCOL.md section 4b)
# ---------------------------------------------------------------------------


def install_weights(args, dest: Path, reporter) -> list[Path]:
    """Fetch the MLX Gemma checkpoint into the host-owned directory."""
    if args.source != "huggingface":
        raise PluginError(
            ErrorCode.BAD_INPUT,
            f"{PLUGIN_ID} only knows the 'huggingface' weight source, "
            f"got '{args.source}'",
            recoverable=False,
        )
    repo = args.repo or MODEL_ID
    revision = args.revision or (MODEL_REVISION if repo == MODEL_ID else None)
    # The built-in mlx-server keeps the same pinned snapshot in the hub cache.
    # When it is complete there, link it rather than hold a second 5.2 GB copy.
    snapshot = hub_cache_snapshot(repo, revision)
    if snapshot is not None:
        files = adopt_snapshot(snapshot, dest, reporter)
    else:
        files = download_huggingface(repo, dest, reporter, revision=revision)
    # mlx-vlm loads a model directory rather than one named file, and the shard
    # count varies by quantization, so the config plus at least one weight
    # shard is what "present" means here.
    config = dest / "config.json"
    shards = [path for path in files if path.suffix == ".safetensors"]
    if not shards:
        raise PluginError(
            ErrorCode.INTERNAL,
            f"No weight shards were downloaded from {args.repo or MODEL_ID}.",
        )
    return [config, *shards]


def main(argv: list[str] | None = None) -> int:
    if install_arg_present(argv):
        return run_install(
            parse_install_args("Gemma 4 E4B weight installer.", argv), install_weights
        )

    if bench_arg_present(argv):
        # Dispatched before the server parser, like --install-weights. The
        # model is loaded through the same entry point the server's startup
        # hook uses, so the measured load cost is the one a user pays.
        return run_resident_bench(
            PLUGIN_ID, GemmaAdapter, lambda adapter: adapter.model.load(), argv)

    args = parse_server_args("Gemma 4 E4B adapter for OpenDicomViewer.", argv)
    adapter = GemmaAdapter()

    from _shared.serve import build_app
    import uvicorn

    # The model loads on a thread, not in the startup hook: a hook that blocks
    # keeps uvicorn from binding the port, so /health could not answer
    # "loading" and the host saw only refused connections for the tens of
    # seconds a load takes.
    app = build_app(adapter, on_startup=lambda: threading.Thread(
        target=adapter.model.load, name="model-load", daemon=True).start())
    attach_legacy_routes(app, adapter)

    if args.host not in ("127.0.0.1", "localhost", "::1"):
        raise SystemExit("refusing to bind a non-loopback address")
    # Started before uvicorn, whose startup hook spends tens of seconds
    # loading the model: a host that crashes meanwhile must still be noticed.
    start_parent_watch()
    uvicorn.run(app, host=args.host, port=args.port,
                log_level=args.log_level, workers=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
