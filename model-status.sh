#!/bin/bash
# llama-server Model Status
# Mirrors LM Studio model-status.sh — queries REST API instead of lms cli

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="$HOME/AI/llama-server/llama-server.log"
SERVER_HOST="127.0.0.1"
SERVER_PORT=1234

echo "════════════════════════════════════════════════════════════"
echo "  llama-server Model Status"
echo "════════════════════════════════════════════════════════════"
echo

# ── server process check ──────────────────────────────────────────────────────

server_pid=""
server_running=false

# Primary: check systemd user service
svc_active=$(systemctl --user is-active llama-server 2>/dev/null || echo "inactive")
if [ "$svc_active" = "active" ]; then
    server_running=true
    server_pid=$(systemctl --user show llama-server --property=MainPID --value 2>/dev/null || echo "")
else
    # Fallback: PID file (for non-systemd runs)
    if [ -f "$PID_FILE" ]; then
        server_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
            server_running=true
        fi
    fi
fi

if $server_running; then
    echo -e "  Server:  ${GREEN}RUNNING${NC}  (PID ${server_pid:-unknown})"
else
    echo -e "  Server:  ${RED}STOPPED${NC}"
    echo
    echo "  No models loaded."
    echo "════════════════════════════════════════════════════════════"
    exit 0
fi

echo "  Address: http://${SERVER_HOST}:${SERVER_PORT}"
echo

# ── health endpoint ───────────────────────────────────────────────────────────

health_json=$(curl -sf "http://${SERVER_HOST}:${SERVER_PORT}/health" 2>/dev/null || echo "")

if [ -z "$health_json" ]; then
    echo -e "  Health:  ${YELLOW}UNREACHABLE${NC} (server process running but not responding yet)"
    echo
    echo "  Tip: Server may still be loading. Check log:"
    echo "       tail -f $LOG_FILE"
    echo "════════════════════════════════════════════════════════════"
    exit 0
fi

health_status=$(echo "$health_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null || echo "unknown")

case "$health_status" in
    ok)         echo -e "  Health:  ${GREEN}OK${NC}" ;;
    loading)    echo -e "  Health:  ${YELLOW}LOADING${NC}" ;;
    *)          echo -e "  Health:  ${CYAN}$health_status${NC}" ;;
esac

# ── models endpoint ───────────────────────────────────────────────────────────

models_json=$(curl -sf "http://${SERVER_HOST}:${SERVER_PORT}/v1/models" 2>/dev/null || echo "")

if [ -z "$models_json" ]; then
    echo
    echo "  Models:  (endpoint not available)"
    echo "════════════════════════════════════════════════════════════"
    exit 0
fi

echo
python3 - "$models_json" "$LOG_FILE" << 'PY'
import sys, json, re, os

raw      = sys.argv[1]
log_file = sys.argv[2]

try:
    data = json.loads(raw)
except Exception:
    print("  Could not parse /v1/models response")
    sys.exit(0)

models = data.get("data", [])

if not models:
    print("  No models loaded.")
    sys.exit(0)

def args_get(args, flag):
    try:
        idx = args.index(flag)
        return args[idx + 1]
    except (ValueError, IndexError):
        return "-"

# ── scrape log: last progress + timing lines per port ─────────────────────────
# Log lines look like:
#   [PORT] slot update_slots: ... prompt processing progress, n_tokens = 4096, ..., progress = 0.588210
#   [PORT] slot print_timing: ... prompt eval time =  5234 ms / 13927 tokens (..., 223 tokens per second)
#   [PORT] slot print_timing: ...        eval time =   267 ms /     6 tokens (...,  22 tokens per second)

port_progress      = {}   # port -> {"pct": float, "n_tokens": int, "total": int}
port_progress_lno  = {}   # port -> line number of last progress line
port_pp_tps        = {}   # port -> tokens/sec for prompt eval
port_pp_tps_lno    = {}   # port -> line number of last prompt eval timing line
port_gen_tps       = {}   # port -> tokens/sec for generation

