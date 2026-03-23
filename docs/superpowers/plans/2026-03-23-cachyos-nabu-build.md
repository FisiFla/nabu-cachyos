# CachyOS Nabu Build System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Docker-based system that produces flashable CachyOS-flavored Arch Linux ARM images for the Xiaomi Pad 5 (nabu).

**Architecture:** An aarch64 Docker container (bootstrapped from Arch Linux ARM rootfs tarball) compiles a custom kernel (sm8150-mainline + CachyOS patches), assembles an Arch ARM rootfs with CachyOS theming/tuning, and packages everything into flashable partition images. A separate flash script handles the tablet-side operations.

**Tech Stack:** Docker (aarch64 native on Apple Silicon), Arch Linux ARM, Linux kernel 6.14.11, GRUB arm64-efi, Btrfs, shell scripts.

**Important context:** Read `CLAUDE.md` at the project root for full technical details, design decisions, and repository links. The design spec is at `docs/superpowers/specs/2026-03-23-cachyos-nabu-design.md`.

**Phase separation:** Tasks 1-9 are Phase 1 (build system, no tablet needed). Task 10 is Phase 2 (flashing, needs tablet + USB-C cable). Phase 1 can be completed entirely on a MacBook Pro M4 Pro.

---

## File Structure

```
nabu-cachyos/
├── CLAUDE.md                                    # Project context (exists)
├── Dockerfile                                   # aarch64 ALARM build environment
├── build.sh                                     # Main entry point, sets KERNEL_VERSION
├── kernel/
│   ├── build-kernel.sh                          # Clone, patch, compile kernel
│   ├── cachyos.config                           # CachyOS kernel config fragment
│   └── patches/
│       ├── 0001-bore.patch                      # BORE scheduler v5.9.6
│       ├── 0002-bbr3.patch                      # BBR3 TCP congestion control
│       ├── 0003-adios.patch                     # ADIOS I/O scheduler (extracted)
│       └── 0004-cachy-arm.patch                 # Arch-neutral CachyOS bits (extracted)
├── firmware/
│   └── fetch-firmware.sh                        # Download nabu Qualcomm firmware blobs
├── rootfs/
│   ├── build-rootfs.sh                          # pacstrap + packages + config + theming
│   ├── packages.txt                             # Official ALARM repo packages
│   ├── packages-aur.txt                         # AUR packages (vivaldi-multiarch-bin, maliit)
│   ├── pacman-alarm.conf                        # pacman.conf for ALARM mirrors
│   ├── mkinitcpio-nabu.preset                   # mkinitcpio preset for consistent naming
│   └── overlay/
│       ├── etc/
│       │   ├── sysctl.d/
│       │   │   └── 70-cachyos.conf              # CachyOS sysctl tuning
│       │   ├── systemd/
│       │   │   ├── zram-generator.conf          # ZRAM config
│       │   │   ├── system.conf.d/
│       │   │   │   └── 10-cachyos.conf          # systemd timeout tuning
│       │   │   └── journald.conf.d/
│       │   │       └── 10-cachyos.conf          # Journal size limit
│       │   ├── udev/rules.d/
│       │   │   └── 60-ioschedulers.rules        # I/O scheduler rules
│       │   ├── security/
│       │   │   └── limits.d/
│       │   │       └── 10-cachyos.conf          # File limits
│       │   ├── NetworkManager/
│       │   │   └── system-connections/
│       │   │       └── wifi.nmconnection        # Pre-configured WiFi (SSID/password filled at build time)
│       │   ├── sddm.conf.d/
│       │   │   └── 10-autologin.conf            # SDDM auto-login config
│       │   └── hostname                         # "nabu-cachyos"
│       ├── home/nabu/
│       │   ├── .config/                         # KDE Plasma tablet configs (from cachyos-kde-settings + overrides)
│       │   └── bin/
│       │       ├── snapshot                     # Btrfs snapshot helper
│       │       ├── rollback                     # Btrfs rollback helper
│       │       └── install-containers           # Optional docker/podman installer
│       └── usr/lib/
│           └── systemd/
│               └── user/
│                   └── maliit-server.service     # On-screen keyboard autostart
├── recovery/
│   └── build-recovery.sh                        # Build minimal recovery initramfs
├── image/
│   ├── build-image.sh                           # Assemble ESP + rootfs images
│   ├── grub.cfg.template                        # GRUB config template (KERNEL_VERSION substitution)
│   └── flash.sh                                 # Flash script (Phase 2, needs tablet)
├── output/                                      # Build artifacts (gitignored)
│   ├── boot.img
│   ├── recovery.img
│   ├── esp.img
│   └── linux.img.zst
└── docs/
    └── superpowers/
        ├── specs/
        │   └── 2026-03-23-cachyos-nabu-design.md  # Design spec (exists)
        └── plans/
            └── 2026-03-23-cachyos-nabu-build.md    # This plan
```

---

## Phase 1: Build System (no tablet needed)

### Task 1: Project scaffolding and Docker environment

**Files:**
- Create: `Dockerfile`
- Create: `build.sh`
- Create: `.gitignore`

This task sets up the aarch64 Arch Linux ARM Docker container that all other tasks run inside. The Dockerfile bootstraps from the ALARM rootfs tarball since no official aarch64 Docker image exists.

- [ ] **Step 1: Create .gitignore**

```gitignore
output/
*.img
*.img.zst
*.tar.gz
.DS_Store
```

- [ ] **Step 2: Create the Dockerfile**

The Dockerfile must:
1. Start `FROM scratch` and ADD the ALARM aarch64 rootfs tarball
2. Initialize pacman keyring (`pacman-key --init && pacman-key --populate archlinuxarm`)
3. Run full system upgrade (`pacman -Syu --noconfirm`)
4. Install all build dependencies: `base-devel bc bison flex dtc grub dosfstools btrfs-progs mtools arch-install-scripts mkinitcpio git wget zstd parted`
5. Create a non-root build user `builder` (needed for `makepkg` which refuses to run as root)

```dockerfile
FROM scratch
ADD ArchLinuxARM-aarch64-latest.tar.gz /

RUN pacman-key --init && pacman-key --populate archlinuxarm

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
    base-devel bc bison flex dtc grub dosfstools btrfs-progs \
    mtools arch-install-scripts mkinitcpio git wget zstd parted \
    cpio android-tools

# Create non-root user for makepkg
RUN useradd -m builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR /build
```

- [ ] **Step 3: Create build.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KERNEL_VERSION="${KERNEL_VERSION:-6.14.11}"
export WIFI_SSID="${WIFI_SSID:?Error: set WIFI_SSID environment variable}"
export WIFI_PASSWORD="${WIFI_PASSWORD:?Error: set WIFI_PASSWORD environment variable}"

echo "=== CachyOS Nabu Builder ==="
echo "Kernel version: ${KERNEL_VERSION}"
echo ""

