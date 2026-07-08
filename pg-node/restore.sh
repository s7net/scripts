#!/usr/bin/env bash
#
# restore.sh
#
# Downloads a backup archive, installs Docker (if needed), restores
# /opt/pg-node and /var/lib/pg-node from the archive, and brings the
# Docker Compose stack back up.
#
# The backup URL is NOT hardcoded in this script. Provide it either:
#   1) With the -b flag:   sudo ./restore.sh -b https://example.com/backup.tar.gz
#   2) Interactively: just run "sudo ./restore.sh" and you'll be prompted.
#
# Usage:
#   sudo ./restore.sh -b <backup-url>
#   sudo ./restore.sh              # will prompt for the URL
#
set -Eeuo pipefail

# BACKUP_URL is populated at runtime from the -b flag or an interactive
# prompt (see resolve_backup_url below). Do not hardcode it here.
BACKUP_URL=""

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
readonly APP_DIR="/opt/pg-node"
readonly DATA_DIR="/var/lib/pg-node"
readonly TMP_ARCHIVE="/tmp/pg-node-backup.tar.gz"
readonly STARTUP_WAIT_SECONDS=10

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
# Error handling
# --------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    log_err "An error occurred (exit code ${exit_code}) on line ${BASH_LINENO[0]}."
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

# Detect distro; only Ubuntu/Debian are supported.
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
            log_ok "Detected supported distribution: ${PRETTY_NAME:-$DISTRO_ID}"
            ;;
        *)
            log_err "Unsupported distribution: ${PRETTY_NAME:-$DISTRO_ID}. Only Ubuntu/Debian are supported."
            exit 1
            ;;
    esac
}

# Detect which downloader is available (curl or wget). Install curl if neither is found.
DOWNLOADER=""
detect_downloader() {
    if command -v curl &>/dev/null; then
        DOWNLOADER="curl"
    elif command -v wget &>/dev/null; then
        DOWNLOADER="wget"
    else
        log_warn "Neither curl nor wget found. Installing curl..."
        apt-get update -y
        apt-get install -y curl
        DOWNLOADER="curl"
    fi
    log_ok "Using ${DOWNLOADER} for downloads."
}

# --------------------------------------------------------------------------
# Docker installation
# --------------------------------------------------------------------------

# 2. Install Docker Engine and Docker Compose plugin if missing.
install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log_ok "Docker and Docker Compose plugin already installed."
        return
    fi

    log_info "Installing Docker Engine and Docker Compose plugin..."

    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings

    # Add Docker's official GPG key (idempotent).
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Add Docker apt repository.
    local arch
    arch="$(dpkg --print-architecture)"
    local codename
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null; then
        log_err "Docker installation failed."
        exit 1
    fi

    log_ok "Docker Engine and Docker Compose plugin installed successfully."
}

# --------------------------------------------------------------------------
# Restore steps
# --------------------------------------------------------------------------

# Resolve the backup URL, in order of priority:
#   1) The -b flag (sudo ./restore.sh -b <url>)
#   2) Interactive prompt (asks the user to type/paste the URL)
resolve_backup_url() {
    # 1) Already set from the -b flag by parse_args().
    if [[ -n "${BACKUP_URL}" ]]; then
        log_ok "Using backup URL provided via -b flag."
        return
    fi

    # 2) Ask the user interactively. Requires an interactive terminal.
    if [[ -t 0 ]]; then
        while [[ -z "${BACKUP_URL}" ]]; do
            read -r -p "$(echo -e "${COLOR_BLUE}[INPUT]${COLOR_RESET} Enter the backup download URL: ")" BACKUP_URL
            if [[ -z "${BACKUP_URL}" ]]; then
                log_warn "URL cannot be empty. Please try again."
            fi
        done
    else
        log_err "No backup URL provided and no interactive terminal available to prompt for it."
        log_err "Run with: sudo ./restore.sh -b <backup-url>"
        exit 1
    fi
}

# Parse command-line options.
#   -b <url>   backup archive URL
#   -h         show usage
parse_args() {
    while getopts ":b:h" opt; do
        case "${opt}" in
            b)
                BACKUP_URL="${OPTARG}"
                ;;
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

# 3. Download the backup archive.
download_backup() {
    log_info "Downloading backup from ${BACKUP_URL}..."

    if [[ "${DOWNLOADER}" == "curl" ]]; then
        curl -fL --retry 3 -o "${TMP_ARCHIVE}" "${BACKUP_URL}"
    else
        wget --tries=3 -O "${TMP_ARCHIVE}" "${BACKUP_URL}"
    fi

    if [[ ! -s "${TMP_ARCHIVE}" ]]; then
        log_err "Downloaded archive is empty or missing."
        exit 1
    fi

    log_ok "Backup downloaded to ${TMP_ARCHIVE}."
}

# 4. Create target directories.
create_dirs() {
    log_info "Creating target directories..."
    mkdir -p "${APP_DIR}" "${DATA_DIR}"
    log_ok "Directories ${APP_DIR} and ${DATA_DIR} ready."
}

# 5. Extract the archive to /.
extract_backup() {
    log_info "Extracting backup archive to /..."
    tar -xzpf "${TMP_ARCHIVE}" -C /
    log_ok "Archive extracted."
}

# 6-7. Start the Docker Compose stack.
start_stack() {
    if [[ ! -f "${APP_DIR}/docker-compose.yml" ]]; then
        log_err "docker-compose.yml not found in ${APP_DIR} after extraction."
        exit 1
    fi

    log_info "Pulling images and starting stack..."
    cd "${APP_DIR}"
    docker compose pull
    docker compose up -d
    log_ok "Stack started."
}

# 8-9. Wait, then show running containers.
show_status() {
    log_info "Waiting ${STARTUP_WAIT_SECONDS} seconds for services to come up..."
    sleep "${STARTUP_WAIT_SECONDS}"
    echo
    docker ps
    echo
}

# 10. Delete downloaded archive.
cleanup() {
    log_info "Cleaning up downloaded archive..."
    rm -f "${TMP_ARCHIVE}"
    log_ok "Temporary archive removed."
}

# 11. Final success message (green).
print_success() {
    echo -e "${COLOR_GREEN}Restore completed successfully.${COLOR_RESET}"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_root
    detect_distro
    detect_downloader
    install_docker
    resolve_backup_url
    download_backup
    create_dirs
    extract_backup
    start_stack
    show_status
    cleanup
    print_success
}

main "$@"
