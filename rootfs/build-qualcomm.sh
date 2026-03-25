#!/usr/bin/env bash
set -euo pipefail

# Build Qualcomm userspace daemons from source (BSD-3-Clause licensed)
# These are required for WiFi on Snapdragon devices running mainline Linux.
#
# Source repos (all from https://github.com/linux-msm):
#   qrtr      — libqrtr library + qrtr-cfg/lookup tools
#   qrtr v0.3 — qrtr-ns (name service, removed from later versions)
#   qmic      — QMI compiler (generates C source from .qmi definitions)
#   rmtfs     — Remote filesystem service
#   tqftpserv — TFTP service for firmware loading

ROOTFS="${1:?Usage: build-qualcomm.sh <rootfs-path>}"
BUILD_DIR="/tmp/qcom-build"

echo "--- Building Qualcomm userspace from source ---"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# 1. Build qrtr latest (libqrtr + tools) via meson
# Install to host so rmtfs/tqftpserv can link, and to rootfs for runtime
echo "  [1/5] Building qrtr (libqrtr)..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/qrtr.git
cd qrtr
meson setup builddir --prefix=/usr --buildtype=release
meson compile -C builddir
meson install -C builddir
DESTDIR="${ROOTFS}" meson install -C builddir
ldconfig

# 2. Build qrtr-ns from v0.3 (last version that includes it)
# qrtr-ns was removed from later qrtr versions but the kernel still
# requires a userspace name service daemon (see net/qrtr/Kconfig)
echo "  [2/5] Building qrtr-ns from v0.3..."
cd "${BUILD_DIR}"
git clone --depth 1 --branch v0.3 https://github.com/linux-msm/qrtr.git qrtr-old
cd qrtr-old
# Build only qrtr-ns, linking against the v1.2 libqrtr we just installed.
# The ns binary only uses the stable socket API, not the QMI structs.
make prefix=/usr qrtr-ns
install -Dm755 qrtr-ns "${ROOTFS}/usr/bin/qrtr-ns"

# 3. Build qmic (QMI compiler) — needed to generate rmtfs/tqftpserv sources
echo "  [3/5] Building qmic..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/qmic.git
cd qmic
make prefix=/usr
make prefix=/usr install

# 4. Build rmtfs — depends on libqrtr + libudev + qmic
echo "  [4/5] Building rmtfs..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/rmtfs.git
cd rmtfs
make prefix=/usr
install -Dm755 rmtfs "${ROOTFS}/usr/bin/rmtfs"

# 5. Build tqftpserv — depends on libqrtr + libzstd
echo "  [5/5] Building tqftpserv..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/tqftpserv.git
cd tqftpserv
meson setup builddir --prefix=/usr --buildtype=release
meson compile -C builddir
DESTDIR="${ROOTFS}" meson install -C builddir

echo "--- Qualcomm userspace build complete ---"
echo "  Installed: qrtr-ns, rmtfs, tqftpserv, libqrtr"

# Clean up
rm -rf "${BUILD_DIR}"
