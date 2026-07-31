#!/bin/bash
# Edit per-model config in ~/AI/llama-server/models-preset.ini
# Mirrors LM Studio edit-model-config.sh
#
# INI format per model section — keys must match llama-server CLI long flag names:
# [ModelFilenameWithoutExtension]
# ctx-size       = 32768
# n-gpu-layers   = 999
# parallel       = 1
# batch-size     = 512
# cache-type-k   = q8_0
# cache-type-v   = q8_0
# threads        =          (blank = auto)
# temperature    = 0.7
# top-k          = 40
# top-p          = 0.95
# repeat-penalty = 1.05

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_setting() { echo -e "${CYAN}  ➜${NC} $*"; }
log_header()  { echo -e "${MAGENTA}[CONFIG]${NC} $*"; }

MODELS_DIR="$HOME/.lmstudio/models"
INI_FILE="$HOME/AI/llama-server/models-preset.ini"
API_KEY_FILE="$HOME/AI/llama-server/api-keys"
MMPROJ_DIR="$HOME/.lmstudio/models/mmproj"
DRAFT_DIR="$HOME/.lmstudio/models/draft"

# ── python helpers ────────────────────────────────────────────────────────────

ini_get() {
    local file="$1" section="$2" key="$3" default="${4:-}"
    python3 - "$file" "$section" "$key" "$default" << 'PY'
import sys, configparser
f, sec, key, default = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
c = configparser.ConfigParser()
c.read(f)
try:
    print(c[sec][key])
except Exception:
    print(default)
PY
}

