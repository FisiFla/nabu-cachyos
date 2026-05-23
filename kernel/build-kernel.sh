#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where the kernel tree gets cloned/built. Default keeps the historical
# in-container path; build.sh overrides this to a persistent host path
# when cross-compiling natively for incremental builds.
BUILD_DIR="${BUILD_DIR:-/tmp/kernel-build}"

# Where Image.gz, dtb, modules/ land. Default matches the docker bind mount.
OUTPUT_DIR="${OUTPUT_DIR:-/build/output/kernel}"

# Where the final Android boot.img lands.
BOOT_IMG_OUT="${BOOT_IMG_OUT:-/build/output/boot.img}"

BOOT_CMDLINE="${BOOT_CMDLINE:-root=PARTLABEL=linux rw}"
ENABLE_EXPERIMENTAL_SENSORS="${ENABLE_EXPERIMENTAL_SENSORS:-0}"

# Cross-compile knobs (default empty → native compile, matching the
# previous in-container arm64 path). build.sh sets these when running
# on an x86_64 host.
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
# Allow overriding CC entirely (e.g. "ccache aarch64-linux-gnu-gcc").
CC="${CC:-}"

# Compose make args once.
MAKE_ARGS=("ARCH=${ARCH}")
[ -n "${CROSS_COMPILE}" ] && MAKE_ARGS+=("CROSS_COMPILE=${CROSS_COMPILE}")
[ -n "${CC}" ] && MAKE_ARGS+=("CC=${CC}")

mkdir -p "${OUTPUT_DIR}"
mkdir -p "$(dirname "${BOOT_IMG_OUT}")"

echo "--- Kernel Build: sm8150/${KERNEL_VERSION} ---"
echo "  ARCH=${ARCH}  CROSS_COMPILE=${CROSS_COMPILE:-<native>}  CC=${CC:-<default>}"
echo "  BUILD_DIR=${BUILD_DIR}"
echo "  OUTPUT_DIR=${OUTPUT_DIR}"

# Clone kernel source (persistent BUILD_DIR enables incremental rebuilds
# across runs — only changed patches force a re-extract).
if [ ! -d "${BUILD_DIR}/linux/.git" ]; then
    echo "Cloning kernel source..."
    rm -rf "${BUILD_DIR}/linux"
    git clone --depth 1 --branch "sm8150/${KERNEL_VERSION}" \
        https://gitlab.com/sm8150-mainline/linux.git "${BUILD_DIR}/linux"
else
    echo "Reusing existing kernel tree at ${BUILD_DIR}/linux"
fi

cd "${BUILD_DIR}/linux"

# Apply CachyOS patches. We track whether the tree is already patched via
# a sentinel file so re-runs don't double-apply.
PATCH_SENTINEL=".cachyos-patches-applied"
if [ ! -f "${PATCH_SENTINEL}" ]; then
    # BORE (0001) is critical. Others are best-effort — the kernel works without them.
    CRITICAL_PATCHES=("0001-bore")
    echo "Applying patches..."
    for patch in "${SCRIPT_DIR}/patches/"*.patch; do
        patchname="$(basename "${patch}")"
        echo "  Applying ${patchname}..."
        is_critical=false
        for cp in "${CRITICAL_PATCHES[@]}"; do
            [[ "${patchname}" == "${cp}"* ]] && is_critical=true
        done
        if git apply --check "${patch}" 2>/dev/null; then
            git apply "${patch}"
            echo "    OK"
        elif git apply --3way "${patch}" 2>/dev/null; then
            echo "    OK (3-way merge)"
        elif ${is_critical}; then
            echo "    FATAL: critical patch ${patchname} failed to apply. Aborting."
            exit 1
        else
            echo "    WARNING: ${patchname} did not apply cleanly, skipping."
            echo "    The kernel will work without it."
        fi
    done
    touch "${PATCH_SENTINEL}"
else
    echo "Patches already applied (sentinel: ${PATCH_SENTINEL})"
fi

# Apply optional device tree modifications.
# nabu's TrustZone firmware reserves GPIO 126-127; changing that range
# is known to cause boot failure, so keep the sensor DTS hack opt-in.
if [ "${ENABLE_EXPERIMENTAL_SENSORS}" = "1" ] && [ -x "${SCRIPT_DIR}/add-sensors.sh" ]; then
    echo "Adding experimental sensor support to device tree..."
    bash "${SCRIPT_DIR}/add-sensors.sh"
else
    echo "Skipping experimental sensor DTS modifications."
fi

# Build config: defconfig + sm8150 fragment + cachyos fragment
# Note: sm8150.config is a fragment at arch/arm64/configs/sm8150.config, NOT a defconfig target.
# We must use merge_config.sh to layer it on top of defconfig.
echo "Configuring kernel..."
make "${MAKE_ARGS[@]}" defconfig
scripts/kconfig/merge_config.sh -m .config \
    arch/arm64/configs/sm8150.config \
    "${SCRIPT_DIR}/cachyos.config"
make "${MAKE_ARGS[@]}" olddefconfig

# Compile
echo "Compiling kernel (this takes ~15 minutes native, longer under qemu)..."
make -j"$(nproc)" "${MAKE_ARGS[@]}" Image.gz dtbs modules

# Collect artifacts
echo "Collecting build artifacts..."
cp arch/arm64/boot/Image.gz "${OUTPUT_DIR}/"
cp arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dtb "${OUTPUT_DIR}/"
make "${MAKE_ARGS[@]}" modules_install INSTALL_MOD_PATH="${OUTPUT_DIR}/modules"

# Create Android boot.img (direct boot, no GRUB)
echo "Creating boot.img..."
cat "${OUTPUT_DIR}/Image.gz" "${OUTPUT_DIR}/sm8150-xiaomi-nabu.dtb" > "${OUTPUT_DIR}/Image.gz-dtb"
mkbootimg \
    --kernel "${OUTPUT_DIR}/Image.gz-dtb" \
    --base 0x0 \
    --kernel_offset 0x8000 \
    --tags_offset 0x100 \
    --pagesize 4096 \
    --header_version 0 \
    --cmdline "${BOOT_CMDLINE}" \
    -o "${BOOT_IMG_OUT}"
rm "${OUTPUT_DIR}/Image.gz-dtb"

echo "--- Kernel build complete ---"
echo "  Image: ${OUTPUT_DIR}/Image.gz"
echo "  DTB:   ${OUTPUT_DIR}/sm8150-xiaomi-nabu.dtb"
echo "  Modules: ${OUTPUT_DIR}/modules/"
echo "  boot.img: ${BOOT_IMG_OUT}"
