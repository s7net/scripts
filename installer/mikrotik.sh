#!/usr/bin/env bash
set -Eeuo pipefail

LOGFILE="/tmp/chr-installer-debug.log"
: > "$LOGFILE"

# fd 3 = real terminal (always visible)
exec 3>&1
# stdout/stderr go to log file only by default
exec >>"$LOGFILE" 2>&1

show()  { echo "$@" | tee -a "$LOGFILE" >&3; }   # visible + logged
dbg()   { echo "[DEBUG] $*"; }                    # logged only

on_error() {
    local line=$1
    show ""
    show "[ERROR] Something went wrong (line ${line}). Showing debug log:"
    show "--------------------------------------------------------------"
    cat "$LOGFILE" >&3
    show "--------------------------------------------------------------"
    show "[ERROR] Full log also saved at: $LOGFILE"
}
trap 'on_error $LINENO' ERR

show '
 ███╗   ███╗██╗██╗  ██╗██████╗  ██████╗ ████████╗██╗██╗  ██╗
 ████╗ ████║██║██║ ██╔╝██╔══██╗██╔═══██╗╚══██╔══╝██║██║ ██╔╝
 ██╔████╔██║██║█████╔╝ ██████╔╝██║   ██║   ██║   ██║█████╔╝
 ██║╚██╔╝██║██║██╔═██╗ ██╔══██╗██║   ██║   ██║   ██║██╔═██╗
 ██║ ╚═╝ ██║██║██║  ██╗██║  ██║╚██████╔╝   ██║   ██║██║  ██╗
 ╚═╝     ╚═╝╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═╝╚═╝  ╚═╝
        MikroTik CHR Auto Installer'

if [ "$(id -u)" -ne 0 ]; then
    show "[ERROR] Run as root."
    exit 1
fi

dbg "Started: $(date) | kernel: $(uname -a)"
dbg "df /tmp: $(df -h /tmp | tail -n1)"

install_pkg() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y wget curl unzip
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y wget curl unzip
    elif command -v yum >/dev/null 2>&1; then
        yum install -y wget curl unzip
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache wget curl unzip
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm wget curl unzip
    else
        show "[ERROR] Unsupported package manager."
        exit 1
    fi
}

show "[INFO] Installing dependencies..."
install_pkg

show "[INFO] Detecting latest RouterOS 7 version..."
RAW_LATEST=$(curl -fsSL https://download.mikrotik.com/routeros/LATEST.7 || echo "")
dbg "Raw LATEST.7 response: '${RAW_LATEST}'"
LATEST_VERSION=$(echo "$RAW_LATEST" | tr -d '\r\n' | awk '{print $1}')

if [ -z "$LATEST_VERSION" ]; then
    show "[ERROR] Failed to get latest RouterOS version."
    exit 1
fi
show "[INFO] Latest version: ${LATEST_VERSION}"

IMG_ZIP="chr-${LATEST_VERSION}.img.zip"
IMG_FILE="chr-${LATEST_VERSION}.img"
MIKROTIK_URL="https://download.mikrotik.com/routeros/${LATEST_VERSION}/${IMG_ZIP}"
dbg "Download URL: ${MIKROTIK_URL}"
dbg "HEAD check: $(curl -sI "${MIKROTIK_URL}" | head -n1)"

# ---------------------------------------------------------------------------
# Auto-detect disks
# ---------------------------------------------------------------------------
dbg "lsblk full:"
dbg "$(lsblk)"

show ""
show "Available disks:"
lsblk -d -o NAME,SIZE,MODEL | grep -v "^loop" | tee -a "$LOGFILE" >&3
show ""

# Find the disk that holds the root filesystem (e.g. /dev/sda1 -> sda)
ROOT_SRC=$(findmnt -no SOURCE / )
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)
if [ -z "$ROOT_DISK" ]; then
    # fallback: strip trailing partition number/letters
    ROOT_DISK=$(echo "$ROOT_SRC" | sed -E 's#^/dev/##; s/p?[0-9]+$//')
fi
dbg "Root source: $ROOT_SRC -> root disk: $ROOT_DISK"

# List candidate whole disks (exclude loop/rom)
mapfile -t ALL_DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
dbg "All disks: ${ALL_DISKS[*]}"

if [ "${#ALL_DISKS[@]}" -eq 1 ]; then
    DEFAULT_DISK="${ALL_DISKS[0]}"
elif [ -n "$ROOT_DISK" ]; then
    DEFAULT_DISK="$ROOT_DISK"
else
    DEFAULT_DISK="${ALL_DISKS[0]:-}"
fi

show "[INFO] Auto-detected target disk: ${DEFAULT_DISK} (currently holds: /)"
read -rp "Target disk [default: ${DEFAULT_DISK}] (example: sda, vda, nvme0n1): " DISK_NAME </dev/tty
DISK_NAME="${DISK_NAME:-$DEFAULT_DISK}"

