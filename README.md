# CachyOS Nabu

CachyOS ARM for the **Xiaomi Pad 5 (nabu)** — the first CachyOS on an ARM tablet.

## Easy Install (No Building Required)

Download the [latest release](https://github.com/FisiFla/nabu-cachyos/releases/latest), then:

1. Download **all files** from the release into one folder
2. Boot tablet into fastboot: **Vol Down + Power**
3. Run: `bash join-and-flash.sh`
4. CachyOS boots in ~60 seconds with GNOME touch UI and the on-screen keyboard enabled by default

Requirements: unlocked bootloader, USB-C cable, `fastboot` and `zstd` installed.
Optional: Docker running locally enables automatic SSH key injection into the image during flash.

---

## Building From Source

This repo also contains a Docker-based build system to produce the image from scratch.

## What This Is

- **Arch Linux ARM** base system bootstrapped via `pacstrap` inside Docker
- **CachyOS kernel** from [sm8150-mainline](https://gitlab.com/sm8150-mainline/linux) (branch `sm8150/6.17-wifi-fix`) with CachyOS patches: **BORE scheduler**, **BBR3 TCP**, 1000Hz timer, full preemption
- **GNOME Shell** desktop on Wayland with **working on-screen keyboard** for touch input
- **CachyOS GNOME settings** (dark theme, CachyOS wallpapers, dconf tuning)
- **CachyOS theming and tools** built from PKGBUILDs, including `cachyos-gnome-settings`, `cachyos-wallpapers`, `char-white`, `cachyos-plymouth-bootanimation`, `cachyos-fish-config`, `cachyos-zsh-config`, `cachyos-settings`, `cachyos-alacritty-config`, and `cachyos-packageinstaller`
- **Full zsh stack**: oh-my-zsh, powerlevel10k, zsh-syntax-highlighting, zsh-autosuggestions, fzf
- **Firefox + Vivaldi** browsers (Vivaldi via AUR aarch64 pre-built binaries)
- **`paru` AUR helper** pre-installed (`paru-bin`) so users can install AUR packages without bootstrapping `makepkg` first
- **Alacritty** terminal with CachyOS config
- **Working audio** with nabu UCM profiles
- **Dynamic CPU governor** (performance when charging, schedutil on battery)
- **`ananicy-cpp`** auto-renicer enabled at boot — keeps the UI responsive when heavy background tasks (e.g. AUR rebuilds) are running
- **MGLRU** enabled via tmpfiles for improved memory management
- **ADIOS I/O scheduler** set via udev rules
- **CachyOS branding**: custom `os-release`, fastfetch logo, Plymouth boot animation
- **USB serial gadget** for debugging via USB-C cable
- **Direct boot** via Android boot.img format (CachyOS kernel + DTB, no GRUB)
- WiFi, Bluetooth, touch screen, GPU acceleration (Adreno 640)
- Auto-login via GDM, connect to WiFi via GNOME Settings (touch-friendly)
- **First-run welcome dialog** (`nabu-welcome`) — touch-friendly GTK4 app that runs once on first login with shortcuts to set a password (none by default), install apps, and read the README
- **Tablet-style power button** — short press suspends, long press powers off (instead of systemd's default "every press powers off")
- **`qbootctl` mark-boot-successful** — runs once after multi-user.target so the bootloader's A/B retry counter resets cleanly on every successful boot (slot B no longer drifts toward unbootable)
- **NTP at boot** (`systemd-timesyncd`) — fixes the RTC drifting to year 2063 on cold boot, which breaks every SSL cert and pacman signature check

## What This Is NOT

- **Not a port of CachyOS x86.** Most CachyOS packages are x86-only. This project uses the nabu-specific kernel from sm8150-mainline and applies only the architecture-neutral CachyOS kernel patches.
- **Not using TheMojoMan's pre-built kernel.** The kernel is compiled from sm8150-mainline source with CachyOS patches (BORE, ADIOS, cachy-arm) layered on top. The `boot.img` contains the CachyOS kernel, not TheMojoMan's.
- **Not a dual-boot setup.** This overwrites the Android userdata partition. The Android slot (slot A) is preserved as a fallback.

## Prerequisites

| Requirement | Details |
|---|---|
| Build machine | macOS Apple Silicon (Docker runs natively), Linux aarch64, **or Linux x86_64** (the build cross-compiles the kernel via `aarch64-linux-gnu-gcc` + `ccache` to avoid qemu emulation on x86) |
| Docker | Via [Colima](https://github.com/abiosoft/colima) on macOS, or Docker Desktop / native Docker on Linux |
| Disk space | ~15 GB for build artifacts + Docker image |
| Xiaomi Pad 5 | Bootloader must be unlocked |
| USB-C cable | Direct connection between build machine and tablet |
| fastboot / adb | `brew install android-platform-tools` on macOS |
| vbmeta_disabled.img | Required to disable Android Verified Boot. The repo does not fetch it automatically; copy it into `output/` or point `release/create-release.sh` at it with `VBMETA_SOURCE=...` |

## Quick Start

```bash
# 1. Build boot.img + linux.img.zst
./build.sh

# 2. Package a local release bundle
VBMETA_SOURCE=/path/to/vbmeta_disabled.img bash release/create-release.sh

# 3. Flash (tablet must be in fastboot mode: hold Vol Down + Power)
bash release/dist/join-and-flash.sh
```

**Optional:** Pre-configure WiFi for headless/SSH access:
```bash
WIFI_SSID="YourNetwork" WIFI_PASSWORD="YourPassword" ./build.sh
```

## Build Process

`build.sh` orchestrates six stages, all running inside a Docker container built from the Arch Linux ARM rootfs tarball:

| Stage | Script | What it does |
|---|---|---|
| 1/6 | `build.sh` | Downloads ALARM rootfs tarball (if not cached) |
| 2/6 | `build.sh` | Builds Docker image from `Dockerfile` + ALARM tarball |
| 3/6 | `firmware/fetch-firmware.sh` | Clones [nabu firmware blobs](https://github.com/map220v/nabu-firmware) (WiFi, GPU, BT, audio) |
| 4/6 | `kernel/build-kernel.sh` | Clones sm8150-mainline kernel, applies CachyOS patches, compiles `Image.gz` + DTB + modules |
| 5/6 | `rootfs/build-rootfs.sh` | Bootstraps rootfs via `pacstrap`, installs kernel/firmware/packages, builds CachyOS theming + tools, configures system |
| 6/6 | `image/build-image.sh` | Creates the fastboot-flashed ext4 rootfs image (`linux.img.zst`) and checksums |

**Caching:** The pacstrap rootfs cache (`.cache/pacstrap-rootfs.tar`), the kernel source tree (`.cache/kernel-build-<KERNEL_VERSION>/`), the ccache directory (`.cache/ccache/`) and built kernel artifacts under `output/kernel/` all persist between builds. Delete the relevant subdirectory of `.cache/` and/or `output/kernel/` to force a full rebuild.

**Host kernel cross-compile (Linux x86_64 only):** When `aarch64-linux-gnu-gcc` and `mkbootimg` are present, `build.sh` builds the kernel natively on the host before launching Docker (stage 2.5/6). This skips qemu-aarch64 emulation entirely and brings the kernel compile from ~2 hours down to ~10-15 minutes. Force the legacy in-container path with `USE_HOST_KERNEL_BUILD=0`.

**CachyOS theming** is built from [CachyOS-PKGBUILDS](https://github.com/CachyOS/CachyOS-PKGBUILDS) and includes: `cachyos-gnome-settings`, `cachyos-wallpapers`, `char-white` cursor theme, `cachyos-plymouth-bootanimation`, `cachyos-fish-config`, `cachyos-zsh-config`.

**CachyOS tools** are also built from CachyOS-PKGBUILDS: `cachyos-settings` (sysctl tuning, systemd configs) and `cachyos-alacritty-config`.

## Flash Instructions

The flash process uses **fastboot only** — no recovery, no ADB, no repartitioning. It writes directly to slot B, preserving Android on slot A as a fallback.

If you built from source, create a release bundle first:

```bash
VBMETA_SOURCE=/path/to/vbmeta_disabled.img bash release/create-release.sh
cd release/dist
```

### Prerequisites

- Either:
  - a packaged release directory containing `join-and-flash.sh`, split `linux.img.zst.part-*`, `boot.img`, and `vbmeta_disabled.img`
  - or an unsplit directory containing `flash.sh`, `boot.img`, `linux.img.zst`, and `vbmeta_disabled.img`
- `fastboot` installed (`brew install android-platform-tools` on macOS)
- `zstd` installed (`brew install zstd` on macOS)

### Step by step

1. **Put the tablet in fastboot mode**: hold **Vol Down + Power** until the fastboot screen appears.

2. **Run the installer**:
   ```bash
   bash join-and-flash.sh
   ```

   If you already have an unsplit `linux.img.zst` next to `flash.sh`, you can run:

   ```bash
   bash flash.sh
   ```

3. The script will:
   - Erase `dtbo_b` and flash `vbmeta_disabled.img` to `vbmeta_b` (disables Android Verified Boot)
   - Flash `boot.img` to `boot_b` (CachyOS kernel + DTB)
   - Decompress `linux.img.zst`, optionally inject your local SSH public key, and flash the `linux` partition (~4 minutes)
   - Set active slot to B and reboot

4. CachyOS boots in about 60 seconds.

### Optional automatic SSH setup

If Docker is available on the machine running `flash.sh`, the installer will try to inject one local public key from `~/.ssh/` into `/home/nabu/.ssh/authorized_keys` before flashing. That makes the first boot reachable with:

```bash
ssh nabu@nabu-cachyos.local
```

Override the key file:

```bash
SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub bash release/flash.sh
```

Skip key injection entirely:

```bash
SKIP_SSH_KEY_INJECTION=1 bash release/flash.sh
```

### Recovery / rollback

If the tablet does not boot:

1. Hold **Vol Down + Power** to enter fastboot
2. Switch back to Android: `fastboot set_active a`
3. Or reflash with Xiaomi stock ROM

## Default Credentials

| Account | Password | Notes |
|---|---|---|
| `nabu` | _(none)_ | Auto-login via GDM. Passwordless `sudo` (`NOPASSWD: ALL` in `/etc/sudoers.d/zz-nabu-nopasswd`). Member of `wheel/video/audio/input`. |
| `root` | _(none)_ | Account is locked from password login. SSH root only via key (`PermitRootLogin yes`, no password auth). |

**Want a password?** Run `passwd` (no current password needed). To make `sudo` prompt for it, also delete `/etc/sudoers.d/zz-nabu-nopasswd`.

PAM rejects empty-password login (no `nullok` set), so this combination is safe in practice: GDM auto-logs in without prompting, `sudo` doesn't ask, SSH requires keys.

SSH is enabled by default. Connect after boot:
```bash
ssh nabu@nabu-cachyos.local    # via mDNS (recommended)
ssh nabu@<tablet-ip>            # via IP address
```

## Known Limitations

- **Camera** -- no mainline driver, does not work on any Linux distro for nabu
- **Auto-rotation** -- the LSM6DSO accelerometer is on I2C bus QUP SE2 (GPIO 126-127), but these pins are reserved by TrustZone secure firmware. Touching them causes the kernel to fail at boot (confirmed: shrinking `gpio-reserved-ranges` drains the A/B retry counter in seconds). The remaining path is the ADSP/SLPI userspace sensor stack (`libssc` + `sns-reg` + a patched `iio-sensor-proxy`) — a separate multi-day project. Manual rotation works fine via Settings → Displays → Orientation.
- **Suspend** -- s2idle wakes back up within ~1 second of entering it because the `msm_mdss` display controller keeps firing IRQs that the kernel can't mask during shallow suspend (no `deep`/S3 path is exposed on sm8150 mainline — only `[s2idle]` in `/sys/power/mem_sleep`). For this reason the build ships with `HandlePowerKey=ignore` (short press does nothing, long press still powers off). The GNOME top-right menu still has "Suspend" but it will resume itself within seconds. Real suspend needs a kernel-side patch to quiesce the DRM IRQs during s2idle, or proper S3 support upstream.
- **Warm-reboot black screen** -- `fastboot reboot` and `sudo systemctl reboot` sometimes drop into a black screen with no display + no USB enumeration. Cold-power-cycle recovers (hold Power ~15 sec, then short-press). Cause: panel-init race on warm transition through the bootloader. Cold boot from full power-off is reliable.
- **`cachyos-packageinstaller`** -- AUR PKGBUILD currently fails on aarch64 against ALARM headers; the build catches and skips it. No alternative GUI installer is shipped right now.
- **`dbus-broker` replaced with `dbus-daemon`** -- the sm8150 mainline kernel lacks namespace support required by dbus-broker
- **Pen pressure sensitivity** -- does not work in landscape mode (known upstream issue)
- **CachyOS kernel patches** -- ADIOS and cachy-arm patches still don't apply cleanly against the sm8150 tree and are skipped (build continues without them). BORE and BBR3 _do_ apply on the 6.17 tree.

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
| | BBR3 TCP | Applied (the 6.14 `tcp_input.c` conflict is gone on the 6.17 tree) |
| | sched-ext | Config enabled + `scx-scheds` userspace tools shipped (start with `systemctl start scx_lavd`) |
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
| **Packages** | cachyos-settings | Installed |
| **Branding** | os-release, fastfetch logo | Applied |
| **N/A** | x86 repo packages (LTO/PGO) | ARM — built from PKGBUILDS |
| | Proton/Wine gaming | x86 only |
| | systemd-boot | Direct boot instead |
| | cachyos-hello | x86 binary — replaced by `nabu-welcome`, a touch-friendly GTK4 first-run dialog |
| | Multiple kernel variants | Single sm8150 kernel |

## Technical Details

### Boot chain

```
PBL (ROM) -> XBL -> ABL -> boot.img (CachyOS kernel + DTB, Android bootimg format) -> ext4 rootfs
```

The boot.img is a direct-boot Android boot image (header v0) containing the CachyOS kernel with DTB appended. Kernel cmdline: `root=PARTLABEL=linux rw`. The rootfs lives on an ext4 partition (`PARTLABEL=linux`). No GRUB or UEFI involved in the actual boot.

### Qualcomm userspace

WiFi on nabu requires Qualcomm userspace that is not available in Arch repos:

- `rmtfs` -- remote filesystem service
- `tqftpserv` -- TFTP service for firmware loading
- `libqrtr` -- QRTR userspace library used by those services

These are built from source during the rootfs build stage from their upstream [linux-msm](https://github.com/linux-msm) repositories (all BSD-3-Clause licensed). `qrtr-ns` is intentionally not used because kernel 6.14 provides in-kernel QRTR name service support.

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
| `0002-bbr3.patch` | BBR3 TCP congestion control | Applied on the 6.17 tree |
| `0003-adios.patch` | ADIOS I/O scheduler | Best-effort |
| `0004-cachy-arm.patch` | ARM-compatible bits from CachyOS (HZ options, PREEMPT_LAZY, THP tuning, v4l2loopback) | Best-effort |

## Repository Structure

```
nabu-cachyos/
├── build.sh                    # Main build orchestrator
├── Dockerfile                  # Docker image (ALARM-based build environment)
├── .dockerignore               # Keeps large local artifacts out of Docker build context
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
│           └── bin/            # Helper scripts (kernel-update, install-containers)
├── image/
│   └── build-image.sh          # Creates the flashable linux.img.zst rootfs image
├── release/
│   ├── create-release.sh       # Packages output/ into a release-ready dist/ directory
│   ├── flash.sh                # Flashes an unsplit local image set via fastboot
│   ├── inject-ssh-key.sh       # Optionally injects a local SSH public key into linux.img
│   └── join-and-flash.sh       # Reassembles split rootfs parts, then runs flash.sh
└── output/                     # Build artifacts (boot.img, linux.img.zst, checksums, kernel/, firmware/)
```

## Credits and Attribution

This project would not be possible without the work of these projects and people:

- **[TheMojoMan](https://github.com/TheMojoMan/xiaomi-nabu)** -- Boot.img and UEFI firmware for nabu.
- **[linux-msm](https://github.com/linux-msm)** -- Qualcomm userspace daemons (qrtr, rmtfs, tqftpserv) built from source for WiFi support.
- **[sm8150-mainline](https://gitlab.com/sm8150-mainline/linux)** -- Mainline Linux kernel with Snapdragon 855 (sm8150) support, the foundation for nabu Linux support.
- **[CachyOS](https://cachyos.org/)** -- Kernel patches (BORE, BBR3, ADIOS), theming packages, system tuning configs, and PKGBUILD recipes via [CachyOS-PKGBUILDS](https://github.com/CachyOS/CachyOS-PKGBUILDS).
- **[map220v](https://github.com/map220v/nabu-firmware)** -- Nabu-specific firmware blobs (WiFi WCN3991, Adreno 640 GPU, Bluetooth, audio codec) required for hardware functionality.
- **[Arch Linux ARM](https://archlinuxarm.org/)** -- The base system and package repositories.
- **[nabu Linux community](https://t.me/nabulinux)** -- Collective knowledge, testing, and documentation for running Linux on the Xiaomi Pad 5.

## License

This project is licensed under the [GPL-2.0](LICENSE), matching the Linux kernel. The components downloaded and assembled during the build are subject to their own respective licenses (GPL for the kernel, BSD-3 for Qualcomm userspace tools, various licenses for CachyOS packages, etc.).
