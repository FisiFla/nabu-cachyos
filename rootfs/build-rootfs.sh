#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Build rootfs in container-local filesystem (not bind mount) to avoid
# macOS Docker volume lock issues with pacman, then copy to output.
ROOTFS="/tmp/rootfs-build"
KERNEL_DIR="/build/output/kernel"
FIRMWARE_DIR="/build/output/firmware/nabu-firmware"
SLPI_BUNDLE_DIR="/build/output/firmware/slpi-bundle"

echo "--- Building rootfs ---"

# 1. Bootstrap Arch ARM (cached: skip pacstrap if cache tarball exists)
PACSTRAP_CACHE="/build/.cache/pacstrap-rootfs.tar"
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"
# Bind-mount to make it a mount point (arch-chroot requires this)
mount --bind "${ROOTFS}" "${ROOTFS}"
trap 'umount "${ROOTFS}" 2>/dev/null || true' EXIT

if [ -f "${PACSTRAP_CACHE}" ]; then
    echo "Restoring cached pacstrap rootfs..."
    tar xf "${PACSTRAP_CACHE}" -C "${ROOTFS}"
else
    echo "Bootstrapping Arch Linux ARM (first run, will be cached)..."
    rm -f /var/lib/pacman/db.lck 2>/dev/null || true
    mapfile -t packages < <(grep -vE '^(#|$)' "${SCRIPT_DIR}/packages.txt")
    pacstrap -C "${SCRIPT_DIR}/pacman-alarm.conf" -K "${ROOTFS}" "${packages[@]}"
    # Disable Landlock sandbox in rootfs pacman (fails inside Docker)
    sed -i '/^\[options\]/a DisableSandbox' "${ROOTFS}/etc/pacman.conf"
    # Cache for next run
    echo "Caching pacstrap rootfs for future builds..."
    mkdir -p "$(dirname "${PACSTRAP_CACHE}")"
    tar cf "${PACSTRAP_CACHE}" -C "${ROOTFS}" . || echo "WARNING: cache tar failed (non-fatal)"
fi

