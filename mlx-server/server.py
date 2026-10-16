"""
MLX Gemma 4 E4B Server for ODV-Annotate
========================================
Local inference server for AI-assisted DICOM annotation.
Runs Gemma 4 E4B (4-bit quantized) on Apple Silicon via MLX.

Endpoints:
    GET  /health               - Server/model status
    GET  /modes                - Available analysis modes
    POST /analyze              - Full image analysis with structure detection
    POST /describe-roi         - Describe a user-selected region
    POST /detect-abnormalities - Highlight potential abnormalities

Every request must carry the per-launch token in the `X-ODV-Token` header and
a Host header naming the loopback interface. The viewer generates the token on
each launch and hands it over through the ODV_AI_TOKEN environment variable;
the Host check defeats DNS-rebinding pages that would otherwise reach a
loopback port from the browser.
"""

import asyncio
import base64
import binascii
import hmac
import io
import json
import logging
import os
import secrets
import threading
import time
from collections.abc import Mapping
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

# Plain HTTP downloads rather than Xet. Xet buffers a file's chunks and writes
# it late, so the size of the hub cache -- the only download progress the
# viewer can show -- stood still for minutes; over HTTP the .incomplete file
# grows as bytes arrive. Must be set before huggingface_hub is imported.
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

import sys

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from starlette.datastructures import Headers
from PIL import Image, ImageDraw, UnidentifiedImageError

# Model-output parsing, cancellable generation and failure hints are shared
# with the Gemma plugin (plugins/_shared), which ships beside this directory
# both in the source tree and in the app bundle's Resources: the same answer
# must produce the same overlay whichever engine served it.
_PLUGINS_DIR = Path(__file__).resolve().parent.parent / "plugins"
if str(_PLUGINS_DIR) not in sys.path:
    sys.path.insert(0, str(_PLUGINS_DIR))

from _shared.coerce import (  # noqa: E402
    MIN_BOX_SIZE,  # noqa: F401 - re-exported for callers and tests
    SEVERITIES,  # noqa: F401
    as_object as _as_object,
    coerce_boxes as _coerce_boxes,
    coerce_confidence as _coerce_confidence,
    coerce_findings as _coerce_findings,
    coerce_severity as _coerce_severity,
    coerce_text as _coerce_text,
    extract_json as _extract_json,
    raw_corners as _raw_corners,
)
from _shared.errors import describe_failure  # noqa: E402
from _shared.vlm import GenerationCancelled, generate_text  # noqa: E402
from _shared.weights import hub_cache_snapshot  # noqa: E402

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("mlx-server")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MODEL_ID = "mlx-community/gemma-4-E4B-it-4bit"
# Pinned so a re-upload of the weights cannot silently change model output.
# Override with ODV_MODEL_REVISION (e.g. "main") to try a newer snapshot.
MODEL_REVISION = os.environ.get(
    "ODV_MODEL_REVISION", "475b9088d29754a3379866cf5aeb6b41acd313c2"
)
MAX_IMAGE_SIZE = 1120  # max dimension before resize
# Every response is a short JSON object; 768 tokens is ample for it, and a
# lower cap bounds how long a run that loops or rambles can hold the model.
MAX_TOKENS = 768
# Low temperature: the same slice should give the same answer twice.
TEMPERATURE = 0.2
TOP_P = 0.95
# Base64 of a 1120x1120 RGBA PNG is well under this; anything larger is abuse.
MAX_IMAGE_B64_CHARS = 40_000_000
HOST = "127.0.0.1"
PORT = int(os.environ.get("ODV_AI_PORT", "8741"))
TOKEN_HEADER = "x-odv-token"
ALLOWED_HOSTS = {"127.0.0.1", "localhost"}


def _load_token() -> str:
    token = os.environ.get("ODV_AI_TOKEN", "").strip()
    if token:
        return token
    # Standalone use (launch.sh without a token): generate one so the server is
    # never open. Printed once so a developer can pass it to curl or the app.
    token = secrets.token_hex(32)
    logger.warning(
        "ODV_AI_TOKEN not set; generated a one-off token. "
        "Export ODV_AI_TOKEN=%s for the viewer to adopt this server.", token
    )
    return token


