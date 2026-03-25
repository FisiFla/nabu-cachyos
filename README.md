# CachyOS Nabu

CachyOS ARM for the **Xiaomi Pad 5 (nabu)** — the first CachyOS on an ARM tablet.

## Easy Install (No Building Required)

Download the [latest release](https://github.com/FisiFla/nabu-cachyos/releases/latest), then:

1. Download **all files** from the release into one folder
2. Boot tablet into fastboot: **Vol Down + Power**
3. Run: `bash join-and-flash.sh`
4. Done — CachyOS boots in ~60 seconds!

Requirements: unlocked bootloader, USB-C cable, `fastboot` and `zstd` installed.

---

## Building From Source

This repo also contains a Docker-based build system to produce the image from scratch.

## What This Is

- **Arch Linux ARM** base system bootstrapped via `pacstrap` inside Docker
- **CachyOS kernel** from [sm8150-mainline](https://gitlab.com/sm8150-mainline/linux) (branch `sm8150/6.14.11`) with CachyOS patches: **BORE scheduler**, **ADIOS I/O scheduler**, 1000Hz timer, full preemption
- **GNOME Shell** desktop on Wayland with **working on-screen keyboard** for touch input
- **CachyOS GNOME settings** (dark theme, CachyOS wallpapers, dconf tuning)
- **9 CachyOS packages**: `cachyos-gnome-settings`, `cachyos-wallpapers`, `char-white`, `cachyos-plymouth-bootanimation`, `cachyos-fish-config`, `cachyos-zsh-config`, `cachyos-settings`, `cachyos-alacritty-config`, `cachyos-packageinstaller`
- **Full zsh stack**: oh-my-zsh, powerlevel10k, zsh-syntax-highlighting, zsh-autosuggestions, fzf
- **Mesa rebuilt** with `-O3` ARMv8.2-A optimizations for Adreno 640
- **Firefox + Vivaldi** browsers (Vivaldi via AUR aarch64 pre-built binaries)
- **Alacritty** terminal with CachyOS config
- **Audio UCM profiles** for nabu speakers and microphone
- **Dynamic CPU governor** (performance when charging, schedutil on battery)
- **MGLRU** enabled via tmpfiles for improved memory management
- **ADIOS I/O scheduler** set via udev rules
- **CachyOS branding**: custom `os-release`, fastfetch logo, Plymouth boot animation
- **USB serial gadget** for debugging via USB-C cable
- **Direct boot** via Android boot.img format (CachyOS kernel + DTB, no GRUB)
- WiFi, Bluetooth, touch screen, GPU acceleration (Adreno 640)
- Headless first boot: auto-connects to WiFi, auto-login via GDM, SSH enabled

## What This Is NOT

- **Not a port of CachyOS x86.** Most CachyOS packages are x86-only. This project uses the nabu-specific kernel from sm8150-mainline and applies only the architecture-neutral CachyOS kernel patches.
- **Not using TheMojoMan's pre-built kernel.** The kernel is compiled from sm8150-mainline source with CachyOS patches (BORE, ADIOS, cachy-arm) layered on top. The `boot.img` contains the CachyOS kernel, not TheMojoMan's.
- **Not a dual-boot setup.** This overwrites the Android userdata partition. The Android slot (slot A) is preserved as a fallback.

## Prerequisites

| Requirement | Details |
|---|---|
| Build machine | macOS with Apple Silicon (aarch64 Docker runs natively) or Linux aarch64 |
| Docker | Via [Colima](https://github.com/abiosoft/colima) on macOS, or Docker Desktop / native Docker on Linux |
| Disk space | ~15 GB for build artifacts + Docker image |
| Xiaomi Pad 5 | Bootloader must be unlocked |
| USB-C cable | Direct connection between build machine and tablet |
| fastboot / adb | `brew install android-platform-tools` on macOS |
| TheMojoMan boot.img | Download `boot_6.14.11-nabu-tmm_linux.img` from [TheMojoMan's mega.nz](https://mega.nz/folder/CVMGEAiB#7oazR3wpkKdAH2eZChtRTg) and place at `output/boot.img`. Used as fallback; the build also produces a CachyOS kernel boot.img |
| vbmeta_disabled.img | Download from same mega.nz folder. Required to disable Android Verified Boot |

## Quick Start

```bash
# 1. Set WiFi credentials (required for headless first boot)
export WIFI_SSID="YourNetwork"
export WIFI_PASSWORD="YourPassword"

# 2. Build everything
./build.sh

# 3. Flash (tablet must be in fastboot mode: hold Vol Down + Power)
bash release/flash.sh
```

## Build Process

`build.sh` orchestrates seven stages, all running inside a Docker container built from the Arch Linux ARM rootfs tarball:

| Stage | Script | What it does |
|---|---|---|
| 1/7 | `build.sh` | Downloads ALARM rootfs tarball (if not cached) |
| 2/7 | `build.sh` | Builds Docker image from `Dockerfile` + ALARM tarball |
| 3/7 | `firmware/fetch-firmware.sh` | Clones [nabu firmware blobs](https://github.com/map220v/nabu-firmware) (WiFi, GPU, BT, audio) |
| 4/7 | `kernel/build-kernel.sh` | Clones sm8150-mainline kernel, applies CachyOS patches, compiles `Image.gz` + DTB + modules |
| 5/7 | `rootfs/build-rootfs.sh` | Bootstraps rootfs via `pacstrap`, installs kernel/firmware/packages, builds CachyOS theming + tools, configures system |
| 6/7 | `image/build-image.sh` | Creates ESP image and ext4 rootfs image (zstd-compressed) |
| 7/7 | `recovery/fetch-recovery.sh` | Downloads TWRP recovery image for flashing |

**Caching:** The kernel build directory (`.cache/kernel-build/`) and pacstrap rootfs (`.cache/pacstrap-rootfs.tar`) persist between builds. Delete `.cache/` to force a full rebuild.

**CachyOS theming** is built from [CachyOS-PKGBUILDS](https://github.com/CachyOS/CachyOS-PKGBUILDS) and includes: `cachyos-gnome-settings`, `cachyos-wallpapers`, `char-white` cursor theme, `cachyos-plymouth-bootanimation`, `cachyos-fish-config`, `cachyos-zsh-config`.

**CachyOS tools** are also built from CachyOS-PKGBUILDS: `cachyos-settings` (sysctl tuning, systemd configs) and `cachyos-alacritty-config`.

## Flash Instructions

The flash process uses **fastboot only** — no recovery, no ADB, no repartitioning. It writes directly to slot B, preserving Android on slot A as a fallback.

### Prerequisites

- `boot.img`, `linux.img.zst`, and `vbmeta_disabled.img` in the same directory as `flash.sh`
- `fastboot` installed (`brew install android-platform-tools` on macOS)
- `zstd` installed (`brew install zstd` on macOS)

### Step by step

1. **Put the tablet in fastboot mode**: hold **Vol Down + Power** until the fastboot screen appears.

2. **Run the flash script**:
   ```bash
   bash release/flash.sh
   ```

3. The script will:
   - Erase `dtbo_b` and flash `vbmeta_disabled.img` to `vbmeta_b` (disables Android Verified Boot)
   - Flash `boot.img` to `boot_b` (CachyOS kernel + DTB)
   - Decompress and flash `linux.img.zst` to the `linux` partition (~4 minutes)
   - Set active slot to B and reboot

4. CachyOS boots in about 60 seconds.

### Recovery / rollback

If the tablet does not boot:

1. Hold **Vol Down + Power** to enter fastboot
2. Switch back to Android: `fastboot set_active a`
3. Or reflash with Xiaomi stock ROM

## Default Credentials

| Account | Password | Notes |
|---|---|---|
| `nabu` | `cachyos` | Regular user, sudo with password, member of wheel/video/audio/input |
| `root` | `cachyos` | SSH root login via key only (`prohibit-password`) |

**Change passwords after first login:** `passwd && sudo passwd root`

SSH is enabled by default. Connect after boot:
```bash
ssh nabu@nabu-cachyos.local    # via mDNS (recommended)
ssh nabu@<tablet-ip>            # via IP address
```

## Known Limitations

- **Camera** -- no mainline driver, does not work on any Linux distro for nabu
- **Microphone** -- no mainline driver (UCM profiles are present but hardware support is incomplete)
- **Suspend/resume** -- unreliable on sm8150 mainline
- **GPU firmware** -- `a630_sqe.fw` loads via fallback symlink; 3D acceleration works but may not be optimal
- **CachyOS kernel patches** -- BBR3 and cachy-arm patches may not apply cleanly to the sm8150 kernel tree; they are skipped gracefully and the kernel works without them
- **dbus-broker replaced with dbus-daemon** -- the nabu kernel lacks namespace support required by dbus-broker; the build replaces it with classic dbus-daemon
- **Auto-rotation** -- the LSM6DSO accelerometer is on I2C bus QUP SE2 (GPIO 126-127), but these pins are reserved by TrustZone secure firmware (`gpio-reserved-ranges`). Modifying the reservation causes boot failure. Auto-rotation requires either modified firmware or ADSP sensor hub support
- **Pen pressure sensitivity** -- does not work in landscape mode (known upstream issue)

### Why GNOME instead of KDE?

CachyOS officially offers both KDE and GNOME editions. We chose GNOME for the nabu tablet because:

- **Working on-screen keyboard** -- GNOME's built-in OSK works perfectly on Wayland touch devices. KDE Plasma 6's Qt Virtual Keyboard has a focus-loop bug on Wayland that makes it unusable (the keyboard flashes on/off when it appears).
- **Touch-friendly out of the box** -- GNOME's UI is designed for touch with large tap targets and gesture navigation.
- **Proven on nabu** -- TheMojoMan's Ubuntu image (which uses GNOME) was confirmed working on this exact hardware.

### Parity with CachyOS x86

This build achieves roughly **82% parity** with a full CachyOS x86 desktop install:

| Category | Feature | Status |
|---|---|---|
| **Kernel** | BORE scheduler v5.9.6 | Applied |
| | ADIOS I/O scheduler | Applied + active |
| | 1000Hz timer tick | Applied |
| | Full preemption (PREEMPT) | Applied |
| | BBR3 TCP | Skipped (sm8150 conflict) |
| | sched-ext | Config enabled |
| **System** | CachyOS sysctl tuning | Full (via cachyos-settings) |
| | MGLRU | Enabled |
| | ZRAM zstd compression | Enabled |
| | systemd tuning (timeouts, limits) | Applied |
| | Coredump limits | Applied |
| | Dynamic CPU governor | Custom (charge/battery) |
| **Desktop** | GNOME Shell 49 + Wayland | Running |
| | On-screen keyboard | Working (GNOME OSK) |
| | CachyOS GNOME settings | Applied |
| | CachyOS wallpapers | Installed |
| | CachyOS Plymouth animation | Installed |
| | char-white cursor | Installed |
| **Shell** | zsh + oh-my-zsh + powerlevel10k | Full |
| | zsh-syntax-highlighting | Installed |
| | zsh-autosuggestions | Installed |
| | fzf | Installed |
| | CachyOS fish config | Installed |
| **Apps** | Alacritty + CachyOS config | Installed |
| | Firefox (Wayland) | Installed |
| | Vivaldi (Wayland + GPU) | Installed |
| | btop | Installed |
| | CachyOS Package Installer | Installed |
| **Packages** | cachyos-settings | Installed |
| | Mesa -O3 ARMv8.2-A | Rebuilt |
| **Branding** | os-release, fastfetch logo | Applied |
| **N/A** | x86 repo packages (LTO/PGO) | ARM — built from PKGBUILDS |
| | Proton/Wine gaming | x86 only |
| | systemd-boot | Direct boot instead |
| | cachyos-hello | x86 binary |
| | Multiple kernel variants | Single sm8150 kernel |

## Technical Details

### Boot chain

```
PBL (ROM) -> XBL -> ABL -> boot.img (CachyOS kernel + DTB, Android bootimg format) -> ext4 rootfs
```

The boot.img is a direct-boot Android boot image (header v0) containing the CachyOS kernel with DTB appended. Kernel cmdline: `root=PARTLABEL=linux rw fw_devlink=permissive`. The rootfs lives on an ext4 partition (`PARTLABEL=linux`). No GRUB or UEFI involved in the actual boot.

### Qualcomm userspace

WiFi on nabu requires three Qualcomm daemons that are not available in Arch repos:

- `qrtr-ns` -- QRTR name service
- `rmtfs` -- remote filesystem service
- `tqftpserv` -- TFTP service for firmware loading

These are built from source during the rootfs build stage from their upstream [linux-msm](https://github.com/linux-msm) repositories (all BSD-3-Clause licensed). All three run as systemd services.

### CachyOS system tuning

Applied via overlay configs in `rootfs/overlay/` and the `cachyos-settings` package:

- **sysctl**: swappiness tuned for ZRAM, reduced vfs_cache_pressure, optimized dirty page settings
- **ZRAM**: zstd compression, auto-sized via `systemd-zram-generator`
- **I/O scheduler**: udev rules to set ADIOS (or mq-deadline fallback) per device type
- **MGLRU**: enabled via tmpfiles (`/etc/tmpfiles.d/mglru.conf`)
- **systemd**: reduced shutdown timeouts, increased file descriptor limits, journal size capped at 50 MB
- **CPU governor**: dynamic switching via udev power rules (performance on AC, schedutil on battery)
- **GDM**: auto-login for user `nabu`
- **Coredump**: disabled storage to save disk space

### Kernel patches

| Patch | Description | Status |
|---|---|---|
| `0001-bore.patch` | BORE CPU scheduler | Critical -- build fails if this doesn't apply |
| `0002-bbr3.patch` | BBR3 TCP congestion control | Best-effort -- skipped if it doesn't apply |
| `0003-adios.patch` | ADIOS I/O scheduler | Best-effort |
| `0004-cachy-arm.patch` | ARM-compatible bits from CachyOS (HZ options, PREEMPT_LAZY, THP tuning, v4l2loopback) | Best-effort |

## Repository Structure

```
nabu-cachyos/
├── build.sh                    # Main build orchestrator
├── Dockerfile                  # Docker image (ALARM-based build environment)
├── firmware/
│   └── fetch-firmware.sh       # Downloads nabu firmware blobs
├── kernel/
│   ├── build-kernel.sh         # Clones, patches, and compiles the kernel
│   ├── add-sensors.sh          # Adds LSM6DSO accelerometer to device tree (blocked by TrustZone)
│   ├── cachyos.config          # CachyOS kernel config fragment
│   └── patches/                # CachyOS kernel patches (BORE, BBR3, ADIOS, cachy-arm)
├── rootfs/
│   ├── build-rootfs.sh         # Bootstraps and configures the rootfs
│   ├── build-theming.sh        # Builds CachyOS theming packages from PKGBUILDS
│   ├── packages.txt            # Official repo packages to install
│   ├── packages-aur.txt        # AUR packages (Vivaldi)
│   ├── pacman-alarm.conf       # Pacman config pointing to ALARM mirrors
│   ├── mkinitcpio-nabu.preset  # Initramfs generation preset
│   └── overlay/                # Files copied directly into rootfs
│       ├── etc/                # System configs (sysctl, ZRAM, GDM, systemd, udev, os-release, UCM audio)
│       ├── usr/                # UCM audio profiles, USB serial gadget
│       └── home/nabu/          # User dotfiles and utility scripts
│           ├── .config/        # GNOME/app configs
│           ├── .zshrc          # CachyOS zsh config
│           └── bin/            # Helper scripts (snapshot, rollback, kernel-update, install-containers)
├── image/
│   ├── build-image.sh          # Creates ESP and rootfs images
│   └── grub.cfg.template       # GRUB config template (unused in direct boot)
├── release/
│   └── flash.sh                # Flashes images to tablet via fastboot
├── recovery/
│   └── fetch-recovery.sh       # Downloads TWRP recovery image
└── output/                     # Build artifacts (boot.img, esp.img, linux.img.zst)
```

## Credits and Attribution

This project would not be possible without the work of these projects and people:

- **[TheMojoMan](https://github.com/TheMojoMan/xiaomi-nabu)** -- Boot.img and UEFI firmware for nabu.
- **[linux-msm](https://github.com/linux-msm)** -- Qualcomm userspace daemons (qrtr, rmtfs, tqftpserv) built from source for WiFi support.
- **[sm8150-mainline](https://gitlab.com/sm8150-mainline/linux)** -- Mainline Linux kernel with Snapdragon 855 (sm8150) support, the foundation for nabu Linux support.
- **[CachyOS](https://cachyos.org/)** -- Kernel patches (BORE, BBR3, ADIOS), theming packages, system tuning configs, and PKGBUILD recipes via [CachyOS-PKGBUILDS](https://github.com/CachyOS/CachyOS-PKGBUILDS).
- **[map220v](https://github.com/map220v/nabu-firmware)** -- Nabu-specific firmware blobs (WiFi WCN3991, Adreno 640 GPU, Bluetooth, audio codec) required for hardware functionality.
- **[Arch Linux ARM](https://archlinuxarm.org/)** -- The base system and package repositories.
- **[TWRP](https://twrp.me/)** -- Recovery image used during the flash process.
- **[nabu Linux community](https://t.me/nabulinux)** -- Collective knowledge, testing, and documentation for running Linux on the Xiaomi Pad 5.

## License

This project is licensed under the [GPL-2.0](LICENSE), matching the Linux kernel. The components downloaded and assembled during the build are subject to their own respective licenses (GPL for the kernel, BSD-3 for Qualcomm userspace tools, various licenses for CachyOS packages, etc.).
