#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="/build/output/firmware"
mkdir -p "${OUTPUT_DIR}"

echo "--- Fetching nabu firmware blobs ---"

if [ ! -d "${OUTPUT_DIR}/nabu-firmware" ]; then
    git clone --depth 1 https://github.com/map220v/nabu-firmware.git \
        "${OUTPUT_DIR}/nabu-firmware"
else
    echo "Firmware already downloaded, skipping."
fi

echo "--- Firmware ready at ${OUTPUT_DIR}/nabu-firmware ---"
echo "These blobs provide: WiFi (WCN3991), GPU (Adreno 640), Bluetooth, audio codec"
echo "They will be installed to /usr/lib/firmware/ in the rootfs."
