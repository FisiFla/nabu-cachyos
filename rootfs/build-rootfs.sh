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

# 1. Bootstrap Arch ARM (cached: skip pacstrap if cache tarball exists)
PACSTRAP_CACHE="/build/.cache/pacstrap-rootfs.tar"
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"
# Bind-mount to make it a mount point (arch-chroot requires this)
mount --bind "${ROOTFS}" "${ROOTFS}"

if [ -f "${PACSTRAP_CACHE}" ]; then
    echo "Restoring cached pacstrap rootfs..."
    tar xf "${PACSTRAP_CACHE}" -C "${ROOTFS}"
else
    echo "Bootstrapping Arch Linux ARM (first run, will be cached)..."
    rm -f /var/lib/pacman/db.lck 2>/dev/null || true
    pacstrap -C "${SCRIPT_DIR}/pacman-alarm.conf" -K "${ROOTFS}" \
        $(cat "${SCRIPT_DIR}/packages.txt" | grep -v '^#' | grep -v '^$' | tr '\n' ' ')
    # Disable Landlock sandbox in rootfs pacman (fails inside Docker)
    sed -i '/^\[options\]/a DisableSandbox' "${ROOTFS}/etc/pacman.conf"
    # Cache for next run
    echo "Caching pacstrap rootfs for future builds..."
    mkdir -p "$(dirname "${PACSTRAP_CACHE}")"
    tar cf "${PACSTRAP_CACHE}" -C "${ROOTFS}" . || echo "WARNING: cache tar failed (non-fatal)"
fi

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

# 8b. Build and install additional CachyOS tools
echo "Building CachyOS tools..."
TOOLS_BUILD="/tmp/cachyos-tools"
mkdir -p "${TOOLS_BUILD}"
chown builder:builder "${TOOLS_BUILD}"
cd "${TOOLS_BUILD}"
if [ ! -d "CachyOS-PKGBUILDS" ]; then
    sudo -u builder git clone --depth 1 https://github.com/CachyOS/CachyOS-PKGBUILDS.git
fi

for tool in cachyos-settings cachyos-alacritty-config cachyos-zsh-config; do
    echo "  Building ${tool}..."
    cd "${TOOLS_BUILD}/CachyOS-PKGBUILDS/${tool}"
    sudo -u builder makepkg -f --noconfirm --nodeps --skipinteg 2>&1 || {
        echo "    WARNING: ${tool} failed, skipping"
        continue
    }
    pkg=$(ls -1 *.pkg.tar* 2>/dev/null | head -1)
    if [ -n "${pkg}" ]; then
        pacman -U --noconfirm --nodeps --nodeps --root "${ROOTFS}" --dbpath "${ROOTFS}/var/lib/pacman" \
            "${TOOLS_BUILD}/CachyOS-PKGBUILDS/${tool}/${pkg}"
        echo "    Installed ${pkg}"
    fi
done

# 8c. Install zsh plugins required by cachyos-zsh-config (not in ALARM repos)
echo "Installing zsh plugins..."
git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "${ROOTFS}/usr/share/oh-my-zsh" 2>/dev/null || true
git clone --depth 1 https://github.com/romkatv/powerlevel10k.git "${ROOTFS}/usr/share/zsh-theme-powerlevel10k" 2>/dev/null || true
git clone --depth 1 https://github.com/zsh-users/zsh-history-substring-search.git "${ROOTFS}/usr/share/zsh/plugins/zsh-history-substring-search" 2>/dev/null || true

# Create default p10k config (skip interactive wizard — no keyboard on tablet)
cat > "${ROOTFS}/etc/skel/.p10k.zsh" << 'P10KEOF'
POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true
POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs)
POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status command_execution_time battery)
POWERLEVEL9K_MODE="nerdfont-complete"
POWERLEVEL9K_PROMPT_ON_NEWLINE=true
POWERLEVEL9K_RPROMPT_ON_NEWLINE=false
POWERLEVEL9K_MULTILINE_FIRST_PROMPT_PREFIX=""
POWERLEVEL9K_MULTILINE_LAST_PROMPT_PREFIX="%F{014}❯%f "
POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION="🐧"
POWERLEVEL9K_DIR_BACKGROUND="024"
POWERLEVEL9K_DIR_FOREGROUND="white"
P10KEOF