# Step 1: Download ALARM rootfs tarball if not present
ALARM_TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"
if [ ! -f "${SCRIPT_DIR}/${ALARM_TARBALL}" ]; then
    echo "[1/6] Downloading Arch Linux ARM rootfs tarball..."
    wget -O "${SCRIPT_DIR}/${ALARM_TARBALL}" \
        "http://os.archlinuxarm.org/os/${ALARM_TARBALL}"
else
    echo "[1/6] ALARM tarball already present, skipping download."
fi

# Step 2: Build Docker image
echo "[2/6] Building Docker image..."
docker build -t nabu-cachyos-builder "${SCRIPT_DIR}"

# Step 3: Run build inside Docker
echo "[3/6] Starting build inside Docker container..."
docker run --rm --privileged \
    -v "${SCRIPT_DIR}:/build" \
    -e KERNEL_VERSION="${KERNEL_VERSION}" \
    -e WIFI_SSID="${WIFI_SSID}" \
    -e WIFI_PASSWORD="${WIFI_PASSWORD}" \
    nabu-cachyos-builder \
    /bin/bash -c "
        set -euo pipefail
        cd /build
        echo '[3/8] Fetching firmware...'
        bash firmware/fetch-firmware.sh
        echo '[4/8] Building kernel...'
        bash kernel/build-kernel.sh
        echo '[5/8] Building rootfs...'
        bash rootfs/build-rootfs.sh
        echo '[6/8] Building images...'
        bash image/build-image.sh
        echo '[7/8] Building recovery...'
        bash recovery/build-recovery.sh
    "

echo "[8/8] Done."

echo ""
echo "=== Build complete! ==="
echo "Artifacts in output/:"
ls -lh "${SCRIPT_DIR}/output/"
echo ""
echo "To flash (when tablet is connected):"
echo "  bash image/flash.sh"
```

- [ ] **Step 4: Make build.sh executable and test Docker build**

Run:
```bash
chmod +x build.sh
docker build -t nabu-cachyos-builder .
```

Expected: Docker image builds successfully. It will take a few minutes to download the ALARM tarball and install packages.

- [ ] **Step 5: Verify the Docker environment is aarch64**

Run:
```bash
docker run --rm nabu-cachyos-builder uname -m
```

Expected: `aarch64` (NOT `x86_64`). On an M4 Pro this runs natively.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile build.sh .gitignore
git commit -m "feat: add Docker build environment and main entry point

Bootstraps aarch64 Arch Linux ARM container from rootfs tarball.
Runs natively on Apple Silicon, no emulation needed."
```

---

### Task 2: Kernel patch preparation

**Files:**
- Create: `kernel/patches/0001-bore.patch`
- Create: `kernel/patches/0002-bbr3.patch`
- Create: `kernel/patches/0003-adios.patch`
- Create: `kernel/patches/0004-cachy-arm.patch`
- Create: `kernel/cachyos.config`

This task downloads and prepares the CachyOS kernel patches. The BORE and BBR3 patches are used as-is. The ADIOS and cachy-arm patches must be extracted from the larger `0005-cachy.patch` since it contains x86-specific code we can't use.

- [ ] **Step 1: Download BORE patch**

Run inside the project directory:
```bash
mkdir -p kernel/patches
wget -O kernel/patches/0001-bore.patch \
    "https://raw.githubusercontent.com/CachyOS/kernel-patches/master/6.14/sched/0001-bore.patch"
```

Expected: File downloaded, ~686 lines. Verify it modifies `kernel/sched/` files (architecture-neutral).

- [ ] **Step 2: Download BBR3 patch**

```bash
wget -O kernel/patches/0002-bbr3.patch \
    "https://raw.githubusercontent.com/CachyOS/kernel-patches/master/6.14/0004-bbr3.patch"
```

Expected: File downloaded, ~2231 lines in `net/ipv4/tcp_bbr.c`.

- [ ] **Step 3: Download the full cachy patch and extract ADIOS**

```bash
wget -O /tmp/0005-cachy-full.patch \
    "https://raw.githubusercontent.com/CachyOS/kernel-patches/master/6.14/0005-cachy.patch"
```

Now extract ONLY the ADIOS I/O scheduler portions. ADIOS lives in `block/adios.c` and its Kconfig/Makefile changes in `block/`. Use `filterdiff` (from `patchutils`) or manually extract the hunks that touch:
- `block/Kconfig.iosched` (ADIOS Kconfig entry)
- `block/Makefile` (ADIOS build rule)
- `block/adios.c` (the scheduler implementation, ~1339 lines)

Save as `kernel/patches/0003-adios.patch`.

- [ ] **Step 4: Extract arch-neutral bits from cachy patch**

From the same `/tmp/0005-cachy-full.patch`, extract hunks that touch these arch-neutral areas:
- `kernel/Kconfig.hz` (additional HZ options: 100/250/500/600/750/1000)
- `init/Kconfig` (PREEMPT_LAZY option)
- `mm/` files (THP/vmpressure/vmscan/compaction tuning Kconfig)
- `drivers/media/v4l2-core/` and `drivers/media/v4l2loopback/` (v4l2loopback)

Exclude ALL hunks touching `arch/x86/`, `drivers/cpufreq/amd*`, `crypto/`, `drivers/platform/x86/`.

Save as `kernel/patches/0004-cachy-arm.patch`.

**Important:** If extracting individual hunks is too fragile, an alternative approach: apply the full `0005-cachy.patch` with `git apply --include='block/*' --include='kernel/Kconfig.hz' --include='init/Kconfig' --include='mm/*' --include='drivers/media/*'` to filter only the paths we want. Test this approach in the Docker container.

- [ ] **Step 5: Create cachyos.config fragment**

Create `kernel/cachyos.config`:
```kconfig
# BORE scheduler
CONFIG_SCHED_BORE=y

# sched-ext (already in mainline 6.14)
CONFIG_SCHED_CLASS_EXT=y

# 1000Hz timer for touch responsiveness
CONFIG_HZ_1000=y
CONFIG_HZ=1000

# Full preemption
CONFIG_PREEMPT=y
CONFIG_PREEMPT_BUILD=y
CONFIG_PREEMPT_COUNT=y

# BBR3 TCP default
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"

# ADIOS I/O scheduler
CONFIG_MQ_IOSCHED_ADIOS=y

# Btrfs
CONFIG_BTRFS_FS=y
CONFIG_BTRFS_FS_POSIX_ACL=y

# ZRAM + zstd
CONFIG_ZRAM=y
CONFIG_ZRAM_DEF_COMP_ZSTD=y
CONFIG_ZSTD_COMPRESS=y

# THP always
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y

# v4l2loopback
CONFIG_V4L2_LOOPBACK=m

# Tickless + high-res timers
CONFIG_NO_HZ_FULL=y
CONFIG_HIGH_RES_TIMERS=y

# Container support (optional docker/podman)
CONFIG_CGROUP_V2=y
CONFIG_OVERLAY_FS=y
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_IP_NF_NAT=y
```

