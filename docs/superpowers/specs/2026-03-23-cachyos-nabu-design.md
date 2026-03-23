# CachyOS on Xiaomi Pad 5 (nabu) — Design Specification

**Date:** 2026-03-23
**Status:** Draft
**Author:** Claude + Flavio

## 1. Overview

Build a CachyOS-flavored Arch Linux ARM distribution for the Xiaomi Pad 5 (codename: nabu, Snapdragon 860 / SM8150). The project produces a flashable image via a Docker-based build system running on an M4 Pro MacBook. The tablet runs Linux-only (no Android dual-boot), with KDE Plasma configured for tablet use, and is accessible via SSH on first boot.

### Goals

- Custom kernel: nabu hardware support (sm8150-mainline 6.14.11) + CachyOS patches (BORE scheduler, BBR3, ADIOS I/O, sched-ext)
- CachyOS desktop: KDE Plasma with CachyOS theming (Nord theme, wallpapers, SDDM theme, dark mode)
- CachyOS system tuning: ZRAM with zstd, sysctl optimizations, I/O scheduler rules, systemd tuning
- Tablet UX: on-screen keyboard, auto-rotation, touch gestures, pen input, 150% display scaling
- First-boot ready: auto-WiFi, auto-login, SSH server — operational within 60 seconds of power-on
- Tinkering-friendly: Btrfs with snapshots, dev tools pre-installed, convenience scripts

### Non-Goals

- Camera or microphone support (no mainline drivers exist)
- Reliable suspend/resume (known kernel limitation on nabu)
- Rebuilding CachyOS's x86-specific packages for ARM (AMD P-State, TLB broadcast, x86 crypto — these are irrelevant on ARM)
- Cachy Browser (requires full Firefox/Chromium rebuild — using Vivaldi from AUR instead)
- Android dual-boot (user opted for Linux-only)

## 2. Hardware Target

| Component | Spec |
|-----------|------|
| SoC | Qualcomm SM8150 v2.2 (Snapdragon 860) |
| CPU | 1x Cortex-A76 @ 2.96GHz + 3x Cortex-A76 @ 2.42GHz + 4x Cortex-A55 @ 1.8GHz |
| GPU | Adreno 640 |
| RAM | 6GB LPDDR4X |
| Storage | 128GB UFS 3.1 |
| Display | 11" 2560x1600 IPS, 120Hz, Novatek NT36523 panel |
| Touch | Novatek NVT-ts capacitive + pen (SPI) |
| Audio | WCD9340 codec + 4x Cirrus CS35L41 speakers |
| WiFi | WCN3991 (WiFi 6) |
| Bluetooth | WCN3991 (BT 5.1, audio supported) |
| Battery | 8720mAh |
| USB | Type-C with OTG, dual-role |
| Sensors | Accelerometer (for auto-rotation), hall effect (magnetic cover) |

## 3. Build System Architecture

### Project structure

```
nabu-cachyos/
├── Dockerfile                 # aarch64 Arch Linux ARM build environment (bootstrapped from ALARM rootfs tarball)
├── build.sh                   # Main entry point — builds everything, sets KERNEL_VERSION variable
├── kernel/
│   ├── build-kernel.sh        # Clones sm8150-mainline, applies patches, compiles
│   ├── sm8150.config          # Base nabu kernel config (from upstream)
│   ├── cachyos.config         # Config fragment: BORE, sched-ext, HZ=1000, BBR3, containers, etc.
│   └── patches/
│       ├── 0001-bore.patch    # BORE scheduler v5.9.6
│       ├── 0002-bbr3.patch    # BBR3 TCP congestion control
│       ├── 0003-adios.patch   # ADIOS I/O scheduler
│       └── 0004-cachy-arm.patch # Arch-neutral bits (HZ options, PREEMPT_LAZY, THP, v4l2loopback)
├── firmware/
│   └── fetch-firmware.sh      # Downloads nabu-specific Qualcomm firmware blobs from map220v/nabu-firmware
├── rootfs/
│   ├── build-rootfs.sh        # pacstrap + package installation + config overlay
│   ├── packages.txt           # Package list (official repos)
│   ├── packages-aur.txt       # AUR package list (vivaldi, maliit-keyboard, maliit-framework)
│   ├── pacman-alarm.conf      # pacman.conf pointing at Arch Linux ARM mirrors (mirror.archlinuxarm.org)
│   └── overlay/               # Files copied directly into the rootfs
│       ├── etc/
│       │   ├── sysctl.d/70-cachyos.conf
│       │   ├── systemd/zram-generator.conf
│       │   ├── udev/rules.d/60-ioschedulers.rules
│       │   ├── NetworkManager/system-connections/wifi.nmconnection
│       │   └── sddm.conf.d/autologin.conf
│       └── usr/share/         # Theming assets
├── recovery/
│   └── build-recovery.sh      # Builds minimal recovery initramfs (busybox + parted + sgdisk + dd + zstd)
├── image/
│   ├── build-image.sh         # Assembles kernel + rootfs into flashable images
│   └── flash.sh               # Fastboot commands to flash the tablet
└── output/
    ├── boot.img               # UEFI firmware (pre-built, downloaded)
    ├── recovery.img            # Minimal recovery for repartitioning and flashing
    ├── esp.img                # EFI System Partition
    └── linux.img.zst          # Btrfs root filesystem (zstd compressed)
```

