# ODV-Annotate MLX Server

Local AI inference server for DICOM annotation using **Gemma 4 E4B** (4-bit quantized) on Apple Silicon.

## Requirements

- **Apple Silicon only (M1 or later)**
- **macOS 14.0+** (Sonoma)
- **Python 3.11–3.13** (the app bundles CPython 3.11.17 from
  python-build-standalone `20261013`; `requirements.txt` is a full lock
  resolved for 3.11: mlx 0.32.0, mlx-vlm 0.6.5, transformers 5.14.1,
  huggingface-hub 1.31.0, ...)
- **RAM:** 8 GB works (close other apps; the app warns on Macs with less than
  12 GiB); 16 GB recommended. The model uses ~5 GB while loaded
- **~8GB free disk** on first run (~1.5GB packages + ~5.2GB model)

The model is `mlx-community/gemma-4-E4B-it-4bit` at revision
`475b9088d29754a3379866cf5aeb6b41acd313c2`. Its weights are downloaded from
Hugging Face, not shipped with the app; Google publishes Gemma 4 under the
[Apache License 2.0](https://ai.google.dev/gemma/docs/gemma_4_license), and you
are responsible for complying with the terms on the model card.

## Quick Start

```bash
cd mlx-server
./launch.sh
```

First run will:
1. Create a Python virtual environment
2. Install the pinned dependencies from PyPI (mlx, mlx-vlm, fastapi, etc.)
3. Download the model from Hugging Face (~5.2GB, one-time) into
   `~/.cache/huggingface/hub` (`HF_HOME` / `HF_HUB_CACHE` move it). While it
   downloads, `/health` reports `"phase": "downloading"` with
   `download_bytes` / `download_total_bytes`. If `ODV_MODEL_DIR` names a
   directory with this revision's `config.json` and `*.safetensors` (the app
   sets it to the Gemma plugin's installed weights when their completion marker
   records the pinned revision), the server loads that and downloads nothing.
4. Start the server on `http://127.0.0.1:8741`

8741 is only the port `launch.sh` uses (`server.py` reads `ODV_AI_PORT`, default 8741). The app
does not use a fixed port: it picks a free loopback port for the server it
spawns and passes it as `ODV_AI_PORT`. The app adopts a server started by
`launch.sh` only if both were started with the same `ODV_AI_TOKEN` (export it
in the shell that runs `launch.sh` and in the environment the viewer is
launched from); otherwise it starts its own.

A successful install writes `.venv/.odv-setup-complete` holding the SHA-256
of `requirements.txt`, the same marker the app writes, so a development build
of the viewer uses this venv as-is instead of running its own setup. When
`requirements.txt` changes, the next `./launch.sh` reinstalls.

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

Network use: the server reaches the network only to download the model from
Hugging Face when no complete local copy exists (and `launch.sh` / the app
reach PyPI to install packages). Inference requests and images stay on
`127.0.0.1`. The viewer itself separately checks GitHub's releases API for a
newer version (at launch, at most once a day, and on **Check for Updates...**).

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