# Prepend wizard disable to skel zshrc
echo 'export POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true' > "${ROOTFS}/etc/skel/.zshrc.tmp"
cat "${ROOTFS}/etc/skel/.zshrc" >> "${ROOTFS}/etc/skel/.zshrc.tmp" 2>/dev/null || echo 'source /usr/share/cachyos-zsh-config/cachyos-config.zsh' >> "${ROOTFS}/etc/skel/.zshrc.tmp"
mv "${ROOTFS}/etc/skel/.zshrc.tmp" "${ROOTFS}/etc/skel/.zshrc"

# 9. System configuration
echo "Configuring system..."

# Locale
echo "en_US.UTF-8 UTF-8" > "${ROOTFS}/etc/locale.gen"
arch-chroot "${ROOTFS}" locale-gen
echo "LANG=en_US.UTF-8" > "${ROOTFS}/etc/locale.conf"

# Timezone (UTC, user can change later)
arch-chroot "${ROOTFS}" ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# User + root accounts
arch-chroot "${ROOTFS}" useradd -m -G wheel,video,audio,input -s /usr/bin/zsh nabu
echo "nabu:cachyos" | arch-chroot "${ROOTFS}" chpasswd
echo "root:cachyos" | arch-chroot "${ROOTFS}" chpasswd
# NOTE: Do NOT use chage -d 0 (password expiry breaks GDM auto-login)

# Passwordless sudo for wheel group
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > "${ROOTFS}/etc/sudoers.d/wheel"
chmod 440 "${ROOTFS}/etc/sudoers.d/wheel"

# Copy skel dotfiles to user home (packages install to /etc/skel/)
cp -rn "${ROOTFS}/etc/skel/." "${ROOTFS}/home/nabu/" 2>/dev/null || true

# Convenience scripts permissions
chmod +x "${ROOTFS}/home/nabu/bin/"* 2>/dev/null || true
chown -R 1000:1000 "${ROOTFS}/home/nabu/"

# 10. Enable services
echo "Enabling services..."
arch-chroot "${ROOTFS}" systemctl enable NetworkManager
arch-chroot "${ROOTFS}" systemctl enable sshd
arch-chroot "${ROOTFS}" systemctl enable gdm
arch-chroot "${ROOTFS}" systemctl enable bluetooth
arch-chroot "${ROOTFS}" systemctl enable systemd-zram-setup@zram0.service
arch-chroot "${ROOTFS}" systemctl enable cpu-performance.service
# USB serial gadget for debugging
arch-chroot "${ROOTFS}" systemctl enable usb-serial-gadget.service 2>/dev/null || true
# Disable heavy/unnecessary services for tablet use
arch-chroot "${ROOTFS}" systemctl disable man-db.timer 2>/dev/null || true
arch-chroot "${ROOTFS}" systemctl mask ldconfig.service 2>/dev/null || true

# --- Live-debugging fixes (discovered during first boot) ---

# 10a. Replace dbus-broker with dbus-daemon
# dbus.service is a SYMLINK to dbus-broker.service — rm it and write a real unit file
echo "Replacing dbus-broker with dbus-daemon..."
rm -f "${ROOTFS}/usr/lib/systemd/system/dbus.service"
cat > "${ROOTFS}/usr/lib/systemd/system/dbus.service" << 'DBUSEOF'
[Unit]
Description=D-Bus System Message Bus
Documentation=man:dbus-daemon(1)
Requires=dbus.socket
DefaultDependencies=no
Wants=sysinit.target
After=sysinit.target basic.target

[Service]
Type=notify
NotifyAccess=main
ExecStart=@/usr/bin/dbus-daemon @dbus-daemon --system --address=systemd: --nofork --nopidfile --systemd-activation --syslog-only
ExecReload=/usr/bin/dbus-send --print-reply --system --type=method_call --dest=org.freedesktop.DBus / org.freedesktop.DBus.ReloadConfig
OOMScoreAdjust=-900
User=messagebus
Group=messagebus
AmbientCapabilities=CAP_AUDIT_WRITE
DBUSEOF
# Mask dbus-broker so it never starts
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/dbus-broker.service"
# Ensure messagebus user exists
arch-chroot "${ROOTFS}" getent passwd messagebus >/dev/null 2>&1 || \
    arch-chroot "${ROOTFS}" useradd -r -s /usr/bin/nologin -d / messagebus

# 10b. NetworkManager sandbox drop-in (kernel doesn't support sandboxing)
echo "Adding NetworkManager no-sandbox drop-in..."
mkdir -p "${ROOTFS}/etc/systemd/system/NetworkManager.service.d"
cat > "${ROOTFS}/etc/systemd/system/NetworkManager.service.d/no-sandbox.conf" << 'NMSDEOF'
[Service]
ProtectSystem=no
ProtectHome=no
PrivateTmp=no
PrivateDevices=no
RestrictNamespaces=no
NMSDEOF