- [ ] **Step 6: Verify patches are clean**

Run inside Docker:
```bash
docker run --rm -v "$(pwd):/build" nabu-cachyos-builder bash -c "
    cd /tmp
    git clone --depth 1 --branch sm8150/6.14.11 https://gitlab.com/sm8150-mainline/linux.git
    cd linux
    for p in /build/kernel/patches/*.patch; do
        echo \"Checking \$(basename \$p)...\"
        git apply --check \"\$p\" && echo '  OK' || echo '  FAILED'
    done
"
```

Expected: All patches report OK. If any fail, the patch needs adjustment (likely context conflicts with the sm8150 tree).

- [ ] **Step 7: Commit**

```bash
git add kernel/
git commit -m "feat: add CachyOS kernel patches and config fragment

BORE v5.9.6 scheduler, BBR3 TCP, ADIOS I/O scheduler, and
arch-neutral CachyOS tuning (HZ options, v4l2loopback, THP).
All x86-specific patches excluded."
```

---

### Task 3: Kernel build script

**Files:**
- Create: `kernel/build-kernel.sh`

- [ ] **Step 1: Write the kernel build script**

```bash
#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/tmp/kernel-build"
OUTPUT_DIR="/build/output/kernel"

mkdir -p "${OUTPUT_DIR}"

echo "--- Kernel Build: sm8150/${KERNEL_VERSION} ---"

# Clone kernel source
if [ ! -d "${BUILD_DIR}/linux" ]; then
    echo "Cloning kernel source..."
    git clone --depth 1 --branch "sm8150/${KERNEL_VERSION}" \
        https://gitlab.com/sm8150-mainline/linux.git "${BUILD_DIR}/linux"
fi

cd "${BUILD_DIR}/linux"

# Apply CachyOS patches
echo "Applying patches..."
for patch in "${SCRIPT_DIR}/patches/"*.patch; do
    patchname="$(basename "${patch}")"
    echo "  Applying ${patchname}..."
    if ! git apply --check "${patch}" 2>/dev/null; then
        echo "  ERROR: ${patchname} does not apply cleanly!"
        echo "  Attempting with --3way merge..."
        git apply --3way "${patch}" || {
            echo "  FATAL: ${patchname} failed to apply. Aborting."
            exit 1
        }
    else
        git apply "${patch}"
    fi
done

# Build config: defconfig + sm8150 fragment + cachyos fragment
# Note: sm8150.config is a fragment at arch/arm64/configs/sm8150.config, NOT a defconfig target.
# We must use merge_config.sh to layer it on top of defconfig.
echo "Configuring kernel..."
make ARCH=arm64 defconfig
scripts/kconfig/merge_config.sh -m .config \
    arch/arm64/configs/sm8150.config \
    "${SCRIPT_DIR}/cachyos.config"
make ARCH=arm64 olddefconfig

# Compile
echo "Compiling kernel (this takes ~15 minutes)..."
make -j"$(nproc)" ARCH=arm64 Image.gz dtbs modules

# Collect artifacts
echo "Collecting build artifacts..."
cp arch/arm64/boot/Image.gz "${OUTPUT_DIR}/"
cp arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dtb "${OUTPUT_DIR}/"
make ARCH=arm64 modules_install INSTALL_MOD_PATH="${OUTPUT_DIR}/modules"

echo "--- Kernel build complete ---"
echo "  Image: ${OUTPUT_DIR}/Image.gz"
echo "  DTB:   ${OUTPUT_DIR}/sm8150-xiaomi-nabu.dtb"
echo "  Modules: ${OUTPUT_DIR}/modules/"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x kernel/build-kernel.sh
```

- [ ] **Step 3: Test kernel build in Docker**

Run (this will take ~15 minutes):
```bash
docker run --rm --privileged \
    -v "$(pwd):/build" \
    -e KERNEL_VERSION=6.14.11 \
    nabu-cachyos-builder \
    bash /build/kernel/build-kernel.sh
```

Expected: Kernel compiles successfully. `output/kernel/Image.gz`, `output/kernel/sm8150-xiaomi-nabu.dtb`, and `output/kernel/modules/` are created. Check the build output for any warnings about missing CONFIG options from cachyos.config.

- [ ] **Step 4: Verify CachyOS configs are applied**

```bash
docker run --rm -v "$(pwd):/build" nabu-cachyos-builder bash -c "
    cd /tmp/kernel-build/linux
    grep CONFIG_SCHED_BORE .config
    grep CONFIG_HZ= .config
    grep CONFIG_TCP_CONG_BBR .config
    grep CONFIG_MQ_IOSCHED_ADIOS .config
    grep CONFIG_BTRFS_FS .config
    grep CONFIG_ZRAM .config
"
```

Expected: All configs show `=y` or `=m` as specified. If any show `is not set`, investigate whether the Kconfig option exists (patches may need adjustment).

- [ ] **Step 5: Commit**

```bash
git add kernel/build-kernel.sh
git commit -m "feat: add kernel build script

Clones sm8150-mainline, applies CachyOS patches with validation,
merges defconfig + sm8150.config + cachyos.config, compiles kernel."
```

---

### Task 4: Firmware fetcher

**Files:**
- Create: `firmware/fetch-firmware.sh`

- [ ] **Step 1: Write the firmware fetch script**

```bash
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
```

- [ ] **Step 2: Make executable and test**

```bash
chmod +x firmware/fetch-firmware.sh
docker run --rm -v "$(pwd):/build" nabu-cachyos-builder bash /build/firmware/fetch-firmware.sh
```

Expected: Firmware repo cloned to `output/firmware/nabu-firmware/`. Should contain directories like `qcom/`, `ath11k/`, etc.

- [ ] **Step 3: Commit**

```bash
git add firmware/
git commit -m "feat: add firmware fetcher for nabu Qualcomm blobs

Downloads WiFi, GPU, Bluetooth, audio firmware from map220v/nabu-firmware.
These are not upstreamed in linux-firmware."
```

---

### Task 5: Rootfs overlay files (CachyOS tuning + tablet config)

**Files:**
- Create: all files under `rootfs/overlay/`
- Create: `rootfs/packages.txt`
- Create: `rootfs/packages-aur.txt`
- Create: `rootfs/pacman-alarm.conf`
- Create: `rootfs/mkinitcpio-nabu.preset`

- [ ] **Step 1: Create pacman-alarm.conf**

```ini
[options]
HoldPkg     = pacman glibc
Architecture = aarch64
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[extra]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[alarm]
Server = http://mirror.archlinuxarm.org/$arch/$repo
```

Note: There is no `[aur]` repository on ALARM mirrors. AUR packages are built from source in `build-rootfs.sh`.

- [ ] **Step 2: Create packages.txt**

