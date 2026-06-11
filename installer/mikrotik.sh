#!/usr/bin/env bash

set -Eeuo pipefail

clear

cat << "EOF"

 ███╗   ███╗██╗██╗  ██╗██████╗  ██████╗ ████████╗██╗██╗  ██╗
 ████╗ ████║██║██║ ██╔╝██╔══██╗██╔═══██╗╚══██╔══╝██║██║ ██╔╝
 ██╔████╔██║██║█████╔╝ ██████╔╝██║   ██║   ██║   ██║█████╔╝
 ██║╚██╔╝██║██║██╔═██╗ ██╔══██╗██║   ██║   ██║   ██║██╔═██╗
 ██║ ╚═╝ ██║██║██║  ██╗██║  ██║╚██████╔╝   ██║   ██║██║  ██╗
 ╚═╝     ╚═╝╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═╝╚═╝  ╚═╝

        MikroTik CHR Auto Installer

EOF

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Run as root."
    exit 1
fi

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
        echo "[ERROR] Unsupported package manager."
        exit 1
    fi
}

echo "[INFO] Installing dependencies..."
install_pkg

echo "[INFO] Detecting latest RouterOS 7 version..."

LATEST_VERSION=$(curl -fsSL https://download.mikrotik.com/routeros/LATEST.7 | tr -d '\r\n')

if [ -z "$LATEST_VERSION" ]; then
    echo "[ERROR] Failed to get latest RouterOS version."
    exit 1
fi

echo "[INFO] Latest version: ${LATEST_VERSION}"

IMG_ZIP="chr-${LATEST_VERSION}.img.zip"
IMG_FILE="chr-${LATEST_VERSION}.img"
MIKROTIK_URL="https://download.mikrotik.com/routeros/${LATEST_VERSION}/${IMG_ZIP}"

echo
echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL | grep -v "^loop"
echo

read -rp "Target disk (example: sda, vda, nvme0n1): " DISK_NAME

DISK="/dev/${DISK_NAME}"

if [ ! -b "$DISK" ]; then
    echo "[ERROR] Disk not found: $DISK"
    exit 1
fi

echo
echo "[WARNING] ALL DATA ON ${DISK} WILL BE DESTROYED!"
echo

read -rp "Type YES to continue: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "[ABORTED]"
    exit 0
fi

mkdir -p /tmp/chr-installer
mount -t tmpfs -o size=1G tmpfs /tmp/chr-installer || true

cd /tmp/chr-installer

echo "[INFO] Downloading CHR ${LATEST_VERSION}..."
wget -q --show-progress "${MIKROTIK_URL}" -O "${IMG_ZIP}"

echo "[INFO] Extracting image..."
unzip -o "${IMG_ZIP}"

if [ ! -f "${IMG_FILE}" ]; then
    echo "[ERROR] Image file not found."
    exit 1
fi

echo "[INFO] Writing image to ${DISK} ..."
sync

dd if="${IMG_FILE}" of="${DISK}" bs=16M status=progress conv=fsync

sync

echo
echo "[SUCCESS] MikroTik CHR ${LATEST_VERSION} installed."
echo "[INFO] Rebooting in 5 seconds..."

sleep 5
reboot -f