# 10c. Install Qualcomm userspace services (qrtr-ns, rmtfs, tqftpserv)
# These binaries are bundled in the repo (extracted from TheMojoMan's Ubuntu image)
echo "Installing Qualcomm userspace services..."
QCOM_DIR="${SCRIPT_DIR}/qualcomm-binaries"
if [ -d "${QCOM_DIR}" ]; then
    for bin in rmtfs tqftpserv qrtr-ns; do
        install -Dm755 "${QCOM_DIR}/${bin}" "${ROOTFS}/usr/bin/${bin}"
        echo "  Installed ${bin}"
    done
    cp -a "${QCOM_DIR}"/libqrtr* "${ROOTFS}/usr/lib/" 2>/dev/null
    # Create proper symlink for libqrtr.so.1
    cd "${ROOTFS}/usr/lib" && ln -sf libqrtr.so.1.1 libqrtr.so.1 2>/dev/null || true
    cd /build
    echo "  Qualcomm binaries installed from repo"
else
    echo "  ERROR: ${QCOM_DIR} not found! WiFi will NOT work."
    echo "  Run: extract Qualcomm binaries from Ubuntu nabu image"
fi

# Create systemd services for Qualcomm daemons (WITHOUT sandboxing)
cat > "${ROOTFS}/usr/lib/systemd/system/qrtr-ns.service" << 'QRTREOF'
[Unit]
Description=QRTR Name Service
DefaultDependencies=no
Before=basic.target
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/bin/qrtr-ns -f 1
Restart=always

[Install]
WantedBy=multi-user.target
QRTREOF

cat > "${ROOTFS}/usr/lib/systemd/system/rmtfs.service" << 'RMTFSEOF'
[Unit]
Description=Qualcomm Remote Filesystem Service
Requires=qrtr-ns.service
After=qrtr-ns.service

[Service]
Type=simple
ExecStart=/usr/bin/rmtfs -r -P -s
Restart=always

[Install]
WantedBy=multi-user.target
RMTFSEOF

cat > "${ROOTFS}/usr/lib/systemd/system/tqftpserv.service" << 'TQFTPEOF'
[Unit]
Description=Qualcomm TFTP Service
Requires=qrtr-ns.service
After=qrtr-ns.service

[Service]
Type=simple
ExecStart=/usr/bin/tqftpserv
Restart=always

[Install]
WantedBy=multi-user.target
TQFTPEOF

arch-chroot "${ROOTFS}" systemctl enable qrtr-ns.service
arch-chroot "${ROOTFS}" systemctl enable rmtfs.service
arch-chroot "${ROOTFS}" systemctl enable tqftpserv.service

# 10d. Mask efi.mount (we handle ESP mounting via fstab)
echo "Masking efi.mount..."
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/efi.mount"

# 10e. GPU firmware symlink (adreno needs this at /usr/lib/firmware/a630_sqe.fw)
echo "Creating GPU firmware symlink..."
ln -sf qcom/a630_sqe.fw "${ROOTFS}/usr/lib/firmware/a630_sqe.fw"

# 10f. SSH root login
echo "Enabling SSH root login..."
mkdir -p "${ROOTFS}/etc/ssh/sshd_config.d"
echo "PermitRootLogin yes" > "${ROOTFS}/etc/ssh/sshd_config.d/root.conf"

# --- End live-debugging fixes ---

# 11. Generate initramfs (non-fatal: warnings about autodetect/microcode are expected in chroot)
echo "Generating initramfs..."
arch-chroot "${ROOTFS}" mkinitcpio -p nabu-cachyos || {
    echo "WARNING: mkinitcpio had errors but initramfs may still be usable"
    ls -la "${ROOTFS}/boot/efi/initramfs-"* 2>/dev/null || echo "  No initramfs found!"
}

# 12. fstab (ext4 root, FAT32 ESP)
cat > "${ROOTFS}/etc/fstab" << 'FSTAB'
# CachyOS Nabu fstab
PARTLABEL=linux  /           ext4   rw,noatime,discard  0 1
PARTLABEL=esp    /boot/efi   vfat   defaults             0 2
FSTAB

# 13. Leave rootfs in container-local path for build-image.sh to consume
# (Don't copy to bind mount — macOS Docker volumes can't handle Linux permissions)
umount "${ROOTFS}" 2>/dev/null || true
echo "--- Rootfs build complete ---"
echo "  Root: ${ROOTFS}"
du -sh "${ROOTFS}"
