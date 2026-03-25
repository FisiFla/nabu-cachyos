#!/bin/bash
# Add LSM6DSO sensor support to nabu device tree
# Run this in the kernel source directory after git clone + patch

DTS="arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dts"

if [ ! -f "$DTS" ]; then
    echo "ERROR: $DTS not found"
    exit 1
fi

# Check if already patched
if grep -q "lsm6dso" "$DTS"; then
    echo "Sensors already added to DTS, skipping"
    exit 0
fi

# CRITICAL: Shrink gpio-reserved-ranges to free GPIO 126-127 for sensor I2C
# Original: <126 4> reserves GPIO 126-129
# Fixed:    <128 2> reserves only GPIO 128-129 (freeing 126-127 for QUP SE2)
# WARNING: Do NOT delete the line entirely — that breaks TrustZone boot!
echo "Fixing gpio-reserved-ranges (freeing GPIO 126-127 for sensor I2C)..."
if grep -q "gpio-reserved-ranges" "$DTS"; then
    sed -i 's/gpio-reserved-ranges = <126 4>/gpio-reserved-ranges = <128 2>/' "$DTS"
    sed -i 's/gpio-reserved-ranges = <0 4>, <126 4>/gpio-reserved-ranges = <0 4>, <128 2>/' "$DTS"
    echo "  Fixed in $DTS"
    grep "gpio-reserved-ranges" "$DTS"
fi

# Find the correct I2C label for 0x888000
# In mainline sm8150.dtsi it could be i2c2, i2c@888000, etc.
I2C_LABEL=$(grep -B1 "i2c@888000" arch/arm64/boot/dts/qcom/sm8150.dtsi 2>/dev/null | grep ":" | sed 's/:.*//' | tr -d '[:space:]')
if [ -z "$I2C_LABEL" ]; then
    echo "WARNING: Could not find I2C label for 0x888000, trying direct node reference"
    I2C_LABEL="i2c@888000"
fi
echo "Using I2C label: $I2C_LABEL"

# Append sensor node to the nabu DTS
cat >> "$DTS" << DTSEOF

/* CachyOS: Enable QUP SE2 I2C for LSM6DSO accelerometer/gyroscope */
&${I2C_LABEL} {
	status = "okay";

	accelerometer@6a {
		compatible = "st,lsm6dso";
		reg = <0x6a>;
		interrupts-extended = <&tlmm 132 IRQ_TYPE_EDGE_RISING>;
		mount-matrix = "1", "0", "0",
			       "0", "1", "0",
			       "0", "0", "1";
	};
};
DTSEOF

echo "LSM6DSO sensor node added to $DTS (bus: $I2C_LABEL)"
