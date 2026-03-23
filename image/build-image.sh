#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="/build/output/rootfs"
OUTPUT="/build/output"

echo "--- Building flashable images ---"

# 1. Download UEFI boot.img from TheMojoMan
echo "Downloading UEFI firmware..."
if [ ! -f "${OUTPUT}/boot.img" ]; then
    # Note: This URL may need updating. Check https://github.com/TheMojoMan/xiaomi-nabu
    # for the latest mega.nz link. For now we use a placeholder.
    echo "WARNING: boot.img must be downloaded manually from TheMojoMan's mega.nz folder."
    echo "Place it at: ${OUTPUT}/boot.img"
    echo "URL: https://mega.nz/folder/CVMGEAiB#7oazR3wpkKdAH2eZChtRTg"
    echo "File: boot_6.14.11-nabu-tmm_linux.img"
    # If the file doesn't exist, create a placeholder so the build continues
    if [ ! -f "${OUTPUT}/boot.img" ]; then
        echo "PLACEHOLDER - download boot.img manually" > "${OUTPUT}/boot.img.README"
    fi
fi

# 2. Build ESP image (512MB FAT32)
echo "Building ESP image..."
ESP_IMG="${OUTPUT}/esp.img"
ESP_MNT="/tmp/esp-mount"

dd if=/dev/zero of="${ESP_IMG}" bs=1M count=512
mkfs.fat -F32 -n ESPNABU "${ESP_IMG}"

mkdir -p "${ESP_MNT}"
mount -o loop "${ESP_IMG}" "${ESP_MNT}"

# Install GRUB for arm64-efi
grub-install --target=arm64-efi \
    --efi-directory="${ESP_MNT}" \
    --boot-directory="${ESP_MNT}" \
    --removable --no-nvram

# Generate GRUB config from template
sed "s/KERNEL_VERSION_PLACEHOLDER/${KERNEL_VERSION}/g" \
    "${SCRIPT_DIR}/grub.cfg.template" > "${ESP_MNT}/grub/grub.cfg"

# Copy kernel, initramfs, DTB to ESP
# These were installed to /boot/efi/ in the rootfs (the ESP mount point)
cp "${ROOTFS}/boot/efi/vmlinuz-${KERNEL_VERSION}-cachyos-nabu" "${ESP_MNT}/"
cp "${ROOTFS}/boot/efi/initramfs-${KERNEL_VERSION}-cachyos-nabu.img" "${ESP_MNT}/"
cp "${ROOTFS}/boot/efi/sm8150-xiaomi-nabu.dtb" "${ESP_MNT}/"

umount "${ESP_MNT}"
echo "  ESP image: ${ESP_IMG} ($(du -h "${ESP_IMG}" | cut -f1))"

# 3. Build Btrfs rootfs image
echo "Building rootfs image..."
LINUX_IMG="${OUTPUT}/linux.img"
LINUX_MNT="/tmp/linux-mount"

# Create a sparse file (~8GB should be enough for the rootfs content)
truncate -s 8G "${LINUX_IMG}"
mkfs.btrfs -f -L linux "${LINUX_IMG}"

mkdir -p "${LINUX_MNT}"
mount -o loop,compress=zstd:3 "${LINUX_IMG}" "${LINUX_MNT}"

# Create subvolumes
btrfs subvolume create "${LINUX_MNT}/@"
btrfs subvolume create "${LINUX_MNT}/@home"
btrfs subvolume create "${LINUX_MNT}/@snapshots"

# Copy rootfs into @ subvolume
echo "  Copying rootfs (this takes a minute)..."
cp -a "${ROOTFS}/"* "${LINUX_MNT}/@/" 2>/dev/null || true

# Move /home to @home
if [ -d "${LINUX_MNT}/@/home/nabu" ]; then
    mv "${LINUX_MNT}/@/home/"* "${LINUX_MNT}/@home/" 2>/dev/null || true
fi
mkdir -p "${LINUX_MNT}/@/home"
mkdir -p "${LINUX_MNT}/@/.snapshots"

umount "${LINUX_MNT}"

# Compress with zstd
echo "  Compressing rootfs image..."
zstd -T0 -9 "${LINUX_IMG}" -o "${OUTPUT}/linux.img.zst"
rm "${LINUX_IMG}"

echo "  Rootfs image: ${OUTPUT}/linux.img.zst ($(du -h "${OUTPUT}/linux.img.zst" | cut -f1))"

echo ""
echo "--- Image build complete ---"
echo "Artifacts:"
ls -lh "${OUTPUT}/"*.img "${OUTPUT}/"*.zst "${OUTPUT}/"*.README 2>/dev/null || true
