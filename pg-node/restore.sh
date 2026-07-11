#!/usr/bin/env bash
#
# restore.sh - restores a pg-node instance from a backup archive.
#
# Flow:
#   1) Repair broken dpkg/apt state.
#   2) Install Docker + base pg-node scaffolding via the official
#      PasarGuard installer (non-interactive, no systemd service).
#   3) Stop the installer's default stack.
#   4) Download and extract the real backup over /opt/pg-node and
#      /var/lib/pg-node, replacing the default config.
#   5) Pull images and bring the restored stack up.
#   6) Block known-abuse IP ranges via iptables (Abuse-Defender source).
#   7) Show a "docker ps" snapshot, then follow logs (Ctrl+C to stop
#      watching; the stack keeps running).
#
# Usage:
#   sudo ./restore.sh -b <backup-url>
#   sudo ./restore.sh              # prompts for the URL
#
set -Eeuo pipefail

# Set via -b flag or interactive prompt (see resolve_backup_url).
BACKUP_URL=""

readonly APP_DIR="/opt/pg-node"
readonly DATA_DIR="/var/lib/pg-node"
readonly TMP_ARCHIVE="/tmp/pg-node-backup.tar.gz"
readonly STARTUP_WAIT_SECONDS=10
readonly LOG_FILE="/var/log/pg-node-restore.log"
readonly PG_NODE_INSTALLER_URL="https://github.com/PasarGuard/scripts/raw/main/pg-node.sh"

# Abuse-Defender integration (https://github.com/Kiya6955/Abuse-Defender)
readonly ABUSE_IP_LIST_URL="https://raw.githubusercontent.com/Kiya6955/Abuse-Defender/main/abuse-ips.ipv4"
readonly ABUSE_CHAIN="abuse-defender"
readonly ABUSE_UPDATE_SCRIPT="/root/abuse-defender-update.sh"

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

on_error() {
    local exit_code=$?
    log_err "Error (exit code ${exit_code}) on line ${BASH_LINENO[0]}. See ${LOG_FILE}"
    exit "${exit_code}"
}
trap on_error ERR

init_log() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    : > "${LOG_FILE}"
    log_info "Logging full output to: ${LOG_FILE}"
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "This script must be run as root (use sudo)."
        exit 1
    fi
    log_ok "Running as root."
}

detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        log_err "Cannot detect operating system (/etc/os-release missing)."
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    DISTRO_ID="${ID:-}"
    DISTRO_ID_LIKE="${ID_LIKE:-}"

    case "${DISTRO_ID} ${DISTRO_ID_LIKE}" in
        *ubuntu*|*debian*)
            log_ok "Detected: ${PRETTY_NAME:-$DISTRO_ID}"
            ;;
        *)
            log_err "Unsupported distribution: ${PRETTY_NAME:-$DISTRO_ID}. Only Ubuntu/Debian are supported."
            exit 1
            ;;
    esac
}

# Repairs an interrupted/broken dpkg state before any package install runs.
repair_broken_packages() {
    log_info "Checking package manager state..."
    export DEBIAN_FRONTEND=noninteractive

    run_quiet "Reconfiguring half-installed packages" dpkg --configure -a || true
    run_quiet "Fixing broken dependencies" apt-get install -f -y || true
    run_quiet "Updating package lists" apt-get update -y || true
    run_quiet "Reconfiguring packages (retry)" dpkg --configure -a || true

    if ! run_quiet "Fixing broken dependencies (final)" apt-get install -f -y; then
        log_err "Unable to automatically repair the package state. Run manually:"
        log_err "  sudo dpkg --configure -a && sudo apt-get install -f -y && sudo apt-get update"
        exit 1
    fi

    log_ok "Package manager state is healthy."
}

# The official installer bootstraps itself with curl.
ensure_curl() {
    if command -v curl &>/dev/null; then
        return
    fi
    export DEBIAN_FRONTEND=noninteractive
    run_quiet "Updating package lists" apt-get update -y
    run_quiet "Installing curl" apt-get install -y curl
}