API_TOKEN = _load_token()

# ---------------------------------------------------------------------------
# Global model state
# ---------------------------------------------------------------------------
_model = None
_processor = None
_load_error: str | None = None
_model_lock = threading.Lock()
# "starting" until load_model runs, then "downloading" (snapshot not cached
# yet) and "loading" (reading weights into memory). Reported by /health.
_phase = "starting"
# Total size of the pinned snapshot per the Hub, when it could be asked.
_expected_bytes: int | None = None

# ---------------------------------------------------------------------------
# Prompt templates
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = (
    "You are a medical image analysis assistant integrated into a DICOM viewer. "
    "You provide structured observations about medical images. "
    "IMPORTANT: Your analysis is for research and educational purposes only. "
    "It must NOT be used as a clinical diagnosis. "
    "Always respond in valid JSON format as specified in the user prompt."
)

# Substituted into the mode prompts as a str.format() *argument*, so its
# braces are not interpreted again: single braces here reach the model as-is.
ANALYZE_JSON_FORMAT = """
Respond in this exact JSON format:
{
  "findings": ["finding 1", "finding 2"],
  "bounding_boxes": [
    {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.2, "label": "label", "confidence": 0.85}
  ],
  "description": "Brief overall description of the image"
}
Coordinates are normalized (0.0 to 1.0) relative to image dimensions: x and y are \
the top-left corner, width and height are fractions of the image size."""

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
Describe the region of interest outlined by the red rectangle in this medical image.
Its normalized coordinates are x={x:.3f}, y={y:.3f}, width={w:.3f}, height={h:.3f}.
Describe only what is inside the rectangle; the red outline itself is not part of the image.
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
# Request / Response models
# ---------------------------------------------------------------------------
class WindowInfo(BaseModel):
    modality: str = "Unknown"
    description: str = ""
    window_center: float | None = None
    window_width: float | None = None
    body_part: str = ""


class AnalyzeRequest(BaseModel):
    image: str  # base64-encoded PNG
    window_info: WindowInfo = Field(default_factory=WindowInfo)
    mode: str = DEFAULT_ANALYZE_MODE


class BoundingBox(BaseModel):
    x: float
    y: float
    width: float
    height: float
    label: str
    confidence: float = 0.0


class AnalyzeResponse(BaseModel):
    findings: list[str] = []
    bounding_boxes: list[BoundingBox] = []
    description: str = ""
    raw_response: str | None = None  # fallback if JSON parse fails


class DescribeROIRequest(BaseModel):
    image: str  # base64-encoded PNG
    roi: dict  # {x, y, width, height} normalized 0-1
    context: str = ""


class ROIDescription(BaseModel):
    label: str = ""
    description: str = ""
    confidence: float = 0.0
    raw_response: str | None = None


class DetectAbnormalitiesRequest(BaseModel):
    image: str  # base64-encoded PNG
    modality: str = "Unknown"


class AbnormalityRegion(BaseModel):
    x: float
    y: float
    width: float
    height: float
    label: str
    confidence: float = 0.0
    severity: str = "unknown"


class DetectAbnormalitiesResponse(BaseModel):
    regions: list[AbnormalityRegion] = []
    raw_response: str | None = None


class HealthResponse(BaseModel):
    status: str  # "loading" | "ready" | "error"
    model: str
    revision: str
    pid: int
    memory_usage_mb: float | None = None
    error: str | None = None
    # While loading: "starting" | "downloading" | "loading".
    phase: str | None = None
    # First-run download progress: bytes in the hub cache for this model, and
    # the snapshot's total size when the Hub could be asked for it.
    download_bytes: int | None = None
    download_total_bytes: int | None = None


# ---------------------------------------------------------------------------
# Model loading
# ---------------------------------------------------------------------------
def _hub_cache_dir() -> Path:
    """The Hugging Face hub cache, honouring HF_HUB_CACHE / HF_HOME."""
    try:
        from huggingface_hub import constants

        return Path(constants.HF_HUB_CACHE)
    except Exception:  # noqa: BLE001 - only used for progress reporting
        if os.environ.get("HF_HUB_CACHE"):
            return Path(os.environ["HF_HUB_CACHE"]).expanduser()
        home = os.environ.get("HF_HOME") or os.path.join(
            os.path.expanduser("~"), ".cache", "huggingface")
        return Path(home).expanduser() / "hub"