### Build flow

All build scripts use `set -euo pipefail` and validate each step (patch application, package availability, kernel compilation) with clear error messages on failure. A `KERNEL_VERSION` variable (e.g., `6.14.11`) is set in `build.sh` and propagated to all scripts — no hardcoded version strings in individual scripts.

1. `build.sh` builds a Docker image (aarch64 Arch Linux ARM with build dependencies)
2. Inside Docker, `firmware/fetch-firmware.sh`:
   - Clones `github.com/map220v/nabu-firmware`
   - Stages firmware blobs for installation into rootfs at `/usr/lib/firmware/`
   - These blobs provide: WiFi (WCN3991), GPU (Adreno 640), Bluetooth, audio codec firmware
   - **Note:** `linux-firmware` (from Arch repos) provides generic firmware; nabu-specific Qualcomm blobs are NOT upstreamed and must come from this repo
3. Inside Docker, `kernel/build-kernel.sh`:
   - Clones `gitlab.com/sm8150-mainline/linux` branch `sm8150/${KERNEL_VERSION}`
   - Applies BORE, BBR3, ADIOS, and cachy-arm patches (each with `git apply --check` validation before applying)
   - Merges `defconfig` + `sm8150.config` + `cachyos.config`
   - Compiles: `make -j$(nproc) Image.gz dtbs modules`
   - Outputs: `Image.gz`, `sm8150-xiaomi-nabu.dtb`, kernel modules
4. Inside Docker, `rootfs/build-rootfs.sh`:
   - Bootstraps Arch Linux ARM via `pacstrap -C pacman-alarm.conf` (uses Arch Linux ARM mirrors at `mirror.archlinuxarm.org`, NOT mainline Arch repos which only serve x86_64)
   - Installs packages from `packages.txt` (official ALARM repos)
   - Builds and installs AUR packages from `packages-aur.txt` (vivaldi, maliit-keyboard, maliit-framework) using `makepkg` as a non-root build user
   - Installs kernel image, modules, DTB
   - Installs nabu-specific firmware blobs to `/usr/lib/firmware/`
   - Copies overlay configs
   - Builds and installs CachyOS theming packages from git (using `makepkg`)
   - Configures: locale, timezone, fstab, user account, sudo, SSH, services
   - Generates initramfs with `mkinitcpio` (preset configured to output `initramfs-${KERNEL_VERSION}-cachyos-nabu.img`)
5. Inside Docker, `recovery/build-recovery.sh`:
   - Builds a minimal initramfs-based recovery image containing: busybox, parted, sgdisk, dd, zstd, mkfs.fat, mkfs.btrfs
   - Packages as an Android boot.img via `mkbootimg` (so it can be loaded via `fastboot boot`)
6. Inside Docker, `image/build-image.sh`:
   - Creates `esp.img` (512MB FAT32) using `grub-install --target=arm64-efi --efi-directory=... --boot-directory=...`:
     - GRUB EFI binary (`BOOTAA64.EFI`)
     - Kernel: `vmlinuz-${KERNEL_VERSION}-cachyos-nabu`
     - Initramfs: `initramfs-${KERNEL_VERSION}-cachyos-nabu.img`
     - DTB: `sm8150-xiaomi-nabu.dtb`
     - GRUB config: generated from template using `KERNEL_VERSION`
   - Creates `linux.img` (Btrfs): rootfs with `@`, `@home`, `@snapshots` subvolumes
   - Compresses `linux.img` with zstd