# Runs the official PasarGuard pg-node installer non-interactively.
# Installs Docker, Compose, jq, yq, and the base APP_DIR/DATA_DIR scaffolding.
_install_pg_node_official() {
    bash -c "$(curl -fsSL "${PG_NODE_INSTALLER_URL}")" @ install -y --no-install-service
}

install_pg_node_official() {
    log_info "Installing pg-node (Docker + base scaffolding) via the official installer..."
    if ! run_quiet "Running official pg-node.sh installer" _install_pg_node_official; then
        log_err "The official pg-node.sh installer failed. See ${LOG_FILE}"
        exit 1
    fi

    if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null; then
        log_err "Docker does not appear to be installed correctly."
        exit 1
    fi
    if [[ ! -f "${APP_DIR}/docker-compose.yml" ]]; then
        log_err "Installer did not create docker-compose.yml in ${APP_DIR}."
        exit 1
    fi

    log_ok "Base pg-node installation complete."
}

# Stops the installer's default stack before overwriting its config.
_stop_default_stack() {
    cd "${APP_DIR}"
    docker compose down
}

stop_default_stack() {
    run_quiet "Stopping default stack" _stop_default_stack
}

# Resolves BACKUP_URL: -b flag, then interactive prompt.
resolve_backup_url() {
    if [[ -n "${BACKUP_URL}" ]]; then
        log_ok "Using backup URL from -b flag."
        return
    fi

    if [[ -t 0 ]]; then
        while [[ -z "${BACKUP_URL}" ]]; do
            read -r -p "$(echo -e "${COLOR_BLUE}[INPUT]${COLOR_RESET} Enter the backup download URL: ")" BACKUP_URL
            [[ -z "${BACKUP_URL}" ]] && log_warn "URL cannot be empty."
        done
    else
        log_err "No backup URL provided and no interactive terminal available."
        log_err "Run with: sudo ./restore.sh -b <backup-url>"
        exit 1
    fi
}

parse_args() {
    while getopts ":b:h" opt; do
        case "${opt}" in
            b) BACKUP_URL="${OPTARG}" ;;
            h)
                echo "Usage: sudo $0 -b <backup-url>"
                exit 0
                ;;
            \?)
                log_err "Invalid option: -${OPTARG}"
                echo "Usage: sudo $0 -b <backup-url>"
                exit 1
                ;;
            :)
                log_err "Option -${OPTARG} requires an argument."
                echo "Usage: sudo $0 -b <backup-url>"
                exit 1
                ;;
        esac
    done
}

DOWNLOADER=""
detect_downloader() {
    if command -v curl &>/dev/null; then
        DOWNLOADER="curl"
    elif command -v wget &>/dev/null; then
        DOWNLOADER="wget"
    else
        export DEBIAN_FRONTEND=noninteractive
        run_quiet "Installing curl" apt-get install -y curl
        DOWNLOADER="curl"
    fi
    log_ok "Using ${DOWNLOADER} for downloads."
}

download_backup() {
    log_info "Downloading backup..."

    if [[ "${DOWNLOADER}" == "curl" ]]; then
        run_quiet "Downloading backup file" curl -fL --retry 3 -o "${TMP_ARCHIVE}" "${BACKUP_URL}"
    else
        run_quiet "Downloading backup file" wget --tries=3 -O "${TMP_ARCHIVE}" "${BACKUP_URL}"
    fi

    if [[ ! -s "${TMP_ARCHIVE}" ]]; then
        log_err "Downloaded archive is empty or missing."
        exit 1
    fi

    log_ok "Backup downloaded: ${TMP_ARCHIVE}"
}

extract_backup() {
    run_quiet "Extracting backup (replacing default config)" tar -xzpf "${TMP_ARCHIVE}" -C /
}

start_stack() {
    if [[ ! -f "${APP_DIR}/docker-compose.yml" ]]; then
        log_err "docker-compose.yml not found in ${APP_DIR} after extraction."
        exit 1
    fi

    cd "${APP_DIR}"
    run_quiet "Pulling Docker images" docker compose pull
    run_quiet "Starting services" docker compose up -d
}

# ---------------------------------------------------------------------------
# Abuse-Defender integration (https://github.com/Kiya6955/Abuse-Defender)
# Blocks known-abuse IP ranges via a dedicated iptables chain, non-interactively.
# ---------------------------------------------------------------------------

