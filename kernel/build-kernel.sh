#!/usr/bin/env bash
set -euo pipefail

# Historical branch tag of the sm8150-mainline tree. Only used to derive the
# default KERNEL_REF below, so it may be omitted when KERNEL_REF is set.
KERNEL_VERSION="${KERNEL_VERSION:-7.3-nabu}"
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

# Kernel source. Defaults to Kumar-Jy's nabu tree (7.3), which carries the
# tested Xiaomi Pad 5 support: Novatek touch, CS35L41 speakers, Iris VPU
# video decode, qcom_bms charger, PSCI deep sleep, keyboard/hall, idtp9418.
# The old sm8150-mainline tree is still reachable with
#   KERNEL_URL=https://gitlab.com/sm8150-mainline/linux.git KERNEL_REF=sm8150/6.17-wifi-fix
KERNEL_URL="${KERNEL_URL:-https://github.com/Kumar-Jy/linux.git}"
KERNEL_REF="${KERNEL_REF:-nabu/7.3.y}"
LOCAL_KERNEL_REF="${KERNEL_REF}"
# Optional commit pin; when set the shallow clone is moved onto exactly that
# commit. Leave empty to follow the branch tip (the sentinel still tracks it).
KERNEL_COMMIT="${KERNEL_COMMIT:-}"
PATCH_SENTINEL=".cachyos-patches-applied"

# Base config: nabu_defconfig is the tree's own Xiaomi Pad 5 config (it
# already includes the sm8150 fragment). Override both for other trees.
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-nabu_defconfig}"
KERNEL_FRAGMENTS="${KERNEL_FRAGMENTS-arch/arm64/configs/sm8150.config}"

echo "--- Kernel Build: ${KERNEL_REF} ---"
echo "  ARCH=${ARCH}  CROSS_COMPILE=${CROSS_COMPILE:-<native>}  CC=${CC:-<default>}"
echo "  BUILD_DIR=${BUILD_DIR}"
echo "  OUTPUT_DIR=${OUTPUT_DIR}"

# Fingerprint = upstream branch HEAD + every patch body. One cheap ls-remote
# query resolves the HEAD so a moved upstream can't be masked by a cached
# tree; editing any .patch changes the hash. Either change forces a clean
# re-extract instead of silently keeping the old tree.
REMOTE_HEAD="$(git ls-remote "${KERNEL_URL}" "refs/heads/${LOCAL_KERNEL_REF}" 2>/dev/null | awk '{print $1}')"
if [ -z "${REMOTE_HEAD}" ]; then
    echo "WARNING: could not resolve remote HEAD for ${LOCAL_KERNEL_REF}; sentinel covers patch content only."
    REMOTE_HEAD="<unresolved>"
fi
EXPECTED_SENTINEL="$( { echo "${KERNEL_COMMIT:-${REMOTE_HEAD}}"; cat "${SCRIPT_DIR}"/patches/*.patch; } | sha256sum | awk '{print $1}')"

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

# Move the shallow clone onto the pinned commit when one is given.
if [ -n "${KERNEL_COMMIT}" ]; then
    if [ "$(git rev-parse HEAD)" != "${KERNEL_COMMIT}" ]; then
        echo "Pinning kernel tree to ${KERNEL_COMMIT}..."
        git fetch --depth 1 origin "${KERNEL_COMMIT}"
        git checkout --detach FETCH_HEAD
    fi
fi

# Apply CachyOS patches. The sentinel above embeds the upstream HEAD and a
# hash of all patch bodies, so re-runs never double-apply and never keep an
# outdated patch revision.
# A FAILED `git apply --3way` must not be trusted silent: git stages the
# hunks that succeeded and leaves conflict markers in the rest, so the tree
# ends up half-applied (this bit a real build: adios half-way in left
# elevator.c with unresolved conflicts and the kernel wouldn't compile).
# rollback_patch_files() restores exactly the files the failed patch touched
# so later patches and the build start from a clean tree. Assumes patches in
# the set touch disjoint files (true here: sched/net/block/drivers/fastrpc).
rollback_patch_files() {
    local patch="$1" f
    git reset -q -- . 2>/dev/null || true
    git apply --numstat "${patch}" 2>/dev/null \
        | awk '{sub("^a/", "", $3); sub("^b/", "", $3); print $3}' \
        | sort -u \
        | while IFS= read -r f; do
            [ -n "${f}" ] || continue
            if git cat-file -e "HEAD:${f}" 2>/dev/null; then
                git checkout -f HEAD -- "${f}"
            else
                rm -f -- "${f}"
            fi
            # git apply --reject/3way leftovers are not listed by --numstat.
            rm -f -- "${f}.rej" "${f}.orig"
        done
}
PATCH_SENTINEL_USED=0
if [ -f "${PATCH_SENTINEL}" ] && grep -qx "${EXPECTED_SENTINEL}" "${PATCH_SENTINEL}" 2>/dev/null; then
    PATCH_SENTINEL_USED=1
    echo "Patches already applied (sentinel stamped, content verified)"