7. Artifacts copied out of Docker to `output/`

### Docker environment

The official `archlinux:latest` Docker image is x86_64 only. Since we need an aarch64 environment (for native `pacstrap`, `makepkg`, and `mkinitcpio`), the Dockerfile bootstraps an Arch Linux ARM container:

```dockerfile
# Stage 1: Bootstrap ALARM rootfs into a Docker image
FROM scratch
ADD ArchLinuxARM-aarch64-latest.tar.gz /
# Configure ALARM mirrors
RUN pacman-key --init && pacman-key --populate archlinuxarm
RUN pacman -Syu --noconfirm
```

On the M4 Pro (Apple Silicon), this runs natively as aarch64 — no emulation, no QEMU binfmt_misc. The kernel compilation, pacstrap, makepkg, and mkinitcpio all execute at native speed.

- **Base:** Arch Linux ARM rootfs tarball (`archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz`)
- **Build deps:** `base-devel`, `bc`, `bison`, `flex`, `dtc`, `grub`, `dosfstools`, `btrfs-progs`, `mtools`, `arch-install-scripts`, `mkinitcpio`, `android-tools` (for `mkbootimg`)
- **Estimated build time:** ~20-30 minutes total (kernel ~15 min, rootfs ~10 min, image ~2 min)

## 4. Kernel Configuration

### Source

- **Repository:** `https://gitlab.com/sm8150-mainline/linux`
- **Branch:** `sm8150/6.14.11`
- **Base config:** `defconfig` + `sm8150.config` (provides all nabu hardware support)

### CachyOS patches applied

| Patch | Source | Purpose |
|-------|--------|---------|
| BORE v5.9.6 | `CachyOS/kernel-patches/6.14/sched/0001-bore.patch` | Burst-Oriented Response Enhancer — improves interactive/touch responsiveness on top of EEVDF scheduler |
| BBR3 | `CachyOS/kernel-patches/6.14/0004-bbr3.patch` | Google BBR v3 TCP congestion control — better WiFi throughput and latency |
| ADIOS | Extracted from `CachyOS/kernel-patches/6.14/0005-cachy.patch` | CachyOS I/O scheduler for flash storage (block/adios.c, ~1339 lines) |
| cachy-arm | Extracted arch-neutral bits from `0005-cachy.patch` | v4l2loopback, additional HZ options, PREEMPT_LAZY option, THP/vmscan tuning |

### CachyOS patches NOT applied (x86-only)

- AMD P-State (x86/AMD CPUs)
- AMD TLB broadcast (x86/AMD)
- ASUS ROG Ally support (x86 handheld)
- x86 crypto optimizations (x86 assembly)
- Apple T2 support (x86 Macs)
- zstd improvements (minor, risk of conflicts)

### cachyos.config fragment

```kconfig
# BORE scheduler
CONFIG_SCHED_BORE=y

# sched-ext (mainline in 6.14, just enable)
CONFIG_SCHED_CLASS_EXT=y

# 1000Hz timer — maximum touch responsiveness
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

# Btrfs root filesystem
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

# Container support (for optional docker/podman post-install)
CONFIG_CGROUP_V2=y
CONFIG_OVERLAY_FS=y
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_IP_NF_NAT=y
```

### Hardware support (provided by sm8150.config, not modified)

- Adreno 640 GPU (DRM_MSM, freedreno Mesa)
- Novatek NT36523 display panel + KTZ8866 backlight
- Novatek pen input (SPI)
- 4x CS35L41 speaker amplifiers (TDM)
- WCN3991 WiFi + Bluetooth
- QCOM fuel gauge (battery monitoring)
- USB Type-C OTG
- UFS 3.1 storage

## 5. Root Filesystem

### User account

- **Username:** `nabu`
- **Default password:** `cachyos` (enforced change on first login via `chage -d 0 nabu`)
- **Shell:** zsh (with CachyOS config)
- **Sudo:** passwordless (convenience for tinkering)
- **Auto-login:** via SDDM to KDE Plasma Wayland

### Package list

