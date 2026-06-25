#!/bin/bash
# Set Optimal Inference Parameters for llama-server models
# Updates models-preset.ini — mirrors LM Studio set-optimal-params.sh

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
log_header()  { echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"; }

INI_FILE="$HOME/AI/llama-server/models-preset.ini"

ini_list_sections() {
    python3 - "$1" << 'PY'
import sys, configparser
c = configparser.ConfigParser()
c.read(sys.argv[1])
for s in c.sections():
    print(s)
PY
}

ini_set() {
    python3 - "$@" << 'PY'
import sys, configparser
f, sec, key, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
c = configparser.ConfigParser()
c.read(f)
if sec not in c:
    c[sec] = {}
c[sec][key] = val
with open(f, "w") as fh:
    c.write(fh)
PY
}

# ── check ini exists ──────────────────────────────────────────────────────────

if [ ! -f "$INI_FILE" ]; then
    log_error "No config file found at: $INI_FILE"
    log_info  "Run 'llm_config' first to create a config for a model."
    exit 1
fi

mapfile -t sections < <(ini_list_sections "$INI_FILE" 2>/dev/null || true)

if [ ${#sections[@]} -eq 0 ]; then
    log_error "No model configs found in $INI_FILE"
    log_info  "Run 'llm_config' first to create a config for a model."
    exit 1
fi

# ── show presets ──────────────────────────────────────────────────────────────

log_header
echo "  Optimal Inference Parameter Presets"
log_header
echo
echo "  CODING (Precise, Deterministic):"
echo "    Temperature: 0.1  |  Top-K: 40  |  Top-P: 0.95  |  Repeat Penalty: 1.05"
echo
echo "  GENERAL CHAT (Creative, Conversational):"
echo "    Temperature: 0.7  |  Top-K: 40  |  Top-P: 0.95  |  Repeat Penalty: 1.05"
echo
log_header
echo

# ── select model ──────────────────────────────────────────────────────────────

log_info "Select model to configure:"
echo
for i in "${!sections[@]}"; do
    echo "  [$((i+1))] ${sections[$i]}"
done
echo

read -p "Select model (1-${#sections[@]}): " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#sections[@]} ]; then
    log_error "Invalid selection"
    exit 1
fi

section="${sections[$((choice-1))]}"
echo
log_info "Configuring: $section"
echo

# ── select use case ───────────────────────────────────────────────────────────

echo "Select use case:"
echo "  [1] Coding (precise, deterministic)"
echo "  [2] General Chat (creative, conversational)"
echo "  [3] Custom (enter your own values)"
read -p "Choice: " use_case

case "$use_case" in
    1)
        temp=0.1
        top_k=40
        top_p=0.95
        repeat_penalty=1.05
        preset_name="Coding"
        ;;
    2)
        temp=0.7
        top_k=40
        top_p=0.95
        repeat_penalty=1.05
        preset_name="General Chat"
        ;;
    3)
        echo
        read -p "Temperature (0.0-2.0): "  temp
        read -p "Top-K (0-100): "          top_k
        read -p "Top-P (0.0-1.0): "        top_p
        read -p "Repeat Penalty (1.0-2.0): " repeat_penalty
        preset_name="Custom"
        ;;
    *)
        log_error "Invalid choice"
        exit 1
        ;;
esac

# ── apply ─────────────────────────────────────────────────────────────────────

echo
log_info "Applying $preset_name preset to [$section]:"
echo "  Temperature:    $temp"
echo "  Top-K:          $top_k"
echo "  Top-P:          $top_p"
echo "  Repeat Penalty: $repeat_penalty"
echo

ini_set "$INI_FILE" "$section" "temperature"    "$temp"
ini_set "$INI_FILE" "$section" "top-k"          "$top_k"
ini_set "$INI_FILE" "$section" "top-p"          "$top_p"
ini_set "$INI_FILE" "$section" "repeat-penalty" "$repeat_penalty"

log_success "Configuration updated in $INI_FILE"
echo
log_info "Reload the model for inference parameter changes to take effect"
