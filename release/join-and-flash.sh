#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== CachyOS Nabu Installer ==="
echo ""

command -v fastboot >/dev/null || { echo "ERROR: fastboot not found. Install: brew install android-platform-tools"; exit 1; }
command -v zstd >/dev/null || { echo "ERROR: zstd not found. Install: brew install zstd"; exit 1; }

# Verify the split archive against the shipped SHA256SUMS BEFORE
# concatenating: a truncated part would otherwise flash a silently corrupt
# rootfs (and ~15 minutes of tablet time is a slow way to find out).
# SHA256SUMS covers the part files; a bundle without the file, or a host
# without a sha256 tool, only warns.
verify_bundle() {
    if [ "${SKIP_SHA256_CHECK:-0}" = "1" ]; then
        echo "SKIP_SHA256_CHECK=1 set — skipping SHA256SUMS verification."
        return 0
    fi
    if [ ! -f "${SCRIPT_DIR}/SHA256SUMS" ]; then
        echo "WARNING: SHA256SUMS missing — skipping integrity verification. Re-download the release if anything misbehaves."
        return 0
    fi
    local rc=0
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "${SCRIPT_DIR}" && sha256sum --quiet -c SHA256SUMS) || rc=1
    elif command -v shasum >/dev/null 2>&1; then
        (cd "${SCRIPT_DIR}" && shasum -a 256 --quiet -c SHA256SUMS) || rc=1
    else
        echo "WARNING: neither sha256sum nor shasum found — skipping integrity verification."
        return 0
    fi
    if [ "${rc}" != "0" ]; then
        echo "ERROR: SHA256SUMS verification failed — the bundle is incomplete or corrupted."
        echo "Re-download the release. To flash anyway (NOT recommended): SKIP_SHA256_CHECK=1"
        exit 1
    fi
    echo "  SHA256SUMS verified."
}
verify_bundle

NEED_JOIN=0
if [ ! -f "${SCRIPT_DIR}/linux.img.zst" ]; then
    NEED_JOIN=1
else
    for part in "${SCRIPT_DIR}"/linux.img.zst.part-??; do
        [ -e "${part}" ] || break
        if [ "${part}" -nt "${SCRIPT_DIR}/linux.img.zst" ]; then
            echo "linux.img.zst is stale — a part file is newer. Reassembling."
            NEED_JOIN=1
            break
        fi
    done
fi

if [ "${NEED_JOIN}" = "1" ]; then
    echo "Reassembling rootfs from parts..."
    cat "${SCRIPT_DIR}"/linux.img.zst.part-* > "${SCRIPT_DIR}/linux.img.zst"
    echo "  Done."
fi

exec bash "${SCRIPT_DIR}/flash.sh"
