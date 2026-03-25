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

# CRITICAL: Remove gpio-reserved-ranges that blocks GPIO 126-129
# The mainline DTS reserves these for ADSP/secure world, but we need
# GPIO 126-127 for the sensor I2C bus (QUP SE2). Without this fix,
# the pinctrl driver returns -EINVAL when the I2C driver tries to
# request these pins, and the bus fails to initialize.
echo "Removing gpio-reserved-ranges (unreserving GPIO 126-129 for sensor I2C)..."
for f in "$DTS" arch/arm64/boot/dts/qcom/sm8150.dtsi; do
    if [ -f "$f" ] && grep -q "gpio-reserved-ranges" "$f"; then
        sed -i '/gpio-reserved-ranges/d' "$f"
        echo "  Removed from $f"
    fi
done

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