def _repo_cache_dir() -> Path:
    return _hub_cache_dir() / ("models--" + MODEL_ID.replace("/", "--"))


def complete_snapshot() -> Path | None:
    """The pinned snapshot in the hub cache, when every weight file is there.

    Files are linked into the snapshot as each finishes, so an interrupted
    download can leave config.json and some shards without the rest; the
    shard index, when the model has one, names every shard that must exist.
    """
    return hub_cache_snapshot(MODEL_ID, MODEL_REVISION, cache_dir=_hub_cache_dir())


def snapshot_present() -> bool:
    """Whether the pinned snapshot is complete in the hub cache."""
    return complete_snapshot() is not None


# A directory already holding this revision's files, normally the Gemma
# plugin's installed weights (one 5.2 GB copy serves both engines). The viewer
# sets it only after checking the directory's completion marker records
# MODEL_REVISION; a directory without the files is ignored here too.
LOCAL_MODEL_DIR_ENV = "ODV_MODEL_DIR"


def _weights_complete(directory: Path) -> bool:
    """config.json plus every shard the index names (or at least one shard)."""
    if not (directory / "config.json").is_file():
        return False
    index = directory / "model.safetensors.index.json"
    if index.is_file():
        try:
            shards = set(json.loads(index.read_text()).get("weight_map", {}).values())
        except (OSError, ValueError):
            return False
        return bool(shards) and all((directory / shard).is_file() for shard in shards)
    return any(path.is_file() for path in directory.glob("*.safetensors"))


def local_model_dir() -> Path | None:
    """The pre-installed model directory to load from instead of the hub cache."""
    value = os.environ.get(LOCAL_MODEL_DIR_ENV, "").strip()
    if not value:
        return None
    directory = Path(value).expanduser()
    if not (directory / "config.json").is_file():
        logger.warning("%s=%s has no config.json; using the hub cache", LOCAL_MODEL_DIR_ENV, value)
        return None
    if not _weights_complete(directory):
        logger.warning("%s=%s is missing weight shards; using the hub cache",
                       LOCAL_MODEL_DIR_ENV, value)
        return None
    return directory


def downloaded_bytes() -> int:
    """Bytes of this model in the hub cache, partial downloads included.

    The hub stages each file as blobs/<hash>.incomplete while it downloads,
    so the size of the blobs directory tracks the download as it happens.
    """
    blobs = _repo_cache_dir() / "blobs"
    total = 0
    try:
        for entry in os.scandir(blobs):
            try:
                if entry.is_file(follow_symlinks=False):
                    total += entry.stat(follow_symlinks=False).st_size
            except OSError:
                continue
    except OSError:
        return 0
    return total


def _fetch_expected_bytes() -> None:
    """Ask the Hub how large the pinned snapshot is (best effort)."""
    global _expected_bytes
    try:
        from huggingface_hub import HfApi

        info = HfApi().model_info(MODEL_ID, revision=MODEL_REVISION, files_metadata=True)
        total = sum((sibling.size or 0) for sibling in (info.siblings or []))
        if total > 0:
            _expected_bytes = total
    except Exception as exc:  # noqa: BLE001 - progress is a nicety
        logger.info("Could not read the snapshot size from the Hub: %s", exc)


