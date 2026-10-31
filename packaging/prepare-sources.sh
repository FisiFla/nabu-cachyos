#!/usr/bin/env bash
# prepare-sources.sh — copy the canonical files next to the PKGBUILDs that
# declare them as local sources, so makepkg builds the same bytes the image
# build uses. The copies are git-ignored; the originals are:
#   kernel/patches/*.patch, kernel/cachyos.config, kernel/enable-slpi.sh
#   rootfs/overlay/usr/local/bin/nabu-kernel-flash
#   rootfs/overlay/etc/nabu/boot.cmdline
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

cp "${ROOT_DIR}"/kernel/patches/*.patch "${SCRIPT_DIR}/linux-nabu-cachyos/"
cp "${ROOT_DIR}/kernel/cachyos.config" "${SCRIPT_DIR}/linux-nabu-cachyos/"
cp "${ROOT_DIR}/kernel/enable-slpi.sh" "${SCRIPT_DIR}/linux-nabu-cachyos/"
cp "${ROOT_DIR}/rootfs/overlay/usr/local/bin/nabu-kernel-flash" "${SCRIPT_DIR}/nabu-boot-tools/"
cp "${ROOT_DIR}/rootfs/overlay/etc/nabu/boot.cmdline" "${SCRIPT_DIR}/nabu-boot-tools/"
echo "Local sources copied into packaging/{linux-nabu-cachyos,nabu-boot-tools}."