if [[ "$DISK_NAME" =~ [0-9]$ ]] && [[ ! "$DISK_NAME" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
    show "[ERROR] '${DISK_NAME}' looks like a PARTITION, not a whole disk."
    show "[ERROR] Enter the whole disk name, e.g. 'sda' (not 'sda1')."
    exit 1
fi

DISK="/dev/${DISK_NAME}"
if [ ! -b "$DISK" ]; then
    show "[ERROR] Disk not found: $DISK"
    exit 1
fi

dbg "Selected disk info:"
dbg "$(lsblk "$DISK")"
dbg "Disk size bytes: $(blockdev --getsize64 "$DISK")"

show ""
show "[WARNING] ALL DATA ON ${DISK} WILL BE DESTROYED!"
if [[ "$ROOT_SRC" == "/dev/${DISK_NAME}"* ]]; then
    show "[WARNING] Your CURRENT root filesystem is on ${DISK}."
    show "[WARNING] The system will become unresponsive after writing."
    show "[WARNING] You will need to reboot via your hosting provider's"
    show "[WARNING] control panel (not 'reboot'), with boot mode set to HDD."
fi
show ""
read -rp "Type YES to continue: " CONFIRM </dev/tty
if [ "$CONFIRM" != "YES" ]; then
    show "[ABORTED]"
    exit 0
fi

# ---------------------------------------------------------------------------
# Download & write
# ---------------------------------------------------------------------------
mkdir -p /tmp/chr-installer
mount -t tmpfs -o size=1G tmpfs /tmp/chr-installer 2>/dev/null || true
cd /tmp/chr-installer
dbg "workdir: $(pwd) -- $(df -h . | tail -n1)"

show "[INFO] Downloading CHR ${LATEST_VERSION}..."
wget -q "${MIKROTIK_URL}" -O "${IMG_ZIP}"
dbg "Downloaded: $(ls -la "${IMG_ZIP}")"

show "[INFO] Extracting image..."
unzip -o "${IMG_ZIP}" >/dev/null
dbg "Extracted files:"
dbg "$(ls -la)"

if [ ! -f "${IMG_FILE}" ]; then
    show "[ERROR] Image file not found: ${IMG_FILE}"
    unzip -l "${IMG_ZIP}"
    exit 1
fi
dbg "Image file: $(ls -la "${IMG_FILE}")"

show "[INFO] Writing image to ${DISK} ..."
sync
dd if="${IMG_FILE}" of="${DISK}" bs=16M conv=fsync
sync
dbg "First bytes of ${DISK}:"
dbg "$(dd if="${DISK}" bs=512 count=1 2>/dev/null | xxd | head -n3)"
dbg "Partition table:"
dbg "$(fdisk -l "${DISK}" 2>/dev/null || true)"
partprobe "${DISK}" 2>/dev/null || blockdev --rereadpt "${DISK}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Post-install notice
# ---------------------------------------------------------------------------
show ""
show "[SUCCESS] MikroTik CHR ${LATEST_VERSION} image written to ${DISK}."
show ""
cat << "EOF" | tee -a "$LOGFILE" >&3
╔══════════════════════════════════════════════════════════════════╗
║                                                                    ║
║   [SUCCESS] MikroTik CHR installation completed successfully.    ║
║                                                                    ║
║   [INFO] After the server reboots:                                ║
║                                                                    ║
║   1. Connect using your VPS provider's VNC/Serial Console.        ║
║                                                                    ║
║   2. Log in with:                                                 ║
║         Username: admin                                           ║
║         Password: (leave empty)                                   ║
║                                                                    ║
║   3. RouterOS may show the LICENSE text instead of the login      ║
║      prompt. If this happens, press, in order, until you exit:    ║
║         q   ->  Ctrl+C  ->  Space  ->  Enter                       ║
║                                                                    ║
║   4. After logging in, immediately set a new password:            ║
║         /password                                                 ║
║                                                                    ║
║   5. If the login prompt does not appear, wait a few seconds      ║
║      and reconnect to the console.                                ║
║                                                                    ║
╚══════════════════════════════════════════════════════════════════╝
EOF

show ""
show "[INFO] Rebooting in 15 seconds... (Ctrl+C to cancel)"
for i in $(seq 15 -1 1); do
    printf "\r[INFO] Rebooting in %2d seconds... " "$i" >&3
    sleep 1
done
echo >&3

read -rp "Reboot now with 'reboot -f'? (y/N): " DOREBOOT </dev/tty
if [[ "$DOREBOOT" =~ ^[Yy]$ ]]; then
    sync
    reboot -f
else
    show "[INFO] Skipping reboot. Done."
fi
