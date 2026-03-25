#!/usr/bin/env bash
set -euo pipefail

# Build Qualcomm userspace daemons from source (BSD-3-Clause licensed)
# These are required for WiFi on Snapdragon devices running mainline Linux.
#
# Source repos (all from https://github.com/linux-msm):
#   qrtr v1.2  — libqrtr library (shared, for rmtfs + tqftpserv)
#   qrtr v0.3  — qrtr-ns only (statically linked, last version to include it)
#   qmic       — QMI compiler (generates C source from .qmi definitions)
#   rmtfs      — Remote filesystem service
#   tqftpserv  — TFTP service for firmware loading

ROOTFS="${1:?Usage: build-qualcomm.sh <rootfs-path>}"
BUILD_DIR="/tmp/qcom-build"

echo "--- Building Qualcomm userspace from source ---"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# 1. Build qrtr v1.2 (libqrtr + tools) via meson
# Install to host (so rmtfs/tqftpserv can compile+link) and to rootfs
echo "  [1/5] Building qrtr v1.2 (libqrtr)..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/qrtr.git
cd qrtr
meson setup builddir --prefix=/usr --buildtype=release
meson compile -C builddir
meson install -C builddir
DESTDIR="${ROOTFS}" meson install -C builddir
ldconfig

# 2. Build qrtr-ns from v0.3 — STATICALLY linked against v0.3's own libqrtr
# qrtr-ns was removed from later versions but the kernel still needs a
# userspace name service daemon (see net/qrtr/Kconfig).
# We build the entire v0.3 tree, then statically link qrtr-ns so it
# doesn't conflict with the v1.2 libqrtr.so in the rootfs.
echo "  [2/5] Building qrtr-ns from v0.3 (static)..."
cd "${BUILD_DIR}"
git clone --depth 1 --branch v0.3 https://github.com/linux-msm/qrtr.git qrtr-old
cd qrtr-old
# Build v0.3's libqrtr as a static archive
make prefix=/usr
ar rcs libqrtr.a lib/*.o
# Relink qrtr-ns statically against v0.3's libqrtr
gcc -o qrtr-ns src/ns.o src/hash.o src/waiter.o src/util.o libqrtr.a -lpthread
install -Dm755 qrtr-ns "${ROOTFS}/usr/bin/qrtr-ns"

# 3. Build qmic (QMI compiler) — needed to generate rmtfs source files
echo "  [3/5] Building qmic..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/qmic.git
cd qmic
make prefix=/usr
make prefix=/usr install

# 4. Build rmtfs — depends on libqrtr v1.2 + libudev + qmic
echo "  [4/5] Building rmtfs..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/rmtfs.git
cd rmtfs
make prefix=/usr
install -Dm755 rmtfs "${ROOTFS}/usr/bin/rmtfs"

# 5. Build tqftpserv — depends on libqrtr v1.2 + libzstd
echo "  [5/5] Building tqftpserv..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/tqftpserv.git
cd tqftpserv
meson setup builddir --prefix=/usr --buildtype=release
meson compile -C builddir
DESTDIR="${ROOTFS}" meson install -C builddir

echo "--- Qualcomm userspace build complete ---"
echo "  Installed: qrtr-ns (static), rmtfs, tqftpserv, libqrtr v1.2"

# Clean up
rm -rf "${BUILD_DIR}"
