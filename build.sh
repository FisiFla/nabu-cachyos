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
    echo "[1/7] Downloading Arch Linux ARM rootfs tarball..."
    curl -L -o "${SCRIPT_DIR}/${ALARM_TARBALL}" \
        "http://os.archlinuxarm.org/os/${ALARM_TARBALL}"
else
    echo "[1/7] ALARM tarball already present, skipping download."
fi

# Step 2: Build Docker image
echo "[2/7] Building Docker image..."
docker build -t nabu-cachyos-builder "${SCRIPT_DIR}"

# NOTE: Kernel build happens inside the container's /tmp (case-sensitive filesystem).
# Do NOT mount a macOS volume for kernel cache — macOS is case-insensitive which
# breaks the Linux kernel build (xt_TCPMSS.c vs xt_tcpmss.c conflict).

# Step 3: Run build inside Docker
# Mount a persistent cache volume for the kernel so git clone + compile
# don't repeat on every retry. Each stage checks if its output exists.
# Ubuntu nabu image (source for Qualcomm userspace binaries: rmtfs, tqftpserv, qrtr-ns)
UBUNTU_IMG="${SCRIPT_DIR}/../nabu/Ubuntu 25.04 (Plucky Puffin)/ubuntu-25.04.img"
UBUNTU_MOUNT_ARGS=()
# Search common locations for the Ubuntu nabu image
for UBUNTU_CANDIDATE in \
    "${SCRIPT_DIR}/../nabu/Ubuntu 25.04 (Plucky Puffin)/ubuntu-25.04.img" \
    "${HOME}/Downloads/nabu/Ubuntu 25.04 (Plucky Puffin)/ubuntu-25.04.img" \
    "${SCRIPT_DIR}/ubuntu-25.04.img"; do
    if [ -f "${UBUNTU_CANDIDATE}" ]; then
        UBUNTU_IMG="${UBUNTU_CANDIDATE}"
        break
    fi
done

if [ -n "${UBUNTU_IMG:-}" ] && [ -f "${UBUNTU_IMG}" ]; then
    echo "  Found Ubuntu nabu image at: ${UBUNTU_IMG}"
    UBUNTU_MOUNT_ARGS=(-v "${UBUNTU_IMG}:/mnt/ubuntu-nabu.img:ro")
else
    echo "  WARNING: Ubuntu nabu image not found."
    echo "  Qualcomm userspace binaries (rmtfs, tqftpserv, qrtr-ns) will NOT be available."
    echo "  Place ubuntu-25.04.img in ../nabu/Ubuntu 25.04 (Plucky Puffin)/ or ~/Downloads/nabu/"
fi

echo "[3/7] Starting build inside Docker container..."
docker run --rm --privileged \
    -v "${SCRIPT_DIR}:/build" \
    ${UBUNTU_MOUNT_ARGS[@]+"${UBUNTU_MOUNT_ARGS[@]}"} \
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
            echo '[4/7] Building kernel...'
            bash kernel/build-kernel.sh
        fi

        # Mount Ubuntu nabu image if available (for Qualcomm binaries)
        if [ -f /mnt/ubuntu-nabu.img ]; then
            echo 'Mounting Ubuntu nabu image for Qualcomm binaries...'
            mkdir -p /mnt/ubuntu-nabu
            LOOP_DEV=\$(losetup --find --show --partscan /mnt/ubuntu-nabu.img)
            # Find the largest partition (the rootfs)
            ROOTFS_PART=\$(lsblk -rno NAME,SIZE \${LOOP_DEV} | tail -n +2 | sort -k2 -h | tail -1 | awk '{print \"/dev/\" \$1}')
            mount -o ro \${ROOTFS_PART} /mnt/ubuntu-nabu || echo 'WARNING: Failed to mount Ubuntu image rootfs partition'
        fi

        # Stage 3: Rootfs
        echo '[5/7] Building rootfs...'
        bash rootfs/build-rootfs.sh

        # Cleanup Ubuntu mount
        umount /mnt/ubuntu-nabu 2>/dev/null || true
        losetup -D 2>/dev/null || true

        # Stage 4: Images
        echo '[6/7] Building images...'
        bash image/build-image.sh

        # Stage 5: Recovery
        if [ -f output/recovery.img ]; then
            echo '[7/7] Recovery already fetched, skipping.'
        else
            echo '[7/7] Fetching recovery...'
            bash recovery/fetch-recovery.sh
        fi
    "

echo ""
echo "=== Build complete! ==="
echo "Artifacts in output/:"
ls -lh "${SCRIPT_DIR}/output/"
echo ""
echo "To flash (when tablet is connected):"
echo "  bash image/flash.sh"
