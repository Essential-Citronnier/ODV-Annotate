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

# Health check
curl http://127.0.0.1:8741/health
```

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
