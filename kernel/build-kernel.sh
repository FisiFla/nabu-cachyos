#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/tmp/kernel-build"
OUTPUT_DIR="/build/output/kernel"

mkdir -p "${OUTPUT_DIR}"

echo "--- Kernel Build: sm8150/${KERNEL_VERSION} ---"

# Clone kernel source
if [ ! -d "${BUILD_DIR}/linux" ]; then
    echo "Cloning kernel source..."
    git clone --depth 1 --branch "sm8150/${KERNEL_VERSION}" \
        https://gitlab.com/sm8150-mainline/linux.git "${BUILD_DIR}/linux"
fi

cd "${BUILD_DIR}/linux"

# Apply CachyOS patches
echo "Applying patches..."
for patch in "${SCRIPT_DIR}/patches/"*.patch; do
    patchname="$(basename "${patch}")"
    echo "  Applying ${patchname}..."
    if ! git apply --check "${patch}" 2>/dev/null; then
        echo "  ERROR: ${patchname} does not apply cleanly!"
        echo "  Attempting with --3way merge..."
        git apply --3way "${patch}" || {
            echo "  FATAL: ${patchname} failed to apply. Aborting."
            exit 1
        }
    else
        git apply "${patch}"
    fi
done

# Build config: defconfig + sm8150 fragment + cachyos fragment
# Note: sm8150.config is a fragment at arch/arm64/configs/sm8150.config, NOT a defconfig target.
# We must use merge_config.sh to layer it on top of defconfig.
echo "Configuring kernel..."
make ARCH=arm64 defconfig
scripts/kconfig/merge_config.sh -m .config \
    arch/arm64/configs/sm8150.config \
    "${SCRIPT_DIR}/cachyos.config"
make ARCH=arm64 olddefconfig

# Compile
echo "Compiling kernel (this takes ~15 minutes)..."
make -j"$(nproc)" ARCH=arm64 Image.gz dtbs modules

# Collect artifacts
echo "Collecting build artifacts..."
cp arch/arm64/boot/Image.gz "${OUTPUT_DIR}/"
cp arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dtb "${OUTPUT_DIR}/"
make ARCH=arm64 modules_install INSTALL_MOD_PATH="${OUTPUT_DIR}/modules"

echo "--- Kernel build complete ---"
echo "  Image: ${OUTPUT_DIR}/Image.gz"
echo "  DTB:   ${OUTPUT_DIR}/sm8150-xiaomi-nabu.dtb"
echo "  Modules: ${OUTPUT_DIR}/modules/"
