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

# 5. Build qbootctl — qcom A/B slot HAL port for Linux.
# Pairs with /etc/systemd/system/qbootctl-mark-success.service (in overlay)
# which runs `qbootctl -m` after multi-user.target to mark the active slot
# as successfully booted. Without it, every reboot drains slot-retry-count
# until the bootloader rolls slot B back to Android. See NAS-229.
echo "  [5/6] Building qbootctl..."
cd "${BUILD_DIR}"
git clone --depth 1 https://github.com/linux-msm/qbootctl.git
cd qbootctl
meson setup builddir --prefix=/usr --buildtype=release
meson compile -C builddir
DESTDIR="${ROOTFS}" meson install -C builddir

# 6. Build hexagonrpc — FastRPC bridge between the AP and Qualcomm DSPs.
# NAS-218: the SLPI co-processor uses FastRPC's reverse tunnel to read
# sensor registry files (sns.reg, *.json configs) from the AP. Without
# hexagonrpcd serving those files, the Sensor Manager firmware can't
# initialize the per-sensor configs and Sensor Manager service never
# appears on QRTR — leaving iio-sensor-proxy with nothing to subscribe to.
#
# Ships three templated systemd units (only the adsp ones are useful on
# sm8150 nabu — there is no separate SDSP):
#   hexagonrpcd-adsp-rootpd.service     — root process domain
#   hexagonrpcd-adsp-sensorspd.service  — sensors process domain (SLPI)
#   hexagonrpcd-sdsp.service            — gated off (no /dev/fastrpc-sdsp)
# build-rootfs.sh enables the first two.
HEXAGONRPC_COMMIT="dd9ac70c026e1bad93e8cffa3801255b8ceb551e"
echo "  [6/6] Building hexagonrpc (sensors FastRPC bridge)..."
cd "${BUILD_DIR}"
git clone https://github.com/linux-msm/hexagonrpc.git
git -C hexagonrpc checkout "${HEXAGONRPC_COMMIT}"
cd hexagonrpc
meson setup builddir --prefix=/usr --buildtype=release
meson compile -C builddir
DESTDIR="${ROOTFS}" meson install -C builddir

echo "--- Qualcomm userspace build complete ---"
echo "  Installed: rmtfs, tqftpserv, libqrtr v1.2, qbootctl, hexagonrpcd"
echo "  (qrtr-ns not needed — kernel has in-kernel QRTR name service)"

# Clean up
rm -rf "${BUILD_DIR}"
