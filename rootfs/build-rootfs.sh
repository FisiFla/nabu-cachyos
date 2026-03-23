#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
WIFI_SSID="${WIFI_SSID:?WIFI_SSID not set}"
WIFI_PASSWORD="${WIFI_PASSWORD:?WIFI_PASSWORD not set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="/build/output/rootfs"
KERNEL_DIR="/build/output/kernel"
FIRMWARE_DIR="/build/output/firmware/nabu-firmware"

echo "--- Building rootfs ---"

# 1. Bootstrap Arch ARM
echo "Bootstrapping Arch Linux ARM..."
mkdir -p "${ROOTFS}"
# Remove stale pacman locks (common in Docker containers)
rm -f /var/lib/pacman/db.lck "${ROOTFS}/var/lib/pacman/db.lck" 2>/dev/null || true
pacstrap -C "${SCRIPT_DIR}/pacman-alarm.conf" -K "${ROOTFS}" \
    $(cat "${SCRIPT_DIR}/packages.txt" | grep -v '^#' | grep -v '^$' | tr '\n' ' ')

# 2. Install kernel to /boot/efi/ (the ESP mount point)
# IMPORTANT: kernel artifacts live on the ESP so GRUB can find them.
# /boot/efi/ is where the ESP partition is mounted (see fstab).
# This ensures build-time placement matches runtime updates (mkinitcpio, kernel-update).
echo "Installing kernel..."
mkdir -p "${ROOTFS}/boot/efi"
install -Dm644 "${KERNEL_DIR}/Image.gz" \
    "${ROOTFS}/boot/efi/vmlinuz-${KERNEL_VERSION}-cachyos-nabu"
install -Dm644 "${KERNEL_DIR}/sm8150-xiaomi-nabu.dtb" \
    "${ROOTFS}/boot/efi/sm8150-xiaomi-nabu.dtb"

# Install kernel modules
cp -a "${KERNEL_DIR}/modules/lib/modules" "${ROOTFS}/usr/lib/modules"

# 3. Install CachyOS patches and config for runtime kernel-update script
echo "Installing CachyOS patches to /opt/nabu-cachyos/..."
mkdir -p "${ROOTFS}/opt/nabu-cachyos/patches"
cp /build/kernel/patches/*.patch "${ROOTFS}/opt/nabu-cachyos/patches/"
cp /build/kernel/cachyos.config "${ROOTFS}/opt/nabu-cachyos/"

# 4. Install nabu firmware blobs
echo "Installing firmware..."
cp -a "${FIRMWARE_DIR}"/* "${ROOTFS}/usr/lib/firmware/" 2>/dev/null || true

# 4. Copy overlay configs
echo "Applying overlay configs..."
cp -a "${SCRIPT_DIR}/overlay/"* "${ROOTFS}/"

# 5. Write WiFi connection file directly (avoids sed fragility with special chars)
echo "Configuring WiFi..."
cat > "${ROOTFS}/etc/NetworkManager/system-connections/wifi.nmconnection" << NMEOF
[connection]
id=Home WiFi
type=wifi
autoconnect=true

[wifi]
ssid=${WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PASSWORD}

[ipv4]
method=auto

[ipv6]
method=auto
NMEOF
chmod 600 "${ROOTFS}/etc/NetworkManager/system-connections/wifi.nmconnection"

# 6. Install mkinitcpio preset (use sed instead of envsubst for portability)
echo "Configuring mkinitcpio..."
sed "s/\${KERNEL_VERSION}/${KERNEL_VERSION}/g" "${SCRIPT_DIR}/mkinitcpio-nabu.preset" \
    > "${ROOTFS}/etc/mkinitcpio.d/nabu-cachyos.preset"

# 7. Build AUR packages
# Note: Use arch-chroot for installation (not pacman -U --root) to ensure
# install hooks run correctly inside the target rootfs context.
echo "Building AUR packages..."
for pkg in $(cat "${SCRIPT_DIR}/packages-aur.txt" | grep -v '^#' | grep -v '^$'); do
    echo "  Building ${pkg} from AUR..."
    cd /tmp
    sudo -u builder git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" || true
    cd "${pkg}"
    sudo -u builder makepkg -s --noconfirm 2>/dev/null || makepkg -s --noconfirm
    pkgfile=$(ls -1 *.pkg.tar* 2>/dev/null | head -1)
    if [ -n "${pkgfile}" ]; then
        cp "${pkgfile}" "${ROOTFS}/tmp/"
        arch-chroot "${ROOTFS}" pacman -U --noconfirm "/tmp/${pkgfile}"
        rm "${ROOTFS}/tmp/${pkgfile}"
    else
        echo "  WARNING: ${pkg} produced no package file"
    fi
done

# 8. Build and install CachyOS theming
echo "Installing CachyOS theming..."
bash "${SCRIPT_DIR}/build-theming.sh" "${ROOTFS}"

# 9. System configuration
echo "Configuring system..."

# Locale
echo "en_US.UTF-8 UTF-8" > "${ROOTFS}/etc/locale.gen"
arch-chroot "${ROOTFS}" locale-gen
echo "LANG=en_US.UTF-8" > "${ROOTFS}/etc/locale.conf"

# Timezone (UTC, user can change later)
arch-chroot "${ROOTFS}" ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# User account
arch-chroot "${ROOTFS}" useradd -m -G wheel,video,audio,input -s /usr/bin/zsh nabu
echo "nabu:cachyos" | arch-chroot "${ROOTFS}" chpasswd
# Force password change on first login
arch-chroot "${ROOTFS}" chage -d 0 nabu

# Passwordless sudo for wheel group
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > "${ROOTFS}/etc/sudoers.d/wheel"
chmod 440 "${ROOTFS}/etc/sudoers.d/wheel"

# Convenience scripts permissions
chmod +x "${ROOTFS}/home/nabu/bin/"* 2>/dev/null || true
chown -R 1000:1000 "${ROOTFS}/home/nabu/"

# 10. Enable services
echo "Enabling services..."
arch-chroot "${ROOTFS}" systemctl enable NetworkManager
arch-chroot "${ROOTFS}" systemctl enable sshd
arch-chroot "${ROOTFS}" systemctl enable sddm
arch-chroot "${ROOTFS}" systemctl enable bluetooth
arch-chroot "${ROOTFS}" systemctl enable systemd-zram-setup@zram0.service
arch-chroot "${ROOTFS}" systemctl --global enable maliit-server.service

# 11. Generate initramfs
echo "Generating initramfs..."
arch-chroot "${ROOTFS}" mkinitcpio -p nabu-cachyos

# 12. fstab
cat > "${ROOTFS}/etc/fstab" << 'FSTAB'
# CachyOS Nabu fstab
PARTLABEL=linux  /           btrfs  subvol=@,compress=zstd:3,noatime,ssd,discard=async  0 0
PARTLABEL=linux  /home       btrfs  subvol=@home,compress=zstd:3,noatime,ssd,discard=async  0 0
PARTLABEL=linux  /.snapshots btrfs  subvol=@snapshots,compress=zstd:3,noatime,ssd,discard=async  0 0
PARTLABEL=esp    /boot/efi   vfat   defaults  0 2
FSTAB

echo "--- Rootfs build complete ---"
echo "  Root: ${ROOTFS}"
du -sh "${ROOTFS}"