if os.path.exists(log_file):
    try:
        with open(log_file, "r", errors="ignore") as f:
            for lno, line in enumerate(f):
                # progress line
                m = re.match(r'\[(\d+)\].*prompt processing progress.*n_tokens\s*=\s*(\d+).*batch\.n_tokens\s*=\s*(\d+).*progress\s*=\s*([\d.]+)', line)
                if m:
                    port, n_tok, _batch, pct = m.group(1), int(m.group(2)), int(m.group(3)), float(m.group(4))
                    total = int(n_tok / pct) if pct > 0 else 0
                    port_progress[port]     = {"pct": pct, "n_tokens": n_tok, "total": total}
                    port_progress_lno[port] = lno
                # prompt eval timing — signals prefill is done
                m2 = re.match(r'\[(\d+)\].*prompt eval time\s*=.*?([\d.]+)\s*tokens per second', line)
                if m2:
                    port_pp_tps[m2.group(1)]     = float(m2.group(2))
                    port_pp_tps_lno[m2.group(1)] = lno
                # generation timing
                m3 = re.match(r'\[(\d+)\]\s+eval time\s*=.*?([\d.]+)\s*tokens per second', line)
                if m3:
                    port_gen_tps[m3.group(1)] = float(m3.group(2))
    except Exception:
        pass

# ── build port→model map ──────────────────────────────────────────────────────
port_to_model = {}
for m in models:
    status_obj = m.get("status", {})
    if isinstance(status_obj, dict):
        args = status_obj.get("args", [])
        port = args_get(args, "--port")
        if port != "-" and port != "0":
            port_to_model[port] = m.get("id", "unknown")

# ── print table ───────────────────────────────────────────────────────────────
STATUS_COLOR = {
    "loaded":   "\033[0;32m",
    "loading":  "\033[1;33m",
    "unloaded": "\033[0;37m",
}
NC = "\033[0m"

header = f"  {'MODEL':<45} {'STATUS':<12} {'CTX':<8} {'PAR':<5} {'THINKING'}"
print(header)
print("  " + "-" * 80)

for m in models:
    model_id   = m.get("id", "unknown")
    status_obj = m.get("status", {})
    if isinstance(status_obj, dict):
        status_val = status_obj.get("value", "unknown")
        args       = status_obj.get("args", [])
    else:
        status_val = str(status_obj)
        args = []

    ctx       = args_get(args, "--ctx-size")
    parallel  = args_get(args, "--parallel")
    reasoning = args_get(args, "--reasoning")
    port      = args_get(args, "--port")

    color      = STATUS_COLOR.get(status_val, "")
    pad        = 12 + len(color) + len(NC)
    status_str = f"{color}{status_val}{NC}".ljust(pad)
    think_str  = f"reasoning={reasoning}" if reasoning != "-" else ""

    print(f"  {model_id:<45} {status_str} {ctx:<8} {parallel:<5} {think_str}")

    # prompt processing progress for this model's port
    if port and port != "-" and port != "0":
        prog    = port_progress.get(port)
        pp_tps  = port_pp_tps.get(port)
        gen_tps = port_gen_tps.get(port)

        # Only show progress bar if prefill is still running:
        # i.e. no timing line exists yet, or the last progress line is newer than the last timing line
        prefill_done = (
            port in port_pp_tps_lno and
            port_pp_tps_lno[port] >= port_progress_lno.get(port, -1)
        )

        if prog and not prefill_done:
            pct_int = int(prog["pct"] * 100)
            bar_len = 30
            filled  = int(bar_len * prog["pct"])
            bar     = "█" * filled + "░" * (bar_len - filled)
            print(f"    Prompt: [{bar}] {pct_int:3d}%  ({prog['n_tokens']}/{prog['total']} tokens)")

PY

# ── uptime from PID start time ────────────────────────────────────────────────

if [ -n "$server_pid" ]; then
    start_time=$(ps -p "$server_pid" -o lstart= 2>/dev/null | xargs || echo "")
    if [ -n "$start_time" ]; then
        echo
        echo "  Started: $start_time"
    fi
fi

echo
echo "  Log:  $LOG_FILE"
echo "════════════════════════════════════════════════════════════"
