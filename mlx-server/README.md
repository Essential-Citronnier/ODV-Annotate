# ODV-Annotate MLX Server

Local AI inference server for DICOM annotation using **Gemma 4 E4B** (4-bit quantized) on Apple Silicon.

## Requirements

- **Apple Silicon Mac** (M1 Pro or better recommended)
- **macOS 14.0+** (Sonoma)
- **Python 3.10+**
- **16GB+ RAM** recommended (model uses ~4-5GB)

## Quick Start

```bash
cd mlx-server
./launch.sh
```

First run will:
1. Create a Python virtual environment
2. Install dependencies (mlx, mlx-vlm, fastapi, etc.)
3. Download the model from Hugging Face (~4.5GB, one-time)
4. Start the server on `http://127.0.0.1:8741`

## Usage

```bash
# Start server
./launch.sh

# Force reinstall dependencies
./launch.sh --setup

# Stop server
./launch.sh --stop

# Health check (every request needs the token the server was started with)
curl -H "X-ODV-Token: $ODV_AI_TOKEN" http://127.0.0.1:8741/health

# Tests (no model download needed)
.venv/bin/python -m unittest test_server
```

## Security

The server binds to `127.0.0.1` only, sends no CORS headers, and rejects any
request that lacks the `X-ODV-Token` header or whose `Host` header is not
`127.0.0.1`/`localhost`. The viewer generates a fresh token on every launch
and passes it to the server it spawns via `ODV_AI_TOKEN`; a server it did not
start is never adopted unless it was started with the same token (export
`ODV_AI_TOKEN` for both the viewer and `launch.sh` during development).

The model revision is pinned in `server.py` (`MODEL_REVISION`, overridable
with the `ODV_MODEL_REVISION` environment variable) and Python dependencies
are pinned exactly in `requirements.txt`.

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Server status and model info |
| `/analyze` | POST | Full image analysis with structure detection |
| `/describe-roi` | POST | Describe a selected region of interest |
| `/detect-abnormalities` | POST | Detect potential abnormalities |

### Example: Analyze an image

```bash
# Encode image to base64
IMAGE_B64=$(base64 -i sample.png)

# Send request
curl -X POST http://127.0.0.1:8741/analyze \
  -H "Content-Type: application/json" \
  -H "X-ODV-Token: $ODV_AI_TOKEN" \
  -d "{
    \"image\": \"$IMAGE_B64\",
    \"window_info\": {
      \"modality\": \"CT\",
      \"description\": \"Chest CT\",
      \"body_part\": \"Chest\"
    }
  }"
```

## Disclaimer

AI analysis is for **research and educational purposes only**. It must NOT be used as a clinical diagnosis tool.
