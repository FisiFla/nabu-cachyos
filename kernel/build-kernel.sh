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

# Clone kernel source (persistent BUILD_DIR enables incremental rebuilds;
# when the patch set or the upstream branch HEAD changes, the tree below is
# re-extracted — see the sentinel fingerprint logic).
KERNEL_URL="${KERNEL_URL:-https://gitlab.com/sm8150-mainline/linux.git}"
LOCAL_KERNEL_REF="sm8150/${KERNEL_VERSION}"
PATCH_SENTINEL=".cachyos-patches-applied"

# Fingerprint = upstream branch HEAD + every patch body. One cheap ls-remote
# query resolves the HEAD so a moved upstream can't be masked by a cached
# tree; editing any .patch changes the hash. Either change forces a clean
# re-extract instead of silently keeping the old tree.
REMOTE_HEAD="$(git ls-remote "${KERNEL_URL}" "refs/heads/${LOCAL_KERNEL_REF}" 2>/dev/null | awk '{print $1}')"
if [ -z "${REMOTE_HEAD}" ]; then
    echo "WARNING: could not resolve remote HEAD for ${LOCAL_KERNEL_REF}; sentinel covers patch content only."
    REMOTE_HEAD="<unresolved>"
fi
EXPECTED_SENTINEL="$( { echo "${REMOTE_HEAD}"; cat "${SCRIPT_DIR}"/patches/*.patch; } | sha256sum | awk '{print $1}')"

needs_clone=0
if [ ! -d "${BUILD_DIR}/linux/.git" ]; then
    needs_clone=1
elif [ ! -f "${BUILD_DIR}/linux/${PATCH_SENTINEL}" ] \
        || ! grep -qx "${EXPECTED_SENTINEL}" "${BUILD_DIR}/linux/${PATCH_SENTINEL}" 2>/dev/null; then
    echo "Reusing kernel tree at ${BUILD_DIR}/linux"
    echo "  Patch set or upstream branch changed — re-extracting."
    rm -rf "${BUILD_DIR}/linux"
    needs_clone=1
else
    echo "Reusing existing kernel tree at ${BUILD_DIR}/linux"
fi
if [ "${needs_clone}" = "1" ]; then
    echo "Cloning kernel source..."
    rm -rf "${BUILD_DIR}/linux"
    git clone --depth 1 --branch "${LOCAL_KERNEL_REF}" \
        "${KERNEL_URL}" "${BUILD_DIR}/linux"
fi

cd "${BUILD_DIR}/linux"

# Apply CachyOS patches. The sentinel above embeds the upstream HEAD and a
# hash of all patch bodies, so re-runs never double-apply and never keep an
# outdated patch revision.
PATCH_SENTINEL_USED=0
if [ -f "${PATCH_SENTINEL}" ] && grep -qx "${EXPECTED_SENTINEL}" "${PATCH_SENTINEL}" 2>/dev/null; then
    PATCH_SENTINEL_USED=1
    echo "Patches already applied (sentinel stamped, content verified)"
