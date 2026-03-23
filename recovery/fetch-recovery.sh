#!/usr/bin/env bash
set -euo pipefail

OUTPUT="/build/output"
WORK="/tmp/recovery-build"

echo "--- Building recovery image ---"

# IMPORTANT: The flash process depends on `adb shell`, `adb push`, and `adb pull`
# after booting this recovery image. This means the recovery MUST include and
# start `adbd` (the Android Debug Bridge daemon).
#
# Rather than building a custom initramfs from scratch (which requires getting
# adbd, USB gadget config, and init exactly right), we use a proven approach:
# download an existing TWRP or minimal recovery image for nabu that already
# has adb support baked in.

mkdir -p "${OUTPUT}"

# Option A (preferred): Download a known-working TWRP recovery for nabu
# TWRP includes adb, parted, sgdisk, dd, and more out of the box.
TWRP_URL="https://dl.twrp.me/nabu/twrp-3.7.1_12-0-nabu.img"
if [ ! -f "${OUTPUT}/recovery.img" ]; then
    echo "Downloading TWRP recovery for nabu..."
    wget -O "${OUTPUT}/recovery.img" "${TWRP_URL}" 2>/dev/null || {
        echo "WARNING: TWRP download failed. Trying alternative..."
        # Option B: Use the recovery from the nabu-alarm project or TheMojoMan
        # The user can also manually place a recovery.img in output/
        echo "Please manually download a TWRP recovery for nabu and place it at:"
        echo "  ${OUTPUT}/recovery.img"
        echo ""
        echo "Sources:"
        echo "  - https://dl.twrp.me/nabu/"
        echo "  - https://xdaforums.com/t/recovery-unofficial-twrp-for-xiaomi-pad-5.4595499/"
        exit 1
    }
fi

# Verify the recovery image exists and is not empty
if [ ! -s "${OUTPUT}/recovery.img" ]; then
    echo "ERROR: recovery.img is empty or missing."
    exit 1
fi

echo "--- Recovery image ready: ${OUTPUT}/recovery.img ---"
echo "This recovery provides: adb shell, parted, sgdisk, dd, mkfs"