def load_model():
    """Download (first run) and load the Gemma 4 E4B model via mlx-vlm.

    Runs on a background thread so the port is bound (and /health answers
    "loading", with download progress) while the ~5 GB first-run download is
    in progress. Failure is recorded, not raised: the viewer polls /health and
    needs a reachable server reporting `error` with a reason.
    """
    global _model, _processor, _load_error, _phase

    logger.info(f"Loading model: {MODEL_ID} @ {MODEL_REVISION}")
    start = time.time()
    try:
        # Always load from a directory on disk: loading by hub id asks the Hub
        # for the revision's file list even when everything is cached, which
        # fails offline. A complete local copy never touches the network.
        source = local_model_dir()
        if source is not None:
            logger.info("Loading from the installed copy at %s", source)
        else:
            source = complete_snapshot()
        if source is None:
            _phase = "downloading"
            # The size query runs beside the download rather than before it.
            threading.Thread(target=_fetch_expected_bytes, name="snapshot-size",
                             daemon=True).start()
            logger.info("Downloading %s @ %s to %s", MODEL_ID, MODEL_REVISION,
                        _hub_cache_dir())
            from huggingface_hub import snapshot_download

            source = Path(snapshot_download(MODEL_ID, revision=MODEL_REVISION))
            logger.info(f"Download finished in {time.time() - start:.1f}s")
        _phase = "loading"
        from mlx_vlm import load

        model, processor = load(str(source))
    except BaseException as exc:  # noqa: BLE001
        _load_error = describe_failure(exc)
        logger.error("Model load failed: %s", _load_error)
        return

    _processor = processor
    _model = model
    _phase = "ready"
    logger.info(f"Model loaded in {time.time() - start:.1f}s")


def _watch_parent():
    """Exit when the viewer that launched us goes away.

    The viewer terminates the server on quit, but a crash or force-quit skips
    that; without this the ~5 GB process would outlive it.
    """
    try:
        parent = int(os.environ.get("ODV_PARENT_PID", "0"))
    except ValueError:
        return
    if parent <= 1:
        return
    while True:
        if os.getppid() != parent:
            logger.info("Parent process %d is gone; exiting.", parent)
            os._exit(0)
        time.sleep(2)


