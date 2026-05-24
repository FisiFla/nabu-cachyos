#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KERNEL_VERSION="${KERNEL_VERSION:-6.17-wifi-fix}"

echo "=== CachyOS Nabu Builder ==="
echo "Kernel version: ${KERNEL_VERSION}"
echo ""

# ─── Prerequisite checks ───────────────────────────────────────────

# WiFi credentials (optional — if not set, user connects via GNOME Settings)
if [ -n "${WIFI_SSID:-}" ] && [ -n "${WIFI_PASSWORD:-}" ]; then
    echo "  WiFi: ${WIFI_SSID} (will be pre-configured)"
    export WIFI_SSID WIFI_PASSWORD
else
    echo "  WiFi: not pre-configured (connect via GNOME Settings after boot)"
    export WIFI_SSID="" WIFI_PASSWORD=""
fi

# Docker
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is required but not installed."
    echo "  macOS: brew install colima docker && colima start"
    echo "  Linux: install docker from your distro repos"
    exit 1
fi
if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon is not running."
    echo "  macOS with Colima: colima start"
    echo "  Linux: sudo systemctl start docker"
    exit 1
fi

echo "  Qualcomm WiFi daemons: built from source during rootfs stage"

# ─── Optional: cross-compile kernel on the host (fast path) ────────
#
# Qemu user-mode arm64 emulation inside Docker makes the kernel compile
# ~5-10x slower than a native cross-build. On Linux x86_64 with the
# aarch64 toolchain installed, we build the kernel on the host BEFORE
# launching Docker. The in-container kernel-build path then no-ops
# because output/kernel/Image.gz already exists.
#
# Set USE_HOST_KERNEL_BUILD=0 to force the legacy in-Docker build.
# On macOS Apple Silicon this stays no-op (host is already arm64 so
# Docker runs natively — no qemu overhead to dodge).

USE_HOST_KERNEL_BUILD="${USE_HOST_KERNEL_BUILD:-auto}"

host_arch="$(uname -m)"
host_os="$(uname -s)"
if [ "${USE_HOST_KERNEL_BUILD}" = "auto" ]; then
    if [ "${host_os}" = "Linux" ] && [ "${host_arch}" = "x86_64" ] \
       && command -v aarch64-linux-gnu-gcc &>/dev/null \
       && command -v mkbootimg &>/dev/null; then
        USE_HOST_KERNEL_BUILD=1
    else
        USE_HOST_KERNEL_BUILD=0
    fi
fi

# ─── Step 1: Download ALARM rootfs tarball ──────────────────────────

ALARM_TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"
if [ ! -f "${SCRIPT_DIR}/${ALARM_TARBALL}" ]; then
    echo "[1/6] Downloading Arch Linux ARM rootfs tarball (~1GB)..."
    curl -L -# -o "${SCRIPT_DIR}/${ALARM_TARBALL}" \
        "http://os.archlinuxarm.org/os/${ALARM_TARBALL}"
else
    echo "[1/6] ALARM tarball present, skipping download."
fi

# ─── Step 2: Build Docker image ────────────────────────────────────

echo "[2/6] Building Docker image..."
docker build -t nabu-cachyos-builder "${SCRIPT_DIR}"

# ─── Step 2.5: Host-native kernel cross-compile (optional fast path) ─
#
# Runs OUTSIDE Docker on x86_64 Linux hosts. Produces Image.gz / dtb /
# modules / boot.img directly into output/, which the in-container
# kernel stage then detects and skips.

if [ "${USE_HOST_KERNEL_BUILD}" = "1" ]; then
    echo "[2.5/6] Cross-compiling kernel on host (aarch64-linux-gnu-, ccache)..."
    # Persistent kernel build tree per kernel version → enables incremental
    # rebuilds when only patches change.
    HOST_KBUILD_DIR="${SCRIPT_DIR}/.cache/kernel-build-${KERNEL_VERSION}"
    mkdir -p "${HOST_KBUILD_DIR}" "${SCRIPT_DIR}/output/kernel"
    export CCACHE_DIR="${CCACHE_DIR:-${SCRIPT_DIR}/.cache/ccache}"
    mkdir -p "${CCACHE_DIR}"
    BUILD_DIR="${HOST_KBUILD_DIR}" \
    OUTPUT_DIR="${SCRIPT_DIR}/output/kernel" \
    BOOT_IMG_OUT="${SCRIPT_DIR}/output/boot.img" \
    ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CC="ccache aarch64-linux-gnu-gcc" \
        bash "${SCRIPT_DIR}/kernel/build-kernel.sh"
    echo "[2.5/6] Host kernel build done — container will skip stage 4."
else
    echo "[2.5/6] Skipping host kernel build (USE_HOST_KERNEL_BUILD=${USE_HOST_KERNEL_BUILD})."
fi

# ─── Step 3: Run build inside Docker ───────────────────────────────

# NOTE: Kernel builds inside the container's /tmp (case-sensitive).
# Do NOT mount a macOS host volume for kernel source — macOS is
# case-insensitive which breaks Linux kernel builds.

echo "[3/6] Starting build inside Docker container..."
docker run --rm --privileged \
    -v "${SCRIPT_DIR}:/build" \
    -e KERNEL_VERSION="${KERNEL_VERSION}" \
    -e WIFI_SSID="${WIFI_SSID}" \
    -e WIFI_PASSWORD="${WIFI_PASSWORD}" \
    nabu-cachyos-builder \
    /bin/bash -c "
        set -euo pipefail
        cd /build

        # Stage 1: Firmware
        # Always invoke fetch-firmware.sh — the script itself does per-target
        # skip-if-cached. The previous outer "if -d nabu-firmware" short-circuit
        # silently skipped newly-added fetch steps (e.g. SLPI bundle for NAS-218)
        # whenever the original nabu-firmware/ dir was already cached.
        echo '[3/6] Fetching firmware (idempotent — per-blob skip inside)...'
        bash firmware/fetch-firmware.sh

        # Stage 2: Kernel
        if [ -f output/kernel/Image.gz ] && [ -f output/kernel/sm8150-xiaomi-nabu.dtb ]; then
            echo '[4/6] Kernel already built, skipping.'
        else
            echo '[4/6] Building kernel (this takes ~20 minutes)...'
            bash kernel/build-kernel.sh
        fi

        # Stage 3: Rootfs (Qualcomm binaries are bundled in repo)
        echo '[5/6] Building rootfs...'
        bash rootfs/build-rootfs.sh

        # Stage 4: Images
        echo '[6/6] Building images...'
        bash image/build-image.sh
    "

echo ""
echo "=== Build complete! ==="
echo ""
echo "Artifacts:"
ls -lh "${SCRIPT_DIR}/output/"*.img "${SCRIPT_DIR}/output/"*.zst 2>/dev/null || true
echo ""
echo "Next steps:"
echo "  1. Package a release bundle (point VBMETA_SOURCE at your vbmeta_disabled.img):"
echo "     VBMETA_SOURCE=/path/to/vbmeta_disabled.img bash release/create-release.sh"
echo ""
echo "  2. Put tablet in fastboot (Vol Down + Power) and run:"
echo "     bash release/dist/join-and-flash.sh"
