#!/bin/bash
# Unload models / stop llama-server
# Mirrors LM Studio unload-models.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }

PID_FILE="$HOME/AI/llama-server/llama-server.pid"
SERVER_HOST="127.0.0.1"
SERVER_PORT=1234

check_server_running() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

get_server_pid() {
    cat "$PID_FILE" 2>/dev/null || echo ""
}

list_models() {
    curl -s "http://${SERVER_HOST}:${SERVER_PORT}/v1/models" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for m in d.get('data', []):
        print(m['id'])
except Exception:
    pass
" 2>/dev/null || true
}

# ── check server is running ───────────────────────────────────────────────────

if ! check_server_running; then
    log_info "llama-server is not running."
    # Clean up stale PID file if present
    rm -f "$PID_FILE"
    exit 0
fi

pid=$(get_server_pid)
echo
log_info "llama-server is running (PID $pid)"
echo

# ── list loaded models ────────────────────────────────────────────────────────

mapfile -t loaded_models < <(list_models)

if [ ${#loaded_models[@]} -eq 0 ]; then
    log_warning "Could not retrieve model list (server may still be loading)."
else
    log_info "Currently loaded model(s):"
    for m in "${loaded_models[@]}"; do
        echo "  • $m"
    done
fi
echo

# ── offer options ─────────────────────────────────────────────────────────────

echo "Options:"
echo "  [s] Stop server (unloads all models, frees all memory)"
echo "  [q] Quit (leave server running)"
echo

# Note: llama-server single-model mode doesn't support hot-swapping via API;
# stopping the process is the equivalent of "unload all".
# If running router mode with multiple models, individual unload via API is possible.
if [ ${#loaded_models[@]} -gt 1 ]; then
    echo "  [u] Unload specific model via API (router mode)"
    echo
    read -p "Choose option (s/u/q): " option
else
    read -p "Choose option (s/q): " option
fi

case "$option" in
    s|S)
        log_warning "Stopping llama-server (PID $pid)..."
        kill "$pid" 2>/dev/null || true

        # Wait for clean shutdown
        for i in $(seq 1 10); do
            sleep 1
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
        done

        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            log_warning "Graceful shutdown timed out, sending SIGKILL..."
            kill -9 "$pid" 2>/dev/null || true
        fi

        rm -f "$PID_FILE"
        log_success "Server stopped. All models unloaded."
        ;;

    u|U)
        if [ ${#loaded_models[@]} -eq 0 ]; then
            log_error "No models to unload."
            exit 1
        fi

        echo
        log_info "Select model to unload:"
        for i in "${!loaded_models[@]}"; do
            echo "  [$((i+1))] ${loaded_models[$i]}"
        done
        echo
        read -p "Select (1-${#loaded_models[@]}): " mchoice

        if ! [[ "$mchoice" =~ ^[0-9]+$ ]] || [ "$mchoice" -lt 1 ] || [ "$mchoice" -gt ${#loaded_models[@]} ]; then
            log_error "Invalid selection"
            exit 1
        fi

        selected_model="${loaded_models[$((mchoice-1))]}"
        log_info "Unloading: $selected_model"

        response=$(curl -s -X POST \
            "http://${SERVER_HOST}:${SERVER_PORT}/models/unload" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"$selected_model\"}" 2>/dev/null || echo "error")

        if echo "$response" | grep -qi "error"; then
            log_error "Unload request failed."
            log_info "Response: $response"
            exit 1
        fi

        log_success "Model unloaded: $selected_model"
        ;;

    q|Q)
        log_info "Exiting (server still running)."
        exit 0
        ;;

    *)
        log_error "Invalid option: $option"
        exit 1
        ;;
esac

echo
log_info "Server status:"
if check_server_running; then
    remaining=$(list_models)
    if [ -n "$remaining" ]; then
        echo "  Running — loaded: $remaining"
    else
        echo "  Running — no models loaded"
    fi
else
    echo "  Stopped"
fi
