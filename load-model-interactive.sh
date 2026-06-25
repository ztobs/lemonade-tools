#!/bin/bash
# Interactive Model Loader for llama-server (Lemonade ROCm gfx1151)
# Mirrors LM Studio load-model-interactive.sh functionality
# Uses llama-server single-model mode (one server per model, port 8080)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_setting() { echo -e "${CYAN}  ➜${NC} $*"; }

LLAMA_SERVER="$HOME/AI/llama-server/bin/llama-server"
MODELS_DIR="$HOME/.lmstudio/models"
PID_FILE="$HOME/AI/llama-server/llama-server.pid"
LOG_FILE="$HOME/AI/llama-server/llama-server.log"
SERVER_HOST="0.0.0.0"
SERVER_PORT=1234
MEMORY_GUARDRAIL_GB=120

# Required ROCm env vars for Lemonade on gfx1151
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export ROCBLAS_USE_HIPBLASLT=1
export RADV_PERFTEST=bfloat16
export LD_LIBRARY_PATH="$HOME/AI/llama-server/bin:${LD_LIBRARY_PATH:-}"

# ── helpers ──────────────────────────────────────────────────────────────────

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

get_loaded_model() {
    curl -s "http://${SERVER_HOST}:${SERVER_PORT}/v1/models" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'] if d.get('data') else '')" 2>/dev/null || echo ""
}

calculate_max_context() {
    local model_size_gb=$1
    local gpu_ratio=$2
    local guardrail=$MEMORY_GUARDRAIL_GB

    python3 - "$model_size_gb" "$gpu_ratio" "$guardrail" << 'PY'
import sys
model_gb, gpu_ratio, guardrail = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
vram_buffer = 7
kv_per_token = 120000
model_vram = model_gb * gpu_ratio
ram_for_cpu = model_gb * (1 - gpu_ratio)
available = guardrail - model_vram - vram_buffer
if gpu_ratio < 1.0:
    available -= ram_for_cpu
available = max(available, 0)
available_bytes = available * 1073741824
max_tokens = int(available_bytes / kv_per_token)
print(f"{max_tokens}:{kv_per_token}:{available:.2f}")
PY
}

read_ini_value() {
    local file="$1" section="$2" key="$3"
    python3 - "$file" "$section" "$key" << 'PY'
import sys, configparser
f, sec, key = sys.argv[1], sys.argv[2], sys.argv[3]
c = configparser.ConfigParser()
c.read(f)
try:
    print(c[sec][key])
except Exception:
    print("")
PY
}

# ── pre-flight ────────────────────────────────────────────────────────────────

if [ ! -f "$LLAMA_SERVER" ]; then
    log_error "llama-server not found at: $LLAMA_SERVER"
    log_info "Run 'llm_install' first to download the binary."
    exit 1
fi

# ── show current state ────────────────────────────────────────────────────────

echo
log_info "Currently loaded model:"
if check_server_running; then
    loaded=$(get_loaded_model)
    if [ -n "$loaded" ]; then
        log_setting "$loaded"
    else
        log_setting "(server running, no model info)"
    fi
    pid=$(cat "$PID_FILE" 2>/dev/null)
    log_setting "PID: $pid  |  http://${SERVER_HOST}:${SERVER_PORT}"
else
    echo "  (none — server not running)"
fi
echo

# ── discover GGUF models ──────────────────────────────────────────────────────

log_info "Scanning for GGUF models in $MODELS_DIR ..."
echo

# Build list: exclude mmproj, shards (.part), duplicates by display path
mapfile -t gguf_files < <(
    find -L "$MODELS_DIR" -type f -name "*.gguf" \
        ! -path "*/toolbox-models/*" \
        ! -path "*/.cache/*" \
        ! -name "*mmproj*" \
        ! -name "*.part*" \
        ! -name "*-0000[2-9]-of-*" \
        ! -name "*-000[1-9][0-9]-of-*" 2>/dev/null \
    | sort
)

