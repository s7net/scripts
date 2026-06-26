#!/usr/bin/env bash
# =============================================================================
# Telegram Backup Downloader — run.sh
# https://github.com/YOUR_USERNAME/YOUR_REPO
#
# USAGE:
#   ./run.sh                          # first run: prompts → saves config string
#   ./run.sh --config <base64string>  # non-interactive with saved string
# =============================================================================

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
VENV_DIR="${SCRIPT_DIR}/.venv_tgdl"
BOT_SCRIPT="${SCRIPT_DIR}/.bot_tgdl.py"
SESSION_FILE="${SCRIPT_DIR}/tg_downloader_bot.session"

# GitHub raw URL for bot.py — update to your repo
BOT_PY_URL="https://raw.githubusercontent.com/s7net/scripts/main/tg-receiver-bot.py"

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
    [[ -f "$BOT_SCRIPT"   ]] && rm -f "$BOT_SCRIPT"   && success "Removed bot.py"
    [[ -f "$SESSION_FILE" ]] && rm -f "$SESSION_FILE" && success "Removed session file"
    [[ -d "$VENV_DIR"     ]] && rm -rf "$VENV_DIR"    && success "Removed virtual environment"
    success "Done. Your files are in: ${DOWNLOAD_DIR:-$SCRIPT_DIR/downloads}"
}
trap cleanup EXIT

# ── Config encode/decode helpers (pure bash + python3) ───────────────────────

# Encode current env vars → base64 JSON string
_encode_config() {
    python3 - <<PYEOF
import base64, json
cfg = {
    "API_ID":            "${API_ID}",
    "API_HASH":          "${API_HASH}",
    "BOT_TOKEN":         "${BOT_TOKEN}",
    "ALLOWED_CHAT":      "${ALLOWED_CHAT}",
    "DOWNLOAD_DIR":      "${DOWNLOAD_DIR}",
    "DOWNLOAD_WORKERS":  "${DOWNLOAD_WORKERS}",
}
print(base64.b64encode(json.dumps(cfg).encode()).decode())
PYEOF
}

# Decode base64 JSON string → export env vars
_decode_config() {
    local b64="$1"
    python3 - <<PYEOF
import base64, json, sys
try:
    cfg  = json.loads(base64.b64decode("${b64}").decode())
    keys = ["API_ID","API_HASH","BOT_TOKEN","ALLOWED_CHAT","DOWNLOAD_DIR","DOWNLOAD_WORKERS"]
    for k in keys:
        v = cfg.get(k, "")
        # escape any single-quotes in value for safe shell export
        v = v.replace("'", "'\\''")
        print(f"{k}='{v}'")
except Exception as e:
    print(f"DECODE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# =============================================================================
echo -e "\n${BOLD}╔══════════════════════════════════════════╗"
echo -e "║   Telegram Backup Downloader Bot         ║"
echo -e "╚══════════════════════════════════════════╝${RESET}\n"

# ── Parse --config flag ───────────────────────────────────────────────────────
CONFIG_B64=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_B64="$2"; shift 2 ;;
        *)        error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -n "$CONFIG_B64" ]]; then
    info "Decoding config string..."
    eval "$(_decode_config "$CONFIG_B64")"
    success "Config loaded"
fi

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

echo -e "${BOLD}Configuration${RESET}"
echo -e "  ${YELLOW}Tip:${RESET} press Enter to use the default shown in [brackets]\n"

prompt_if_empty API_ID    "API ID    (my.telegram.org, or press Enter for public fallback)"
prompt_if_empty API_HASH  "API HASH  (my.telegram.org, or press Enter for public fallback)" true

# ── If API_ID/HASH left blank → pick a random public one ─────────────────────
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

echo ""

# ── Validate ──────────────────────────────────────────────────────────────────
[[ "${API_ID}"       =~ ^[0-9]+$   ]] || { error "API_ID must be numeric.";    exit 1; }
[[ "${ALLOWED_CHAT}" =~ ^-?[0-9]+$ ]] || { error "ALLOWED_CHAT must be numeric."; exit 1; }
[[ -n "${API_HASH}"                ]] || { error "API_HASH is empty.";          exit 1; }
[[ -n "${BOT_TOKEN}"               ]] || { error "BOT_TOKEN is empty.";         exit 1; }