# 2. Install kernel artifacts under /boot/efi/ on the rootfs.
# This is a plain directory on the ext4 root — there is no ESP at runtime
# (see the commented fstab line below) and no GRUB. The path matches
# mkinitcpio-nabu.preset so mkinitcpio writes the initramfs to the same place.
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
# nabu-firmware repo has flat files but the kernel expects device-specific paths
echo "Installing firmware..."
cp -a "${FIRMWARE_DIR}"/* "${ROOTFS}/usr/lib/firmware/" 2>/dev/null || true

# Device-specific firmware: kernel looks for qcom/sm8150/xiaomi/nabu/<file>
mkdir -p "${ROOTFS}/usr/lib/firmware/qcom/sm8150/xiaomi/nabu"
for fw in modem.mbn adsp.mbn cdsp.mbn venus.mbn modemuw.jsn wlanmdsp.mbn a640_zap.mbn; do
    cp -f "${FIRMWARE_DIR}/${fw}" "${ROOTFS}/usr/lib/firmware/qcom/sm8150/xiaomi/nabu/" 2>/dev/null || true
done

# NAS-218: SLPI firmware (loaded by remoteproc once enable-slpi.sh has flipped
# the DT node to status="okay"). Comes from postmarketOS bundle, not map220v.
if [ -f "${SLPI_BUNDLE_DIR}/slpi_nb.mbn" ]; then
    cp -f "${SLPI_BUNDLE_DIR}/slpi_nb.mbn" \
        "${ROOTFS}/usr/lib/firmware/qcom/sm8150/xiaomi/nabu/slpi_nb.mbn"
    echo "  Installed slpi_nb.mbn (Sensor Low-Power Island firmware)"
else
    echo "WARNING: ${SLPI_BUNDLE_DIR}/slpi_nb.mbn missing — sensors will not work."
fi

# NAS-218: Hexagonfs config tree the SLPI firmware fetches via FastRPC reverse
# tunnel. Path layout matches postmarketOS convention
# (`/usr/share/qcom/<soc>/<vendor>/<device>/`) — hexagonrpcd is invoked with
# `-R /usr/share/qcom/sm8150/xiaomi/nabu` by a drop-in below. Tree includes
# sensor-config JSONs for LSM6DSO accel/gyro, AK991x magnetometer, BU27030
# ambient light, ADUX1050 proximity, TCS3701 RGB+IR, and 20+ virtual sensors
# (orient/tilt/AOD/etc.).
if [ -d "${SLPI_BUNDLE_DIR}/hexagonfs" ]; then
    mkdir -p "${ROOTFS}/usr/share/qcom/sm8150/xiaomi/nabu"
    cp -a "${SLPI_BUNDLE_DIR}/hexagonfs/." "${ROOTFS}/usr/share/qcom/sm8150/xiaomi/nabu/"
    echo "  Installed hexagonfs tree ($(find "${SLPI_BUNDLE_DIR}/hexagonfs" -type f | wc -l | tr -d ' ') files)"
fi

# Generic GPU firmware paths used by drm/msm and Mesa
mkdir -p "${ROOTFS}/usr/lib/firmware/qcom"
for fw in a630_sqe.fw a640_gmu.bin a640_zap.mbn; do
    cp -f "${FIRMWARE_DIR}/${fw}" "${ROOTFS}/usr/lib/firmware/qcom/" 2>/dev/null || true
done

# Touch firmware: driver looks for novatek/novatek_nt36523_fw.bin but the
# nabu-firmware repo ships it at the flat path. Symlink (mirrors the live fix
# applied during NAS-228 debug — kept as symlink so any future blob refresh
# at the flat path is picked up automatically).
mkdir -p "${ROOTFS}/usr/lib/firmware/novatek"
ln -sf ../novatek_nt36523_fw.bin \
    "${ROOTFS}/usr/lib/firmware/novatek/novatek_nt36523_fw.bin"

# Audio codec firmware: cs35l41 files need to be under cirrus/
mkdir -p "${ROOTFS}/usr/lib/firmware/cirrus"
cp -f "${FIRMWARE_DIR}"/*cs35l41* "${ROOTFS}/usr/lib/firmware/cirrus/" 2>/dev/null || true

# Mountpoint for the device's factory persist partition (NAS-218 auto-rotation).
# The actual mount is in /etc/fstab below; this just creates the empty target so
# fstab's nofail can find it. Without /persist/sensors/registry/sns.reg the
# ADSP SSC firmware has no calibration data for the LSM6DSO and iio-sensor-proxy
# stays silent — auto-rotate fails closed without affecting anything else.
mkdir -p "${ROOTFS}/persist"

# 4. Copy overlay configs
echo "Applying overlay configs..."
cp -a "${SCRIPT_DIR}/overlay/"* "${ROOTFS}/"

# 5. Write WiFi connection file (only if credentials provided)
if [ -n "${WIFI_SSID}" ] && [ -n "${WIFI_PASSWORD}" ]; then
    echo "Configuring WiFi (${WIFI_SSID})..."
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
else
    echo "No WiFi credentials provided — user will connect via GNOME Settings."
fi

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
mapfile -t aur_packages < <(grep -vE '^(#|$)' "${SCRIPT_DIR}/packages-aur.txt")
for pkg in "${aur_packages[@]}"; do
    echo "  Building ${pkg} from AUR..."
    if [ -d "${AUR_BUILD:?}/${pkg:?}" ]; then
        rm -rf "${AUR_BUILD:?}/${pkg:?}"
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

for tool in cachyos-settings cachyos-alacritty-config cachyos-zsh-config cachyos-packageinstaller; do
    echo "  Building ${tool}..."
    cd "${TOOLS_BUILD}/CachyOS-PKGBUILDS/${tool}"
    sudo -u builder makepkg -f --noconfirm --nodeps --skipinteg 2>&1 || {
        echo "    WARNING: ${tool} failed, skipping"
        continue
    }
    pkg=$(ls -1 *.pkg.tar* 2>/dev/null | head -1)
    if [ -n "${pkg}" ]; then
        # Double --nodeps (-dd): skip dep *name* checks too, not just versions.
        # See the matching comment in build-theming.sh for the rationale.
        pacman -U --noconfirm --nodeps --nodeps --root "${ROOTFS}" --dbpath "${ROOTFS}/var/lib/pacman" \
            "${TOOLS_BUILD}/CachyOS-PKGBUILDS/${tool}/${pkg}"
        echo "    Installed ${pkg}"
    fi
done

# 8c. Install zsh plugins required by cachyos-zsh-config (not in ALARM repos)
echo "Installing zsh plugins..."
git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "${ROOTFS}/usr/share/oh-my-zsh" 2>/dev/null || true
rm -rf "${ROOTFS}/usr/share/oh-my-zsh/.git" 2>/dev/null || true
git clone --depth 1 https://github.com/romkatv/powerlevel10k.git "${ROOTFS}/usr/share/zsh-theme-powerlevel10k" 2>/dev/null || true
rm -rf "${ROOTFS}/usr/share/zsh-theme-powerlevel10k/.git" 2>/dev/null || true
git clone --depth 1 https://github.com/zsh-users/zsh-history-substring-search.git "${ROOTFS}/usr/share/zsh/plugins/zsh-history-substring-search" 2>/dev/null || true
rm -rf "${ROOTFS}/usr/share/zsh/plugins/zsh-history-substring-search/.git" 2>/dev/null || true

# .zshrc and .p10k.zsh come from rootfs/overlay/home/nabu/ (copied at line 92).
# That overlay is the single source of truth — do not re-write them here.

# 9. System configuration
echo "Configuring system..."

# Locale
echo "en_US.UTF-8 UTF-8" > "${ROOTFS}/etc/locale.gen"
arch-chroot "${ROOTFS}" locale-gen
echo "LANG=en_US.UTF-8" > "${ROOTFS}/etc/locale.conf"

# Timezone (UTC, user can change later)
arch-chroot "${ROOTFS}" ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# User + root accounts
# nabu is the daily-driver account. By default it ships with NO password —
# this is a tablet, not a multi-user server. The user opts IN to a password
# via gnome-control-center (nabu-welcome links there) or `passwd`. Empty
# passwords are still rejected by PAM (no `nullok` set), so accidental
# password-bypass login isn't possible — sudo just doesn't prompt, and SSH
# requires keys.
arch-chroot "${ROOTFS}" useradd -m -G wheel,video,audio,input -s /usr/bin/zsh nabu
arch-chroot "${ROOTFS}" passwd -d nabu
arch-chroot "${ROOTFS}" passwd -d root
# NOTE: Do NOT use chage -d 0 (password expiry breaks GDM auto-login)

# Passwordless sudo for nabu (matches the "no password by default" stance).
# Filename is "zz-nabu-nopasswd" so it sorts last in /etc/sudoers.d/* — sudo
# uses last-matching rule, so anything earlier (e.g. a future "wheel" rule
# requiring a password) is correctly overridden for the nabu user.
# Drop this file if you set a password and want sudo to prompt for it.
echo 'nabu ALL=(ALL) NOPASSWD: ALL' > "${ROOTFS}/etc/sudoers.d/zz-nabu-nopasswd"
chmod 440 "${ROOTFS}/etc/sudoers.d/zz-nabu-nopasswd"
# Intentionally NOT writing /etc/sudoers.d/wheel: nabu is the only account
# in this build, and the explicit nabu rule above covers it. Adding a wheel
# rule that requires a password would override nabu's NOPASSWD because
# sudo applies the last matching entry.

# Copy skel dotfiles to user home (packages install to /etc/skel/)
cp -rn "${ROOTFS}/etc/skel/." "${ROOTFS}/home/nabu/" 2>/dev/null || true

# Convenience scripts permissions
chmod +x "${ROOTFS}/home/nabu/bin/"* 2>/dev/null || true
chown -R 1000:1000 "${ROOTFS}/home/nabu/"

# Enable GNOME accessibility keyboard by default for both the login screen
# and the user session so touch-only first boot stays usable.
mkdir -p "${ROOTFS}/etc/dconf/db/gdm.d" "${ROOTFS}/etc/dconf/db/local.d" "${ROOTFS}/etc/dconf/profile"
cat > "${ROOTFS}/etc/dconf/db/gdm.d/00-a11y" << 'DCONFEOF'
[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=true
DCONFEOF
cp "${ROOTFS}/etc/dconf/db/gdm.d/00-a11y" "${ROOTFS}/etc/dconf/db/local.d/00-a11y"
cat > "${ROOTFS}/etc/dconf/db/local.d/01-gnome-stability" << 'DCONFEOF'
[org/gnome/mutter]
experimental-features=[]
DCONFEOF
cp "${ROOTFS}/etc/dconf/db/local.d/01-gnome-stability" "${ROOTFS}/etc/dconf/db/gdm.d/01-gnome-stability"
cat > "${ROOTFS}/etc/dconf/profile/user" << 'DCONFPROFEOF'
user-db:user
system-db:local
DCONFPROFEOF
cat > "${ROOTFS}/etc/dconf/profile/gdm" << 'DCONFPROFEOF'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
DCONFPROFEOF

# GNOME sometimes ignores the system default on the very first login, so
# enforce it once inside the real user session and then get out of the way.
mkdir -p "${ROOTFS}/usr/local/bin" "${ROOTFS}/etc/xdg/autostart"
cat > "${ROOTFS}/usr/local/bin/enable-default-osk.sh" << 'OSKEOF'
#!/usr/bin/env bash
set -euo pipefail

marker="${XDG_CONFIG_HOME:-${HOME}/.config}/.nabu-osk-initialized"
[ -f "${marker}" ] && exit 0

mkdir -p "$(dirname "${marker}")"

if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true || exit 0
    : > "${marker}"
fi
OSKEOF
chmod 755 "${ROOTFS}/usr/local/bin/enable-default-osk.sh"
cat > "${ROOTFS}/etc/xdg/autostart/nabu-enable-osk.desktop" << 'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Enable Default On-Screen Keyboard
Exec=/usr/local/bin/enable-default-osk.sh
NoDisplay=true
OnlyShowIn=GNOME;
X-GNOME-Autostart-Delay=5
DESKTOPEOF

# 10. Enable services
echo "Enabling services..."
arch-chroot "${ROOTFS}" systemctl enable NetworkManager
arch-chroot "${ROOTFS}" systemctl enable avahi-daemon
arch-chroot "${ROOTFS}" systemctl enable sshd
arch-chroot "${ROOTFS}" systemctl enable gdm
arch-chroot "${ROOTFS}" systemctl enable bluetooth
arch-chroot "${ROOTFS}" systemctl enable systemd-zram-setup@zram0.service
arch-chroot "${ROOTFS}" systemctl enable cpu-performance.service
# NTP at boot — RTC on nabu is unreliable (drifts to 2063 on cold boot), and
# every SSL cert + pacman signature check fails with a wrong clock.
arch-chroot "${ROOTFS}" systemctl enable systemd-timesyncd.service
# Mark current A/B slot as successfully booted (NAS-229) — without this,
# slot-retry-count drains 7→0 across reboots and the bootloader rolls back
# to Android. Binary comes from build-qualcomm.sh.
arch-chroot "${ROOTFS}" systemctl enable qbootctl-mark-success.service 2>/dev/null || true
# USB serial gadget for debugging
arch-chroot "${ROOTFS}" systemctl enable usb-serial-gadget.service 2>/dev/null || true
# ananicy-cpp ships inside cachyos-settings; enable best-effort in case that install ever skips
arch-chroot "${ROOTFS}" systemctl enable ananicy-cpp.service 2>/dev/null || true
# Auto-rotation full sensor stack (NAS-218).
# Chain (boot order):
#   1. local-fs.target mounts /persist (factory sns.reg calibrations)
#   2. remoteproc autoloads SLPI from /usr/lib/firmware/.../slpi_nb.mbn
#      (DT enable-slpi.sh flipped the node to status="okay")
#   3. /dev/fastrpc-adsp appears
#   4. hexagonrpcd-adsp-rootpd.service starts (root process domain)
#   5. hexagonrpcd-adsp-sensorspd.service starts (sensors PD; serves the
#      hexagonfs/ tree to SLPI over FastRPC reverse tunnel)
#   6. SLPI firmware reads sensor configs (lsm6dso/akm/bu27030/etc) +
#      sns.reg from /persist, registers Sensor Manager via QRTR
#   7. iio-sensor-proxy starts (after sensorspd), subscribes via libssc,
#      exposes net.hadess.SensorProxy on D-Bus
#   8. GNOME auto-rotates
#
# hexagonrpcd services run as User=fastrpc — create the system user. Using a
# sysusers.d snippet so the user exists at first boot regardless of pacman
# scriptlet ordering.
mkdir -p "${ROOTFS}/usr/lib/sysusers.d"
cat > "${ROOTFS}/usr/lib/sysusers.d/hexagonrpc.conf" << 'SYSUSEOF'
u fastrpc - "Hexagon FastRPC bridge" - /usr/bin/nologin
SYSUSEOF

# Without this udev rule the FastRPC device nodes ship as `crw------- root:root`
# and hexagonrpcd's `User=fastrpc` cannot open them — daemon exits status 4
# (NOPERMISSION) on every restart. Grant the fastrpc group read+write.
mkdir -p "${ROOTFS}/etc/udev/rules.d"
cat > "${ROOTFS}/etc/udev/rules.d/91-fastrpc.rules" << 'UDEVEOF'
KERNEL=="fastrpc-*", GROUP="fastrpc", MODE="0660"
UDEVEOF

# Drop-ins to point each hexagonrpcd unit at the nabu-specific hexagonfs root.
# Without `-R`, the daemon defaults to `/usr/share/qcom/` and won't find the
# JSON sensor configs which we install at the `<soc>/<vendor>/<device>`
# subpath. Each unit has a different upstream ExecStart (different -f device
# + -d domain + optional -s) — preserve those, just append -R.
NABU_HEXAGONFS=/usr/share/qcom/sm8150/xiaomi/nabu

mkdir -p "${ROOTFS}/etc/systemd/system/hexagonrpcd-adsp-rootpd.service.d"
cat > "${ROOTFS}/etc/systemd/system/hexagonrpcd-adsp-rootpd.service.d/nabu-path.conf" << CONFEOF
[Service]
ExecStart=
ExecStart=/usr/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp -R ${NABU_HEXAGONFS}
CONFEOF

mkdir -p "${ROOTFS}/etc/systemd/system/hexagonrpcd-adsp-sensorspd.service.d"
cat > "${ROOTFS}/etc/systemd/system/hexagonrpcd-adsp-sensorspd.service.d/nabu-path.conf" << CONFEOF
[Service]
ExecStart=
ExecStart=/usr/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp -s -R ${NABU_HEXAGONFS}
CONFEOF

mkdir -p "${ROOTFS}/etc/systemd/system/hexagonrpcd-sdsp.service.d"
# NAS-247: use -S sensorspd (INIT_CREATE_STATIC, our patched -S option) NOT
# -s (INIT_ATTACH_SNS). On nabu's SLPI the sensorspd PD doesn't pre-exist;
# we need to CREATE it, not attach to an existing one. The patch lives at
# tools/hexagonrpc-add-create-static.patch and is applied by build-qualcomm.sh.
cat > "${ROOTFS}/etc/systemd/system/hexagonrpcd-sdsp.service.d/nabu-path.conf" << CONFEOF
[Service]
ExecStart=
ExecStart=/usr/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -S sensorspd -R ${NABU_HEXAGONFS}
CONFEOF

# iio-sensor-proxy comes from a package (already installed by pacstrap), so we
# can enable it now. The drop-in below orders it AFTER hexagonrpcd-adsp-sensorspd
# so libssc can find Sensor Manager on QRTR before iio-sensor-proxy probes —
# without the drop-in iio-sensor-proxy races, finds no sensors, and exits.
mkdir -p "${ROOTFS}/etc/systemd/system/iio-sensor-proxy.service.d"
cat > "${ROOTFS}/etc/systemd/system/iio-sensor-proxy.service.d/wait-for-slpi.conf" << 'IIOEOF'
[Unit]
After=hexagonrpcd-adsp-sensorspd.service
Wants=hexagonrpcd-adsp-sensorspd.service
IIOEOF

arch-chroot "${ROOTFS}" systemctl enable iio-sensor-proxy.service 2>/dev/null || true

# NOTE: hexagonrpcd-* services are NOT enabled here. Their unit files are
# installed by build-qualcomm.sh which runs further down (~line 514). Enabling
# them now would silently no-op (unit not found). The actual enable happens
# after build-qualcomm.sh — see the block right after that call.
# Disable heavy/unnecessary services for tablet use
arch-chroot "${ROOTFS}" systemctl disable man-db.timer 2>/dev/null || true
arch-chroot "${ROOTFS}" systemctl mask ldconfig.service 2>/dev/null || true
arch-chroot "${ROOTFS}" dconf update 2>/dev/null || true

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

# 10a-bis. Wire nss-mdns into /etc/nsswitch.conf so the tablet can resolve
# *.local hostnames and other machines on the LAN can resolve nabu-cachyos.local
# in return. The `nss-mdns` package is installed but does nothing on its own —
# glibc only consults it if `mdns_minimal` is on the `hosts:` line. Insert it
# right before `resolve` so systemd-resolved still wins for non-mDNS queries.
# Idempotent: re-running the sed when mdns_minimal is already present is a no-op.
echo "Enabling mDNS resolution in nsswitch.conf..."
if ! grep -q "mdns_minimal" "${ROOTFS}/etc/nsswitch.conf" 2>/dev/null; then
    sed -i -E 's/^(hosts:[[:space:]]*[^[:space:]]+)[[:space:]]+(resolve|dns|files)/\1 mdns_minimal [NOTFOUND=return] \2/' \
        "${ROOTFS}/etc/nsswitch.conf"
    if ! grep -q "mdns_minimal" "${ROOTFS}/etc/nsswitch.conf"; then
        echo "  WARNING: nsswitch.conf hosts: line did not match expected pattern — mDNS will not work."
        echo "  Current line:"
        grep "^hosts:" "${ROOTFS}/etc/nsswitch.conf" | sed 's/^/    /'
    fi
fi

# Advertise SSH over mDNS so `ssh nabu@nabu-cachyos.local` works out of the box.
# Without this file avahi still publishes the hostname A-record (mDNS resolution
# works) but doesn't advertise the _ssh._tcp service — fine for ssh, but the
# explicit service makes the tablet discoverable in Finder/`dns-sd -B _ssh._tcp`.
mkdir -p "${ROOTFS}/etc/avahi/services"
cat > "${ROOTFS}/etc/avahi/services/ssh.service" << 'AVAHISSHEOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h SSH</name>
  <service>
    <type>_ssh._tcp</type>
    <port>22</port>
  </service>
</service-group>
AVAHISSHEOF

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

# 10c. Build and install Qualcomm userspace services from source (BSD-3-Clause)
# qrtr-ns, rmtfs, tqftpserv — required for WiFi on Snapdragon mainline Linux
echo "Building Qualcomm userspace services from source..."
bash "${SCRIPT_DIR}/build-qualcomm.sh" "${ROOTFS}"

# NAS-218: enable hexagonrpcd units NOW (they were just installed by
# build-qualcomm.sh stage 6). Enabling them earlier silently no-op'd because
# the unit files didn't exist yet. All three are enabled; ConditionPathExists
# in the upstream units gates them on /dev/fastrpc-* presence at runtime.
arch-chroot "${ROOTFS}" systemctl enable hexagonrpcd-adsp-rootpd.service 2>/dev/null || true
arch-chroot "${ROOTFS}" systemctl enable hexagonrpcd-adsp-sensorspd.service 2>/dev/null || true
arch-chroot "${ROOTFS}" systemctl enable hexagonrpcd-sdsp.service 2>/dev/null || true

# Create systemd services for Qualcomm daemons
# NOTE: qrtr-ns is NOT needed — kernel 6.14 has in-kernel QRTR name service.
# Userspace qrtr-ns fails with "bind control socket: Address already in use".

cat > "${ROOTFS}/usr/lib/systemd/system/rmtfs.service" << 'RMTFSEOF'
[Unit]
Description=Qualcomm Remote Filesystem Service
After=local-fs.target

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
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/bin/tqftpserv
Restart=always

[Install]
WantedBy=multi-user.target
TQFTPEOF

# Modem remoteproc must start before WiFi can work
cat > "${ROOTFS}/usr/lib/systemd/system/modem-remoteproc.service" << 'MODEMEOF'
[Unit]
Description=Start Qualcomm Modem Remoteproc
DefaultDependencies=no
Before=rmtfs.service tqftpserv.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo start > /sys/class/remoteproc/remoteproc0/state'

[Install]
WantedBy=multi-user.target
MODEMEOF

arch-chroot "${ROOTFS}" systemctl enable modem-remoteproc.service
arch-chroot "${ROOTFS}" systemctl enable rmtfs.service
arch-chroot "${ROOTFS}" systemctl enable tqftpserv.service

# 10d. GPU firmware symlink (adreno needs this at /usr/lib/firmware/a630_sqe.fw)
echo "Creating GPU firmware symlink..."
ln -sf qcom/a630_sqe.fw "${ROOTFS}/usr/lib/firmware/a630_sqe.fw"

# 10e. SSH config (key-based root login only, password login for nabu user)
echo "Configuring SSH..."
mkdir -p "${ROOTFS}/etc/ssh/sshd_config.d"
cat > "${ROOTFS}/etc/ssh/sshd_config.d/nabu.conf" << 'SSHEOF'
PermitRootLogin prohibit-password
PasswordAuthentication yes
SSHEOF

# --- End live-debugging fixes ---

# 11. Generate initramfs (non-fatal: warnings about autodetect/microcode are expected in chroot)
echo "Generating initramfs..."
arch-chroot "${ROOTFS}" mkinitcpio -p nabu-cachyos || {
    echo "WARNING: mkinitcpio had errors but initramfs may still be usable"
    ls -la "${ROOTFS}/boot/efi/initramfs-"* 2>/dev/null || echo "  No initramfs found!"
}

# 12. fstab (ext4 root, FAT32 ESP, factory /persist for sensor calibration)
cat > "${ROOTFS}/etc/fstab" << 'FSTAB'
# CachyOS Nabu fstab
PARTLABEL=linux    /           ext4   rw,noatime,discard           0 1
# ESP commented out: FAT32 sector size incompatible with UFS, causes emergency mode
# PARTLABEL=esp    /boot/efi   vfat   defaults                     0 2
# Factory persist: ext4 on most nabu firmware revisions, but some ship f2fs.
# nofail keeps boot alive on a mismatch — auto-rotation just stops working.
# Re-flash with `fastboot getvar partition-type:persist` to confirm FS-type if
# /persist/sensors/registry/sns.reg never appears after a clean boot.
PARTLABEL=persist  /persist    ext4   ro,nosuid,nodev,nofail       0 0
FSTAB

# 13. Leave rootfs in container-local path for build-image.sh to consume
# (Don't copy to bind mount — macOS Docker volumes can't handle Linux permissions)
umount "${ROOTFS}" 2>/dev/null || true
echo "--- Rootfs build complete ---"
echo "  Root: ${ROOTFS}"
du -sh "${ROOTFS}"