if [ ${#gguf_files[@]} -eq 0 ]; then
    log_error "No GGUF models found in $MODELS_DIR"
    exit 1
fi

declare -a model_paths model_names model_sizes_gb

for f in "${gguf_files[@]}"; do
    rel="${f#$MODELS_DIR/}"
    # Sum all shards: strip shard suffix to find siblings
    base_name=$(basename "$f" .gguf | sed 's/-0000[0-9]-of-[0-9]*$//')
    base_dir=$(dirname "$f")
    total_bytes=0
    while IFS= read -r shard; do
        sz=$(stat -c%s "$shard" 2>/dev/null || echo 0)
        total_bytes=$((total_bytes + sz))
    done < <(find -L "$base_dir" -maxdepth 1 -type f -name "${base_name}*.gguf" ! -path "*/.cache/*" 2>/dev/null)
    size_gb=$(python3 -c "print(f'{$total_bytes / 1073741824:.2f}')")
    model_paths+=("$f")
    model_names+=("$rel")
    model_sizes_gb+=("$size_gb")
done

log_info "Available models:"
echo
for i in "${!model_names[@]}"; do
    printf "  [%d] %s  (%s GB)\n" "$((i+1))" "${model_names[$i]}" "${model_sizes_gb[$i]}"
done
echo

read -p "Select model number (1-${#model_names[@]}) or 'q' to quit: " choice

if [ "x$choice" = "xq" ] || [ "x$choice" = "xQ" ]; then
    log_info "Exiting..."
    exit 0
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#model_names[@]} ]; then
    log_error "Invalid selection: $choice"
    exit 1
fi

idx=$((choice - 1))
selected_path="${model_paths[$idx]}"
selected_name="${model_names[$idx]}"
selected_size="${model_sizes_gb[$idx]}"

log_info "Selected: $selected_name  (${selected_size} GB)"
echo

# ── load per-model config defaults from models-preset.ini ────────────────────

INI_FILE="$HOME/AI/llama-server/models-preset.ini"
# Derive a short key: last two path segments minus extension
# e.g. "lmstudio-community/Qwen3.5-35B-A3B-GGUF/Qwen3.5-35B-A3B-Q4_K_M.gguf"
#   -> "Qwen3.5-35B-A3B-Q4_K_M" (filename without .gguf)
model_key=$(basename "$selected_path" .gguf)

default_ngl=999
default_context=32768
default_parallel=1
default_batch=512
default_cache_type_k="q8_0"
default_cache_type_v="q8_0"
default_threads=""

if [ -f "$INI_FILE" ]; then
    v=$(read_ini_value "$INI_FILE" "$model_key" "n-gpu-layers"); [ -n "$v" ] && default_ngl="$v"
    v=$(read_ini_value "$INI_FILE" "$model_key" "ctx-size");     [ -n "$v" ] && default_context="$v"
    v=$(read_ini_value "$INI_FILE" "$model_key" "parallel");     [ -n "$v" ] && default_parallel="$v"
    v=$(read_ini_value "$INI_FILE" "$model_key" "batch-size");   [ -n "$v" ] && default_batch="$v"
    v=$(read_ini_value "$INI_FILE" "$model_key" "cache-type-k"); [ -n "$v" ] && default_cache_type_k="$v"
    v=$(read_ini_value "$INI_FILE" "$model_key" "cache-type-v"); [ -n "$v" ] && default_cache_type_v="$v"
    v=$(read_ini_value "$INI_FILE" "$model_key" "threads");      [ -n "$v" ] && default_threads="$v"
    log_info "Loaded per-model config from: $INI_FILE  [section: $model_key]"
fi

# ── GPU offload + memory analysis ────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════"
log_info "Configuration Settings:"
echo

log_setting "GPU Layers (n-gpu-layers)"
echo "  999 = all layers on GPU (recommended for Strix Halo unified memory)"
echo "  0   = CPU only"
read -p "  Enter value (default: $default_ngl): " ngl
ngl=${ngl:-$default_ngl}

# Effective ratio for memory calc: clamp to 0..1
if [ "$ngl" -ge 999 ] 2>/dev/null; then
    effective_ratio=1.0
else
    effective_ratio=0.5  # conservative estimate for partial offload
fi

calc=$(calculate_max_context "$selected_size" "$effective_ratio")
max_context=$(echo "$calc" | cut -d: -f1)
kv_bytes=$(echo "$calc" | cut -d: -f2)
available_gb=$(echo "$calc" | cut -d: -f3)

echo
log_success "Memory Analysis:"
log_setting "Model size: ${selected_size} GB"
log_setting "GPU layers: $ngl"
log_setting "System memory guardrail: ${MEMORY_GUARDRAIL_GB} GB"
log_setting "Available for KV cache: ${available_gb} GB"
log_setting "KV cache per token: $(python3 -c "print($kv_bytes // 1024)") KB"
log_setting "Maximum safe context: ${max_context} tokens"
echo
echo "  ⚠️  Exceeding ${max_context} tokens risks OOM crash!"
echo

log_setting "Context Length"
echo "  Current default: $default_context  |  Max safe: $max_context"

while true; do
    read -p "  Enter value (or press Enter for default): " context_length
    context_length=${context_length:-$default_context}

    if ! [[ "$context_length" =~ ^[0-9]+$ ]]; then
        log_error "Please enter a valid number"
        continue
    fi

    if [ "$context_length" -gt "$max_context" ]; then
        log_warning "Context $context_length exceeds maximum safe value ($max_context)!"
        read -p "  Continue anyway? (y/n): " confirm_override
        if [ "x$confirm_override" = "xy" ] || [ "x$confirm_override" = "xY" ]; then
            log_warning "Proceeding with risk of OOM crash..."
            break
        fi
    else
        break
    fi
done

echo
log_setting "Parallel Slots (concurrent prediction sequences)"
read -p "  Enter value (default: $default_parallel): " parallel_slots
parallel_slots=${parallel_slots:-$default_parallel}

echo
log_setting "Batch Size (tokens processed per forward pass)"
read -p "  Enter value (default: $default_batch): " batch_size
batch_size=${batch_size:-$default_batch}

echo
log_setting "KV Cache Type K  (q8_0 recommended — good quality, saves memory)"
echo "  Options: f16, q8_0, q4_0, q4_1"
read -p "  Enter value (default: $default_cache_type_k): " cache_type_k
cache_type_k=${cache_type_k:-$default_cache_type_k}

echo
log_setting "KV Cache Type V"
echo "  Options: f16, q8_0, q4_0, q4_1"
read -p "  Enter value (default: $default_cache_type_v): " cache_type_v
cache_type_v=${cache_type_v:-$default_cache_type_v}

echo
log_setting "CPU Threads (for CPU-side work, leave blank for auto)"
if [ -n "$default_threads" ]; then
    read -p "  Enter value (default: $default_threads): " threads
    threads=${threads:-$default_threads}
else
    read -p "  Enter value (or press Enter for auto): " threads
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo
echo "═══════════════════════════════════════════════════════════"
log_info "Final Configuration:"
log_setting "Model:         $selected_name  (${selected_size} GB)"
log_setting "Context:       $context_length  (max safe: $max_context)"
log_setting "GPU layers:    $ngl"
log_setting "Parallel:      $parallel_slots"
log_setting "Batch size:    $batch_size"
log_setting "Cache type K:  $cache_type_k"
log_setting "Cache type V:  $cache_type_v"
log_setting "Threads:       ${threads:-auto}"
log_setting "Flash Attn:    enabled  (-fa on)"
log_setting "No-mmap:       yes  (required on Strix Halo)"
log_setting "Host:          ${SERVER_HOST}:${SERVER_PORT}"
echo "═══════════════════════════════════════════════════════════"
echo

# ── handle already-running server ────────────────────────────────────────────

if check_server_running; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    log_warning "llama-server is already running (PID $pid)"
    read -p "Stop it and load new model? (y/n): " stop_confirm
    if [ "x$stop_confirm" != "xy" ] && [ "x$stop_confirm" != "xY" ]; then
        log_info "Cancelled."
        exit 0
    fi
    log_info "Stopping existing server (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 2
    rm -f "$PID_FILE"
fi

read -p "Proceed with loading? (y/n): " confirm
if [ "x$confirm" != "xy" ] && [ "x$confirm" != "xY" ]; then
    log_info "Cancelled."
    exit 0
fi

# ── build command ──────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$PID_FILE")"

cmd=(
    "$LLAMA_SERVER"
    --model "$selected_path"
    --ctx-size "$context_length"
    --n-gpu-layers "$ngl"
    --parallel "$parallel_slots"
    --batch-size "$batch_size"
    --cache-type-k "$cache_type_k"
    --cache-type-v "$cache_type_v"
    -fa on
    --no-mmap
    --host "$SERVER_HOST"
    --port "$SERVER_PORT"
    --log-file "$LOG_FILE"
)

if [ -n "$threads" ]; then
    cmd+=(--threads "$threads")
fi

echo
log_info "Starting llama-server..."
log_warning "Do not interrupt this process!"
echo
log_setting "Command: ${cmd[*]}"
echo

# Launch in background, save PID
"${cmd[@]}" &
server_pid=$!
echo "$server_pid" > "$PID_FILE"

log_info "Server PID: $server_pid  |  Log: $LOG_FILE"
log_info "Waiting for server to become ready..."

# Poll health endpoint for up to 120 seconds
for i in $(seq 1 60); do
    sleep 2
    if curl -sf "http://127.0.0.1:${SERVER_PORT}/health" > /dev/null 2>&1; then
        echo
        log_success "llama-server is ready!"
        log_setting "Endpoint: http://${SERVER_HOST}:${SERVER_PORT}"
        log_setting "Model:    $selected_name"
        echo
        log_info "Test with: curl http://${SERVER_HOST}:${SERVER_PORT}/v1/models"
        exit 0
    fi
    printf "."
done

echo
log_error "Server did not become ready after 120 seconds."
log_info "Check log: tail -50 $LOG_FILE"
exit 1
