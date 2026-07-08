#!/usr/bin/env bash
#
# backup.sh
#
# Stops the pg-node Docker Compose stack, archives its application
# and data directories into backup.tar.gz, then restarts the stack.
#
# Fixed application paths:
#   /opt/pg-node               -> application / compose project
#   /var/lib/pg-node           -> persistent data
#   /opt/pg-node/docker-compose.yml -> compose file
#
# Usage:
#   sudo ./backup.sh
#
set -Eeuo pipefail

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
readonly APP_DIR="/opt/pg-node"
readonly DATA_DIR="/var/lib/pg-node"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
readonly BACKUP_FILE="backup.tar.gz"
readonly BACKUP_PATH="$(pwd)/${BACKUP_FILE}"

# --------------------------------------------------------------------------
# Colors
# --------------------------------------------------------------------------
readonly COLOR_RED="\033[0;31m"
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[0;33m"
readonly COLOR_BLUE="\033[0;34m"
readonly COLOR_RESET="\033[0m"

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_err()   { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*" >&2; }

# --------------------------------------------------------------------------
# Error handling / cleanup
# --------------------------------------------------------------------------
STACK_STOPPED=0

# Always try to bring the stack back up if we stopped it and something
# failed afterwards, so we don't leave the service down.
on_error() {
    local exit_code=$?
    log_err "An error occurred (exit code ${exit_code}) on line ${BASH_LINENO[0]}."
    if [[ "${STACK_STOPPED}" -eq 1 ]]; then
        log_warn "Attempting to restart the Docker Compose stack after failure..."
        docker compose -f "${COMPOSE_FILE}" up -d || \
            log_err "Failed to restart the stack automatically. Please check manually."
    fi
    exit "${exit_code}"
}
trap on_error ERR

# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

# 1. Verify root privileges
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "This script must be run as root (use sudo)."
        exit 1
    fi
    log_ok "Running with root privileges."
}

# 2. Verify Docker is installed
check_docker() {
    if ! command -v docker &>/dev/null; then
        log_err "Docker is not installed. Please install Docker before running this script."
        exit 1
    fi
    if ! docker compose version &>/dev/null; then
        log_err "Docker Compose plugin is not installed."
        exit 1
    fi
    log_ok "Docker and Docker Compose plugin are present."
}

# Verify required paths exist
check_paths() {
    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        log_err "Compose file not found at ${COMPOSE_FILE}."
        exit 1
    fi
    if [[ ! -d "${APP_DIR}" ]]; then
        log_err "Application directory ${APP_DIR} does not exist."
        exit 1
    fi
    if [[ ! -d "${DATA_DIR}" ]]; then
        log_warn "Data directory ${DATA_DIR} does not exist. It will be skipped in the archive."
    fi
    log_ok "Required paths verified."
}

# --------------------------------------------------------------------------
# Steps
# --------------------------------------------------------------------------

# 3. Stop the Docker Compose project
stop_stack() {
    log_info "Stopping Docker Compose stack..."
    docker compose -f "${COMPOSE_FILE}" down
    STACK_STOPPED=1
    log_ok "Stack stopped."
}

# 4. Create compressed archive
create_backup() {
    log_info "Creating backup archive: ${BACKUP_FILE}"

    # Build list of existing directories only, to avoid tar failing
    # if one of them is missing.
    local targets=()
    [[ -d "${APP_DIR}" ]] && targets+=("${APP_DIR}")
    [[ -d "${DATA_DIR}" ]] && targets+=("${DATA_DIR}")

    if [[ "${#targets[@]}" -eq 0 ]]; then
        log_err "Neither ${APP_DIR} nor ${DATA_DIR} exist. Nothing to back up."
        exit 1
    fi

    # Archive with paths relative to / so restore can extract to / directly.
    tar -czpf "${BACKUP_PATH}" -C / \
        $(printf '%s\n' "${targets[@]}" | sed 's|^/||')

    log_ok "Archive created at ${BACKUP_PATH}"
}

# 5. Start the project again
start_stack() {
    log_info "Starting Docker Compose stack..."
    docker compose -f "${COMPOSE_FILE}" up -d
    STACK_STOPPED=0
    log_ok "Stack started."
}

# 6. Print backup size and success message
print_summary() {
    local size
    size=$(du -h "${BACKUP_PATH}" | cut -f1)
    echo
    log_ok "Backup completed successfully."
    log_info "Backup file: ${BACKUP_PATH}"
    log_info "Backup size: ${size}"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    check_root
    check_docker
    check_paths
    stop_stack
    create_backup
    start_stack
    print_summary
}

main "$@"
