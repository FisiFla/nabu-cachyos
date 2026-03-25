#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KERNEL_VERSION="${KERNEL_VERSION:-6.14.11}"

echo "=== CachyOS Nabu Builder ==="
echo "Kernel version: ${KERNEL_VERSION}"
echo ""

# ─── Prerequisite checks ───────────────────────────────────────────

# WiFi credentials
if [ -z "${WIFI_SSID:-}" ] || [ -z "${WIFI_PASSWORD:-}" ]; then
    echo "ERROR: WiFi credentials required for headless first boot."
    echo ""
    echo "Usage:"
    echo "  WIFI_SSID=\"YourNetwork\" WIFI_PASSWORD=\"YourPassword\" ./build.sh"
    echo ""
    exit 1
fi
export WIFI_SSID WIFI_PASSWORD

# Docker
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is required but not installed."
    echo "  macOS: brew install colima docker && colima start"
    echo "  Linux: install docker from your distro repos"
    exit 1
fi
if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon is not running."
    echo "  macOS with Colima: colima start"
    echo "  Linux: sudo systemctl start docker"
    exit 1
fi

# Ubuntu nabu image (for Qualcomm WiFi binaries)
UBUNTU_IMG=""
for candidate in \
    "${SCRIPT_DIR}/../nabu/Ubuntu 25.04 (Plucky Puffin)/ubuntu-25.04.img" \
    "${HOME}/Downloads/nabu/Ubuntu 25.04 (Plucky Puffin)/ubuntu-25.04.img" \
    "${SCRIPT_DIR}/ubuntu-25.04.img"; do
    if [ -f "${candidate}" ]; then
        UBUNTU_IMG="${candidate}"
        break
    fi
done
if [ -z "${UBUNTU_IMG}" ]; then
    echo "ERROR: Ubuntu nabu image not found (required for WiFi/Qualcomm binaries)."
    echo ""
    echo "Download from TheMojoMan's mega.nz:"
    echo "  https://mega.nz/folder/CVMGEAiB#7oazR3wpkKdAH2eZChtRTg"
    echo ""
    echo "Place ubuntu-25.04.img in one of:"
    echo "  ../nabu/Ubuntu 25.04 (Plucky Puffin)/ubuntu-25.04.img"
    echo "  ~/Downloads/nabu/Ubuntu 25.04 (Plucky Puffin)/ubuntu-25.04.img"
    echo "  ./ubuntu-25.04.img"
    exit 1
fi
echo "  Ubuntu image: ${UBUNTU_IMG}"

# ─── Step 1: Download ALARM rootfs tarball ──────────────────────────

ALARM_TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"
if [ ! -f "${SCRIPT_DIR}/${ALARM_TARBALL}" ]; then
    echo "[1/7] Downloading Arch Linux ARM rootfs tarball (~1GB)..."
    curl -L -# -o "${SCRIPT_DIR}/${ALARM_TARBALL}" \
        "http://os.archlinuxarm.org/os/${ALARM_TARBALL}"
else
    echo "[1/7] ALARM tarball present, skipping download."
fi

# ─── Step 2: Build Docker image ────────────────────────────────────

echo "[2/7] Building Docker image..."
docker build -t nabu-cachyos-builder "${SCRIPT_DIR}"

# ─── Step 3: Run build inside Docker ───────────────────────────────

# NOTE: Kernel builds inside the container's /tmp (case-sensitive).
# Do NOT mount a macOS host volume for kernel source — macOS is
# case-insensitive which breaks Linux kernel builds.

echo "[3/7] Starting build inside Docker container..."
docker run --rm --privileged \
    -v "${SCRIPT_DIR}:/build" \
    -v "${UBUNTU_IMG}:/mnt/ubuntu-nabu.img:ro" \
    -e KERNEL_VERSION="${KERNEL_VERSION}" \
    -e WIFI_SSID="${WIFI_SSID}" \
    -e WIFI_PASSWORD="${WIFI_PASSWORD}" \
    nabu-cachyos-builder \
    /bin/bash -c "
        set -euo pipefail
        cd /build

        # Stage 1: Firmware
        if [ -d output/firmware/nabu-firmware ]; then
            echo '[3/7] Firmware already fetched, skipping.'
        else
            echo '[3/7] Fetching firmware...'
            bash firmware/fetch-firmware.sh
        fi

        # Stage 2: Kernel
        if [ -f output/kernel/Image.gz ] && [ -f output/kernel/sm8150-xiaomi-nabu.dtb ]; then
            echo '[4/7] Kernel already built, skipping.'
        else
            echo '[4/7] Building kernel (this takes ~20 minutes)...'
            bash kernel/build-kernel.sh
        fi

        # Mount Ubuntu nabu image for Qualcomm binaries
        echo 'Mounting Ubuntu nabu image for Qualcomm binaries...'
        mkdir -p /mnt/ubuntu-nabu
        LOOP_DEV=\$(losetup --find --show --partscan /mnt/ubuntu-nabu.img)
        ROOTFS_PART=\$(lsblk -rno NAME,SIZE \${LOOP_DEV} | tail -n +2 | sort -k2 -h | tail -1 | awk '{print \"/dev/\" \$1}')
        mount -o ro \${ROOTFS_PART} /mnt/ubuntu-nabu || {
            echo 'ERROR: Failed to mount Ubuntu image. WiFi will not work.'
            exit 1
        }

        # Stage 3: Rootfs
        echo '[5/7] Building rootfs...'
        bash rootfs/build-rootfs.sh

        # Cleanup Ubuntu mount
        umount /mnt/ubuntu-nabu 2>/dev/null || true
        losetup -D 2>/dev/null || true

        # Stage 4: Images
        echo '[6/7] Building images...'
        bash image/build-image.sh

        # Stage 5: Recovery (best-effort)
        if [ -f output/recovery.img ]; then
            echo '[7/7] Recovery already present, skipping.'
        else
            echo '[7/7] Fetching recovery (optional)...'
            bash recovery/fetch-recovery.sh || echo 'Recovery download failed (not critical).'
        fi
    "

echo ""
echo "=== Build complete! ==="
echo ""
echo "Artifacts:"
ls -lh "${SCRIPT_DIR}/output/"*.img "${SCRIPT_DIR}/output/"*.zst 2>/dev/null || true
echo ""
echo "Next steps:"
echo "  1. Download boot.img from TheMojoMan's mega.nz and place in output/"
echo "     https://mega.nz/folder/CVMGEAiB#7oazR3wpkKdAH2eZChtRTg"
echo "     File: boot_6.14.11-nabu-tmm_linux.img -> output/boot.img"
echo ""
echo "  2. Download vbmeta_disabled.img from same folder -> output/"
echo ""
echo "  3. Put tablet in fastboot (Vol Down + Power) and run:"
echo "     bash image/flash.sh"
