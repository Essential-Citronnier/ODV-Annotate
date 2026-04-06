#!/bin/bash
# ============================================================================
# ODV-Annotate MLX Server Launcher
# ============================================================================
# Sets up a Python virtual environment and starts the Gemma 4 E4B server.
#
# Usage:
#   ./launch.sh           # Setup (first run) + start server
#   ./launch.sh --setup   # Force reinstall dependencies
#   ./launch.sh --stop    # Stop running server
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
PID_FILE="$SCRIPT_DIR/.server.pid"
PORT=8741

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------------------------------------------------------
# Stop server
# ---------------------------------------------------------------------------
stop_server() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            info "Stopping server (PID $PID)..."
            kill "$PID"
            rm -f "$PID_FILE"
            info "Server stopped."
        else
            rm -f "$PID_FILE"
            info "Server was not running."
        fi
    else
        info "No PID file found. Server may not be running."
    fi
}

if [ "${1:-}" = "--stop" ]; then
    stop_server
    exit 0
fi

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------
# Check Apple Silicon
if [ "$(uname -m)" != "arm64" ]; then
    error "MLX requires Apple Silicon (M1+). This machine is $(uname -m)."
    exit 1
fi

# Check Python 3.10+
if ! command -v python3 &>/dev/null; then
    error "python3 not found. Install Python 3.10+ from python.org or via Homebrew."
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)

if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 10 ]; }; then
    error "Python 3.10+ required. Found Python $PYTHON_VERSION."
    exit 1
fi

info "Using Python $PYTHON_VERSION"

# ---------------------------------------------------------------------------
# Setup virtual environment
# ---------------------------------------------------------------------------
FORCE_SETUP=false
if [ "${1:-}" = "--setup" ]; then
    FORCE_SETUP=true
fi

if [ ! -d "$VENV_DIR" ] || [ "$FORCE_SETUP" = true ]; then
    info "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"

    info "Installing dependencies (this may take a few minutes)..."
    "$VENV_DIR/bin/pip" install --upgrade pip -q
    "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"
    info "Dependencies installed."
else
    info "Virtual environment found."
fi

# ---------------------------------------------------------------------------
# Check if server is already running
# ---------------------------------------------------------------------------
if curl -s "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    warn "Server already running on port $PORT."
    curl -s "http://127.0.0.1:$PORT/health" | python3 -m json.tool
    exit 0
fi

# ---------------------------------------------------------------------------
# Start server
# ---------------------------------------------------------------------------
stop_server 2>/dev/null || true

info "Starting MLX server on port $PORT..."
info "Model will be downloaded on first run (~4.5GB for 4-bit quantized Gemma 4 E4B)"
echo ""

"$VENV_DIR/bin/python" "$SCRIPT_DIR/server.py" &
SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"

info "Server started (PID $SERVER_PID)"
info "Waiting for model to load..."

# Wait for server to be ready (model loading can take 30-60s on first run)
MAX_WAIT=300
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    HEALTH=$(curl -s "http://127.0.0.1:$PORT/health" 2>/dev/null || echo "")
    if echo "$HEALTH" | grep -q '"ready"'; then
        echo ""
        info "Server ready!"
        echo "$HEALTH" | python3 -m json.tool
        exit 0
    fi

    # Check if process is still alive
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        error "Server process exited unexpectedly."
        rm -f "$PID_FILE"
        exit 1
    fi

    sleep 2
    WAITED=$((WAITED + 2))
    printf "."
done

echo ""
warn "Server did not become ready within ${MAX_WAIT}s. It may still be loading the model."
info "Check: curl http://127.0.0.1:$PORT/health"
