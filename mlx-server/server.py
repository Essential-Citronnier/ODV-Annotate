"""
MLX Gemma 4 E4B Server for ODV-Annotate
========================================
Local inference server for AI-assisted DICOM annotation.
Runs Gemma 4 E4B (4-bit quantized) on Apple Silicon via MLX.

Endpoints:
    GET  /health               - Server/model status
    POST /analyze              - Full image analysis with structure detection
    POST /describe-roi         - Describe a user-selected region
    POST /detect-abnormalities - Highlight potential abnormalities
"""

import asyncio
import base64
import io
import json
import logging
import re
import time
from contextlib import asynccontextmanager
from threading import Lock

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from PIL import Image

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("mlx-server")

# ---------------------------------------------------------------------------
# Global model state
# ---------------------------------------------------------------------------
_model = None
_processor = None
_model_lock = Lock()

MODEL_ID = "mlx-community/gemma-4-E4B-it-4bit"
MAX_IMAGE_SIZE = 1120  # max dimension before resize
MAX_TOKENS = 2048

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
    severity: str = "normal"


class DetectAbnormalitiesResponse(BaseModel):
    regions: list[AbnormalityRegion] = []
    raw_response: str | None = None


class HealthResponse(BaseModel):
    status: str
    model: str
    memory_usage_mb: float | None = None


# ---------------------------------------------------------------------------
# Model loading
# ---------------------------------------------------------------------------
def load_model():
    """Load the Gemma 4 E4B model via mlx-vlm."""
    global _model, _processor

    logger.info(f"Loading model: {MODEL_ID}")
    start = time.time()

    from mlx_vlm import load

    _model, _processor = load(MODEL_ID)

    elapsed = time.time() - start
    logger.info(f"Model loaded in {elapsed:.1f}s")


# ---------------------------------------------------------------------------
# Inference helpers
# ---------------------------------------------------------------------------
def _decode_image(base64_str: str) -> Image.Image:
    """Decode a base64 PNG string to a PIL Image."""
    image_bytes = base64.b64decode(base64_str)
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")

    # Resize if too large (preserve aspect ratio)
    w, h = image.size
    if max(w, h) > MAX_IMAGE_SIZE:
        scale = MAX_IMAGE_SIZE / max(w, h)
        image = image.resize((int(w * scale), int(h * scale)), Image.LANCZOS)

    return image


def _generate(image: Image.Image, prompt: str) -> str:
    """Run inference with the model. Thread-safe via lock."""
    from mlx_vlm import generate

    with _model_lock:
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "image"},
                    {"type": "text", "text": prompt},
                ],
            },
        ]

        formatted_prompt = _processor.apply_chat_template(
            messages, add_generation_prompt=True
        )

        response = generate(
            _model,
            _processor,
            formatted_prompt,
            image=[image],
            max_tokens=MAX_TOKENS,
            temperature=1.0,
            top_p=0.95,
        )

    return response.text if hasattr(response, 'text') else str(response)


def _extract_json(text: str) -> dict | None:
    """Try to extract a JSON object from model output."""
    # Try direct parse
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Try to find JSON block in markdown code fences
    match = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(1))
        except json.JSONDecodeError:
            pass

    # Try to find any JSON object
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            pass

    return None


def _get_memory_usage_mb() -> float | None:
    """Get current MLX memory usage in MB."""
    try:
        import mlx.core as mx
        peak = mx.metal.get_peak_memory() / (1024 * 1024)
        return round(peak, 1)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load model on startup."""
    load_model()
    yield
    logger.info("Server shutting down")


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(
    title="ODV-Annotate MLX Server",
    description="Local Gemma 4 E4B inference for DICOM annotation",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # localhost only via bind address
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health", response_model=HealthResponse)
async def health():
    """Check server and model status."""
    if _model is None:
        return HealthResponse(status="loading", model=MODEL_ID)
    return HealthResponse(
        status="ready",
        model=MODEL_ID,
        memory_usage_mb=_get_memory_usage_mb(),
    )


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


@app.post("/analyze", response_model=AnalyzeResponse)
async def analyze(request: AnalyzeRequest):
    """Analyze a full DICOM image for anatomical structures and findings."""
    if _model is None:
        raise HTTPException(503, "Model not loaded yet")

    mode_key = request.mode if request.mode in ANALYZE_MODES else DEFAULT_ANALYZE_MODE
    mode = ANALYZE_MODES[mode_key]

    image = _decode_image(request.image)
    info = request.window_info

    prompt = mode["prompt"].format(
        modality=info.modality,
        description=info.description or info.body_part or "medical image",
        json_format=ANALYZE_JSON_FORMAT,
    )

    loop = asyncio.get_event_loop()
    raw = await loop.run_in_executor(None, _generate, image, prompt)

    parsed = _extract_json(raw)
    if parsed is None:
        return AnalyzeResponse(
            description=raw.strip(),
            raw_response=raw,
        )

    boxes = []
    for b in parsed.get("bounding_boxes", []):
        try:
            boxes.append(BoundingBox(**b))
        except Exception:
            continue

    return AnalyzeResponse(
        findings=parsed.get("findings", []),
        bounding_boxes=boxes,
        description=parsed.get("description", ""),
        raw_response=raw,
    )


@app.post("/describe-roi", response_model=ROIDescription)
async def describe_roi(request: DescribeROIRequest):
    """Describe a user-selected region of interest."""
    if _model is None:
        raise HTTPException(503, "Model not loaded yet")

    image = _decode_image(request.image)
    roi = request.roi

    prompt = DESCRIBE_ROI_PROMPT_TEMPLATE.format(
        x=roi.get("x", 0),
        y=roi.get("y", 0),
        w=roi.get("width", 0),
        h=roi.get("height", 0),
        context=request.context,
    )

    loop = asyncio.get_event_loop()
    raw = await loop.run_in_executor(None, _generate, image, prompt)

    parsed = _extract_json(raw)
    if parsed is None:
        return ROIDescription(
            description=raw.strip(),
            raw_response=raw,
        )

    return ROIDescription(
        label=parsed.get("label", ""),
        description=parsed.get("description", ""),
        confidence=parsed.get("confidence", 0.0),
        raw_response=raw,
    )


@app.post("/detect-abnormalities", response_model=DetectAbnormalitiesResponse)
async def detect_abnormalities(request: DetectAbnormalitiesRequest):
    """Detect potential abnormalities in a DICOM image."""
    if _model is None:
        raise HTTPException(503, "Model not loaded yet")

    image = _decode_image(request.image)

    prompt = DETECT_ABNORMALITIES_PROMPT_TEMPLATE.format(
        modality=request.modality,
    )

    loop = asyncio.get_event_loop()
    raw = await loop.run_in_executor(None, _generate, image, prompt)

    parsed = _extract_json(raw)
    if parsed is None:
        return DetectAbnormalitiesResponse(raw_response=raw)

    regions = []
    for r in parsed.get("regions", []):
        try:
            regions.append(AbnormalityRegion(**r))
        except Exception:
            continue

    return DetectAbnormalitiesResponse(
        regions=regions,
        raw_response=raw,
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "server:app",
        host="127.0.0.1",
        port=8741,
        log_level="info",
        workers=1,  # single worker — MLX model is not fork-safe
    )