ini_set() {
    # ini_set FILE SECTION KEY VALUE
    python3 - "$@" << 'PY'
import sys, configparser, os
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

ini_rename_section() {
    # ini_rename_section FILE OLD_SECTION NEW_SECTION
    python3 - "$@" << 'PY'
import sys, configparser
f, old_sec, new_sec = sys.argv[1], sys.argv[2], sys.argv[3]
c = configparser.ConfigParser()
c.read(f)
if not c.has_section(old_sec):
    print("not_found"); sys.exit(0)
if c.has_section(new_sec):
    print("exists"); sys.exit(0)
items = list(c[old_sec].items())
c.remove_section(old_sec)
c[new_sec] = dict(items)
with open(f, "w") as fh:
    c.write(fh)
print("renamed")
PY
}

ini_duplicate_section() {
    # ini_duplicate_section FILE SRC_SECTION NEW_SECTION
    python3 - "$@" << 'PY'
import sys, configparser
f, src_sec, new_sec = sys.argv[1], sys.argv[2], sys.argv[3]
c = configparser.ConfigParser()
c.read(f)
if not c.has_section(src_sec):
    print("not_found"); sys.exit(0)
if c.has_section(new_sec):
    print("exists"); sys.exit(0)
c[new_sec] = dict(c[src_sec])
with open(f, "w") as fh:
    c.write(fh)
print("duplicated")
PY
}

ini_delete_section() {
    python3 - "$@" << 'PY'
import sys, configparser
f, sec = sys.argv[1], sys.argv[2]
c = configparser.ConfigParser()
c.read(f)
if c.has_section(sec):
    c.remove_section(sec)
with open(f, "w") as fh:
    c.write(fh)
print("deleted")
PY
}

ini_delete_key() {
    # ini_delete_key FILE SECTION KEY
    python3 - "$@" << 'PY'
import sys, configparser
f, sec, key = sys.argv[1], sys.argv[2], sys.argv[3]
c = configparser.ConfigParser()
c.read(f)
if c.has_section(sec) and key in c[sec]:
    del c[sec][key]
with open(f, "w") as fh:
    c.write(fh)
PY
}

ini_list_sections() {
    python3 - "$1" << 'PY'
import sys, configparser
c = configparser.ConfigParser()
c.read(sys.argv[1])
for s in c.sections():
    print(s)
PY
}

ini_show_section() {
    python3 - "$1" "$2" << 'PY'
import sys, configparser
c = configparser.ConfigParser()
c.read(sys.argv[1])
sec = sys.argv[2]
if c.has_section(sec):
    for k, v in c[sec].items():
        print(f"    {k} = {v}")
else:
    print("  (section not found)")
PY
}

# ── API key helpers ───────────────────────────────────────────────────────────

apikey_list() {
    # prints all keys with index, or "(none)" if file is empty/missing
    if [ ! -s "$API_KEY_FILE" ]; then
        echo "(none)"
        return
    fi
    local i=1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf "  [%d] %s\n" "$i" "$line"
        i=$((i+1))
    done < "$API_KEY_FILE"
}

apikey_count() {
    [ ! -s "$API_KEY_FILE" ] && echo 0 && return
    grep -c '[^[:space:]]' "$API_KEY_FILE" || echo 0
}

apikey_generate() {
    # generates a random 32-byte hex key
    python3 -c "import secrets; print(secrets.token_hex(32))"
}

apikey_add() {
    local key="$1"
    mkdir -p "$(dirname "$API_KEY_FILE")"
    echo "$key" >> "$API_KEY_FILE"
}

apikey_delete_by_index() {
    local idx="$1"
    # remove the Nth non-blank line
    python3 - "$API_KEY_FILE" "$idx" << 'PY'
import sys
f, n = sys.argv[1], int(sys.argv[2])
with open(f) as fh:
    lines = [l for l in fh.readlines() if l.strip()]
if n < 1 or n > len(lines):
    print("out_of_range"); sys.exit(0)
del lines[n - 1]
with open(f, "w") as fh:
    fh.writelines(lines)
print("deleted")
PY
}

# ── discover GGUF models ──────────────────────────────────────────────────────

get_model_keys() {
    find -L "$MODELS_DIR" -type f -name "*.gguf" ! -path "*/.cache/*" ! -path "*/toolbox-models/*" ! -path "*/draft/*" ! -name "*mmproj*" ! -name "*.part*" ! -name "*-0000[2-9]-of-*" ! -name "*-000[1-9][0-9]-of-*" \
        2>/dev/null | sort | xargs -I{} basename {} .gguf
}

get_model_path_by_key() {
    # Given a GGUF basename (without .gguf), return the full path to the file
    local key="$1"
    find -L "$MODELS_DIR" -type f -name "${key}.gguf" ! -path "*/.cache/*" ! -path "*/toolbox-models/*" ! -path "*/draft/*" 2>/dev/null | head -1
}

get_model_size_by_key() {
    local key="$1"
    # Strip shard suffix to get base name (e.g. "Foo-00001-of-00004" -> "Foo")
    local base
    base=$(echo "$key" | sed 's/-0000[0-9]-of-[0-9]*$//')
    local total=0
    local found=0
    while IFS= read -r f; do
        sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        total=$((total + sz))
        found=1
    done < <(find -L "$MODELS_DIR" -type f -name "${base}*.gguf" ! -path "*/.cache/*" ! -path "*/toolbox-models/*" ! -path "*/draft/*" 2>/dev/null)
    if [ "$found" -eq 1 ]; then
        python3 -c "print(f'{$total / 1073741824:.2f}')"
    else
        echo "?"
    fi
}

get_size_from_path() {
    # Given a full model path (first shard), sum all shard sizes
    local model_path="$1"
    [ -z "$model_path" ] && echo "?" && return
    local dir base total=0 found=0
    dir=$(dirname "$model_path")
    base=$(basename "$model_path" .gguf | sed 's/-0000[0-9]-of-[0-9]*$//')
    while IFS= read -r f; do
        sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        total=$((total + sz))
        found=1
    done < <(find -L "$dir" -type f -name "${base}*.gguf" 2>/dev/null)
    if [ "$found" -eq 1 ]; then
        python3 -c "print(f'{$total / 1073741824:.2f}')"
    else
        echo "?"
    fi
}

# ── mmproj helpers ────────────────────────────────────────────────────────────

# Return the canonical filename we store a mmproj under, derived from the URL.
# e.g. https://…/mmproj-model-f16.gguf?download=true  →  mmproj-model-f16.gguf
mmproj_canonical_name() {
    local url="$1"
    # Strip query string, then take the last path component
    basename "$(echo "$url" | sed 's/?.*//')"
}

# List all *.gguf files in MMPROJ_DIR with their index
mmproj_list() {
    mkdir -p "$MMPROJ_DIR"
    local i=1
    while IFS= read -r f; do
        printf "  [%d] %s\n" "$i" "$(basename "$f")"
        i=$((i+1))
    done < <(find "$MMPROJ_DIR" -maxdepth 1 -type f -name "*.gguf" | sort)
}

# Count *.gguf files in MMPROJ_DIR
mmproj_count() {
    mkdir -p "$MMPROJ_DIR"
    find "$MMPROJ_DIR" -maxdepth 1 -type f -name "*.gguf" | wc -l
}

# Return path of Nth mmproj file (1-based)
mmproj_path_by_index() {
    local idx="$1"
    mkdir -p "$MMPROJ_DIR"
    find "$MMPROJ_DIR" -maxdepth 1 -type f -name "*.gguf" | sort | sed -n "${idx}p"
}

# Check whether a file with a given canonical name already exists; print its
# full path if found, empty string otherwise.
mmproj_find_existing() {
    local name="$1"
    local target="$MMPROJ_DIR/$name"
    if [ -f "$target" ]; then
        echo "$target"
    else
        echo ""
    fi
}

# Download a mmproj from a URL, save as canonical name under MMPROJ_DIR.
# Sets MMPROJ_DOWNLOAD_PATH on success (does NOT print it — avoids capture pollution).
mmproj_download() {
    local url="$1" name="$2"
    mkdir -p "$MMPROJ_DIR"
    local dest="$MMPROJ_DIR/$name"
    MMPROJ_DOWNLOAD_PATH=""
    log_info "Downloading: $name"
    log_info "         to: $dest"
    if wget --progress=bar --force-progress -O "$dest" "$url"; then
        log_success "Download complete: $dest"
        MMPROJ_DOWNLOAD_PATH="$dest"
    else
        rm -f "$dest"
        log_error "Download failed."
        return 1
    fi
}

# Interactive mmproj setup: ask for URL or pick existing, return chosen path.
# Sets global MMPROJ_PATH on success (empty = user skipped).
mmproj_interactive() {
    local current_mmproj="$1"   # pass "" if not set yet
    MMPROJ_PATH=""

    echo
    log_header "Image / Vision (mmproj)"
    echo
    log_info "mmproj files are stored in: $MMPROJ_DIR"
    local count
    count=$(mmproj_count)

    if [ "$count" -gt 0 ]; then
        log_info "Existing mmproj files:"
        mmproj_list
        echo
        echo "  [U] Enter a download URL for a new mmproj"
        echo "  [1-${count}] Use an existing mmproj from the list above"
        echo "  [P] Enter an absolute path to a mmproj file"
        [ -n "$current_mmproj" ] && echo "  [C] Keep current  ($(basename "$current_mmproj"))"
        echo "  [R] Remove mmproj from this config"
        echo "  [S] Skip / no change"
        echo
        read -p "Choice: " mm_choice
        case "$mm_choice" in
            [Ss]) MMPROJ_PATH="__skip__"; return 0 ;;
            [Cc])
                if [ -n "$current_mmproj" ]; then
                    MMPROJ_PATH="$current_mmproj"; return 0
                else
                    log_error "No current mmproj set."; mmproj_interactive ""; return $?
                fi
                ;;
            [Rr]) MMPROJ_PATH="__remove__"; return 0 ;;
            [Uu]) : ;;  # fall through to URL prompt below
            [Pp])
                read -p "  mmproj absolute path: " mm_path
                if [ -z "$mm_path" ]; then
                    log_info "No path entered — skipping."; MMPROJ_PATH="__skip__"; return 0
                fi
                if [ ! -f "$mm_path" ]; then
                    log_error "File not found: $mm_path"; return 1
                fi
                log_success "Set to: $mm_path"
                MMPROJ_PATH="$mm_path"; return 0
                ;;
            *)
                if [[ "$mm_choice" =~ ^[0-9]+$ ]] && [ "$mm_choice" -ge 1 ] && [ "$mm_choice" -le "$count" ]; then
                    MMPROJ_PATH=$(mmproj_path_by_index "$mm_choice")
                    log_success "Selected: $(basename "$MMPROJ_PATH")"
                    return 0
                else
                    log_error "Invalid choice."; return 1
                fi
                ;;
        esac
    else
        log_info "No mmproj files downloaded yet."
        echo
        echo "  [U] Enter a download URL"
        echo "  [P] Enter an absolute path to a mmproj file"
        echo "  [S] Skip (set up image capability later)"
        echo
        read -p "Choice [S]: " mm_choice
        case "${mm_choice:-S}" in
            [Ss]) MMPROJ_PATH="__skip__"; return 0 ;;
            [Uu]) : ;;
            [Pp])
                read -p "  mmproj absolute path: " mm_path
                if [ -z "$mm_path" ]; then
                    log_info "No path entered — skipping."; MMPROJ_PATH="__skip__"; return 0
                fi
                if [ ! -f "$mm_path" ]; then
                    log_error "File not found: $mm_path"; return 1
                fi
                log_success "Set to: $mm_path"
                MMPROJ_PATH="$mm_path"; return 0
                ;;
            *)    MMPROJ_PATH="__skip__"; return 0 ;;
        esac
    fi

    # ── URL download path ──────────────────────────────────────────────────
    echo
    read -p "  mmproj download URL: " mm_url
    if [ -z "$mm_url" ]; then
        log_info "No URL entered — skipping."; MMPROJ_PATH="__skip__"; return 0
    fi

    local canon_name
    canon_name=$(mmproj_canonical_name "$mm_url")
    log_info "Canonical filename: $canon_name"

    # Allow user to rename (e.g. to share across quants of same family)
    read -p "  Save as (Enter to keep '$canon_name'): " rename_input
    local save_name="${rename_input:-$canon_name}"

    # Ensure .gguf extension
    [[ "$save_name" != *.gguf ]] && save_name="${save_name}.gguf"

    local existing
    existing=$(mmproj_find_existing "$save_name")
    if [ -n "$existing" ]; then
        log_info "Already exists: $existing"
        read -p "  Re-download and overwrite? (yes/no) [no]: " overwrite
        if [ "${overwrite:-no}" = "yes" ]; then
            mmproj_download "$mm_url" "$save_name" || return 1
            MMPROJ_PATH="$MMPROJ_DOWNLOAD_PATH"
        else
            log_info "Using existing file."
            MMPROJ_PATH="$existing"
        fi
    else
        mmproj_download "$mm_url" "$save_name" || return 1
        MMPROJ_PATH="$MMPROJ_DOWNLOAD_PATH"
    fi
}