```
base
base-devel
linux-firmware
networkmanager
bluez
bluez-utils
sudo
openssh
btrfs-progs
zram-generator
iwd
gettext
wget
curl
git
vim
nano
htop
btop
fastfetch
man-db
man-pages
zsh
fish
plasma-desktop
plasma-nm
plasma-pa
plasma-systemmonitor
sddm
sddm-kcm
bluedevil
powerdevil
kscreen
dolphin
kate
konsole
ark
spectacle
gwenview
kcalc
kinfocenter
filelight
kdegraphics-thumbnailers
ffmpegthumbs
kde-gtk-config
phonon-qt6-vlc
breeze-gtk
kdeplasma-addons
kdeconnect
iio-sensor-proxy
xdg-desktop-portal-kde
qt6-virtualkeyboard
libwacom
pipewire
pipewire-pulse
pipewire-alsa
wireplumber
python
python-pip
nodejs
npm
rustup
strace
lsof
iotop
powertop
noto-fonts
noto-fonts-cjk
noto-fonts-emoji
ttf-fantasque-nerd
ttf-fira-sans
plymouth
grub
capitaine-cursors
```

- [ ] **Step 3: Create packages-aur.txt**

```
vivaldi-multiarch-bin
maliit-keyboard
maliit-framework
```

- [ ] **Step 4: Create mkinitcpio preset**

Create `rootfs/mkinitcpio-nabu.preset`:
```bash
# mkinitcpio preset for CachyOS Nabu kernel
# IMPORTANT: kernel and initramfs live on the ESP (mounted at /boot/efi)
# so that GRUB can find them. This must match the GRUB config paths.

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/efi/vmlinuz-${KERNEL_VERSION}-cachyos-nabu"

PRESETS=('default')

default_image="/boot/efi/initramfs-${KERNEL_VERSION}-cachyos-nabu.img"
```

- [ ] **Step 5: Create sysctl config**

Create `rootfs/overlay/etc/sysctl.d/70-cachyos.conf`:
```ini
# CachyOS system tuning (from CachyOS-Settings)

# ZRAM-optimized swappiness (critical with 6GB RAM)
vm.swappiness = 100
vm.vfs_cache_pressure = 50

# Dirty page limits
vm.dirty_bytes = 268435456
vm.dirty_background_bytes = 67108864
vm.dirty_writeback_centisecs = 1500

# Single-page swap for ZRAM
vm.page-cluster = 0

# Power savings
kernel.nmi_watchdog = 0

# Security
kernel.unprivileged_userns_clone = 1
kernel.printk = 3 3 3 3
kernel.kptr_restrict = 2

# Network
net.core.netdev_max_backlog = 4096

# File limits
fs.file-max = 2097152
```

- [ ] **Step 6: Create ZRAM config**

Create `rootfs/overlay/etc/systemd/zram-generator.conf`:
```ini
[zram0]
zram-size = ram
compression-algorithm = zstd
swap-priority = 100
```

- [ ] **Step 7: Create I/O scheduler udev rules**

Create `rootfs/overlay/etc/udev/rules.d/60-ioschedulers.rules`:
```
# CachyOS I/O scheduler rules for nabu
# UFS storage appears as /dev/sda on nabu
# Try ADIOS first (CachyOS custom), kernel falls back to mq-deadline if unavailable
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
# Rotational devices (external USB HDDs) use BFQ
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
```

