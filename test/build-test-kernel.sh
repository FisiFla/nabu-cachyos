#!/usr/bin/env bash
#
# Build a Linux kernel for QEMU's "virt" machine, so the nabu-cachyos rootfs
# can be booted and tested on a Mac (or an arm64 Linux box) without touching
# the tablet.
#
# This builds from the SAME sm8150-mainline kernel source the tablet kernel
# uses (kernel/build-kernel.sh), but with a different config: `make
# virtconfig`, the kernel's own "virtualization guest" merge (defconfig +
# efi.config + hardening.config + virt.config). That keeps the QEMU virt
# device models built in (virtio-blk/net/mmio, PL011 serial, generic PCI
# host, devtmpfs) and drops SoC-specific drivers -- exactly what a boot and
# rootfs test wants.
#
# This Image is NOT the tablet kernel. The tablet kernel is the sm8150
# defconfig + CachyOS fragments built as Image.gz + DTB and packaged with
# mkbootimg (see kernel/build-kernel.sh); this one is a plain uncompressed
# arm64 Image for `-machine virt`, never flashed anywhere.
#
# Toolchain: nothing is installed on the host. The build runs in a native
# arm64 Docker container:
#
#   Apple Silicon macOS : arm64 container runs natively (plain gcc build)
#   arm64 Linux         : same
#   x86_64 Linux host   : the arm64 container runs under qemu emulation;
#                         same result, but compilation is slow. Prefer
#                         pointing test-qemu.sh at a prebuilt --kernel.
#
# Usage: test/build-test-kernel.sh [--src-dir DIR] [--out-dir DIR] [--force]
#   --src-dir   existing sm8150-mainline checkout to build (default: fresh
#               shallow sm8150/6.17 clone under .cache/qemu-test/linux)
#   --out-dir   where Image lands (default: output/qemu-test)
#   --force     rebuild even if output/qemu-test/Image already exists
#
# Output:
#   output/qemu-test/Image           (uncompressed arm64 Image)
#   output/qemu-test/kernelrelease   (uname -r of the built kernel)
#   output/qemu-test/build-kernel.log
#
# output/ and .cache/ are gitignored; this script reproduces the build, the
# repo never ships binaries.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/output/qemu-test"
CACHE_DIR="${REPO_ROOT}/.cache/qemu-test"

# Keep in sync with kernel/build-kernel.sh, which tracks the same upstream
# tree. sm8150/6.17 carries the Linux version used by the nabu kernel.
LINUX_URL="${LINUX_URL:-https://gitlab.com/sm8150-mainline/linux.git}"
LINUX_BRANCH="${LINUX_BRANCH:-sm8150/6.17}"
SRC_DIR="${KERNEL_SRC_DIR:-${CACHE_DIR}/linux}"
BUILD_IMAGE="${BUILD_TEST_IMAGE:-arm64v8/ubuntu:24.04}"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^# output\/ and/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --src-dir)  SRC_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --out-dir)  OUT_DIR="$2"; shift 2 ;;
        --force)    FORCE=1; shift ;;
        -h|--help)  usage ;;
        *)          die "unknown argument: $1 (use --help)" ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    die "docker is required (macOS: brew install docker colima && colima start)"
fi
if ! docker info >/dev/null 2>&1; then
    die "docker daemon is not running (macOS with Colima: colima start)"
fi

mkdir -p "${SRC_DIR}" "${OUT_DIR}"

if [ ! -f "${SRC_DIR}/Makefile" ]; then
    rm -rf "${SRC_DIR}"
    mkdir -p "$(dirname "${SRC_DIR}")"
    log "Cloning ${LINUX_URL} (${LINUX_BRANCH}, shallow) into ${SRC_DIR} ..."
    git clone --depth 1 --branch "${LINUX_BRANCH}" "${LINUX_URL}" "${SRC_DIR}"
fi

if [ -f "${OUT_DIR}/Image" ] && [ "${FORCE}" -eq 0 ]; then
    log "Already built: ${OUT_DIR}/Image"
    log "Pass --force to rebuild, or start a test with ./test/test-qemu.sh"
    exit 0
fi

# Re-installing the build deps on every run keeps the container disposable:
# no persistent image state for the user to manage, and a fresh container
# is the same machine for `make virtconfig` + `make Image`.
log "Building kernel Image for QEMU virt (several minutes)..."
log "  source: ${SRC_DIR} (${LINUX_BRANCH})"
log "  log   : ${OUT_DIR}/build-kernel.log"
{
    echo "=== build-test-kernel.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo "source: ${SRC_DIR} (${LINUX_BRANCH})"
    echo "image : ${BUILD_IMAGE}"
} > "${OUT_DIR}/build-kernel.log"

if ! docker run --rm \
    --platform linux/arm64 \
    -v "${SRC_DIR}:/work/src" -w /work/src \
    "${BUILD_IMAGE}" /bin/bash -c '
        set -eu
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends \
            gcc make bison flex bc openssl libssl-dev libelf-dev rsync >/dev/null
        make -j"$(nproc)" ARCH=arm64 virtconfig
        make -j"$(nproc)" ARCH=arm64 Image
        make -s ARCH=arm64 kernelrelease > .kernelrelease-out
    ' >> "${OUT_DIR}/build-kernel.log" 2>&1; then
    die "docker kernel build failed, full log: ${OUT_DIR}/build-kernel.log"
fi

mv "${SRC_DIR}/arch/arm64/boot/Image" "${OUT_DIR}/Image"
printf '%s\n' "$(cat "${SRC_DIR}/.kernelrelease-out")" > "${OUT_DIR}/kernelrelease"
rm -f "${SRC_DIR}/.kernelrelease-out"
KERNEL_RELEASE="$(cat "${OUT_DIR}/kernelrelease")"

log ""
log "Kernel built: ${OUT_DIR}/Image (kernelrelease: ${KERNEL_RELEASE})"
log "Next: ./test/test-qemu.sh --smoke"