# ── draft model helpers (for EAGLE3 / draft-simple) ──────────────────────────

# List all *.gguf files in DRAFT_DIR with their index
draft_list() {
    mkdir -p "$DRAFT_DIR"
    local i=1
    while IFS= read -r f; do
        printf "  [%d] %s\n" "$i" "$(basename "$f")"
        i=$((i+1))
    done < <(find "$DRAFT_DIR" -maxdepth 1 -type f -name "*.gguf" | sort)
}

# Count *.gguf files in DRAFT_DIR
draft_count() {
    mkdir -p "$DRAFT_DIR"
    find "$DRAFT_DIR" -maxdepth 1 -type f -name "*.gguf" | wc -l
}

# Return path of Nth draft file (1-based)
draft_path_by_index() {
    local idx="$1"
    mkdir -p "$DRAFT_DIR"
    find "$DRAFT_DIR" -maxdepth 1 -type f -name "*.gguf" | sort | sed -n "${idx}p"
}

# Download a draft model from a URL, save under DRAFT_DIR.
# Sets DRAFT_DOWNLOAD_PATH on success.
draft_download() {
    local url="$1" name="$2"
    mkdir -p "$DRAFT_DIR"
    local dest="$DRAFT_DIR/$name"
    DRAFT_DOWNLOAD_PATH=""
    log_info "Downloading draft model: $name"
    log_info "               to: $dest"
    if wget --progress=bar --force-progress -O "$dest" "$url"; then
        log_success "Download complete: $dest"
        DRAFT_DOWNLOAD_PATH="$dest"
    else
        rm -f "$dest"
        log_error "Download failed."
        return 1
    fi
}

# Interactive draft model setup: ask for URL or pick existing.
# Sets global DRAFT_PATH on success (empty = user skipped).
draft_interactive() {
    local current_draft="$1"   # pass "" if not set yet
    DRAFT_PATH=""

    echo
    log_header "Draft Model (EAGLE3 / draft-simple)"
    echo
    log_info "Draft models are stored in: $DRAFT_DIR"
    local count
    count=$(draft_count)

    if [ "$count" -gt 0 ]; then
        log_info "Existing draft models:"
        draft_list
        echo
        echo "  [U] Enter a download URL for a new draft model"
        echo "  [1-${count}] Use an existing draft model from the list above"
        [ -n "$current_draft" ] && echo "  [C] Keep current  ($(basename "$current_draft"))"
        echo "  [R] Remove draft from this config"
        echo "  [S] Skip / no change"
        echo
        read -p "Choice: " dr_choice
        case "$dr_choice" in
            [Ss]) DRAFT_PATH="__skip__"; return 0 ;;
            [Cc])
                if [ -n "$current_draft" ]; then
                    DRAFT_PATH="$current_draft"; return 0
                else
                    log_error "No current draft model set."; draft_interactive ""; return $?
                fi
                ;;
            [Rr]) DRAFT_PATH="__remove__"; return 0 ;;
            [Uu]) : ;;
            *)
                if [[ "$dr_choice" =~ ^[0-9]+$ ]] && [ "$dr_choice" -ge 1 ] && [ "$dr_choice" -le "$count" ]; then
                    DRAFT_PATH=$(draft_path_by_index "$dr_choice")
                    log_success "Selected: $(basename "$DRAFT_PATH")"
                    return 0
                else
                    log_error "Invalid choice."; return 1
                fi
                ;;
        esac
    else
        log_info "No draft models downloaded yet."
        echo
        echo "  [U] Enter a download URL"
        echo "  [S] Skip (set up draft model later)"
        echo
        read -p "Choice [S]: " dr_choice
        case "${dr_choice:-S}" in
            [Ss]) DRAFT_PATH="__skip__"; return 0 ;;
            [Uu]) : ;;
            *)    DRAFT_PATH="__skip__"; return 0 ;;
        esac
    fi

    # URL download path
    echo
    read -p "  Draft model download URL: " dr_url
    if [ -z "$dr_url" ]; then
        log_info "No URL entered — skipping."; DRAFT_PATH="__skip__"; return 0
    fi

    # Derive a sensible filename from URL
    local canon_name
    canon_name=$(basename "$(echo "$dr_url" | sed 's/?.*//')")
    log_info "Filename: $canon_name"

    read -p "  Save as (Enter to keep '$canon_name'): " rename_input
    local save_name="${rename_input:-$canon_name}"

    [[ "$save_name" != *.gguf ]] && save_name="${save_name}.gguf"

    local existing
    existing=$(test -f "$DRAFT_DIR/$save_name" && echo "$DRAFT_DIR/$save_name" || echo "")
    if [ -n "$existing" ]; then
        log_info "Already exists: $existing"
        read -p "  Re-download and overwrite? (yes/no) [no]: " overwrite
        if [ "${overwrite:-no}" = "yes" ]; then
            draft_download "$dr_url" "$save_name" || return 1
            DRAFT_PATH="$DRAFT_DOWNLOAD_PATH"
        else
            log_info "Using existing file."
            DRAFT_PATH="$existing"
        fi
    else
        draft_download "$dr_url" "$save_name" || return 1
        DRAFT_PATH="$DRAFT_DOWNLOAD_PATH"
    fi
}

