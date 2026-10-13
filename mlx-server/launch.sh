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
# The app's setup marker (AIServerManager.setupMarkerURL): SHA-256 of
# requirements.txt, written only after a successful install and import probe.
# Writing the same marker here lets a development build of the app use this
# venv as-is instead of rerunning its own setup once.
SETUP_MARKER="$VENV_DIR/.odv-setup-complete"
REQUIREMENTS="$SCRIPT_DIR/requirements.txt"
PORT=8741

# The server rejects requests without this per-launch token. Export the same
# ODV_AI_TOKEN when launching the viewer so it adopts this server.
if [ -z "${ODV_AI_TOKEN:-}" ]; then
    ODV_AI_TOKEN="$(openssl rand -hex 32)"
fi
export ODV_AI_TOKEN
AUTH_HEADER="X-ODV-Token: $ODV_AI_TOKEN"

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

requirements_hash() {
    shasum -a 256 "$REQUIREMENTS" | cut -d' ' -f1
}

# Installed, and for the current requirements? The same test the app applies.
setup_current() {
    [ -x "$VENV_DIR/bin/python3" ] || return 1
    [ -f "$SETUP_MARKER" ] || return 1
    [ "$(tr -d '[:space:]' < "$SETUP_MARKER")" = "$(requirements_hash)" ]
}

if [ "$FORCE_SETUP" = true ] || ! setup_current; then
    if [ ! -d "$VENV_DIR" ] || [ "$FORCE_SETUP" = true ]; then
        info "Creating virtual environment..."
        python3 -m venv --clear "$VENV_DIR"
    else
        info "Virtual environment out of date; reinstalling dependencies..."
    fi
    # An interrupted install must not look complete.
    rm -f "$SETUP_MARKER"

    info "Installing dependencies (this may take a few minutes)..."
    "$VENV_DIR/bin/pip" install --upgrade pip -q
    "$VENV_DIR/bin/pip" install -r "$REQUIREMENTS"

    info "Verifying installation..."
    "$VENV_DIR/bin/python3" -c "import mlx_vlm, fastapi, uvicorn, PIL"
    requirements_hash > "$SETUP_MARKER"
    info "Dependencies installed."
else
    info "Virtual environment found and current."
fi

# ---------------------------------------------------------------------------
# Check if server is already running
# ---------------------------------------------------------------------------
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "$AUTH_HEADER" "http://127.0.0.1:$PORT/health" 2>/dev/null || true)
if [ "$STATUS" = "200" ]; then
    warn "Server already running on port $PORT."
    curl -s -H "$AUTH_HEADER" "http://127.0.0.1:$PORT/health" | python3 -m json.tool
    exit 0
elif [ -n "$STATUS" ] && [ "$STATUS" != "000" ]; then
    error "Port $PORT is in use by another process (or a server started with a different ODV_AI_TOKEN)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Start server
# ---------------------------------------------------------------------------
stop_server 2>/dev/null || true

info "Starting MLX server on port $PORT..."
info "Model will be downloaded on first run (~5.2 GB for 4-bit Gemma 4 E4B), unless ODV_MODEL_DIR names an installed copy"
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
    HEALTH=$(curl -s -H "$AUTH_HEADER" "http://127.0.0.1:$PORT/health" 2>/dev/null || echo "")
    if echo "$HEALTH" | grep -q '"ready"'; then
        echo ""
        info "Server ready!"
        echo "$HEALTH" | python3 -m json.tool
        info "To let the viewer use this server, start it with ODV_AI_TOKEN=$ODV_AI_TOKEN"
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
info "Check: curl -H \"X-ODV-Token: $ODV_AI_TOKEN\" http://127.0.0.1:$PORT/health"
