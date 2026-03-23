#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Rootfs is built in container-local filesystem (not on bind mount)
ROOTFS="/tmp/rootfs-build"
OUTPUT="/build/output"

echo "--- Building flashable images ---"

# 1. Check UEFI boot.img
if [ ! -f "${OUTPUT}/boot.img" ]; then
    echo "WARNING: boot.img (UEFI firmware) must be downloaded manually."
    echo "Place it at: ${OUTPUT}/boot.img"
    echo "URL: https://mega.nz/folder/CVMGEAiB#7oazR3wpkKdAH2eZChtRTg"
    echo "File: boot_6.14.11-nabu-tmm_linux.img"
fi

# 2. Build ESP image (1GB FAT32 — UEFI firmware expects this size)
echo "Building ESP image (1GB)..."
ESP_IMG="${OUTPUT}/esp.img"
ESP_MNT="/tmp/esp-mount"

dd if=/dev/zero of="${ESP_IMG}" bs=1M count=1024
mkfs.fat -F32 -n ESPNABU "${ESP_IMG}"

mkdir -p "${ESP_MNT}"
mount -o loop "${ESP_IMG}" "${ESP_MNT}"

# Install GRUB for arm64-efi (removable media path for UEFI discovery)
grub-install --target=arm64-efi \
    --efi-directory="${ESP_MNT}" \
    --boot-directory="${ESP_MNT}" \
    --removable --no-nvram

# Generate GRUB config from template
sed "s/KERNEL_VERSION_PLACEHOLDER/${KERNEL_VERSION}/g" \
    "${SCRIPT_DIR}/grub.cfg.template" > "${ESP_MNT}/grub/grub.cfg"

# Copy kernel, initramfs, DTB to ESP root (where GRUB config references them)
cp "${ROOTFS}/boot/efi/vmlinuz-${KERNEL_VERSION}-cachyos-nabu" "${ESP_MNT}/"
cp "${ROOTFS}/boot/efi/sm8150-xiaomi-nabu.dtb" "${ESP_MNT}/"

# Initramfs might not exist if mkinitcpio failed — check and warn
if [ -f "${ROOTFS}/boot/efi/initramfs-${KERNEL_VERSION}-cachyos-nabu.img" ]; then
    cp "${ROOTFS}/boot/efi/initramfs-${KERNEL_VERSION}-cachyos-nabu.img" "${ESP_MNT}/"
else
    echo "WARNING: initramfs not found, generating minimal one..."
    # Generate a minimal initramfs with just base hooks
    arch-chroot "${ROOTFS}" mkinitcpio -k "${KERNEL_VERSION}-sm8150" -g "/boot/efi/initramfs-${KERNEL_VERSION}-cachyos-nabu.img" || true
    [ -f "${ROOTFS}/boot/efi/initramfs-${KERNEL_VERSION}-cachyos-nabu.img" ] && \
        cp "${ROOTFS}/boot/efi/initramfs-${KERNEL_VERSION}-cachyos-nabu.img" "${ESP_MNT}/"
fi

# Show ESP contents for debugging
echo "  ESP contents:"
find "${ESP_MNT}" -type f | head -20
echo "  GRUB config:"
cat "${ESP_MNT}/grub/grub.cfg"

umount "${ESP_MNT}"
echo "  ESP image: ${ESP_IMG} ($(du -h "${ESP_IMG}" | cut -f1))"

# 3. Build ext4 rootfs image
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
zstd -T0 -9 "${LINUX_IMG}" -o "${OUTPUT}/linux.img.zst"
rm "${LINUX_IMG}"

echo "  Rootfs image: ${OUTPUT}/linux.img.zst ($(du -h "${OUTPUT}/linux.img.zst" | cut -f1))"

echo ""
echo "--- Image build complete ---"
echo "Artifacts:"
ls -lh "${OUTPUT}/"*.img "${OUTPUT}/"*.zst 2>/dev/null || true