# ── ensure INI file exists ────────────────────────────────────────────────────

mkdir -p "$(dirname "$INI_FILE")"
touch "$INI_FILE"

# ── main menu ─────────────────────────────────────────────────────────────────

echo
log_info "llama-server Model Configuration Manager"
log_info "Config file: $INI_FILE"
echo
echo "  [1] Edit existing model config"
echo "  [2] Create new config for a model"
echo "  [3] Duplicate config with new section name"
echo "  [4] Delete a model config"
echo "  [5] Manage API keys"
echo "  [q] Quit"
echo
read -p "Select option: " main_choice

case "$main_choice" in
    2)
        # ── create new config ─────────────────────────────────────────────────
        mapfile -t all_keys < <(get_model_keys)
        mapfile -t existing_sections < <(ini_list_sections "$INI_FILE" 2>/dev/null || true)

        if [ ${#all_keys[@]} -eq 0 ]; then
            log_error "No GGUF models found in $MODELS_DIR"
            exit 1
        fi

        echo
        log_info "Available models:"
        echo
        for i in "${!all_keys[@]}"; do
            sz=$(get_model_size_by_key "${all_keys[$i]}")
            # mark models that already have at least one config
            has_config=""
            for e in "${existing_sections[@]}"; do
                [ "$e" = "${all_keys[$i]}" ] && has_config=" *" && break
            done
            printf "  [%d] %s  (%s GB)%s\n" "$((i+1))" "${all_keys[$i]}" "$sz" "$has_config"
        done
        echo
        log_info "(* = already has a config with default section name)"
        echo
        read -p "Select model (1-${#all_keys[@]}) or 'q' to quit: " choice
        [ "x$choice" = "xq" ] || [ "x$choice" = "xQ" ] && exit 0

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#all_keys[@]} ]; then
            log_error "Invalid selection"; exit 1
        fi

        gguf_key="${all_keys[$((choice-1))]}"
        model_path=$(get_model_path_by_key "$gguf_key")
        sz=$(get_size_from_path "$model_path")
        echo
        log_info "GGUF file: ${model_path:-(not found)}"
        log_info "The section name is what you use as the API \"model\" field."
        read -p "  Section name (API alias) [${gguf_key}]: " section_input
        section="${section_input:-$gguf_key}"
        # check for duplicate section name
        for e in "${existing_sections[@]}"; do
            if [ "$e" = "$section" ]; then
                log_error "Section '$section' already exists. Aborting."; exit 1
            fi
        done
        if [ -z "$model_path" ]; then
            log_error "Could not resolve path for: $gguf_key"; exit 1
        fi
        log_info "Creating config for: $section  (${sz} GB)"
        # Write model path first — this is what the router uses to find the file
        ini_set "$INI_FILE" "$section" "model" "$model_path"
        # Suggest context based on model size
        sz_int=$(echo "$sz" | cut -d. -f1)
        if [ "$sz_int" -gt 80 ] 2>/dev/null; then
            sug_ctx=98304
        elif [ "$sz_int" -gt 30 ] 2>/dev/null; then
            sug_ctx=65536
        else
            sug_ctx=32768
        fi

        # ── thinking mode ──────────────────────────────────────────────────
        echo
        echo "  Thinking/reasoning mode:"
        echo "    [3] auto — let model/client decide (recommended default)"
        echo "    [1] off  — non-thinking instruct mode (recommended for Qwen3.5 large)"
        echo "    [2] on   — full thinking/CoT mode"
        read -p "  Choice [3]: " think_choice
        case "${think_choice:-3}" in
            1) thinking_mode="off" ;;
            2) thinking_mode="on" ;;
            *) thinking_mode="auto" ;;
        esac

        # Set inference param defaults based on thinking mode
        # Per Qwen official recommendations
        if [ "$thinking_mode" = "off" ]; then
            def_tmp="0.7"; def_top_k="20"; def_top_p="0.8"; def_min_p="0.0"; def_presence="1.5"; def_repeat="1.0"
        else
            def_tmp="1.0"; def_top_k="20"; def_top_p="0.95"; def_min_p="0.0"; def_presence="1.5"; def_repeat="1.0"
        fi

        echo
        read -p "  ctx-size       (default: $sug_ctx): " v; ini_set "$INI_FILE" "$section" "ctx-size"       "${v:-$sug_ctx}"
        read -p "  n-gpu-layers   (default: 999): "       v; ini_set "$INI_FILE" "$section" "n-gpu-layers"   "${v:-999}"
        read -p "  parallel       (default: 1): "         v; ini_set "$INI_FILE" "$section" "parallel"       "${v:-1}"
        read -p "  cache-type-k   (default: q8_0): "      v; ini_set "$INI_FILE" "$section" "cache-type-k"   "${v:-q8_0}"
        read -p "  cache-type-v   (default: q8_0): "      v; ini_set "$INI_FILE" "$section" "cache-type-v"   "${v:-q8_0}"
        read -p "  temperature    (default: $def_tmp): "   v; ini_set "$INI_FILE" "$section" "temperature"    "${v:-$def_tmp}"
        read -p "  top-k          (default: $def_top_k): " v; ini_set "$INI_FILE" "$section" "top-k"          "${v:-$def_top_k}"
        read -p "  top-p          (default: $def_top_p): " v; ini_set "$INI_FILE" "$section" "top-p"          "${v:-$def_top_p}"
        read -p "  min-p          (default: $def_min_p): " v; ini_set "$INI_FILE" "$section" "min-p"          "${v:-$def_min_p}"
        read -p "  presence-penalty (default: $def_presence): " v; ini_set "$INI_FILE" "$section" "presence-penalty" "${v:-$def_presence}"
        read -p "  repeat-penalty (default: $def_repeat): " v; ini_set "$INI_FILE" "$section" "repeat-penalty" "${v:-$def_repeat}"

        # Write reasoning params
        ini_set "$INI_FILE" "$section" "reasoning" "$thinking_mode"
        if [ "$thinking_mode" = "off" ]; then
            ini_set "$INI_FILE" "$section" "reasoning-budget"      "0"
            ini_set "$INI_FILE" "$section" "chat-template-kwargs"  "{\"enable_thinking\": false}"
        elif [ "$thinking_mode" = "on" ]; then
            ini_set "$INI_FILE" "$section" "reasoning-budget"      "-1"
            ini_set "$INI_FILE" "$section" "chat-template-kwargs"  "{\"enable_thinking\": true}"
        fi
        # auto: no reasoning-budget or chat-template-kwargs set (use server defaults)

        # ── mmproj / image capability ──────────────────────────────────────
        # Auto-detect mmproj in model's own directory
        local_mmproj=""
        if [ -n "$model_path" ]; then
            model_dir=$(dirname "$model_path")
            local_mmproj=$(find "$model_dir" -maxdepth 1 -type f -name "mmproj*.gguf" 2>/dev/null | head -1)
        fi
        if [ -n "$local_mmproj" ]; then
            echo
            log_info "Found mmproj in model directory: $(basename "$local_mmproj")"
            read -p "  Use this? [Y/n]: " use_local
            if [ "${use_local:-Y}" != "n" ] && [ "${use_local:-Y}" != "N" ]; then
                MMPROJ_PATH="$local_mmproj"
            else
                mmproj_interactive ""
            fi
        else
            mmproj_interactive ""
        fi
        case "$MMPROJ_PATH" in
            __skip__|"") : ;;   # user skipped — no mmproj key written
            __remove__)
                ini_delete_key "$INI_FILE" "$section" "mmproj"
                ;;
            *)
                ini_set "$INI_FILE" "$section" "mmproj" "$MMPROJ_PATH"
                log_success "mmproj set to: $MMPROJ_PATH"
                ;;
        esac

        # ── speculative decoding ───────────────────────────────────────────
        echo
        log_header "Speculative Decoding"
        echo
        echo "  Types that work on ANY model (no extra files needed):"
        echo "    ngram-simple  — n-gram pattern matching"
        echo
        echo "  Types that need MTP heads built into the model:"
        echo "    draft-mtp     — Qwen3.6/Qwopus, Gemma4, Step3.5+, GLM-4.5+, Hy3"
        echo
        echo "  Types that need a separate draft model file:"
        echo "    draft-eagle3  — EAGLE3 head (best quality)"
        echo "    draft-simple  — small standalone draft model"
        echo
        read -p "  Enable? Enter type or leave blank to skip: " spec_type
        if [ -n "$spec_type" ]; then
            ini_set "$INI_FILE" "$section" "spec-type" "$spec_type"
            read -p "  spec-draft-n-max (default: 16): " v
            ini_set "$INI_FILE" "$section" "spec-draft-n-max" "${v:-16}"
            read -p "  draft-p-min (default: 0.75): " v
            ini_set "$INI_FILE" "$section" "draft-p-min" "${v:-0.75}"
            if [ "$spec_type" = "draft-eagle3" ] || [ "$spec_type" = "draft-simple" ]; then
                draft_interactive ""
                case "$DRAFT_PATH" in
                    __skip__|"")
                        log_warning "No draft model set — spec decoding may not work."
                        ;;
                    __remove__)
                        : ;;
                    *)
                        ini_set "$INI_FILE" "$section" "model-draft" "$DRAFT_PATH"
                        log_success "Draft model set to: $DRAFT_PATH"
                        ;;
                esac
            fi
        else
            log_info "Skipped — can add later via llm_config > option 6"
        fi

        echo
        log_success "Config created for: $section"
        log_info "Note: Reload the model for changes to take effect"
        exit 0
        ;;

    3)
        # ── duplicate config ──────────────────────────────────────────────────
        mapfile -t sections < <(ini_list_sections "$INI_FILE" 2>/dev/null || true)

        if [ ${#sections[@]} -eq 0 ]; then
            log_info "No configs to duplicate."
            exit 0
        fi

        echo
        log_info "Select config to duplicate:"
        echo
        for i in "${!sections[@]}"; do
            echo "  [$((i+1))] ${sections[$i]}"
        done
        echo
        read -p "Select (1-${#sections[@]}) or 'q': " choice
        [ "x$choice" = "xq" ] || [ "x$choice" = "xQ" ] && exit 0

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#sections[@]} ]; then
            log_error "Invalid selection"; exit 1
        fi

        src_section="${sections[$((choice-1))]}"
        echo
        log_info "Duplicating: $src_section"
        read -p "  New section name (API alias): " new_section
        if [ -z "$new_section" ]; then
            log_error "Section name cannot be empty."; exit 1
        fi

        result=$(ini_duplicate_section "$INI_FILE" "$src_section" "$new_section")
        case "$result" in
            duplicated) log_success "Duplicated '$src_section'  →  '$new_section'" ;;
            exists)     log_error "Section '$new_section' already exists."; exit 1 ;;
            not_found)  log_error "Source section '$src_section' not found."; exit 1 ;;
        esac
        exit 0
        ;;

    4)
        # ── delete config ─────────────────────────────────────────────────────
        mapfile -t sections < <(ini_list_sections "$INI_FILE" 2>/dev/null || true)

        if [ ${#sections[@]} -eq 0 ]; then
            log_info "No configs to delete."
            exit 0
        fi

        echo
        log_info "Configs available:"
        for i in "${!sections[@]}"; do
            echo "  [$((i+1))] ${sections[$i]}"
        done
        echo
        read -p "Select config to delete (1-${#sections[@]}) or 'q': " choice
        [ "x$choice" = "xq" ] || [ "x$choice" = "xQ" ] && exit 0

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#sections[@]} ]; then
            log_error "Invalid selection"; exit 1
        fi

        section="${sections[$((choice-1))]}"
        echo
        log_warning "This will delete config for: $section"
        read -p "Are you sure? (yes/no): " confirm
        [ "x$confirm" != "xyes" ] && log_info "Cancelled" && exit 0

        ini_delete_section "$INI_FILE" "$section"
        log_success "Config deleted: $section"
        exit 0
        ;;

    5)
        # ── manage API keys ───────────────────────────────────────────────────
        while true; do
            echo
            log_info "API Key Manager"
            log_info "Key file: $API_KEY_FILE"
            echo
            apikey_list
            echo
            echo "  [1] Generate new key"
            echo "  [2] Add custom key"
            echo "  [3] Delete a key"
            echo "  [q] Back"
            echo
            read -p "Choice: " key_choice
            case "$key_choice" in
                1)
                    new_key=$(apikey_generate)
                    apikey_add "$new_key"
                    log_success "Generated and added: $new_key"
                    log_warning "Restart llama-server for the new key to take effect."
                    ;;
                2)
                    read -p "  Enter key: " custom_key
                    if [ -z "$custom_key" ]; then
                        log_error "Key cannot be empty."; continue
                    fi
                    apikey_add "$custom_key"
                    log_success "Added key."
                    log_warning "Restart llama-server for the new key to take effect."
                    ;;
                3)
                    count=$(apikey_count)
                    if [ "$count" -eq 0 ]; then
                        log_info "No keys to delete."; continue
                    fi
                    read -p "  Delete key number: " del_idx
                    if ! [[ "$del_idx" =~ ^[0-9]+$ ]] || [ "$del_idx" -lt 1 ] || [ "$del_idx" -gt "$count" ]; then
                        log_error "Invalid selection."; continue
                    fi
                    result=$(apikey_delete_by_index "$del_idx")
                    case "$result" in
                        deleted)       log_success "Key deleted."
                                       log_warning "Restart llama-server for the change to take effect." ;;
                        out_of_range)  log_error "Index out of range." ;;
                    esac
                    ;;
                q|Q)
                    break
                    ;;
                *)
                    log_error "Invalid choice."
                    ;;
            esac
        done
        exit 0
        ;;

    q|Q)
        exit 0
        ;;

    1)
        : # fall through to edit logic below
        ;;

    *)
        log_error "Invalid option"; exit 1
        ;;
