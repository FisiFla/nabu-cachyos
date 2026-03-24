#!/usr/bin/env bash
# USB serial gadget for debugging via USB-C cable
# Creates a serial console accessible from the host machine
set -euo pipefail

GADGET_DIR="/sys/kernel/config/usb_gadget/serial"

# Clean up any existing gadget
if [ -d "${GADGET_DIR}" ]; then
    echo "" > "${GADGET_DIR}/UDC" 2>/dev/null || true
    rm -rf "${GADGET_DIR}"
fi

# Load required modules
modprobe libcomposite 2>/dev/null || true
modprobe usb_f_acm 2>/dev/null || true

# Create gadget
mkdir -p "${GADGET_DIR}"
cd "${GADGET_DIR}"

echo 0x1d6b > idVendor   # Linux Foundation
echo 0x0104 > idProduct   # Multifunction Composite Gadget
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

# Strings
mkdir -p strings/0x409
echo "cachyos-nabu" > strings/0x409/serialnumber
echo "CachyOS" > strings/0x409/manufacturer
echo "CachyOS Nabu Serial" > strings/0x409/product

# ACM function (serial)
mkdir -p configs/c.1/strings/0x409
echo "ACM Serial" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

mkdir -p functions/acm.usb0
ln -sf functions/acm.usb0 configs/c.1/

# Bind to UDC
UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
if [ -n "${UDC}" ]; then
    echo "${UDC}" > UDC
    echo "USB serial gadget enabled on ${UDC}"
    # Start a getty on the gadget serial port
    systemctl start serial-getty@ttyGS0.service 2>/dev/null || true
else
    echo "WARNING: No UDC found, USB serial gadget not enabled"
fi
