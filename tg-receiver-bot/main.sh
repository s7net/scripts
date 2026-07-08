#!/usr/bin/env bash
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Paths ─────────────────────────────────────────────────────────────────────
# When run via "bash <(curl ...)", BASH_SOURCE[0] is /dev/fd/N — fall back to $PWD
_src="${BASH_SOURCE[0]:-}"
if [[ -z "$_src" || "$_src" == /dev/fd/* || "$_src" == /proc/self/fd/* ]]; then
    SCRIPT_DIR="$PWD"
else
    SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
fi
SESSION_FILE="${SCRIPT_DIR}/tg_downloader_bot.session"

# GitHub URLs for the precompiled static Go bot binaries
GO_BIN_URL_AMD64="https://github.com/s7net/scripts/releases/download/release/tg-receiver-bot-amd64"
GO_BIN_URL_ARM64="https://github.com/s7net/scripts/releases/download/release/tg-receiver-bot-arm64"

# Fallback public API credentials (used only if user leaves API_ID/HASH blank)
# Risk: Telegram may flag sessions using 3rd-party client credentials.
# Recommended: get your own free at https://my.telegram.org
declare -A FALLBACK_APIS=(
  [0]="2040|b18441a1ff607e10a989891a5462e627|TDesktop"
  [1]="6|eb06d4abfb49dc3eeb1aeb98ae0f581e|Telegram Android"
  [2]="94575|a3406de8d171bb422bb6ddf3bbd800e2|Nicegram/iOS"
  [3]="2496|8da85b0d5bfe62527e5b244c209159c3|Webogram"
  [4]="21724|3e0cb5efcd52300aec5994fdfc5bdc16|TGX Android"
  [5]="414121|db09ccfc2a65e1b14a937be15bdb5d4b|TG-React"
)

# ── Cleanup (always runs on exit) ─────────────────────────────────────────────
cleanup() {
    echo ""
    info "Cleaning up temporary files..."
    [[ -f "$SESSION_FILE" ]] && rm -f "$SESSION_FILE" && success "Removed session file"
    success "Done. Your files are in: ${DOWNLOAD_DIR:-$SCRIPT_DIR/downloads}"
}
trap cleanup EXIT

# =============================================================================
echo -e "\n${BOLD}╔══════════════════════════════════════════╗"
echo -e "║   Telegram Backup Downloader Bot         ║"
echo -e "╚══════════════════════════════════════════╝${RESET}\n"

# ── Parse flags ──────────────────────────────────────────────────────────────
CONFIG_B64=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_B64="$2"; shift 2 ;;
        *)        error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Prompt for any missing values ─────────────────────────────────────────────
prompt_if_empty() {
    local var_name="$1" prompt_text="$2" secret="${3:-false}" hint="${4:-}" value=""
    if [[ -z "${!var_name:-}" ]]; then
        local label="${prompt_text}"
        [[ -n "$hint" ]] && label="${prompt_text} ${YELLOW}[${hint}]${RESET}"
        if [[ "$secret" == "true" ]]; then
            echo -en "  ${label}: "; read -rs value; echo ""
        else
            echo -en "  ${label}: "; read -r value
        fi
        export "$var_name"="$value"
    fi
}

if [[ -z "$CONFIG_B64" ]]; then
    echo -e "${BOLD}Configuration${RESET}"
    echo -e "  ${YELLOW}Tip:${RESET} press Enter to use the default shown in [brackets]\n"

    prompt_if_empty API_ID    "API ID    (my.telegram.org, or press Enter for public fallback)"
    prompt_if_empty API_HASH  "API HASH  (my.telegram.org, or press Enter for public fallback)" true

    # If API_ID/HASH left blank → pick a random public one
    if [[ -z "${API_ID:-}" ]] || [[ -z "${API_HASH:-}" ]]; then
        rand_idx=$(( RANDOM % ${#FALLBACK_APIS[@]} ))
        IFS='|' read -r fb_id fb_hash fb_name <<< "${FALLBACK_APIS[$rand_idx]}"
        warn "No API credentials supplied — using public fallback: ${fb_name}"
        export API_ID="$fb_id"
        export API_HASH="$fb_hash"
    fi

    prompt_if_empty BOT_TOKEN    "Bot Token    (@BotFather)" true
    prompt_if_empty ALLOWED_CHAT "Your Chat ID (@userinfobot)"

    # Defaults
    export DOWNLOAD_DIR="${DOWNLOAD_DIR:-${SCRIPT_DIR}/downloads}"
    export DOWNLOAD_WORKERS="${DOWNLOAD_WORKERS:-10}"

    # Validate
    [[ "${API_ID}"       =~ ^[0-9]+$   ]] || { error "API_ID must be numeric.";    exit 1; }
    [[ "${ALLOWED_CHAT}" =~ ^-?[0-9]+$ ]] || { error "ALLOWED_CHAT must be numeric."; exit 1; }
    [[ -n "${API_HASH}"                ]] || { error "API_HASH is empty.";          exit 1; }
    [[ -n "${BOT_TOKEN}"               ]] || { error "BOT_TOKEN is empty.";         exit 1; }
else
    export DOWNLOAD_DIR="${DOWNLOAD_DIR:-${SCRIPT_DIR}/downloads}"
fi

info "Download directory : ${DOWNLOAD_DIR}"
mkdir -p "${DOWNLOAD_DIR}"

# Detect and execute Go binary (auto-download from GitHub if missing on Linux)
GO_BINARY="${SCRIPT_DIR}/tg-receiver-bot"

if [[ ! -f "$GO_BINARY" && ! -f "${GO_BINARY}.exe" ]]; then
    if [[ "$(uname -s)" == "Linux" ]]; then
        ARCH="$(uname -m)"
        URL=""
        if [[ "$ARCH" == "x86_64" ]]; then
            URL="$GO_BIN_URL_AMD64"
        elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
            URL="$GO_BIN_URL_ARM64"
        fi
        
        if [[ -n "$URL" ]]; then
            info "Go binary not found. Downloading precompiled static binary for ${ARCH} from GitHub..."
            if command -v curl &>/dev/null; then
                curl -fsSL "$URL" -o "$GO_BINARY"
            elif command -v wget &>/dev/null; then
                wget -q "$URL" -O "$GO_BINARY"
            fi
            if [[ -f "$GO_BINARY" ]]; then
                chmod +x "$GO_BINARY"
                success "Go binary downloaded successfully"
            else
                error "Failed to download Go binary automatically."
                exit 1
            fi
        else
            error "Unsupported Linux architecture: ${ARCH}. Compile from source or install Go manually."
            exit 1
        fi
    else
        error "Go binary not found. Please compile it on your system or run in WSL/Linux."
        exit 1
    fi
fi

[[ -f "${GO_BINARY}.exe" ]] && GO_BINARY="${GO_BINARY}.exe"
if [[ -f "$GO_BINARY" && -x "$GO_BINARY" ]]; then
    info "Launching Go version..."
    
    # ── Instructions ──────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Ready!${RESET}"
    echo -e "  1. Send your backup files to the bot in Telegram"
    echo -e "  2. Send ${BOLD}/done${RESET} when finished — bot shuts down and cleans up"
    echo ""
    
    # Run Go bot
    ARGS=()
    if [[ -n "$CONFIG_B64" ]]; then
        ARGS+=("--config" "$CONFIG_B64")
    fi

    API_ID="${API_ID:-}" \
    API_HASH="${API_HASH:-}" \
    BOT_TOKEN="${BOT_TOKEN:-}" \
    ALLOWED_CHAT="${ALLOWED_CHAT:-}" \
    DOWNLOAD_DIR="$DOWNLOAD_DIR" \
    DOWNLOAD_WORKERS="${DOWNLOAD_WORKERS:-10}" \
        "$GO_BINARY" "${ARGS[@]}"
    
    exit 0
else
    error "Go binary not executable: $GO_BINARY"
    exit 1
fi