esac

# ── edit existing config ──────────────────────────────────────────────────────

mapfile -t sections < <(ini_list_sections "$INI_FILE" 2>/dev/null || true)

if [ ${#sections[@]} -eq 0 ]; then
    log_warning "No configs found. Use option 2 to create one."
    exit 1
fi

echo
log_info "Available model configs:"
echo
for i in "${!sections[@]}"; do
    sec_mdl=$(ini_get "$INI_FILE" "${sections[$i]}" "model" "")
    if [ -n "$sec_mdl" ]; then
        sz=$(get_size_from_path "$sec_mdl")
    else
        sz=$(get_model_size_by_key "${sections[$i]}")
    fi
    printf "  [%d] %s  (%s GB)\n" "$((i+1))" "${sections[$i]}" "$sz"
done
echo

read -p "Select config to edit (1-${#sections[@]}) or 'q': " choice
[ "x$choice" = "xq" ] || [ "x$choice" = "xQ" ] && exit 0

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#sections[@]} ]; then
    log_error "Invalid selection"; exit 1
fi

section="${sections[$((choice-1))]}"

echo
log_header "Configuration for: $section"
echo

# Read current values
mdl=$(ini_get "$INI_FILE" "$section" "model"               "")
ctx=$(ini_get "$INI_FILE" "$section" "ctx-size"            "32768")
ngl=$(ini_get "$INI_FILE" "$section" "n-gpu-layers"        "999")
par=$(ini_get "$INI_FILE" "$section" "parallel"            "1")
ctk=$(ini_get "$INI_FILE" "$section" "cache-type-k"        "q8_0")
ctv=$(ini_get "$INI_FILE" "$section" "cache-type-v"        "q8_0")
tmp=$(ini_get "$INI_FILE" "$section" "temperature"         "0.7")
tok=$(ini_get "$INI_FILE" "$section" "top-k"               "40")
top=$(ini_get "$INI_FILE" "$section" "top-p"               "0.95")
mnp=$(ini_get "$INI_FILE" "$section" "min-p"               "0.0")
pre=$(ini_get "$INI_FILE" "$section" "presence-penalty"    "0.0")
rep=$(ini_get "$INI_FILE" "$section" "repeat-penalty"      "1.05")
rea=$(ini_get "$INI_FILE" "$section" "reasoning"           "")
reb=$(ini_get "$INI_FILE" "$section" "reasoning-budget"    "")
ctk_kwargs=$(ini_get "$INI_FILE" "$section" "chat-template-kwargs" "")
mmp=$(ini_get "$INI_FILE" "$section" "mmproj"              "")
spc=$(ini_get "$INI_FILE" "$section" "spec-type"          "")
spn=$(ini_get "$INI_FILE" "$section" "spec-draft-n-max"   "16")
dpm=$(ini_get "$INI_FILE" "$section" "draft-p-min"        "0.75")
mdr=$(ini_get "$INI_FILE" "$section" "model-draft"         "")

# Compute size — prefer model= path, fall back to key-based scan
if [ -n "$mdl" ]; then
    sz=$(get_size_from_path "$mdl")
else
    sz=$(get_model_size_by_key "$section")
fi

echo "═══════════════════════════════════════════════════════════"
echo "LOADING PARAMETERS:"
log_setting "model:                 ${mdl:-(not set — router will scan by section name)}"
log_setting "ctx-size:              $ctx"
log_setting "n-gpu-layers:          $ngl"
log_setting "parallel:              $par"
log_setting "cache-type-k:          $ctk"
log_setting "cache-type-v:          $ctv"
echo
echo "INFERENCE PARAMETERS:"
log_setting "temperature:           $tmp"
log_setting "top-k:                 $tok"
log_setting "top-p:                 $top"
log_setting "min-p:                 $mnp"
log_setting "presence-penalty:      $pre"
log_setting "repeat-penalty:        $rep"
echo
echo "THINKING / REASONING:"
log_setting "reasoning:             ${rea:-(not set — server default: auto)}"
log_setting "reasoning-budget:      ${reb:-(not set)}"
log_setting "chat-template-kwargs:  ${ctk_kwargs:-(not set)}"
echo
echo "IMAGE / VISION:"
log_setting "mmproj:                ${mmp:-(not set — text-only)}"
echo "═══════════════════════════════════════════════════════════"
echo

echo "SPECULATIVE DECODING:"
log_setting "spec-type:             ${spc:-(not set)}"
log_setting "spec-draft-n-max:      ${spn:-(not set)}"
log_setting "draft-p-min:           ${dpm:-(not set)}"
log_setting "model-draft:           ${mdr:-(not set)}"
echo "═══════════════════════════════════════════════════════════"
echo

echo "What would you like to edit?"
echo "  [1] Loading Parameters (ctx, ngl, parallel, cache-type)"
echo "  [2] Inference Parameters (temperature, top-k, top-p, min-p, presence, repeat)"
echo "  [3] Rename section (API model alias)"
echo "  [4] Thinking / Reasoning"
echo "  [5] Image / Vision (mmproj)"
echo "  [6] Speculative Decoding (spec-type, draft-max, draft-p-min)"
echo "  [q] Quit"
read -p "Choice: " edit_choice

case "$edit_choice" in
    1)
        echo
        log_header "Edit Loading Parameters"
        echo
        read -p "  model path   [${mdl:-(not set)}]: " v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "model"        "$v"
        read -p "  ctx-size     [$ctx]: "               v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "ctx-size"     "$v"
        read -p "  n-gpu-layers [$ngl]: "               v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "n-gpu-layers" "$v"
        read -p "  parallel     [$par]: "               v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "parallel"     "$v"
        read -p "  cache-type-k [$ctk]: "               v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "cache-type-k" "$v"
        read -p "  cache-type-v [$ctv]: "               v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "cache-type-v" "$v"
        log_success "Loading parameters updated!"
        ;;
    2)
        echo
        log_header "Edit Inference Parameters"
        echo
        read -p "  temperature      [$tmp]: "  v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "temperature"      "$v"
        read -p "  top-k            [$tok]: "  v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "top-k"            "$v"
        read -p "  top-p            [$top]: "  v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "top-p"            "$v"
        read -p "  min-p            [$mnp]: "  v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "min-p"            "$v"
        read -p "  presence-penalty [$pre]: "  v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "presence-penalty" "$v"
        read -p "  repeat-penalty   [$rep]: "  v; [ -n "$v" ] && ini_set "$INI_FILE" "$section" "repeat-penalty"   "$v"
        log_success "Inference parameters updated!"
        ;;
    3)
        echo
        log_header "Rename Section (API alias)"
        echo
        log_info "Current section name (API model field): $section"
        read -p "  New section name: " new_section
        if [ -z "$new_section" ]; then
            log_info "No change made."
            exit 0
        fi
        if [ "$new_section" = "$section" ]; then
            log_info "Same name — no change made."
            exit 0
        fi
        result=$(ini_rename_section "$INI_FILE" "$section" "$new_section")
        case "$result" in
            renamed)  log_success "Section renamed: '$section'  →  '$new_section'" ;;
            exists)   log_error "Section '$new_section' already exists."; exit 1 ;;
            not_found) log_error "Section '$section' not found."; exit 1 ;;
        esac
        ;;
    4)
        echo
        log_header "Edit Thinking / Reasoning"
        echo
        echo "  Current: reasoning=${rea:-(not set)}, reasoning-budget=${reb:-(not set)}"
        echo "  Presets:"
        echo "    [1] off  — disable thinking  (reasoning=off, budget=0, enable_thinking:false)"
        echo "    [2] on   — enable thinking   (reasoning=on,  budget=-1, enable_thinking:true)"
        echo "    [3] auto — server default     (clears all reasoning params)"
        echo "    [4] manual — set values individually"
        read -p "  Choice [4]: " rthink_choice
        case "${rthink_choice:-4}" in
            1)
                ini_set "$INI_FILE" "$section" "reasoning"             "off"
                ini_set "$INI_FILE" "$section" "reasoning-budget"      "0"
                ini_set "$INI_FILE" "$section" "chat-template-kwargs"  "{\"enable_thinking\": false}"
                log_success "Thinking disabled."
                ;;
            2)
                ini_set "$INI_FILE" "$section" "reasoning"             "on"
                ini_set "$INI_FILE" "$section" "reasoning-budget"      "-1"
                ini_set "$INI_FILE" "$section" "chat-template-kwargs"  "{\"enable_thinking\": true}"
                log_success "Thinking enabled."
                ;;
            3)
                python3 - "$INI_FILE" "$section" << 'PY'
