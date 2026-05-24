#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="/build/output/firmware"
mkdir -p "${OUTPUT_DIR}"

echo "--- Fetching nabu firmware blobs ---"

# Bump this SHA to pull in new upstream firmware updates.
NABU_FIRMWARE_COMMIT="60bcc8485fe3b36861a4b18bfd87d4784f285716"

if [ ! -d "${OUTPUT_DIR}/nabu-firmware" ]; then
    git clone https://github.com/map220v/nabu-firmware.git "${OUTPUT_DIR}/nabu-firmware"
    git -C "${OUTPUT_DIR}/nabu-firmware" checkout "${NABU_FIRMWARE_COMMIT}"
else
    echo "Firmware already downloaded, skipping."
    # Verify the cached clone is at the pinned commit
    actual="$(git -C "${OUTPUT_DIR}/nabu-firmware" rev-parse HEAD)"
    if [ "${actual}" != "${NABU_FIRMWARE_COMMIT}" ]; then
        echo "ERROR: cached firmware clone is at ${actual}, expected ${NABU_FIRMWARE_COMMIT}." >&2
        echo "       Delete ${OUTPUT_DIR}/nabu-firmware and re-run to refresh." >&2
        exit 1
    fi
fi

echo "--- Firmware ready at ${OUTPUT_DIR}/nabu-firmware ---"
echo "These blobs provide: WiFi (WCN3991), GPU (Adreno 640), Bluetooth, audio codec"
echo "They will be installed to /usr/lib/firmware/ in the rootfs."

# ─── Sensor Low-Power Island (SLPI) firmware + hexagonfs config tree ──
# NAS-218: full sensor stack. map220v/nabu-firmware does NOT ship slpi_nb.mbn
# (Android loads SLPI from a dedicated dsp partition, not /vendor/firmware/),
# so we pull from postmarketOS's redistributable mirror instead. Verified
# byte-identical to Android's vendor/etc/sensors/config/ via md5sum (crDroid
# 16 ROM scrape, 2026-05-24).
#
# Bump this SHA to refresh.
SLPI_FIRMWARE_COMMIT="b17a3ce0f08871f1c4553351b2f64b2c6969cd5c"
SLPI_BUNDLE_URL="https://gitlab.postmarketos.org/panpanpanpan/nabu-firmware/-/archive/${SLPI_FIRMWARE_COMMIT}/nabu-firmware-${SLPI_FIRMWARE_COMMIT}.tar.gz"
SLPI_STAGE_DIR="${OUTPUT_DIR}/slpi-bundle"
SLPI_TARBALL="${OUTPUT_DIR}/.slpi-bundle.tar.gz"

if [ ! -f "${SLPI_STAGE_DIR}/slpi_nb.mbn" ] || [ ! -d "${SLPI_STAGE_DIR}/hexagonfs" ]; then
    echo "Fetching SLPI firmware + hexagonfs config tree (postmarketOS @ ${SLPI_FIRMWARE_COMMIT:0:8})..."
    rm -rf "${SLPI_STAGE_DIR}" "${SLPI_TARBALL}"
    mkdir -p "${SLPI_STAGE_DIR}"
    curl -fsSL "${SLPI_BUNDLE_URL}" -o "${SLPI_TARBALL}"
    tar xzf "${SLPI_TARBALL}" -C "${SLPI_STAGE_DIR}" --strip-components=1 \
        "nabu-firmware-${SLPI_FIRMWARE_COMMIT}/slpi_nb.mbn" \
        "nabu-firmware-${SLPI_FIRMWARE_COMMIT}/hexagonfs"
    rm -f "${SLPI_TARBALL}"
    # Sanity check: slpi_nb.mbn must be a Qualcomm DSP6 ELF (~6 MB).
    if ! file "${SLPI_STAGE_DIR}/slpi_nb.mbn" 2>/dev/null | grep -q "QUALCOMM DSP6"; then
        echo "WARNING: slpi_nb.mbn may not be a valid Qualcomm DSP6 firmware blob."
        echo "         Check ${SLPI_STAGE_DIR}/slpi_nb.mbn manually."
    fi
else
    echo "SLPI firmware + hexagonfs already staged at ${SLPI_STAGE_DIR}."
fi

echo "  SLPI firmware: $(ls -lh "${SLPI_STAGE_DIR}/slpi_nb.mbn" 2>/dev/null | awk '{print $5}') @ ${SLPI_STAGE_DIR}/slpi_nb.mbn"
echo "  Hexagonfs:     $(find "${SLPI_STAGE_DIR}/hexagonfs" -type f 2>/dev/null | wc -l | tr -d ' ') files @ ${SLPI_STAGE_DIR}/hexagonfs"