fi
if [ "${PATCH_SENTINEL_USED}" != "1" ]; then
    # BORE (0001) is critical on the old 6.17 tree; the 7.3 nabu tree builds
    # fine without the CachyOS patch set, so it can be emptied there with
    # KERNEL_CRITICAL_PATCHES="" to make every patch best-effort.
    # NAS-218 / NAS-247: the fastrpc INIT_CREATE_STATIC pageslen fix is critical
    # on 6.17 — without it, SLPI sensorspd PD-create fails with EPIPE and the
    # entire sensor stack stays dead. The 7.3 tree reworked that path, so it is
    # optional there (the build uses attach mode).
    # shellcheck disable=SC2206  # deliberate word splitting of a space-separated list
    # Note: ${VAR-default} (no colon) so an explicit empty value means "no critical patches".
    CRITICAL_PATCHES=(${KERNEL_CRITICAL_PATCHES-0001-bore 0005-fastrpc-fix-init-create-static-pageslen})
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
            continue
        fi
        if git apply --3way "${patch}" 2>/dev/null; then
            echo "    OK (3-way merge)"
            continue
        fi
        # The 3-way attempt just failed and may have left hunks behind.
        rollback_patch_files "${patch}"
        if [ "${unshallowed}" = "0" ] && [ -f .git/shallow ] \
                && [ "${KERNEL_NO_UNSHALLOW:-0}" != "1" ]; then
            # --3way needs the base blobs the patch's index lines reference;
            # a --depth 1 clone doesn't have them. Fetch the full branch
            # history once (large, one-time) and retry. Opt out with
            # KERNEL_NO_UNSHALLOW=1 when bandwidth matters.
            echo "    shallow clone lacks 3-way base blobs — fetching full history (one-time)..."
            git fetch --unshallow origin "${LOCAL_KERNEL_REF}" 2>/dev/null || true
            unshallowed=1
        fi
        if git apply --3way "${patch}" 2>/dev/null; then
            echo "    OK (3-way merge)"
        elif ${is_critical}; then
            echo "    FATAL: critical patch ${patchname} failed to apply. Aborting."
            exit 1
        else
            rollback_patch_files "${patch}"
            echo "    WARNING: ${patchname} did not apply cleanly, skipping."
            echo "    The kernel will work without it."
        fi
    done
    echo "${EXPECTED_SENTINEL}" > "${PATCH_SENTINEL}"
fi

# NAS-218: enable the Sensor Low-Power Island remoteproc. Mandatory now —
# this is the route to ALL nabu sensors (accel/gyro/mag/light/prox) via
# the Qualcomm Sensor Manager running on SLPI. See enable-slpi.sh comments
# for context.
if [ -x "${SCRIPT_DIR}/enable-slpi.sh" ]; then
    echo "Enabling SLPI remoteproc in device tree..."
    bash "${SCRIPT_DIR}/enable-slpi.sh"
fi

# Build config: the tree's base config plus the CachyOS fragment.
# nabu_defconfig already folds in the sm8150 fragment; the old sm8150-mainline
# tree instead needs `defconfig` + arch/arm64/configs/sm8150.config, which is
# what KERNEL_DEFCONFIG/KERNEL_FRAGMENTS select.
echo "Configuring kernel (${KERNEL_DEFCONFIG})..."
make "${MAKE_ARGS[@]}" "${KERNEL_DEFCONFIG}"
CONFIG_FRAGMENTS=()
for frag in ${KERNEL_FRAGMENTS}; do
    [ -f "${frag}" ] && CONFIG_FRAGMENTS+=("${frag}")
done
scripts/kconfig/merge_config.sh -m .config \
    ${CONFIG_FRAGMENTS[@]+"${CONFIG_FRAGMENTS[@]}"} \
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
            # The DT property is `firmware-name` (no qcom, prefix — that only
            # exists on some other nodes); a bare `firmware-name` grep also
            # matches a qcom,firmware-name variant.
            if grep -q 'status = "okay";' <<< "${slpi_block}" \
                && grep -q 'firmware-name = "qcom/sm8150/xiaomi/nabu/slpi_nb.mbn";' <<< "${slpi_block}"; then
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