import sys, configparser
f, sec = sys.argv[1], sys.argv[2]
c = configparser.ConfigParser()
c.read(f)
for k in ["reasoning", "reasoning-budget", "chat-template-kwargs"]:
    if c.has_section(sec) and k in c[sec]:
        del c[sec][k]
with open(f, "w") as fh:
    c.write(fh)
print("Reasoning params cleared.")
PY
                ;;
            4)
                echo
                read -p "  reasoning      (on/off/auto, blank=keep) [${rea:-(not set)}]: " v
                [ -n "$v" ] && ini_set "$INI_FILE" "$section" "reasoning" "$v"
                read -p "  reasoning-budget (-1=unlimited, 0=disable, blank=keep) [${reb:-(not set)}]: " v
                [ -n "$v" ] && ini_set "$INI_FILE" "$section" "reasoning-budget" "$v"
                read -p "  chat-template-kwargs (blank=keep) [${ctk_kwargs:-(not set)}]: " v
                [ -n "$v" ] && ini_set "$INI_FILE" "$section" "chat-template-kwargs" "$v"
                log_success "Reasoning parameters updated."
                ;;
        esac
        ;;
    5)
        mmproj_interactive "$mmp"
        case "$MMPROJ_PATH" in
            __skip__)
                log_info "No changes made to mmproj."
                ;;
            __remove__)
                ini_delete_key "$INI_FILE" "$section" "mmproj"
                log_success "mmproj removed from config."
                ;;
            "")
                log_info "No changes made to mmproj."
                ;;
            *)
                ini_set "$INI_FILE" "$section" "mmproj" "$MMPROJ_PATH"
                log_success "mmproj set to: $MMPROJ_PATH"
                ;;
        esac
        ;;
    6)
        echo
        log_header "Edit Speculative Decoding"
        echo
        echo "  Current: spec-type=${spc:-(not set)}, spec-draft-n-max=${spn:-(not set)}, draft-p-min=${dpm:-(not set)}"
        echo
        echo "  Spec type options (no draft model needed):"
        echo "    ngram-simple  — n-gram pattern matching (works on ANY model)"
        echo "    ngram-map-k   — n-gram map-k variant"
        echo "    ngram-map-k4v — n-gram map-k4v variant"
        echo "    ngram-mod     — n-gram mod variant"
        echo "    ngram-cache   — n-gram cache variant"
        echo
        echo "  Spec type options (needs MTP head in model — no draft file):"
        echo "    draft-mtp     — Multi-Token Prediction (Qwen3.6, Qwopus, Gemma4, Step3.5/3.7, GLM-4.5/4.6)"
        echo
        echo "  Spec type options (needs separate draft model via model-draft=):"
        echo "    draft-simple  — small standalone draft model"
        echo "    draft-eagle3  — EAGLE3 head draft model (best quality, needs b1293+)"
        echo
        echo "  WARNING: 'draft-mtp' will CRASH the server if the model lacks MTP heads!"
        echo "           Only enable it on MTP-capable models (Qwen3.6/Qwopus, Gemma4, Step3.5+, GLM-4.5+)"
        echo
        read -p "  spec-type (blank=keep, 'none' to clear) [${spc:-(not set)}]: " v
        if [ -n "$v" ]; then
            if [ "$v" = "none" ]; then
                python3 - "$INI_FILE" "$section" << 'PY'
