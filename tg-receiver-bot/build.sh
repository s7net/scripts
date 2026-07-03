#!/usr/bin/env bash
set -euo pipefail

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# Ensure we are in the script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

info "Checking for Go compiler..."
if ! command -v go &>/dev/null; then
    warn "Go is not installed. Attempting to install..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y golang-go
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y golang
    elif command -v yum &>/dev/null; then
        sudo yum install -y golang
    elif command -v brew &>/dev/null; then
        brew install go
    else
        error "Go compiler not found. Please install Go 1.20+ manually (https://go.dev/doc/install) and rerun this script."
        exit 1
    fi
fi

success "Go version: $(go version)"

info "Fetching Go dependencies..."
go mod tidy

info "Compiling standalone bot binary..."
go build -o tg-receiver-bot main.go

success "Compilation successful! Standalone binary created: ./tg-receiver-bot"
