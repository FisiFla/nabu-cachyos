#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== CachyOS Nabu Flasher ==="
echo ""
echo "This will install CachyOS ARM on your Xiaomi Pad 5."
echo "Android data will be erased. Slot A (Android) is preserved as fallback."
echo ""

# Check prerequisites
command -v fastboot >/dev/null || { echo "ERROR: fastboot not found. Install: brew install android-platform-tools"; exit 1; }

for f in boot.img linux.img.zst vbmeta_disabled.img; do
    [ -f "${SCRIPT_DIR}/${f}" ] || { echo "ERROR: ${f} not found in ${SCRIPT_DIR}/"; exit 1; }
done

# Check device
echo "Checking device connection..."
fastboot devices | grep -q . || { echo "ERROR: No device found. Boot tablet into fastboot (Vol Down + Power)."; exit 1; }
echo "  Device found."
echo ""

read -p "Ready to flash? This will erase Android userdata. [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

echo ""
echo "[1/5] Erasing dtbo_b + flashing vbmeta..."
fastboot erase dtbo_b
fastboot flash vbmeta_b "${SCRIPT_DIR}/vbmeta_disabled.img"

echo "[2/5] Flashing CachyOS kernel..."
fastboot flash boot_b "${SCRIPT_DIR}/boot.img"

echo "[3/5] Decompressing rootfs..."
if [ ! -f "${SCRIPT_DIR}/linux.img" ]; then
    command -v zstd >/dev/null || { echo "ERROR: zstd not found. Install: brew install zstd"; exit 1; }
    zstd -d "${SCRIPT_DIR}/linux.img.zst" -o "${SCRIPT_DIR}/linux.img"
fi

echo "[4/5] Flashing rootfs (this takes ~4 minutes)..."
fastboot flash linux "${SCRIPT_DIR}/linux.img"

echo "[5/5] Setting boot slot and rebooting..."
fastboot set_active b
fastboot reboot

echo ""
echo "=== Flash complete! ==="
echo ""
echo "CachyOS will boot in ~60 seconds."
echo ""
echo "Default login: nabu / cachyos"
echo "SSH: ssh root@nabu-cachyos.local"
echo ""
echo "If it doesn't boot: hold Vol Down + Power → fastboot set_active a"