import sys, configparser
f, sec = sys.argv[1], sys.argv[2]
c = configparser.ConfigParser()
c.read(f)
for k in ["spec-type", "spec-draft-n-max", "draft-p-min"]:
    if c.has_section(sec) and k in c[sec]:
        del c[sec][k]
with open(f, "w") as fh:
    c.write(fh)
print("Speculative decoding disabled.")
PY
            else
                ini_set "$INI_FILE" "$section" "spec-type" "$v"
            fi
        fi
        if [ "$v" != "none" ]; then
            read -p "  spec-draft-n-max (blank=keep)  [${spn:-(not set)}]: " v
            [ -n "$v" ] && ini_set "$INI_FILE" "$section" "spec-draft-n-max" "$v"
            read -p "  draft-p-min      (blank=keep)  [${dpm:-(not set)}]: " v
            [ -n "$v" ] && ini_set "$INI_FILE" "$section" "draft-p-min" "$v"
            
            # If draft-eagle3 or draft-simple, offer to download/select a draft model
            current_spec=$(ini_get "$INI_FILE" "$section" "spec-type" "")
            if [ "$current_spec" = "draft-eagle3" ] || [ "$current_spec" = "draft-simple" ]; then
                draft_interactive "$mdr"
                case "$DRAFT_PATH" in
                    __skip__)
                        existing_mdr=$(ini_get "$INI_FILE" "$section" "model-draft" "")
                        if [ -z "$existing_mdr" ]; then
                            log_warning "draft-eagle3/draft-simple requires a draft model file!"
                            log_warning "No model-draft set and no download performed."
                            log_warning "Reverting spec-type to avoid broken config."
                            ini_delete_key "$INI_FILE" "$section" "spec-type"
                            ini_delete_key "$INI_FILE" "$section" "spec-draft-n-max"
                            ini_delete_key "$INI_FILE" "$section" "draft-p-min"
                            log_info "Speculative decoding reverted. Run again with a draft model URL."
                        else
                            log_info "Keeping existing model-draft: $existing_mdr"
                        fi
                        ;;
                    __remove__)
                        ini_delete_key "$INI_FILE" "$section" "model-draft"
                        log_success "Draft model removed from config."
                        ;;
                    "")
                        # Prompt for manual path
                        read -p "  model-draft      (blank=keep)  [${mdr:-(not set)}]: " v
                        [ -n "$v" ] && ini_set "$INI_FILE" "$section" "model-draft" "$v"
                        ;;
                    *)
                        ini_set "$INI_FILE" "$section" "model-draft" "$DRAFT_PATH"
                        log_success "Draft model set to: $DRAFT_PATH"
                        ;;
                esac
            else
                # Non-draft spec types: just prompt for model-draft path
                read -p "  model-draft      (blank=keep)  [${mdr:-(not set)}]: " v
                [ -n "$v" ] && ini_set "$INI_FILE" "$section" "model-draft" "$v"
            fi
        fi
        log_success "Speculative decoding settings updated!"
        ;;
    q|Q)
        exit 0
        ;;
    *)
        log_error "Invalid choice"
        exit 1
        ;;
esac

echo
log_info "Note: Reload the model for changes to take effect"