**Base system (official ALARM repos):**
```
base base-devel linux-firmware networkmanager bluez bluez-utils
sudo openssh btrfs-progs zram-generator iwd wget curl git vim nano
htop btop fastfetch man-db man-pages zsh fish
```

**KDE Plasma (official ALARM repos):**
```
plasma-desktop plasma-nm plasma-pa plasma-systemmonitor
sddm sddm-kcm bluedevil powerdevil kscreen
dolphin kate konsole ark spectacle gwenview
kcalc kinfocenter filelight kdegraphics-thumbnailers
ffmpegthumbs kde-gtk-config phonon-qt6-vlc
breeze-gtk kdeplasma-addons kdeconnect
```

**Tablet-specific (official ALARM repos):**
```
iio-sensor-proxy
xdg-desktop-portal-kde
qt6-virtualkeyboard
libwacom
```

Note: `xf86-input-wacom` is excluded — it is X11-only and unused on Wayland. Pen input is handled by libinput + `libwacom` device database.

**Audio/media (official ALARM repos):**
```
pipewire pipewire-pulse pipewire-alsa wireplumber
```

**Dev tools (official ALARM repos):**
```
python python-pip nodejs npm rustup
strace lsof iotop powertop
```

Note: `docker` and `podman` are excluded from the default install — they require additional kernel config (cgroups v2, overlayfs) which may not be in the sm8150 defconfig, and their daemons consume resources on every boot. Instead, a post-install script `~/bin/install-containers` is provided that enables the required kernel configs, installs docker/podman, and enables their services on demand.

**Fonts (official ALARM repos):**
```
noto-fonts noto-fonts-cjk noto-fonts-emoji
ttf-fantasque-nerd ttf-fira-sans
```

**AUR packages (built during image creation via `makepkg`):**
```
vivaldi
maliit-keyboard
maliit-framework
```

Note: `maliit-keyboard` and `maliit-framework` are not in official ALARM repos and must be built from AUR.

### CachyOS theming packages (all arch=any, built from git)

| Package | Repository | Purpose |
|---------|-----------|---------|
| cachyos-kde-settings | CachyOS/cachyos-kde-settings | Dark mode, floating panel, reduced animations, capitaine-cursors, CachyOS defaults |
| cachyos-wallpapers | CachyOS/cachyos-wallpapers | ~40 wallpapers, default: north.png |
| cachyos-themes-sddm | StarterX4/cachyos-themes-sddm | SimplyBlack and SoftGrey SDDM login themes |
| cachyos-nord-kde-theme | CachyOS/CachyOS-Nord-KDE | Nord color scheme, Plasma theme, Konsole theme |
| cachyos-fish-config | CachyOS PKGBUILDs | Fish shell CachyOS config |
| cachyos-zsh-config | CachyOS PKGBUILDs | Zsh CachyOS config |
| char-white | CachyOS/char-white | White cursor theme |
| cachyos-plymouth-bootanimation | CachyOS PKGBUILDs | Plymouth boot animation |

### CachyOS system tuning

**sysctl (`/etc/sysctl.d/70-cachyos.conf`):**
- `vm.swappiness=100` — aggressive ZRAM usage (critical with 6GB RAM)
- `vm.vfs_cache_pressure=50` — retain VFS cache
- `vm.dirty_bytes=268435456` — 256MB per-process dirty limit
- `vm.dirty_background_bytes=67108864` — 64MB background flusher
- `vm.page-cluster=0` — single-page ZRAM swap
- `kernel.nmi_watchdog=0` — power savings
- `net.core.netdev_max_backlog=4096` — larger network queue
- `fs.file-max=2097152` — 2M file handles

**ZRAM (`/etc/systemd/zram-generator.conf`):**
- Compression: zstd
- Size: full RAM (6GB)
- Priority: 100

**I/O scheduler (`/etc/udev/rules.d/60-ioschedulers.rules`):**
- UFS storage → ADIOS
- Fallback → mq-deadline

**systemd tuning:**
- Reduced timeouts: StartSec=15s, StopSec=10s
- Increased file limits: DefaultLimitNOFILE=2048:2097152
- Journal max 50MB
- cgroup delegation for user services

### Filesystem layout (Btrfs)

```
Subvolume   Mount point    Purpose
@           /              Root filesystem
@home       /home          User data
@snapshots  /.snapshots    Btrfs snapshots for rollback
```

