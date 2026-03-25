#!/usr/bin/env bash
set -euo pipefail

# Build Qualcomm userspace daemons from source (BSD-3-Clause licensed)
# These are required for WiFi on Snapdragon devices running mainline Linux.
#
# Source repos (all from https://github.com/linux-msm):
#   qrtr      — libqrtr library (shared, for rmtfs + tqftpserv)
#   qmic      — QMI compiler (generates C source from .qmi definitions)
#   rmtfs     — Remote filesystem service
#   tqftpserv — TFTP service for firmware loading
#
# NOTE: qrtr-ns is NOT built. Kernel 6.14+ has in-kernel QRTR name service.
# Userspace qrtr-ns fails with "bind control socket: Address already in use".

ROOTFS="${1:?Usage: build-qualcomm.sh <rootfs-path>}"
BUILD_DIR="/tmp/qcom-build"

echo "--- Building Qualcomm userspace from source ---"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# 1. Build qrtr v1.2 (libqrtr + tools) via meson
# Install to host (so rmtfs/tqftpserv can compile+link) and to rootfs
echo "  [1/4] Building qrtr v1.2 (libqrtr)..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/qrtr.git
cd qrtr
meson setup builddir --prefix=/usr --buildtype=release
meson compile -C builddir
meson install -C builddir
DESTDIR="${ROOTFS}" meson install -C builddir
ldconfig

# 2. Build qmic (QMI compiler) — needed to generate rmtfs source files
echo "  [2/4] Building qmic..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/qmic.git
cd qmic
make prefix=/usr
make prefix=/usr install

# 3. Build rmtfs — depends on libqrtr + libudev + qmic
echo "  [3/4] Building rmtfs..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/rmtfs.git
cd rmtfs
make prefix=/usr
install -Dm755 rmtfs "${ROOTFS}/usr/bin/rmtfs"

# 4. Build tqftpserv — depends on libqrtr + libzstd
echo "  [4/4] Building tqftpserv..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/tqftpserv.git
cd tqftpserv
meson setup builddir --prefix=/usr --buildtype=release
meson compile -C builddir
DESTDIR="${ROOTFS}" meson install -C builddir

echo "--- Qualcomm userspace build complete ---"
echo "  Installed: rmtfs, tqftpserv, libqrtr v1.2"
echo "  (qrtr-ns not needed — kernel has in-kernel QRTR name service)"

# Clean up
rm -rf "${BUILD_DIR}"
