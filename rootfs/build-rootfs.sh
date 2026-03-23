#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
WIFI_SSID="${WIFI_SSID:?WIFI_SSID not set}"
WIFI_PASSWORD="${WIFI_PASSWORD:?WIFI_PASSWORD not set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Build rootfs in container-local filesystem (not bind mount) to avoid
# macOS Docker volume lock issues with pacman, then copy to output.
ROOTFS="/tmp/rootfs-build"
FINAL_ROOTFS="/build/output/rootfs"
KERNEL_DIR="/build/output/kernel"
FIRMWARE_DIR="/build/output/firmware/nabu-firmware"

echo "--- Building rootfs ---"

# 1. Bootstrap Arch ARM
echo "Bootstrapping Arch Linux ARM..."
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"
# Bind-mount to make it a mount point (arch-chroot requires this)
mount --bind "${ROOTFS}" "${ROOTFS}"
rm -f /var/lib/pacman/db.lck 2>/dev/null || true
pacstrap -C "${SCRIPT_DIR}/pacman-alarm.conf" -K "${ROOTFS}" \
    $(cat "${SCRIPT_DIR}/packages.txt" | grep -v '^#' | grep -v '^$' | tr '\n' ' ')

# Disable Landlock sandbox in rootfs pacman (fails inside Docker)
sed -i '/^\[options\]/a DisableSandbox' "${ROOTFS}/etc/pacman.conf"

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
mkdir -p "${ROOTFS}/etc/mkinitcpio.d"
sed "s/\${KERNEL_VERSION}/${KERNEL_VERSION}/g" "${SCRIPT_DIR}/mkinitcpio-nabu.preset" \
    > "${ROOTFS}/etc/mkinitcpio.d/nabu-cachyos.preset"

# 7. Build AUR packages
# Use pacman -U with --root to install directly (avoids arch-chroot sandbox issues)
echo "Building AUR packages..."
AUR_BUILD="/tmp/aur-build"
mkdir -p "${AUR_BUILD}"
chown builder:builder "${AUR_BUILD}"
for pkg in $(cat "${SCRIPT_DIR}/packages-aur.txt" | grep -v '^#' | grep -v '^$'); do
    echo "  Building ${pkg} from AUR..."
    if [ -d "${AUR_BUILD}/${pkg}" ]; then
        rm -rf "${AUR_BUILD}/${pkg}"
    fi
    sudo -u builder git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "${AUR_BUILD}/${pkg}" || {
        echo "  WARNING: Failed to clone ${pkg}, skipping"
        continue
    }
    cd "${AUR_BUILD}/${pkg}"
    # makepkg must run as non-root; -s installs deps via sudo
    sudo -u builder makepkg -s --noconfirm || {
        echo "  WARNING: makepkg failed for ${pkg}, skipping"
        continue
    }
    pkgfile=$(ls -1 *.pkg.tar* 2>/dev/null | head -1)
    if [ -n "${pkgfile}" ]; then
        pacman -U --noconfirm --root "${ROOTFS}" --dbpath "${ROOTFS}/var/lib/pacman" \
            "${AUR_BUILD}/${pkg}/${pkgfile}"
        echo "    Installed ${pkgfile}"
    else
        echo "  WARNING: ${pkg} produced no package file, skipping"
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

# 13. Copy rootfs to output directory (from container-local to bind mount)
echo "Copying rootfs to output..."
umount "${ROOTFS}" 2>/dev/null || true
rm -rf "${FINAL_ROOTFS}"
mkdir -p "${FINAL_ROOTFS}"
cp -a "${ROOTFS}/"* "${FINAL_ROOTFS}/"

echo "--- Rootfs build complete ---"
echo "  Root: ${FINAL_ROOTFS}"
du -sh "${FINAL_ROOTFS}"