Btrfs mount options: `compress=zstd:3,noatime,ssd,discard=async`

## 6. Partition Layout

Linux-only configuration — no Android userdata partition.

| # | Name | Type | Size | Content |
|---|------|------|------|---------|
| 1-30 | (stock) | various | ~10GB | PBL/XBL/ABL and other Qualcomm partitions. Untouched. |
| 31 | esp | FAT32 | 512MB | GRUB, kernel, initramfs, DTB |
| 32 | linux | Btrfs | ~117GB | Root filesystem with subvolumes |

## 7. Boot Chain

```
PBL (SoC ROM, immutable)
  → XBL (UFS Boot LUN)
    → ABL (reads boot_b slot)
      → UEFI firmware (EDK2, disguised as boot.img)
        → GRUB (from ESP partition)
          → Linux kernel + initramfs + DTB
            → systemd → NetworkManager, sshd, SDDM → KDE Plasma
```

### GRUB configuration

Generated by `build-image.sh` from a template, substituting `KERNEL_VERSION`:

```
set default=0
set timeout=3

menuentry "CachyOS Nabu (${KERNEL_VERSION})" {
    linux /vmlinuz-${KERNEL_VERSION}-cachyos-nabu root=PARTLABEL=linux rootflags=subvol=@ rw rootwait quiet splash
    initrd /initramfs-${KERNEL_VERSION}-cachyos-nabu.img
    devicetree /sm8150-xiaomi-nabu.dtb
}

menuentry "CachyOS Nabu (${KERNEL_VERSION}) - Verbose" {
    linux /vmlinuz-${KERNEL_VERSION}-cachyos-nabu root=PARTLABEL=linux rootflags=subvol=@ rw rootwait loglevel=7
    initrd /initramfs-${KERNEL_VERSION}-cachyos-nabu.img
    devicetree /sm8150-xiaomi-nabu.dtb
}
```

The second entry boots with verbose logging — useful for debugging boot issues. Both entries use the same kernel; the difference is `quiet splash` vs `loglevel=7`.

Note: mkinitcpio preset is configured to output `initramfs-${KERNEL_VERSION}-cachyos-nabu.img` to match the GRUB references.

## 8. Flash Process

### Prerequisites

- MacBook with `fastboot` and `adb` installed (`brew install android-platform-tools`)
- Tablet with unlocked bootloader (already done — running HyperOSPro custom ROM)
- USB-C cable connecting MacBook to tablet

### Flash script sequence

1. Boot tablet into fastboot mode (Volume Down + Power)
2. Flash UEFI firmware to `boot_b`: `fastboot flash boot_b output/boot.img`
3. Boot our custom recovery image: `fastboot boot output/recovery.img`
   - This recovery image is built by `recovery/build-recovery.sh` and contains: busybox, parted, sgdisk, dd, zstd, mkfs.fat, mkfs.btrfs
   - It boots into a minimal shell accessible via `adb shell`
4. Repartition via adb (GPT partition table, the most dangerous step):
   ```bash
   # Backup current partition table
   adb shell sgdisk --backup=/tmp/gpt-backup.bin /dev/block/sda
   # Expand GPT table to support more partitions
   adb shell sgdisk --resize-table 64 /dev/block/sda
   # Delete userdata (partition 31 in stock layout)
   adb shell sgdisk --delete=31 /dev/block/sda
   # Create ESP: partition 31, 512MB, type EF00 (EFI System Partition)
   adb shell sgdisk --new=31:0:+512M --typecode=31:EF00 --change-name=31:esp /dev/block/sda
   # Create linux: partition 32, remaining space, type 8300 (Linux filesystem)
   adb shell sgdisk --new=32:0:0 --typecode=32:8300 --change-name=32:linux /dev/block/sda
   # Verify partition table
   adb shell sgdisk --print /dev/block/sda
   # Format partitions
   adb shell mkfs.fat -F32 -n ESPNABU /dev/block/sda31
   # Note: Btrfs rootfs is written as a raw image, not formatted separately
   ```
5. Flash ESP via adb push + dd:
   ```bash
   adb push output/esp.img /tmp/esp.img
   adb shell dd if=/tmp/esp.img of=/dev/block/sda31 bs=4M
   ```
