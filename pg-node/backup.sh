#!/usr/bin/env bash
#
# backup.sh - stops the pg-node stack, archives /opt/pg-node and
# /var/lib/pg-node into backup.tar.gz, then restarts the stack.
#
# Usage: sudo ./backup.sh
#
set -Eeuo pipefail

readonly APP_DIR="/opt/pg-node"
readonly DATA_DIR="/var/lib/pg-node"
readonly COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
readonly BACKUP_FILE="backup.tar.gz"
readonly BACKUP_PATH="$(pwd)/${BACKUP_FILE}"
readonly LOG_FILE="/var/log/pg-node-backup.log"

readonly COLOR_RED="\033[0;31m"
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[0;33m"
readonly COLOR_BLUE="\033[0;34m"
readonly COLOR_RESET="\033[0m"

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_err()   { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*" >&2; }

# Runs a command with output hidden (only a spinner is shown); full output
# goes to LOG_FILE.
run_quiet() {
    local desc="$1"
    shift

    echo "----- $(date '+%Y-%m-%d %H:%M:%S') :: ${desc} -----" >> "${LOG_FILE}"

    ( "$@" ) >> "${LOG_FILE}" 2>&1 &
    local pid=$!

    if [[ -t 1 ]]; then
        local frames='|/-\'
        local i=0
        while kill -0 "${pid}" 2>/dev/null; do
            i=$(( (i + 1) % 4 ))
            printf "\r${COLOR_BLUE}[....]${COLOR_RESET} %s %s" "${desc}" "${frames:$i:1}"
            sleep 0.2
        done
    else
        printf "${COLOR_BLUE}[....]${COLOR_RESET} %s\n" "${desc}"
    fi

    wait "${pid}"
    local exit_code=$?

    if [[ "${exit_code}" -eq 0 ]]; then
        printf "\r${COLOR_GREEN}[ OK ]${COLOR_RESET} %s\n" "${desc}"
    else
        printf "\r${COLOR_RED}[FAIL]${COLOR_RESET} %s (see: %s)\n" "${desc}" "${LOG_FILE}"
    fi

    return "${exit_code}"
}

init_log() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    : > "${LOG_FILE}"
    log_info "Logging full output to: ${LOG_FILE}"
}

STACK_STOPPED=0

on_error() {
    local exit_code=$?
    log_err "Error (exit code ${exit_code}) on line ${BASH_LINENO[0]}. See ${LOG_FILE}"
    if [[ "${STACK_STOPPED}" -eq 1 ]]; then
        log_warn "Attempting to restart the stack after failure..."
        docker compose -f "${COMPOSE_FILE}" up -d || log_err "Failed to restart the stack automatically."
    fi
    exit "${exit_code}"
}
trap on_error ERR

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "This script must be run as root (use sudo)."
        exit 1
    fi
    log_ok "Running as root."
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_err "Docker is not installed."
        exit 1
    fi
    if ! docker compose version &>/dev/null; then
        log_err "Docker Compose plugin is not installed."
        exit 1
    fi
    log_ok "Docker and Compose plugin present."
}

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
        log_warn "Data directory ${DATA_DIR} does not exist; it will be skipped."
    fi
    log_ok "Required paths verified."
}

stop_stack() {
    run_quiet "Stopping Docker Compose stack" docker compose -f "${COMPOSE_FILE}" down
    STACK_STOPPED=1
}

create_backup() {
    local targets=()
    [[ -d "${APP_DIR}" ]] && targets+=("${APP_DIR}")
    [[ -d "${DATA_DIR}" ]] && targets+=("${DATA_DIR}")

    if [[ "${#targets[@]}" -eq 0 ]]; then
        log_err "Neither ${APP_DIR} nor ${DATA_DIR} exist. Nothing to back up."
        exit 1
    fi

    # Paths relative to / so restore.sh can extract straight to /.
    run_quiet "Creating backup archive" tar -czpf "${BACKUP_PATH}" -C / \
        $(printf '%s\n' "${targets[@]}" | sed 's|^/||')

    log_ok "Archive created: ${BACKUP_PATH}"
}

start_stack() {
    run_quiet "Starting Docker Compose stack" docker compose -f "${COMPOSE_FILE}" up -d
    STACK_STOPPED=0
}

print_summary() {
    local size
    size=$(du -h "${BACKUP_PATH}" | cut -f1)
    echo
    log_ok "Backup completed successfully."
    log_info "File: ${BACKUP_PATH}"
    log_info "Size: ${size}"
}

main() {
    check_root
    init_log
    check_docker
    check_paths
    stop_stack
    create_backup
    start_stack
    print_summary
}

main "$@"
