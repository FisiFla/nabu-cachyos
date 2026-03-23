#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${SCRIPT_DIR}/../output"

echo "=== CachyOS Nabu Flasher ==="
echo ""
echo "WARNING: This will ERASE all data on the tablet."
echo "Make sure you have a backup of anything important."
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

# Step 0: Verify prerequisites
echo "[0/9] Checking prerequisites..."
command -v fastboot >/dev/null || { echo "ERROR: fastboot not found. Install: brew install android-platform-tools"; exit 1; }
command -v adb >/dev/null || { echo "ERROR: adb not found. Install: brew install android-platform-tools"; exit 1; }

for f in boot.img esp.img linux.img.zst; do
    [ -f "${OUTPUT}/${f}" ] || { echo "ERROR: ${OUTPUT}/${f} not found. Run build.sh first."; exit 1; }
done

# Step 1: Verify fastboot connection
echo "[1/9] Checking device connection..."
fastboot devices | grep -q . || { echo "ERROR: No device found. Boot tablet into fastboot (Vol Down + Power)."; exit 1; }
echo "  Device found."

# Step 2: Flash UEFI firmware
echo "[2/9] Flashing UEFI firmware to boot_b..."
fastboot flash boot_b "${OUTPUT}/boot.img"

# Step 3: Boot recovery
echo "[3/9] Booting into recovery..."
if [ -f "${OUTPUT}/recovery.img" ]; then
    echo "  Booting recovery.img via fastboot..."
    fastboot boot "${OUTPUT}/recovery.img"
else
    echo "  No recovery.img found, booting into existing on-device recovery..."
    fastboot reboot recovery
fi
echo "  Waiting for device..."
adb wait-for-device
sleep 5

# Step 4: Backup partition table
echo "[4/9] Backing up partition table..."
adb shell sgdisk --backup=/tmp/gpt-backup.bin /dev/block/sda
adb pull /tmp/gpt-backup.bin "${OUTPUT}/gpt-backup.bin"
echo "  Backup saved to ${OUTPUT}/gpt-backup.bin"

# Step 5: Repartition
echo "[5/9] Repartitioning..."
adb shell sgdisk --resize-table 64 /dev/block/sda
# Delete userdata (partition 31)
adb shell sgdisk --delete=31 /dev/block/sda
# Create ESP (512MB, EFI System Partition type)
adb shell sgdisk --new=31:0:+512M --typecode=31:EF00 --change-name=31:esp /dev/block/sda
# Create linux (remaining space, Linux filesystem type)
adb shell sgdisk --new=32:0:0 --typecode=32:8300 --change-name=32:linux /dev/block/sda
# Verify
echo "  New partition table:"
adb shell sgdisk --print /dev/block/sda

# Step 6: Format ESP
echo "[6/9] Formatting ESP..."
adb shell mkfs.fat -F32 -n ESPNABU /dev/block/sda31

# Step 7: Flash ESP
echo "[7/9] Flashing ESP image..."
adb push "${OUTPUT}/esp.img" /tmp/esp.img
adb shell dd if=/tmp/esp.img of=/dev/block/sda31 bs=4M
adb shell rm /tmp/esp.img

# Step 8: Flash rootfs
echo "[8/9] Flashing rootfs (this may take several minutes)..."
adb push "${OUTPUT}/linux.img.zst" /tmp/linux.img.zst
adb shell "zstdcat /tmp/linux.img.zst | dd of=/dev/block/sda32 bs=4M"
adb shell rm /tmp/linux.img.zst

# Step 9: Set boot slot and reboot
echo "[9/9] Setting boot slot and rebooting..."
adb reboot bootloader
sleep 5
fastboot set_active b
fastboot reboot

echo ""
echo "=== Flash complete! ==="
echo ""
echo "The tablet should boot into CachyOS in ~60 seconds."
echo "Once booted, connect via SSH:"
echo "  ssh nabu@<tablet-ip>"
echo ""
echo "Default credentials:"
echo "  User: nabu"
echo "  Password: cachyos (will be forced to change on first login)"
echo ""
echo "If the tablet doesn't boot:"
echo "  1. Hold Vol Down + Power to enter fastboot"
echo "  2. Run: fastboot set_active a  (switches back to Android slot)"
echo "  3. Or reflash with Xiaomi stock ROM"