6. Flash rootfs via adb push + zstdcat + dd:
   ```bash
   adb push output/linux.img.zst /tmp/linux.img.zst
   adb shell "zstdcat /tmp/linux.img.zst | dd of=/dev/block/sda32 bs=4M"
   ```
7. Reboot to fastboot: `adb reboot bootloader`
8. Set active slot: `fastboot set_active b`
9. Reboot: `fastboot reboot`

### Recovery options

1. **GRUB verbose entry** — boots same kernel with `loglevel=7` for debugging
2. **Btrfs snapshots** — rollback filesystem changes (a `fresh-install` snapshot is created on first SSH)
3. **Fastboot always available** — Volume Down + Power enters fastboot from any state, regardless of OS state
4. **Reflash from build system** — re-run `flash.sh` to start over with a fresh image
5. **Full stock restore** — download Xiaomi official fastboot ROM, flash with Mi Flash Tool to restore Android completely

## 9. First Boot Experience

### Timeline

- 0s: Power on → UEFI loads
- 3s: GRUB auto-selects CachyOS Nabu
- 15s: Kernel booted, systemd starting services
- 25s: NetworkManager connects to WiFi
- 30s: sshd listening
- 45s: SDDM auto-login → KDE Plasma session
- 60s: Desktop ready, SSH available

### From MacBook

```bash
ssh nabu@<tablet-ip>
passwd                    # Change default password
sudo btrfs subvolume snapshot / /.snapshots/fresh-install
```

### KDE Plasma tablet configuration

- Session: Wayland
- Virtual keyboard: Maliit (auto-shows on text field focus)
- Panel: bottom, floating, auto-hide
- Display scaling: 150% (effective ~1707x1067)
- Night color: enabled, follows sunset/sunrise
- Auto-rotation: enabled via iio-sensor-proxy
- Touch gestures: 3-finger swipe up (overview), 4-finger swipe (switch desktop)

### Convenience scripts in ~/bin/

- `snapshot <name>` — create Btrfs snapshot
- `rollback` — list and restore snapshots
- `kernel-update` — rebuild kernel from latest sources

## 10. Hardware Support Matrix

| Feature | Status | Notes |
|---------|--------|-------|
| Display (2560x1600 120Hz) | Working | Novatek NT36523, freedreno GPU |
| Touchscreen (multi-touch) | Working | Full gesture support |
| Pen input | Working | Hover + drawing, no pressure in landscape |
| WiFi | Working | WCN3991, pre-configured |
| Bluetooth + audio | Working | BT 5.1, headphones/speakers |
| Speakers (quad) | Working | 4x CS35L41 via PipeWire |
| USB-C (OTG + charging) | Working | Dual-role, audio out |
| Battery monitoring | Working | QCOM fuel gauge, 8720mAh |
| GPU acceleration | Working | Adreno 640, Mesa freedreno |
| Auto-rotation | Working | Accelerometer + iio-sensor-proxy |
| SSH | Working | Auto-started on boot |
| Camera | Not working | No mainline driver |
| Microphone | Not working | No mainline driver |
| Suspend/resume | Partial | May not wake reliably |

## 11. Key Repositories and Resources

| Resource | URL |
|----------|-----|
| Kernel source | `https://gitlab.com/sm8150-mainline/linux` (branch: sm8150/6.14.11) |
| CachyOS kernel patches | `https://github.com/CachyOS/kernel-patches` (dir: 6.14/) |
| CachyOS settings | `https://github.com/CachyOS/CachyOS-Settings` |
| CachyOS KDE settings | `https://github.com/CachyOS/cachyos-kde-settings` |
| CachyOS wallpapers | `https://github.com/CachyOS/cachyos-wallpapers` |
| CachyOS Nord theme | `https://github.com/CachyOS/CachyOS-Nord-KDE` |
| UEFI firmware source | `https://github.com/map220v/MU-sm8150pkg` |
| TheMojoMan images | `https://github.com/TheMojoMan/xiaomi-nabu` |
| Nabu firmware blobs | `https://github.com/map220v/nabu-firmware` |
| nabu-fedora-builder (reference) | `https://github.com/nik012003/nabu-fedora-builder` |
| qbootctl | `https://github.com/linux-msm/qbootctl` |
| Telegram community | `https://t.me/nabulinux` |