# ---------------------------------------------------------------------------
# Input decoding
# ---------------------------------------------------------------------------
def _decode_image(base64_str: str) -> Image.Image:
    """Decode a base64 PNG string to a PIL Image. Raises 400 on bad input."""
    if len(base64_str) > MAX_IMAGE_B64_CHARS:
        raise HTTPException(413, "Image payload too large")
    try:
        image_bytes = base64.b64decode(base64_str, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(400, "image is not valid base64") from None
    try:
        image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as exc:
        raise HTTPException(400, f"image is not a readable image: {exc}") from None

    # Resize if too large (preserve aspect ratio)
    w, h = image.size
    if max(w, h) > MAX_IMAGE_SIZE:
        scale = MAX_IMAGE_SIZE / max(w, h)
        image = image.resize((max(1, int(w * scale)), max(1, int(h * scale))),
                             Image.LANCZOS)

    return image


def _mark_roi(image: Image.Image, roi: tuple[float, float, float, float]) -> Image.Image:
    """Return a copy of `image` with the normalized ROI outlined in red."""
    x, y, w, h = roi
    width, height = image.size
    marked = image.copy()
    draw = ImageDraw.Draw(marked)
    line = max(2, round(max(width, height) / 300))
    draw.rectangle(
        [x * width, y * height, (x + w) * width, (y + h) * height],
        outline=(255, 0, 0), width=line,
    )
    return marked


# ---------------------------------------------------------------------------
# Model output coercion
# ---------------------------------------------------------------------------
# The parsing helpers live in plugins/_shared/coerce.py (imported above).


def _coerce_roi(roi: Mapping) -> tuple[float, float, float, float]:
    """Validate a requested ROI; raises 400 when it is not a usable region."""
    corners = _raw_corners(roi)
    if corners is None:
        raise HTTPException(400, "roi needs numeric x, y, width, height")
    boxes = _coerce_boxes([{"x": corners[0], "y": corners[1],
                            "width": corners[2] - corners[0],
                            "height": corners[3] - corners[1]}])
    if not boxes or max(abs(v) for v in corners) > 1.0 + 1e-3:
        raise HTTPException(400, "roi must be a non-empty normalized (0-1) rectangle")
    b = boxes[0]
    return b["x"], b["y"], b["width"], b["height"]


# ---------------------------------------------------------------------------
# Inference
# ---------------------------------------------------------------------------
def _generate(image: Image.Image, prompt: str,
              cancel: threading.Event | None = None) -> str:
    """Run inference with the model, serialized on the model lock.

    Raises GenerationCancelled when `cancel` is set before or during the run.
    """
    return generate_text(_model, _processor, SYSTEM_PROMPT, prompt, image,
                         _model_lock, cancel, max_tokens=MAX_TOKENS,
                         temperature=TEMPERATURE, top_p=TOP_P)


# How often a running request checks whether its client is still connected.
DISCONNECT_POLL_SECONDS = 0.5


async def _run_generate(image: Image.Image, prompt: str,
                        request: Request | None = None) -> str:
    """Generate off the event loop; stop if the client goes away.

    The viewer abandons a request when its timeout fires or the user retries.
    Without this the abandoned run would hold the model lock to completion and
    the retry would queue behind it.
    """
    loop = asyncio.get_running_loop()
    cancel = threading.Event()
    future = loop.run_in_executor(None, _generate, image, prompt, cancel)
    try:
        while True:
            done, _ = await asyncio.wait({future}, timeout=DISCONNECT_POLL_SECONDS)
            if done:
                return future.result()
            if request is not None and await request.is_disconnected():
                logger.info("Client disconnected; cancelling generation")
                cancel.set()
                raise GenerationCancelled()
    finally:
        cancel.set()


def _require_model():
    if _model is None:
        raise HTTPException(503, _load_error or "Model not loaded yet")


def _get_memory_usage_mb() -> float | None:
    """Get current MLX memory usage in MB."""
    try:
        import mlx.core as mx
        getter = getattr(mx, "get_peak_memory", None) or mx.metal.get_peak_memory
        return round(getter() / (1024 * 1024), 1)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Start the model load in the background so the port binds immediately."""
    threading.Thread(target=load_model, name="model-load", daemon=True).start()
    threading.Thread(target=_watch_parent, name="parent-watch", daemon=True).start()
    yield
    logger.info("Server shutting down")


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(
    title="ODV-Annotate MLX Server",
    description="Local Gemma 4 E4B inference for DICOM annotation",
    version="0.2.0",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


@app.exception_handler(GenerationCancelled)
async def _cancelled(_request: Request, _exc: GenerationCancelled):
    # Nobody is listening any more; 499 is nginx's "client closed request".
    return JSONResponse({"detail": "Request cancelled"}, status_code=499)


@app.exception_handler(Exception)
async def _unexpected(_request: Request, exc: Exception):
    """Every failure answers {"detail": ...}, never a bare 500 text body.

    MLX raises plain RuntimeErrors (Metal out of memory, for one); the viewer
    shows `detail` to the user, so it carries the cause and, when recognised,
    what to do about it.
    """
    logger.exception("Request failed")
    return JSONResponse({"detail": describe_failure(exc)}, status_code=500)


def _host_allowed(host_header: str | None) -> bool:
    if not host_header:
        return False
    host = host_header.strip().lower()
    if host.startswith("["):
        return False  # IPv6 literal: we only bind IPv4 loopback
    return host.rsplit(":", 1)[0] in ALLOWED_HOSTS


class RequireLocalCaller:
    """Reject requests not addressed to loopback or lacking the launch token.

    No CORS headers are ever sent, so browsers cannot read responses either.

    A pure ASGI middleware rather than ``@app.middleware("http")``: Starlette's
    BaseHTTPMiddleware hands the route a receive channel that never reports
    ``http.disconnect``, so ``Request.is_disconnected()`` stayed False and an
    abandoned run kept the model to completion. Passing ``receive`` through
    untouched lets _run_generate see the client hang up.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        headers = Headers(scope=scope)
        if not _host_allowed(headers.get("host")):
            response = JSONResponse({"detail": "Forbidden host"}, status_code=403)
        elif not hmac.compare_digest(headers.get(TOKEN_HEADER, "").encode(),
                                     API_TOKEN.encode()):
            response = JSONResponse({"detail": "Missing or invalid token"}, status_code=401)
        else:
            await self.app(scope, receive, send)
            return
        await response(scope, receive, send)


app.add_middleware(RequireLocalCaller)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health", response_model=HealthResponse)
async def health():
    """Check server and model status."""
    common = {"model": MODEL_ID, "revision": MODEL_REVISION, "pid": os.getpid()}
    if _load_error is not None:
        return HealthResponse(status="error", error=_load_error, **common)
    if _model is None:
        progress = {}
        if _phase == "downloading":
            progress = {"download_bytes": downloaded_bytes(),
                        "download_total_bytes": _expected_bytes}
        return HealthResponse(status="loading", phase=_phase, **progress, **common)
    return HealthResponse(status="ready", memory_usage_mb=_get_memory_usage_mb(),
                          **common)


@app.get("/modes")
async def list_modes():
    """Return available analysis modes."""
    return {
        "modes": {
            key: {"label": val["label"], "description": val["description"]}
            for key, val in ANALYZE_MODES.items()
        },
        "default": DEFAULT_ANALYZE_MODE,
    }


def build_analyze_response(raw: str, image_size: tuple[int, int]) -> AnalyzeResponse:
    parsed = _as_object(_extract_json(raw), "bounding_boxes")
    if parsed is None:
        return AnalyzeResponse(description=raw.strip(), raw_response=raw)
    return AnalyzeResponse(
        findings=_coerce_findings(parsed.get("findings")),
        bounding_boxes=[BoundingBox(**b) for b in
                        _coerce_boxes(parsed.get("bounding_boxes"), image_size)],
        description=_coerce_text(parsed.get("description")),
        raw_response=raw,
    )


def build_roi_response(raw: str) -> ROIDescription:
    parsed = _as_object(_extract_json(raw), "items")
    if parsed is None or "items" in parsed:
        return ROIDescription(description=raw.strip(), raw_response=raw)
    return ROIDescription(
        label=_coerce_text(parsed.get("label")),
        description=_coerce_text(parsed.get("description")),
        confidence=_coerce_confidence(parsed.get("confidence")),
        raw_response=raw,
    )


def build_abnormality_response(raw: str,
                               image_size: tuple[int, int]) -> DetectAbnormalitiesResponse:
    parsed = _as_object(_extract_json(raw), "regions")
    if parsed is None:
        return DetectAbnormalitiesResponse(raw_response=raw)
    regions = _coerce_boxes(parsed.get("regions"), image_size, with_severity=True)
    return DetectAbnormalitiesResponse(
        regions=[AbnormalityRegion(**r) for r in regions],
        raw_response=raw,
    )


@app.post("/analyze", response_model=AnalyzeResponse)
async def analyze(request: AnalyzeRequest, http_request: Request):
    """Analyze a full DICOM image for anatomical structures and findings."""
    _require_model()

    mode_key = request.mode if request.mode in ANALYZE_MODES else DEFAULT_ANALYZE_MODE
    mode = ANALYZE_MODES[mode_key]

    image = _decode_image(request.image)
    info = request.window_info

    prompt = mode["prompt"].format(
        modality=info.modality,
        description=info.description or info.body_part or "medical image",
        json_format=ANALYZE_JSON_FORMAT,
    )

    raw = await _run_generate(image, prompt, http_request)
    return build_analyze_response(raw, image.size)


@app.post("/describe-roi", response_model=ROIDescription)
async def describe_roi(request: DescribeROIRequest, http_request: Request):
    """Describe a user-selected region of interest."""
    _require_model()

    roi = _coerce_roi(request.roi)
    image = _mark_roi(_decode_image(request.image), roi)

    prompt = DESCRIBE_ROI_PROMPT_TEMPLATE.format(
        x=roi[0], y=roi[1], w=roi[2], h=roi[3],
        context=request.context or "none",
    )

    raw = await _run_generate(image, prompt, http_request)
    return build_roi_response(raw)


@app.post("/detect-abnormalities", response_model=DetectAbnormalitiesResponse)
async def detect_abnormalities(request: DetectAbnormalitiesRequest, http_request: Request):
    """Detect potential abnormalities in a DICOM image."""
    _require_model()

    image = _decode_image(request.image)

    prompt = DETECT_ABNORMALITIES_PROMPT_TEMPLATE.format(
        modality=request.modality,
    )

    raw = await _run_generate(image, prompt, http_request)
    return build_abnormality_response(raw, image.size)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=HOST,
        port=PORT,
        log_level="info",
        workers=1,  # single worker — MLX model is not fork-safe
    )