_ensure_iptables_stack() {
    if ! command -v iptables &>/dev/null; then
        apt-get update -y
        apt-get install -y iptables
    fi
    if ! dpkg -s iptables-persistent &>/dev/null; then
        apt-get update -y
        apt-get install -y iptables-persistent
    fi
    mkdir -p /etc/iptables
}

_setup_abuse_chain() {
    if ! iptables -L "${ABUSE_CHAIN}" -n >/dev/null 2>&1; then
        iptables -N "${ABUSE_CHAIN}"
    fi
    if ! iptables -L OUTPUT -n | awk '{print $1}' | grep -wq "^${ABUSE_CHAIN}\$"; then
        iptables -I OUTPUT -j "${ABUSE_CHAIN}"
    fi
}

_populate_abuse_chain() {
    iptables -F "${ABUSE_CHAIN}"

    local ip_list
    ip_list=$(curl -fsSL "${ABUSE_IP_LIST_URL}")
    if [[ -z "${ip_list}" ]]; then
        echo "Failed to fetch abuse IP-range list from ${ABUSE_IP_LIST_URL}" >&2
        return 1
    fi

    local ip
    for ip in ${ip_list}; do
        iptables -A "${ABUSE_CHAIN}" -d "${ip}" -j DROP
    done

    echo '127.0.0.1 appclick.co' | tee -a /etc/hosts >/dev/null
    echo '127.0.0.1 pushnotificationws.com' | tee -a /etc/hosts >/dev/null

    iptables-save > /etc/iptables/rules.v4
}

# Installs a daily cron job that refreshes the abuse-IP list, mirroring
# Abuse-Defender's own auto-update option.
_setup_abuse_auto_update() {
    cat <<EOF >"${ABUSE_UPDATE_SCRIPT}"
#!/bin/bash
iptables -F ${ABUSE_CHAIN}
IP_LIST=\$(curl -fsSL '${ABUSE_IP_LIST_URL}')
for IP in \$IP_LIST; do
    iptables -A ${ABUSE_CHAIN} -d \$IP -j DROP
done
iptables-save > /etc/iptables/rules.v4
EOF
    chmod +x "${ABUSE_UPDATE_SCRIPT}"

    crontab -l 2>/dev/null | grep -v "${ABUSE_UPDATE_SCRIPT}" | crontab - || true
    (crontab -l 2>/dev/null; echo "0 0 * * * ${ABUSE_UPDATE_SCRIPT}") | crontab -
}

block_abuse_ips() {
    log_info "Blocking known-abuse IP ranges (Abuse-Defender)..."
    run_quiet "Installing iptables/iptables-persistent" _ensure_iptables_stack
    run_quiet "Setting up abuse-defender chain" _setup_abuse_chain

    if ! run_quiet "Fetching and applying abuse IP-range list" _populate_abuse_chain; then
        log_warn "Could not apply abuse IP-range list; continuing without it."
        return
    fi

    run_quiet "Enabling daily abuse-list auto-update" _setup_abuse_auto_update
    log_ok "Abuse IP-ranges blocked."
}

show_status() {
    log_info "Waiting ${STARTUP_WAIT_SECONDS}s for services to come up..."
    sleep "${STARTUP_WAIT_SECONDS}"
    echo
    docker ps
    echo
}

cleanup() {
    rm -f "${TMP_ARCHIVE}"
}

print_success() {
    echo -e "${COLOR_GREEN}Restore completed successfully.${COLOR_RESET}"
}

# Follows the stack's logs (not run_quiet: the point is to show live output).
follow_logs() {
    cd "${APP_DIR}"
    log_info "Following logs. Press Ctrl+C to stop watching (the stack keeps running)."
    echo
    docker compose logs -f || true
}

main() {
    parse_args "$@"
    check_root
    init_log
    detect_distro
    repair_broken_packages
    ensure_curl
    install_pg_node_official
    stop_default_stack
    detect_downloader
    resolve_backup_url
    download_backup
    extract_backup
    start_stack
    block_abuse_ips
    show_status
    cleanup
    print_success
    follow_logs
}

main "$@"
