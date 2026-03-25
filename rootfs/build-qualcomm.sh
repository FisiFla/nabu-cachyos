#!/usr/bin/env bash
set -euo pipefail

# Build Qualcomm userspace daemons from source (BSD-3-Clause licensed)
# These are required for WiFi on Snapdragon devices running mainline Linux.
#
# Source repos (all from https://github.com/linux-msm):
#   qrtr     — QRTR name service + libqrtr library
#   rmtfs    — Remote filesystem service
#   tqftpserv — TFTP service for firmware loading

ROOTFS="${1:?Usage: build-qualcomm.sh <rootfs-path>}"
BUILD_DIR="/tmp/qcom-build"

echo "--- Building Qualcomm userspace from source ---"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# 1. Build qrtr (libqrtr + qrtr-ns) — no external deps
echo "  [1/3] Building qrtr..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/qrtr.git
cd qrtr
meson setup builddir --prefix=/usr --buildtype=release
meson compile -C builddir
DESTDIR="${ROOTFS}" meson install -C builddir

# 2. Build rmtfs — depends on libqrtr + libudev
echo "  [2/3] Building rmtfs..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/rmtfs.git
cd rmtfs
# rmtfs uses plain make; needs pkg-config to find qrtr from the rootfs
export PKG_CONFIG_PATH="${ROOTFS}/usr/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
make prefix=/usr
make prefix=/usr DESTDIR="${ROOTFS}" install

# 3. Build tqftpserv — depends on libqrtr + libzstd
echo "  [3/3] Building tqftpserv..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/tqftpserv.git
cd tqftpserv
meson setup builddir --prefix=/usr --buildtype=release \
    --pkg-config-path="${ROOTFS}/usr/lib/pkgconfig"
meson compile -C builddir
DESTDIR="${ROOTFS}" meson install -C builddir

echo "--- Qualcomm userspace build complete ---"
echo "  Installed: qrtr-ns, rmtfs, tqftpserv, libqrtr"

# Clean up
rm -rf "${BUILD_DIR}"
