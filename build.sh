#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KERNEL_VERSION="${KERNEL_VERSION:-6.14.11}"
export WIFI_SSID="${WIFI_SSID:?Error: set WIFI_SSID environment variable}"
export WIFI_PASSWORD="${WIFI_PASSWORD:?Error: set WIFI_PASSWORD environment variable}"

echo "=== CachyOS Nabu Builder ==="
echo "Kernel version: ${KERNEL_VERSION}"
echo ""

# Step 1: Download ALARM rootfs tarball if not present
ALARM_TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"
if [ ! -f "${SCRIPT_DIR}/${ALARM_TARBALL}" ]; then
    echo "[1/6] Downloading Arch Linux ARM rootfs tarball..."
    wget -O "${SCRIPT_DIR}/${ALARM_TARBALL}" \
        "http://os.archlinuxarm.org/os/${ALARM_TARBALL}"
else
    echo "[1/6] ALARM tarball already present, skipping download."
fi

# Step 2: Build Docker image
echo "[2/6] Building Docker image..."
docker build -t nabu-cachyos-builder "${SCRIPT_DIR}"

# Step 3: Run build inside Docker
echo "[3/6] Starting build inside Docker container..."
docker run --rm --privileged \
    -v "${SCRIPT_DIR}:/build" \
    -e KERNEL_VERSION="${KERNEL_VERSION}" \
    -e WIFI_SSID="${WIFI_SSID}" \
    -e WIFI_PASSWORD="${WIFI_PASSWORD}" \
    nabu-cachyos-builder \
    /bin/bash -c "
        set -euo pipefail
        cd /build
        echo '[3/8] Fetching firmware...'
        bash firmware/fetch-firmware.sh
        echo '[4/8] Building kernel...'
        bash kernel/build-kernel.sh
        echo '[5/8] Building rootfs...'
        bash rootfs/build-rootfs.sh
        echo '[6/8] Building images...'
        bash image/build-image.sh
        echo '[7/8] Building recovery...'
        bash recovery/fetch-recovery.sh
    "

echo "[8/8] Done."

echo ""
echo "=== Build complete! ==="
echo "Artifacts in output/:"
ls -lh "${SCRIPT_DIR}/output/"
echo ""
echo "To flash (when tablet is connected):"
echo "  bash image/flash.sh"
