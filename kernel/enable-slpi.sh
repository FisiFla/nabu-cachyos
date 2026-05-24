#!/bin/bash
# Enable the Sensor Low-Power Island (SLPI) co-processor in nabu's DTS.
#
# NAS-218: SLPI is the third Qualcomm remoteproc on sm8150 (alongside ADSP +
# CDSP + Modem) and is where the Sensor Manager service actually runs on this
# tablet. Mainline sm8150.dtsi defines the node as `qcom,sm8150-slpi-pas` but
# leaves status="disabled" because no upstream firmware path is set per-device.
# This script flips it to "okay" and points firmware-name at the slpi_nb.mbn
# blob fetched by firmware/fetch-firmware.sh.
#
# Source for the DT change: rodriguezst/manjaro-kernel-nabu patch 0050
# (Pan Ortiz, Nov 2024 — verified against crDroid 16 vendor partition
# config which references the same firmware name "slpi_nb").
#
# Run this in the kernel source directory after git clone + patch.
set -euo pipefail

DTS="arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dts"

if [ ! -f "$DTS" ]; then
    echo "ERROR: $DTS not found"
    exit 1
fi

if grep -q "remoteproc_slpi" "$DTS" && grep -q "slpi_nb.mbn" "$DTS"; then
    echo "SLPI already enabled in $DTS, skipping."
    exit 0
fi

# Append the override at the end of the DTS. Order doesn't matter — DT
# overrides resolve by label regardless of position — but appending keeps
# the patch idempotent and minimal-diff.
cat >> "$DTS" << 'DTSEOF'

/* CachyOS NAS-218: enable the Sensor Low-Power Island remoteproc.
 * SLPI runs the Qualcomm Sensor Manager service which exposes the
 * LSM6DSO accel/gyro, AK991x magnetometer, BU27030 ambient light,
 * ADUX1050 capacitive prox, and 20+ virtual/fused sensors via QRTR.
 * Firmware blob comes from postmarketOS's panpanpanpan/nabu-firmware
 * mirror (md5-verified against crDroid 16 vendor partition). */
&remoteproc_slpi {
	status = "okay";
	firmware-name = "qcom/sm8150/xiaomi/nabu/slpi_nb.mbn";
};
DTSEOF

echo "SLPI enabled in $DTS (firmware-name = qcom/sm8150/xiaomi/nabu/slpi_nb.mbn)"
