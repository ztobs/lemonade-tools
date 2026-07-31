#!/bin/bash
# Install llama-server from Lemonade SDK (ROCm gfx1151 pre-built binaries)
# Lemonade release b1220 — bundles its own ROCm 7 runtime, no system ROCm needed
# Binary is labeled "ubuntu" but is standard Linux ELF (glibc 2.39+); works on Fedora 43 (glibc 2.43)

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

RELEASE_TAG="b1302"
DOWNLOAD_URL="https://github.com/lemonade-sdk/llamacpp-rocm/releases/download/${RELEASE_TAG}/llama-${RELEASE_TAG}-ubuntu-rocm-gfx1151-x64.zip"
INSTALL_DIR="$HOME/AI/llama-server/bin"
TMP_DIR="/tmp/lemonade-install-$$"

echo "═══════════════════════════════════════════════════════════"
log_info "llama-server Installer (Lemonade SDK ROCm gfx1151)"
log_setting "Release: $RELEASE_TAG"
log_setting "Install dir: $INSTALL_DIR"
echo "═══════════════════════════════════════════════════════════"
echo

# Check for existing install
if [ -f "$INSTALL_DIR/llama-server" ]; then
    existing_ver=$("$INSTALL_DIR/llama-server" --version 2>/dev/null | head -1 || echo "unknown")
    log_warning "llama-server already installed at $INSTALL_DIR"
    log_setting "Current version: $existing_ver"
    echo
    read -p "Reinstall/upgrade? (y/n): " confirm
    if [ "x$confirm" != "xy" ] && [ "x$confirm" != "xY" ]; then
        log_info "Cancelled."
        exit 0
    fi
fi

# Check for required tools
for tool in curl unzip; do
    if ! command -v "$tool" &>/dev/null; then
        log_error "Required tool not found: $tool"
        log_info "Install with: sudo dnf install $tool"
        exit 1
    fi
done

mkdir -p "$INSTALL_DIR"
mkdir -p "$TMP_DIR"

trap "rm -rf '$TMP_DIR'" EXIT

ZIP_FILE="$TMP_DIR/lemonade.zip"

log_info "Downloading llama-server (Lemonade ROCm gfx1151)..."
log_setting "URL: $DOWNLOAD_URL"
echo

if ! curl -L --progress-bar -o "$ZIP_FILE" "$DOWNLOAD_URL"; then
    log_error "Download failed!"
    exit 1
fi

echo
log_info "Extracting to $INSTALL_DIR ..."
if ! unzip -o "$ZIP_FILE" -d "$TMP_DIR/extracted" > /dev/null; then
    log_error "Extraction failed!"
    exit 1
fi

# Copy all extracted files into bin dir
cp -r "$TMP_DIR/extracted"/. "$INSTALL_DIR/"

# Make all binaries executable
find "$INSTALL_DIR" -type f \( -name "llama-*" -o -name "*.so*" \) -exec chmod +x {} \; 2>/dev/null || true
chmod +x "$INSTALL_DIR"/llama-server 2>/dev/null || true

echo
log_success "llama-server installed to: $INSTALL_DIR"
echo

# Verify install
if [ -f "$INSTALL_DIR/llama-server" ]; then
    log_info "Verifying binary..."
    # Set required env vars for AMD ROCm gfx1151
    export HSA_OVERRIDE_GFX_VERSION=11.5.1
    export ROCBLAS_USE_HIPBLASLT=1
    export LD_LIBRARY_PATH="$INSTALL_DIR:${LD_LIBRARY_PATH:-}"

    version_out=$("$INSTALL_DIR/llama-server" --version 2>&1 | head -3 || echo "(version check failed)")
    log_setting "Version: $version_out"
else
    log_error "llama-server binary not found after extraction. Check zip contents:"
    ls "$INSTALL_DIR/"
    exit 1
fi

echo
log_success "Installation complete!"
echo
log_info "Runtime environment variables required (already set in load scripts):"
log_setting "HSA_OVERRIDE_GFX_VERSION=11.5.1"
log_setting "ROCBLAS_USE_HIPBLASLT=1"
log_setting "RADV_PERFTEST=bfloat16  (optional, BF16 perf boost)"
echo
log_info "Binary location: $INSTALL_DIR/llama-server"
log_info "Use 'llm_load' to start loading models."