Note: If ADIOS is not available (e.g., if the patch didn't apply), the kernel's default mq-deadline is used automatically. The udev rule is a best-effort override.

- [ ] **Step 8: Create systemd tuning configs**

Create `rootfs/overlay/etc/systemd/system.conf.d/10-cachyos.conf`:
```ini
[Manager]
DefaultTimeoutStartSec=15s
DefaultTimeoutStopSec=10s
DefaultLimitNOFILE=2048:2097152
```

Create `rootfs/overlay/etc/systemd/journald.conf.d/10-cachyos.conf`:
```ini
[Journal]
SystemMaxUse=50M
```

Create `rootfs/overlay/etc/security/limits.d/10-cachyos.conf`:
```
*               soft    nofile          1024
*               hard    nofile          1048576
```

- [ ] **Step 9: Create SDDM auto-login config**

Create `rootfs/overlay/etc/sddm.conf.d/10-autologin.conf`:
```ini
[Autologin]
User=nabu
Session=plasma.desktop
```

- [ ] **Step 10: Create WiFi connection template**

Create `rootfs/overlay/etc/NetworkManager/system-connections/wifi.nmconnection`:
```ini
[connection]
id=Home WiFi
type=wifi
autoconnect=true

[wifi]
ssid=WIFI_SSID_PLACEHOLDER

[wifi-security]
key-mgmt=wpa-psk
psk=WIFI_PASSWORD_PLACEHOLDER

[ipv4]
method=auto

[ipv6]
method=auto
```

Note: `build-rootfs.sh` will substitute `WIFI_SSID_PLACEHOLDER` and `WIFI_PASSWORD_PLACEHOLDER` with the `WIFI_SSID` and `WIFI_PASSWORD` environment variables. File permissions must be set to `600` (NetworkManager requires this).

- [ ] **Step 11: Create hostname file**

Create `rootfs/overlay/etc/hostname`:
```
nabu-cachyos
```

- [ ] **Step 12: Create maliit on-screen keyboard autostart service**

Create `rootfs/overlay/usr/lib/systemd/user/maliit-server.service`:
```ini
[Unit]
Description=Maliit Input Method Server
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/maliit-server
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
```

Note: This service is enabled in `build-rootfs.sh` via `arch-chroot "${ROOTFS}" systemctl --global enable maliit-server.service`.

- [ ] **Step 13: Create KDE Plasma tablet configuration overrides**

These override `cachyos-kde-settings` defaults with tablet-specific settings.

Create `rootfs/overlay/home/nabu/.config/kdeglobals`:
```ini
[KDE]
AnimationDurationFactor=0.25

[General]
fixed=Hack,10,-1,5,50,0,0,0,0,0,Regular
font=Noto Sans,10,-1,5,50,0,0,0,0,0,Regular
```

Create `rootfs/overlay/home/nabu/.config/kwinrc`:
```ini
[Compositing]
Backend=OpenGL

[Wayland]
InputMethod=/usr/bin/maliit-keyboard
VirtualKeyboardEnabled=true

[Plugins]
kwin4_effect_overviewEnabled=true

[TouchEdges]
Bottom=None
Left=None
Right=None
Top=None
```

Create `rootfs/overlay/home/nabu/.config/kcmfonts`:
```ini
[General]
forceFontDPI=144
```

Create `rootfs/overlay/home/nabu/.config/kscreenlockerrc`:
```ini
[Daemon]
Autolock=false
```

Create `rootfs/overlay/home/nabu/.config/plasmashellrc`:
```ini
[PlasmaViews][Panel 2]
floating=1
```

Create `rootfs/overlay/home/nabu/.config/kwinoutputconfig.json`:
```json
[{"scale": 1.5}]
```

Note: The 150% scaling is set via `kwinoutputconfig.json`. KDE on Wayland reads this for display scaling. The exact format may need adjustment based on the KDE version in ALARM repos — if this doesn't work, we can set it via `kscreen-doctor output.1.scale 1.5` in a first-boot script.

- [ ] **Step 14: Create convenience scripts**

Create `rootfs/overlay/home/nabu/bin/snapshot`:
```bash
#!/usr/bin/env bash
set -euo pipefail
NAME="${1:?Usage: snapshot <name>}"
SNAP="/.snapshots/$(date +%Y%m%d-%H%M)-${NAME}"
sudo btrfs subvolume snapshot / "${SNAP}"
echo "Snapshot created: ${SNAP}"
```

Create `rootfs/overlay/home/nabu/bin/rollback`:
```bash
#!/usr/bin/env bash
echo "Available snapshots:"
sudo btrfs subvolume list /.snapshots 2>/dev/null || echo "  (none)"
echo ""
echo "To rollback:"
echo "  1. Boot into GRUB verbose mode"
echo "  2. Edit kernel line, change rootflags=subvol=@ to rootflags=subvol=@snapshots/<name>"
echo "  3. Boot and verify"
echo "  4. If good, make permanent: sudo btrfs subvolume set-default <id> /"
```

Create `rootfs/overlay/home/nabu/bin/install-containers`:
```bash
#!/usr/bin/env bash
set -euo pipefail
echo "Installing Docker and Podman..."
sudo pacman -S --noconfirm docker podman
sudo systemctl enable --now docker.service
echo "Done. Docker and Podman are now available."
echo "Note: Docker daemon uses ~100MB RAM. Stop with: sudo systemctl stop docker"
```

Create `rootfs/overlay/home/nabu/bin/kernel-update`:
```bash
#!/usr/bin/env bash
set -euo pipefail

# Default to current known-good version. User can override with argument.
# WARNING: Not all sm8150-mainline branches boot on nabu. Known-good: 6.14.11.
# Check https://gitlab.com/sm8150-mainline/linux/-/branches for available branches.
# Branch 6.16+ does NOT boot on some devices.
DEFAULT_BRANCH="sm8150/6.14.11"
BRANCH="${1:-${DEFAULT_BRANCH}}"
PATCHES_DIR="/opt/nabu-cachyos/patches"
CONFIG_FILE="/opt/nabu-cachyos/cachyos.config"

echo "=== CachyOS Nabu Kernel Updater ==="
echo ""
echo "Current kernel: $(uname -r)"
echo "Target branch:  ${BRANCH}"
echo ""
echo "WARNING: Only sm8150/6.14.x branches are known to boot reliably."
echo "Using an untested branch may make your tablet unbootable."
echo "Make sure to run 'snapshot pre-kernel-update' first!"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

WORK="/tmp/kernel-update"
rm -rf "${WORK}"
mkdir -p "${WORK}"
cd "${WORK}"

# Clone specific branch
echo "Cloning sm8150-mainline branch ${BRANCH}..."
git clone --depth 1 --branch "${BRANCH}" \
    https://gitlab.com/sm8150-mainline/linux.git
cd linux

# Apply CachyOS patches if available
if [ -d "${PATCHES_DIR}" ]; then
    echo "Applying CachyOS patches..."
    for patch in "${PATCHES_DIR}"/*.patch; do
        patchname="$(basename "${patch}")"
        echo "  ${patchname}..."
        git apply --check "${patch}" 2>/dev/null && git apply "${patch}" || {
            echo "  WARNING: ${patchname} did not apply cleanly, skipping."
        }
    done
else
    echo "WARNING: No patches found at ${PATCHES_DIR}"
    echo "Kernel will be built without CachyOS patches (BORE, BBR3, ADIOS)."
fi

# Build config
echo "Configuring kernel..."
make defconfig
scripts/kconfig/merge_config.sh -m .config arch/arm64/configs/sm8150.config
[ -f "${CONFIG_FILE}" ] && \
    scripts/kconfig/merge_config.sh -m .config "${CONFIG_FILE}"
make olddefconfig

# Compile
echo "Compiling kernel (this takes ~15 minutes)..."
make -j$(nproc) Image.gz dtbs modules

# Install
KVER=$(make kernelversion)
echo "Installing kernel ${KVER}..."
sudo make modules_install
sudo cp arch/arm64/boot/Image.gz "/boot/efi/vmlinuz-${KVER}-cachyos-nabu"
sudo cp arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dtb /boot/efi/
sudo mkinitcpio -g "/boot/efi/initramfs-${KVER}-cachyos-nabu.img" -k "${KVER}"

# Update GRUB config
echo "Updating GRUB config..."
sudo sed -i "s|vmlinuz-[0-9.]\\+-cachyos-nabu|vmlinuz-${KVER}-cachyos-nabu|g" /boot/efi/grub/grub.cfg
sudo sed -i "s|initramfs-[0-9.]\\+-cachyos-nabu|initramfs-${KVER}-cachyos-nabu|g" /boot/efi/grub/grub.cfg

echo ""
echo "Kernel ${KVER} installed and GRUB updated."
echo "Reboot to use the new kernel."
echo "If it doesn't boot, select Verbose mode in GRUB to see what's wrong."
```

Note: The script defaults to the known-good `sm8150/6.14.11` branch but allows overriding with an argument (e.g., `kernel-update sm8150/6.15.3`). CachyOS patches and config are applied from `/opt/nabu-cachyos/` which is populated during the initial build. The script installs kernel artifacts to `/boot/efi/` (the ESP mount point) and updates the GRUB config in-place — matching the boot path layout.

- [ ] **Step 15: Make convenience scripts executable and commit**

```bash
chmod +x rootfs/overlay/home/nabu/bin/*
git add rootfs/
git commit -m "feat: add rootfs overlay configs and package lists

CachyOS sysctl tuning, ZRAM config, I/O scheduler rules, systemd tuning,
SDDM auto-login, WiFi template, pacman ALARM mirror config, mkinitcpio
preset, convenience scripts (snapshot, rollback, install-containers)."
```

---

### Task 6: CachyOS theming package builder

**Files:**
- Create: `rootfs/build-theming.sh`

This script clones CachyOS theming repos and builds them with `makepkg` inside the Docker container. All theming packages are `arch=any` (pure config/assets), so they build instantly.

- [ ] **Step 1: Write the theming build script**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOTFS="${1:?Usage: build-theming.sh <rootfs-path>}"
THEME_BUILD="/tmp/theming-build"
PKGBUILDS_REPO="https://github.com/CachyOS/CachyOS-PKGBUILDS.git"

echo "--- Building CachyOS theming packages ---"

# IMPORTANT: All CachyOS PKGBUILDs live in the CachyOS-PKGBUILDS repo, NOT
# in the individual asset repos (cachyos-kde-settings, cachyos-wallpapers, etc).
# The asset repos contain the source files; CachyOS-PKGBUILDS contains the
# packaging recipes that reference those sources. We clone PKGBUILDS once and
# build each package from its subdirectory.

mkdir -p "${THEME_BUILD}"
cd "${THEME_BUILD}"

if [ ! -d "CachyOS-PKGBUILDS" ]; then
    echo "Cloning CachyOS-PKGBUILDS..."
    git clone --depth 1 "${PKGBUILDS_REPO}" CachyOS-PKGBUILDS
fi

# Helper: build a PKGBUILD from CachyOS-PKGBUILDS/<subdir> and install to rootfs
build_and_install() {
    local subdir="$1"
    echo "  Building ${subdir}..."
    cd "${THEME_BUILD}/CachyOS-PKGBUILDS/${subdir}"

    # Build as non-root user (makepkg requirement)
    sudo -u builder makepkg -f --noconfirm --syncdeps 2>&1 || {
        echo "    WARNING: makepkg failed for ${subdir}, attempting without deps..."
        sudo -u builder makepkg -f --noconfirm 2>&1 || true
    }

    # Install into target rootfs (use arch-chroot so install hooks run correctly)
    local pkg
    pkg=$(ls -1 *.pkg.tar* 2>/dev/null | head -1)
    if [ -n "${pkg}" ]; then
        cp "${pkg}" "${ROOTFS}/tmp/"
        arch-chroot "${ROOTFS}" pacman -U --noconfirm "/tmp/$(basename "${pkg}")"
        rm "${ROOTFS}/tmp/$(basename "${pkg}")"
        echo "    Installed ${pkg}"
    else
        echo "    WARNING: No package produced for ${subdir}"
    fi
}

# All packages from CachyOS-PKGBUILDS repo
build_and_install "cachyos-kde-settings"
build_and_install "cachyos-wallpapers"
build_and_install "cachyos-themes-sddm"
build_and_install "cachyos-nord-kde"
build_and_install "char-white"
build_and_install "cachyos-plymouth-bootanimation"
build_and_install "cachyos-fish-config"
build_and_install "cachyos-zsh-config"

echo "--- Theming packages installed ---"
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x rootfs/build-theming.sh
git add rootfs/build-theming.sh
git commit -m "feat: add CachyOS theming package builder

Builds cachyos-kde-settings, wallpapers, SDDM themes, Nord theme,
char-white cursor, Plymouth animation from source repos."
```

---

### Task 7: Rootfs build script

**Files:**
- Create: `rootfs/build-rootfs.sh`

This is the main rootfs assembly script. It runs inside Docker and produces a complete filesystem tree.

- [ ] **Step 1: Write the rootfs build script**

```bash
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
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x rootfs/build-rootfs.sh
git add rootfs/build-rootfs.sh
git commit -m "feat: add rootfs build script

Bootstraps ALARM, installs kernel + firmware + packages,
builds AUR and theming packages, configures user account,
WiFi, SSH, auto-login, mkinitcpio, fstab."
```

---

### Task 8: Image assembly

**Files:**
- Create: `image/build-image.sh`
- Create: `image/grub.cfg.template`

- [ ] **Step 1: Create GRUB config template**

Create `image/grub.cfg.template`:

Note on boot path consistency: GRUB runs from the ESP. The ESP is mounted at `/boot/efi` on the running system. GRUB paths are relative to the ESP root, so `/vmlinuz-...` in GRUB config corresponds to `/boot/efi/vmlinuz-...` on the running filesystem. All kernel artifacts (vmlinuz, initramfs, DTB) live on the ESP so that both the build-time image assembly and runtime updates (mkinitcpio, kernel-update) write to the same location GRUB reads from.

```
set default=0
set timeout=3

menuentry "CachyOS Nabu (KERNEL_VERSION_PLACEHOLDER)" {
    linux /vmlinuz-KERNEL_VERSION_PLACEHOLDER-cachyos-nabu root=PARTLABEL=linux rootflags=subvol=@ rw rootwait quiet splash
    initrd /initramfs-KERNEL_VERSION_PLACEHOLDER-cachyos-nabu.img
    devicetree /sm8150-xiaomi-nabu.dtb
}

menuentry "CachyOS Nabu (KERNEL_VERSION_PLACEHOLDER) - Verbose" {
    linux /vmlinuz-KERNEL_VERSION_PLACEHOLDER-cachyos-nabu root=PARTLABEL=linux rootflags=subvol=@ rw rootwait loglevel=7
    initrd /initramfs-KERNEL_VERSION_PLACEHOLDER-cachyos-nabu.img
    devicetree /sm8150-xiaomi-nabu.dtb
}
```

- [ ] **Step 2: Write the image assembly script**

```bash
#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="/build/output/rootfs"
OUTPUT="/build/output"

echo "--- Building flashable images ---"

# 1. Download UEFI boot.img from TheMojoMan
echo "Downloading UEFI firmware..."
if [ ! -f "${OUTPUT}/boot.img" ]; then
    # Note: This URL may need updating. Check https://github.com/TheMojoMan/xiaomi-nabu
    # for the latest mega.nz link. For now we use a placeholder.
    echo "WARNING: boot.img must be downloaded manually from TheMojoMan's mega.nz folder."
    echo "Place it at: ${OUTPUT}/boot.img"
    echo "URL: https://mega.nz/folder/CVMGEAiB#7oazR3wpkKdAH2eZChtRTg"
    echo "File: boot_6.14.11-nabu-tmm_linux.img"
    # If the file doesn't exist, create a placeholder so the build continues
    if [ ! -f "${OUTPUT}/boot.img" ]; then
        echo "PLACEHOLDER - download boot.img manually" > "${OUTPUT}/boot.img.README"
    fi
fi

# 2. Build ESP image (512MB FAT32)
echo "Building ESP image..."
ESP_IMG="${OUTPUT}/esp.img"
ESP_MNT="/tmp/esp-mount"

dd if=/dev/zero of="${ESP_IMG}" bs=1M count=512
mkfs.fat -F32 -n ESPNABU "${ESP_IMG}"

mkdir -p "${ESP_MNT}"
mount -o loop "${ESP_IMG}" "${ESP_MNT}"

# Install GRUB for arm64-efi
grub-install --target=arm64-efi \
    --efi-directory="${ESP_MNT}" \
    --boot-directory="${ESP_MNT}" \
    --removable --no-nvram

# Generate GRUB config from template
sed "s/KERNEL_VERSION_PLACEHOLDER/${KERNEL_VERSION}/g" \
    "${SCRIPT_DIR}/grub.cfg.template" > "${ESP_MNT}/grub/grub.cfg"

# Copy kernel, initramfs, DTB to ESP
# These were installed to /boot/efi/ in the rootfs (the ESP mount point)
cp "${ROOTFS}/boot/efi/vmlinuz-${KERNEL_VERSION}-cachyos-nabu" "${ESP_MNT}/"
cp "${ROOTFS}/boot/efi/initramfs-${KERNEL_VERSION}-cachyos-nabu.img" "${ESP_MNT}/"
cp "${ROOTFS}/boot/efi/sm8150-xiaomi-nabu.dtb" "${ESP_MNT}/"

umount "${ESP_MNT}"
echo "  ESP image: ${ESP_IMG} ($(du -h "${ESP_IMG}" | cut -f1))"

# 3. Build Btrfs rootfs image
echo "Building rootfs image..."
LINUX_IMG="${OUTPUT}/linux.img"
LINUX_MNT="/tmp/linux-mount"

# Create a sparse file (~8GB should be enough for the rootfs content)
truncate -s 8G "${LINUX_IMG}"
mkfs.btrfs -f -L linux "${LINUX_IMG}"

mkdir -p "${LINUX_MNT}"
mount -o loop,compress=zstd:3 "${LINUX_IMG}" "${LINUX_MNT}"

# Create subvolumes
btrfs subvolume create "${LINUX_MNT}/@"
btrfs subvolume create "${LINUX_MNT}/@home"
btrfs subvolume create "${LINUX_MNT}/@snapshots"

# Copy rootfs into @ subvolume
echo "  Copying rootfs (this takes a minute)..."
cp -a "${ROOTFS}/"* "${LINUX_MNT}/@/" 2>/dev/null || true

# Move /home to @home
if [ -d "${LINUX_MNT}/@/home/nabu" ]; then
    mv "${LINUX_MNT}/@/home/"* "${LINUX_MNT}/@home/" 2>/dev/null || true
fi
mkdir -p "${LINUX_MNT}/@/home"
mkdir -p "${LINUX_MNT}/@/.snapshots"

umount "${LINUX_MNT}"

# Compress with zstd
echo "  Compressing rootfs image..."
zstd -T0 -9 "${LINUX_IMG}" -o "${OUTPUT}/linux.img.zst"
rm "${LINUX_IMG}"

echo "  Rootfs image: ${OUTPUT}/linux.img.zst ($(du -h "${OUTPUT}/linux.img.zst" | cut -f1))"

echo ""
echo "--- Image build complete ---"
echo "Artifacts:"
ls -lh "${OUTPUT}/"*.img "${OUTPUT}/"*.zst "${OUTPUT}/"*.README 2>/dev/null || true
```

- [ ] **Step 3: Make executable and commit**

```bash
chmod +x image/build-image.sh
git add image/
git commit -m "feat: add image assembly script and GRUB template

Builds ESP (FAT32 with GRUB arm64-efi + kernel) and rootfs
(Btrfs with subvolumes, zstd compressed) images."
```

---

### Task 9: Recovery image and flash script

**Files:**
- Create: `recovery/build-recovery.sh`
- Create: `image/flash.sh`

- [ ] **Step 1: Write recovery build script**

```bash
#!/usr/bin/env bash
set -euo pipefail

OUTPUT="/build/output"
WORK="/tmp/recovery-build"

echo "--- Building recovery image ---"

# IMPORTANT: The flash process depends on `adb shell`, `adb push`, and `adb pull`
# after booting this recovery image. This means the recovery MUST include and
# start `adbd` (the Android Debug Bridge daemon).
#
# Rather than building a custom initramfs from scratch (which requires getting
# adbd, USB gadget config, and init exactly right), we use a proven approach:
# download an existing TWRP or minimal recovery image for nabu that already
# has adb support baked in.

mkdir -p "${OUTPUT}"

# Option A (preferred): Download a known-working TWRP recovery for nabu
# TWRP includes adb, parted, sgdisk, dd, and more out of the box.
TWRP_URL="https://dl.twrp.me/nabu/twrp-3.7.1_12-0-nabu.img"
if [ ! -f "${OUTPUT}/recovery.img" ]; then
    echo "Downloading TWRP recovery for nabu..."
    wget -O "${OUTPUT}/recovery.img" "${TWRP_URL}" 2>/dev/null || {
        echo "WARNING: TWRP download failed. Trying alternative..."
        # Option B: Use the recovery from the nabu-alarm project or TheMojoMan
        # The user can also manually place a recovery.img in output/
        echo "Please manually download a TWRP recovery for nabu and place it at:"
        echo "  ${OUTPUT}/recovery.img"
        echo ""
        echo "Sources:"
        echo "  - https://dl.twrp.me/nabu/"
        echo "  - https://xdaforums.com/t/recovery-unofficial-twrp-for-xiaomi-pad-5.4595499/"
        exit 1
    }
fi

# Verify the recovery image exists and is not empty
if [ ! -s "${OUTPUT}/recovery.img" ]; then
    echo "ERROR: recovery.img is empty or missing."
    exit 1
fi

echo "--- Recovery image ready: ${OUTPUT}/recovery.img ---"
echo "This recovery provides: adb shell, parted, sgdisk, dd, mkfs"
```

Note: We use a pre-built TWRP recovery instead of building our own initramfs. Building a custom recovery that correctly initializes adbd (including USB gadget configuration, init scripts, and the adbd binary itself) is non-trivial and error-prone. TWRP for nabu is battle-tested and includes everything we need (adb, partition tools, filesystem tools). If the TWRP URL changes, check https://dl.twrp.me/nabu/ for the latest version, or use any nabu-compatible recovery that supports `adb shell`.

The flash script's `adb shell` commands (sgdisk, dd, mkfs) all depend on tools present in TWRP. If using a different recovery, verify these tools are available before proceeding.

- [ ] **Step 2: Write flash script**

Create `image/flash.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${SCRIPT_DIR}/../output"

echo "=== CachyOS Nabu Flasher ==="
echo ""
echo "WARNING: This will ERASE all data on the tablet."
echo "Make sure you have a backup of anything important."
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

# Step 0: Verify prerequisites
echo "[0/9] Checking prerequisites..."
command -v fastboot >/dev/null || { echo "ERROR: fastboot not found. Install: brew install android-platform-tools"; exit 1; }
command -v adb >/dev/null || { echo "ERROR: adb not found. Install: brew install android-platform-tools"; exit 1; }

for f in boot.img esp.img linux.img.zst; do
    [ -f "${OUTPUT}/${f}" ] || { echo "ERROR: ${OUTPUT}/${f} not found. Run build.sh first."; exit 1; }
done

# Step 1: Verify fastboot connection
echo "[1/9] Checking device connection..."
fastboot devices | grep -q . || { echo "ERROR: No device found. Boot tablet into fastboot (Vol Down + Power)."; exit 1; }
echo "  Device found."

# Step 2: Flash UEFI firmware
echo "[2/9] Flashing UEFI firmware to boot_b..."
fastboot flash boot_b "${OUTPUT}/boot.img"

# Step 3: Boot recovery
echo "[3/9] Booting recovery (wait ~10 seconds for it to start)..."
fastboot boot "${OUTPUT}/recovery.img"
echo "  Waiting for device..."
adb wait-for-device
sleep 5

# Step 4: Backup partition table
echo "[4/9] Backing up partition table..."
adb shell sgdisk --backup=/tmp/gpt-backup.bin /dev/block/sda
adb pull /tmp/gpt-backup.bin "${OUTPUT}/gpt-backup.bin"
echo "  Backup saved to ${OUTPUT}/gpt-backup.bin"

# Step 5: Repartition
echo "[5/9] Repartitioning..."
adb shell sgdisk --resize-table 64 /dev/block/sda
# Delete userdata (partition 31)
adb shell sgdisk --delete=31 /dev/block/sda
# Create ESP (512MB, EFI System Partition type)
adb shell sgdisk --new=31:0:+512M --typecode=31:EF00 --change-name=31:esp /dev/block/sda
# Create linux (remaining space, Linux filesystem type)
adb shell sgdisk --new=32:0:0 --typecode=32:8300 --change-name=32:linux /dev/block/sda
# Verify
echo "  New partition table:"
adb shell sgdisk --print /dev/block/sda

# Step 6: Format ESP
echo "[6/9] Formatting ESP..."
adb shell mkfs.fat -F32 -n ESPNABU /dev/block/sda31

# Step 7: Flash ESP
echo "[7/9] Flashing ESP image..."
adb push "${OUTPUT}/esp.img" /tmp/esp.img
adb shell dd if=/tmp/esp.img of=/dev/block/sda31 bs=4M
adb shell rm /tmp/esp.img

# Step 8: Flash rootfs
echo "[8/9] Flashing rootfs (this may take several minutes)..."
adb push "${OUTPUT}/linux.img.zst" /tmp/linux.img.zst
adb shell "zstdcat /tmp/linux.img.zst | dd of=/dev/block/sda32 bs=4M"
adb shell rm /tmp/linux.img.zst

# Step 9: Set boot slot and reboot
echo "[9/9] Setting boot slot and rebooting..."
adb reboot bootloader
sleep 5
fastboot set_active b
fastboot reboot

echo ""
echo "=== Flash complete! ==="
echo ""
echo "The tablet should boot into CachyOS in ~60 seconds."
echo "Once booted, connect via SSH:"
echo "  ssh nabu@<tablet-ip>"
echo ""
echo "Default credentials:"
echo "  User: nabu"
echo "  Password: cachyos (will be forced to change on first login)"
echo ""
echo "If the tablet doesn't boot:"
echo "  1. Hold Vol Down + Power to enter fastboot"
echo "  2. Run: fastboot set_active a  (switches back to Android slot)"
echo "  3. Or reflash with Xiaomi stock ROM"
```

- [ ] **Step 3: Make executable and commit**

```bash
chmod +x recovery/build-recovery.sh image/flash.sh
git add recovery/ image/flash.sh
git commit -m "feat: add recovery image builder and flash script

Recovery: minimal initramfs with partition tools for repartitioning.
Flash: full end-to-end script with safety checks, GPT backup,
repartitioning, ESP + rootfs flashing, and boot slot switching."
```

---

## Phase 2: Flash and Boot (needs tablet)

### Task 10: Flash the tablet

**Prerequisites:**
- Phase 1 complete (all images built)
- Tablet connected via USB-C
- Tablet booted into fastboot mode (Vol Down + Power)
- `android-platform-tools` installed on Mac (`brew install android-platform-tools`)
- UEFI `boot.img` downloaded from TheMojoMan's mega.nz (see Task 8 output)

- [ ] **Step 1: Download boot.img**

Download `boot_6.14.11-nabu-tmm_linux.img` from TheMojoMan's mega.nz folder:
https://mega.nz/folder/CVMGEAiB#7oazR3wpkKdAH2eZChtRTg

Rename to `output/boot.img`.

- [ ] **Step 2: Verify tablet is in fastboot mode**

```bash
fastboot devices
```

Expected: Shows device serial number. If empty, ensure USB cable is connected and tablet is in fastboot (Vol Down + Power from off state).

- [ ] **Step 3: Run flash script**

```bash
bash image/flash.sh
```

Expected: Script walks through all 9 steps, asking for confirmation before starting. Takes ~5-10 minutes total (rootfs transfer is the slowest part).

- [ ] **Step 4: Wait for boot and find IP**

After reboot, wait ~60 seconds. Find the tablet's IP:
- Check your router's DHCP lease table
- Or try: `ping nabu-cachyos.local` (if mDNS is working)
- Or look at the tablet screen — it should show the KDE Plasma desktop with the IP in the network widget

- [ ] **Step 5: SSH in and verify**

```bash
ssh nabu@<tablet-ip>
# Password: cachyos (will be forced to change)

# After changing password:
fastfetch
uname -r                    # Should show 6.14.11-cachyos-nabu or similar
cat /proc/cmdline           # Should show BORE, BBR3 config
sysctl vm.swappiness        # Should show 100
systemctl status sshd       # Should be active
systemctl status sddm       # Should be active
systemctl status NetworkManager  # Should be active
lsmod | grep adios          # Check ADIOS scheduler loaded
```

- [ ] **Step 6: Create initial snapshot**

```bash
snapshot fresh-install
```

- [ ] **Step 7: Commit any fixes needed**

If anything needed adjustment during flashing, commit the fixes back to the build system.

---

## Troubleshooting Guide

### Kernel doesn't boot (stuck at GRUB or black screen)
- Select "Verbose" GRUB entry to see kernel output
- If stuck at GRUB: kernel or DTB path is wrong in grub.cfg
- If black screen after GRUB: kernel panic — likely missing firmware or wrong DTB
- Recovery: Vol Down + Power → fastboot → `fastboot set_active a` → back to Android

### WiFi doesn't connect
- SSH won't work without WiFi. Connect USB keyboard or use `fastboot boot recovery.img` + adb shell
- Check: `nmcli device wifi list` — does it see networks?
- If no networks: firmware blobs missing from `/usr/lib/firmware/`
- If network visible but won't connect: check `/etc/NetworkManager/system-connections/wifi.nmconnection` credentials

### Display is black but system is running
- The freedreno GPU driver may fail to initialize. SSH in (if WiFi works) and check `dmesg | grep drm`
- Try adding `drm.debug=0x1e` to kernel cmdline in GRUB

### Patches don't apply cleanly
- The sm8150-mainline tree may have commits that conflict with CachyOS patches
- Try: `git apply --3way` for fuzzy matching
- Or: manually resolve conflicts in the patch hunks
- Last resort: skip the conflicting patch and add its config options manually

### AUR packages fail to build
- Some AUR packages may have missing dependencies on aarch64
- For Vivaldi: it ships pre-built aarch64 binaries, so it should work
- For maliit: if it fails, skip it and install `qt6-virtualkeyboard` as the on-screen keyboard fallback