fi
if [ "${PATCH_SENTINEL_USED}" != "1" ]; then
    # BORE (0001) is critical. Others are best-effort — the kernel works without them.
    # NAS-218 / NAS-247: the fastrpc INIT_CREATE_STATIC pageslen fix is also
    # critical — without it, SLPI sensorspd PD-create fails with EPIPE and the
    # entire sensor stack stays dead. Sensor hardware is unreachable any other
    # way on nabu (the I2C path is TrustZone-blocked, see add-sensors.sh).
    CRITICAL_PATCHES=("0001-bore" "0005-fastrpc-fix-init-create-static-pageslen")
    echo "Applying patches..."
    unshallowed=0
    for patch in "${SCRIPT_DIR}"/patches/*.patch; do
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
        elif [ "${unshallowed}" = "0" ] && [ -f .git/shallow ] \
                && [ "${KERNEL_NO_UNSHALLOW:-0}" != "1" ]; then
            # --3way needs the base blobs the patch's index lines reference;
            # a --depth 1 clone doesn't have them. Fetch the full branch
            # history once (large, one-time) and retry. Opt out with
            # KERNEL_NO_UNSHALLOW=1 when bandwidth matters.
            echo "    shallow clone lacks 3-way base blobs — fetching full history (one-time)..."
            git fetch --unshallow origin "${LOCAL_KERNEL_REF}" 2>/dev/null || true
            unshallowed=1
            if git apply --3way "${patch}" 2>/dev/null; then
                echo "    OK (3-way merge after unshallow)"
            elif ${is_critical}; then
                echo "    FATAL: critical patch ${patchname} failed to apply. Aborting."
                exit 1
            else
                echo "    WARNING: ${patchname} did not apply cleanly, skipping."
                echo "    The kernel will work without it."
            fi
        elif ${is_critical}; then
            echo "    FATAL: critical patch ${patchname} failed to apply. Aborting."
            exit 1
        else
            echo "    WARNING: ${patchname} did not apply cleanly, skipping."
            echo "    The kernel will work without it."
        fi
    done
    echo "${EXPECTED_SENTINEL}" > "${PATCH_SENTINEL}"
fi

# Apply optional device tree modifications.
# nabu's TrustZone firmware reserves GPIO 126-127; changing that range
# is known to cause boot failure, so keep the direct-I2C sensor DTS hack
# opt-in. The SLPI path below bypasses this entirely — sensors are driven
# by the SLPI co-processor over QRTR, not by the AP's I2C controller.
if [ "${ENABLE_EXPERIMENTAL_SENSORS}" = "1" ] && [ -x "${SCRIPT_DIR}/add-sensors.sh" ]; then
    echo "Adding experimental sensor support to device tree..."
    bash "${SCRIPT_DIR}/add-sensors.sh"
else
    echo "Skipping experimental sensor DTS modifications."
fi

# NAS-218: enable the Sensor Low-Power Island remoteproc. Mandatory now —
# this is the route to ALL nabu sensors (accel/gyro/mag/light/prox) via
# the Qualcomm Sensor Manager running on SLPI. See enable-slpi.sh comments
# for context.
if [ -x "${SCRIPT_DIR}/enable-slpi.sh" ]; then
    echo "Enabling SLPI remoteproc in device tree..."
    bash "${SCRIPT_DIR}/enable-slpi.sh"
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

# NAS-218: prove the SLPI override survived into the compiled DTB. dtc only
# WARNS when an override references a nonexistent label — the build would
# succeed with SLPI silently disabled and every nabu sensor dead.
SLPI_DTB="arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dtb"
if command -v dtc >/dev/null 2>&1; then
    SLPI_DTS_DUMP="$(mktemp)"
    if dtc -I dtb -O dts -o "${SLPI_DTS_DUMP}" "${SLPI_DTB}" 2>/dev/null; then
        # Find the SLPI pas node by its compatible; the override must have
        # left it enabled and pointed at the firmware blob
        # fetch-firmware.sh installs.
        slpi_line=$(grep -n 'qcom,sm8150-slpi-pas' "${SLPI_DTS_DUMP}" | head -n 1 | cut -d: -f1)
        slpi_ok=0
        if [ -n "${slpi_line}" ]; then
            slpi_block=$(sed -n "${slpi_line},$((slpi_line + 40))p" "${SLPI_DTS_DUMP}")
            if grep -q 'status = "okay";' <<< "${slpi_block}" \
                && grep -q 'qcom,firmware-name = "qcom/sm8150/xiaomi/nabu/slpi_nb.mbn";' <<< "${slpi_block}"; then
                slpi_ok=1
            fi
        fi
        if [ "${slpi_ok}" = "1" ]; then
            echo "SLPI override verified in DTB: status=okay, firmware-name=slpi_nb.mbn"
        else
            echo "ERROR: SLPI remoteproc (qcom,sm8150-slpi-pas) is missing from the"
            echo "       compiled DTB or not enabled with our firmware-name."
            echo "       enable-slpi.sh's override probably referenced a renamed or"
            echo "       removed label — check it against the upstream DTS."
            rm -f "${SLPI_DTS_DUMP}"
            exit 1
        fi
        rm -f "${SLPI_DTS_DUMP}"
    else
        echo "WARNING: could not decompile ${SLPI_DTB} — skipping the SLPI node"
        echo "         verification."
    fi
else
    echo "WARNING: dtc not found — skipping the SLPI node verification."
fi
make "${MAKE_ARGS[@]}" modules_install INSTALL_MOD_PATH="${OUTPUT_DIR}/modules"

# modules_install leaves absolute "build" and "source" symlinks pointing at
# the container's build tree (e.g. /tmp/kernel-build/linux). They are copied
# verbatim into the flashed rootfs by the image stage and confuse anything
# that follows them; module loading does not need them. Remove them from
# every module directory regardless of naming.
find "${OUTPUT_DIR}/modules/lib/modules" -mindepth 1 -maxdepth 2 \
    \( -name build -o -name source \) -type l \
    -delete 2>/dev/null || true

# Record the real kernel release string.
#
# KERNEL_VERSION is the *branch tag* of the sm8150-mainline fork
# (e.g. 6.17-wifi-fix). The release string is what the kernel itself
# reports (e.g. 6.17.0-sm8150-gc22201bb8db6-dirty) and is what
# /lib/modules, the kernel image name and the mkinitcpio preset have to
# agree on. The rootfs stage reads it from this file.
KERNEL_RELEASE="$(make -s "${MAKE_ARGS[@]}" kernelrelease 2>/dev/null | tail -n 1)"
if [ -z "${KERNEL_RELEASE}" ]; then
    echo "ERROR: could not determine the kernel release string (make kernelrelease)."
    exit 1
fi
# The directory modules_install just created is the authoritative name.
MODULES_RELEASE="$(find "${OUTPUT_DIR}/modules/lib/modules" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | head -n 1)"
if [ -n "${MODULES_RELEASE}" ] && [ "${MODULES_RELEASE}" != "${KERNEL_RELEASE}" ]; then
    echo "WARNING: kernelrelease (${KERNEL_RELEASE}) differs from the module"
    echo "         directory (${MODULES_RELEASE}) — using the module directory."
    KERNEL_RELEASE="${MODULES_RELEASE}"
fi
printf '%s\n' "${KERNEL_RELEASE}" > "${OUTPUT_DIR}/kernel-release"

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
echo "  Release: ${KERNEL_RELEASE}"
echo "  Modules: ${OUTPUT_DIR}/modules/"
echo "  boot.img: ${BOOT_IMG_OUT}"
