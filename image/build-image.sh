#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Rootfs is built in container-local filesystem (not on bind mount)
ROOTFS="/tmp/rootfs-build"
OUTPUT="/build/output"

echo "--- Building flashable images ---"

# 1. Verify boot.img was created by kernel build
if [ ! -f "${OUTPUT}/boot.img" ]; then
    echo "ERROR: boot.img not found. Kernel build should have created it."
    exit 1
fi

# 2. Build ext4 rootfs image for the fastboot-flashed linux partition.
# The release path direct-boots the Android boot.img and does not use the
# legacy GRUB/ESP flow anymore, so we intentionally do not build esp.img here.
echo "Building ext4 rootfs image..."
LINUX_IMG="${OUTPUT}/linux.img"
LINUX_MNT="/tmp/linux-mount"

# Calculate rootfs size and add 20% headroom
ROOTFS_SIZE_MB=$(du -sm "${ROOTFS}" | awk '{print $1}')
IMG_SIZE_MB=$(( ROOTFS_SIZE_MB * 120 / 100 ))
echo "  Rootfs is ${ROOTFS_SIZE_MB}MB, creating ${IMG_SIZE_MB}MB image..."

truncate -s "${IMG_SIZE_MB}M" "${LINUX_IMG}"
mkfs.ext4 -F -L linux "${LINUX_IMG}"

mkdir -p "${LINUX_MNT}"
mount -o loop "${LINUX_IMG}" "${LINUX_MNT}"

# Copy rootfs
echo "  Copying rootfs (this takes a minute)..."
cp -a "${ROOTFS}/"* "${LINUX_MNT}/" 2>/dev/null || true

umount "${LINUX_MNT}"

# Compress with zstd
echo "  Compressing rootfs image..."
zstd -f -T0 -9 "${LINUX_IMG}" -o "${OUTPUT}/linux.img.zst"
rm "${LINUX_IMG}"

echo "  Rootfs image: ${OUTPUT}/linux.img.zst ($(du -h "${OUTPUT}/linux.img.zst" | cut -f1))"

# 3. Generate SHA256 checksums
echo "Generating checksums..."
cd "${OUTPUT}"
sha256sum *.img *.zst 2>/dev/null > SHA256SUMS || true
cat SHA256SUMS

echo ""
echo "--- Image build complete ---"
echo "Artifacts:"
ls -lh "${OUTPUT}/"*.img "${OUTPUT}/"*.zst "${OUTPUT}/SHA256SUMS" 2>/dev/null || true
