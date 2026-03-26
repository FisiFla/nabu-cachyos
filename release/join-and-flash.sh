#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== CachyOS Nabu Installer ==="
echo ""

command -v fastboot >/dev/null || { echo "ERROR: fastboot not found. Install: brew install android-platform-tools"; exit 1; }
command -v zstd >/dev/null || { echo "ERROR: zstd not found. Install: brew install zstd"; exit 1; }

if [ ! -f "${SCRIPT_DIR}/linux.img.zst" ]; then
    echo "Reassembling rootfs from parts..."
    cat "${SCRIPT_DIR}"/linux.img.zst.part-* > "${SCRIPT_DIR}/linux.img.zst"
    echo "  Done."
fi

exec bash "${SCRIPT_DIR}/flash.sh"