info "Download directory : ${DOWNLOAD_DIR}"
info "Parallel workers   : ${DOWNLOAD_WORKERS} chunks"
mkdir -p "${DOWNLOAD_DIR}"

# ── Generate & display config string (only on first run / no --config given) ──
if [[ -z "$CONFIG_B64" ]]; then
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${GREEN}  Your config string (save this for next time):${RESET}"
    echo ""
    CONFIG_GENERATED=$(_encode_config)
    echo -e "  ${BOLD}${CONFIG_GENERATED}${RESET}"
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
fi

# ── Ensure Python 3.9+ ────────────────────────────────────────────────────────
info "Checking Python..."
PYTHON=""
for cmd in python3 python; do
    if command -v "$cmd" &>/dev/null; then
        if "$cmd" -c "import sys; sys.exit(0 if sys.version_info>=(3,9) else 1)" 2>/dev/null; then
            PYTHON="$cmd"; break
        fi
    fi
done

if [[ -z "$PYTHON" ]]; then
    warn "Python 3.9+ not found — installing..."
    if   command -v apt-get &>/dev/null; then sudo apt-get update -qq && sudo apt-get install -y python3 python3-pip
    elif command -v dnf     &>/dev/null; then sudo dnf install -y python3 python3-pip
    elif command -v yum     &>/dev/null; then sudo yum install -y python3 python3-pip
    elif command -v brew    &>/dev/null; then brew install python3
    else error "Cannot install Python automatically. Install Python 3.9+ manually."; exit 1
    fi
    PYTHON="python3"
fi
success "Python: $($PYTHON --version)"

# ── Ensure python3-venv ───────────────────────────────────────────────────────
info "Checking python3-venv..."
PY_VER=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

if ! "$PYTHON" -m venv --help &>/dev/null 2>&1; then
    warn "python3-venv not found — installing..."
    if command -v apt-get &>/dev/null; then
        if apt-cache show "python${PY_VER}-venv" &>/dev/null 2>&1; then
            sudo apt-get install -y "python${PY_VER}-venv"
        else
            sudo apt-get install -y python3-venv python3-pip
        fi
    elif command -v dnf &>/dev/null; then sudo dnf install -y python3-venv
    elif command -v yum &>/dev/null; then sudo yum install -y python3-venv
    else error "Cannot install python3-venv. Run: sudo apt install python${PY_VER}-venv"; exit 1
    fi
    "$PYTHON" -m venv --help &>/dev/null 2>&1 || { error "python3-venv still unavailable."; exit 1; }
fi
success "python3-venv OK"

# ── Download bot.py from GitHub ───────────────────────────────────────────────
echo ""
info "Downloading bot.py..."
if   command -v curl &>/dev/null; then curl -fsSL "$BOT_PY_URL" -o "$BOT_SCRIPT"
elif command -v wget &>/dev/null; then wget -q "$BOT_PY_URL" -O "$BOT_SCRIPT"
else "$PYTHON" -c "import urllib.request; urllib.request.urlretrieve('${BOT_PY_URL}','${BOT_SCRIPT}')"
fi
chmod +x "$BOT_SCRIPT"
success "bot.py downloaded"

# ── Venv + deps ───────────────────────────────────────────────────────────────
echo ""
info "Creating virtual environment..."
"$PYTHON" -m venv "$VENV_DIR"
PIP="${VENV_DIR}/bin/pip"
PYTHON_VENV="${VENV_DIR}/bin/python"
info "Installing Telethon..."
"$PIP" install --quiet --upgrade pip
"$PIP" install --quiet telethon
success "Telethon installed"

# ── Instructions ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Ready!${RESET}"
echo -e "  1. Send your backup files to the bot in Telegram"
echo -e "  2. Send ${BOLD}/done${RESET} when finished — bot shuts down and cleans up"
echo ""

# ── Run bot ───────────────────────────────────────────────────────────────────
API_ID="$API_ID" \
API_HASH="$API_HASH" \
BOT_TOKEN="$BOT_TOKEN" \
ALLOWED_CHAT="$ALLOWED_CHAT" \
DOWNLOAD_DIR="$DOWNLOAD_DIR" \
DOWNLOAD_WORKERS="$DOWNLOAD_WORKERS" \
    "$PYTHON_VENV" "$BOT_SCRIPT"

# trap cleanup fires here automatically
