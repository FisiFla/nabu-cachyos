# CachyOS Nabu

A Docker-based build system that produces a flashable CachyOS-flavored Arch Linux ARM image for the **Xiaomi Pad 5 (nabu)** tablet.

## What This Is

- **Arch Linux ARM** base system bootstrapped via `pacstrap` inside Docker
- **CachyOS theming**: Nord color scheme, CachyOS wallpapers, SDDM themes, Plymouth boot animation, shell configs (fish + zsh)
- **KDE Plasma 6** desktop with touch-friendly settings (reduced animations, on-screen keyboard via Maliit)
- **Vivaldi** browser (aarch64 pre-built binaries from AUR)
- **Custom kernel** from the [sm8150-mainline](https://gitlab.com/sm8150-mainline/linux) project (branch `sm8150/6.14.11`) with CachyOS patches (BORE scheduler, ADIOS I/O scheduler, BBR3 TCP) applied where possible
- **UEFI + GRUB boot chain** using TheMojoMan's EDK2 firmware
- WiFi, Bluetooth, touch screen, GPU acceleration (Adreno 640)
- Headless first boot: auto-connects to WiFi, auto-login via SDDM, SSH enabled

## What This Is NOT

- **Not a port of CachyOS x86.** Most CachyOS packages are x86-only. This project uses the nabu-specific kernel from sm8150-mainline and applies only the architecture-neutral CachyOS kernel patches.
- **Not using the CachyOS custom kernel.** The kernel comes from sm8150-mainline, with CachyOS patches (BORE, BBR3, ADIOS, cachy-arm) layered on top. Some patches (BBR3, cachy-arm) may not apply cleanly to the sm8150 tree and are skipped gracefully.
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
| Ubuntu nabu image | TheMojoMan's Ubuntu 25.04 image (source for Qualcomm userspace binaries). Place at `../nabu/Ubuntu 25.04 (Plucky Puffin)/ubuntu-25.04.img` relative to this repo |
| boot.img (UEFI) | Download `boot_6.14.11-nabu-tmm_linux.img` from [TheMojoMan's mega.nz](https://mega.nz/folder/CVMGEAiB#7oazR3wpkKdAH2eZChtRTg) and place at `output/boot.img` |

## Quick Start

```bash
# 1. Set WiFi credentials (required for headless first boot)
export WIFI_SSID="YourNetwork"
export WIFI_PASSWORD="YourPassword"

# 2. Build everything
./build.sh

# 3. Flash (tablet must be in fastboot mode: hold Vol Down + Power)
bash image/flash.sh
```

## Build Process

`build.sh` orchestrates seven stages, all running inside a Docker container built from the Arch Linux ARM rootfs tarball:

| Stage | Script | What it does |
|---|---|---|
| 1/7 | `build.sh` | Downloads ALARM rootfs tarball (if not cached) |
| 2/7 | `build.sh` | Builds Docker image from `Dockerfile` + ALARM tarball |
| 3/7 | `firmware/fetch-firmware.sh` | Clones [nabu firmware blobs](https://github.com/map220v/nabu-firmware) (WiFi, GPU, BT, audio) |
| 4/7 | `kernel/build-kernel.sh` | Clones sm8150-mainline kernel, applies CachyOS patches, compiles `Image.gz` + DTB + modules |
| 5/7 | `rootfs/build-rootfs.sh` | Bootstraps rootfs via `pacstrap`, installs kernel/firmware/packages, configures system |
| 6/7 | `image/build-image.sh` | Creates ESP image (GRUB + kernel + initramfs) and ext4 rootfs image (zstd-compressed) |
| 7/7 | `recovery/fetch-recovery.sh` | Downloads TWRP recovery image for flashing |

**Caching:** The kernel build directory (`.cache/kernel-build/`) and pacstrap rootfs (`.cache/pacstrap-rootfs.tar`) persist between builds. Delete `.cache/` to force a full rebuild.

**CachyOS theming** is built from [CachyOS-PKGBUILDS](https://github.com/CachyOS/CachyOS-PKGBUILDS) and includes: `cachyos-kde-settings`, `cachyos-wallpapers`, `cachyos-themes-sddm`, `cachyos-nord-kde`, `char-white` cursor theme, `cachyos-plymouth-bootanimation`, `cachyos-fish-config`, `cachyos-zsh-config`.

## Flash Instructions

The flash process uses TWRP recovery to repartition and write images via ADB.

### Step by step

1. **Download boot.img** from [TheMojoMan's mega.nz](https://mega.nz/folder/CVMGEAiB#7oazR3wpkKdAH2eZChtRTg) (file: `boot_6.14.11-nabu-tmm_linux.img`) and place it at `output/boot.img`.

2. **Put the tablet in fastboot mode**: hold **Vol Down + Power** until the fastboot screen appears.

3. **Run the flash script**:
   ```bash
   bash image/flash.sh
   ```

4. The script will:
   - Flash UEFI firmware to `boot_b`
   - Boot into TWRP recovery
   - Back up the partition table to `output/gpt-backup.bin`
   - Repartition: delete `userdata`, create 1 GB ESP (partition 31) + Linux root (partition 32, remaining space)
   - Format and flash the ESP image
   - Flash the zstd-compressed rootfs image
   - Set active slot to B and reboot

5. The tablet should boot into CachyOS in about 60 seconds.

### Recovery / rollback

If the tablet does not boot:

1. Hold **Vol Down + Power** to enter fastboot
2. Switch back to Android: `fastboot set_active a`
3. Or reflash with Xiaomi stock ROM

## Default Credentials

| Account | Password | Notes |
|---|---|---|
| `nabu` | `cachyos` | Regular user, passwordless sudo, member of wheel/video/audio/input |
| `root` | *(no password set)* | SSH root login enabled via `PermitRootLogin yes` |

SSH is enabled by default. Connect after boot:
```bash
ssh nabu@<tablet-ip>
```

## Known Limitations

- **Camera** -- no mainline driver, does not work on any Linux distro for nabu
- **Microphone** -- no mainline driver
- **Suspend/resume** -- unreliable on sm8150 mainline
- **Audio output** -- PipeWire runs but UCM (Use Case Manager) profiles for nabu speakers may need manual configuration
- **GPU firmware** -- `a630_sqe.fw` loads via fallback symlink; 3D acceleration works but may not be optimal
- **CachyOS kernel patches** -- BBR3 and cachy-arm patches may not apply cleanly to the sm8150 kernel tree; they are skipped gracefully and the kernel works without them
- **dbus-broker replaced with dbus-daemon** -- the nabu kernel lacks namespace support required by dbus-broker; the build replaces it with classic dbus-daemon
- **Pen pressure sensitivity** -- does not work in landscape mode (known upstream issue)

## Technical Details

### Boot chain

```
PBL (ROM) -> XBL -> ABL -> boot.img (TheMojoMan's UEFI/EDK2) -> GRUB (from ESP) -> Kernel + initramfs + DTB
```

The ESP partition contains GRUB (`arm64-efi`), the kernel (`vmlinuz-*`), initramfs, and device tree blob. The rootfs lives on a separate ext4 partition (`PARTLABEL=linux`).

### Qualcomm userspace

WiFi on nabu requires three Qualcomm daemons that are not available in Arch repos:

- `qrtr-ns` -- QRTR name service
- `rmtfs` -- remote filesystem service
- `tqftpserv` -- TFTP service for firmware loading

These binaries (plus `libqrtr`) are extracted from TheMojoMan's Ubuntu 25.04 nabu image and installed into the rootfs. All three run as systemd services.

### CachyOS system tuning

Applied via overlay configs in `rootfs/overlay/`:

- **sysctl**: swappiness tuned for ZRAM, reduced vfs_cache_pressure, optimized dirty page settings
- **ZRAM**: zstd compression, auto-sized via `systemd-zram-generator`
- **I/O scheduler**: udev rules to set optimal scheduler per device type
- **systemd**: reduced shutdown timeouts, increased file descriptor limits, journal size capped at 50 MB
- **SDDM**: auto-login for user `nabu`

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
│   ├── cachyos.config          # CachyOS kernel config fragment
│   └── patches/                # CachyOS kernel patches (BORE, BBR3, ADIOS, cachy-arm)
├── rootfs/
│   ├── build-rootfs.sh         # Bootstraps and configures the rootfs
│   ├── build-theming.sh        # Builds CachyOS theming packages from PKGBUILDS
│   ├── packages.txt            # Official repo packages to install
│   ├── packages-aur.txt        # AUR packages (Vivaldi, Maliit)
│   ├── pacman-alarm.conf       # Pacman config pointing to ALARM mirrors
│   ├── mkinitcpio-nabu.preset  # Initramfs generation preset
│   └── overlay/                # Files copied directly into rootfs
│       ├── etc/                # System configs (sysctl, ZRAM, SDDM, systemd, NetworkManager)
│       └── home/nabu/          # User dotfiles and utility scripts
│           ├── .config/        # KDE/Plasma config (Nord theme, touch optimizations)
│           └── bin/            # Helper scripts (snapshot, rollback, kernel-update, install-containers)
├── image/
│   ├── build-image.sh          # Creates ESP and rootfs images
│   ├── flash.sh                # Flashes images to tablet via fastboot/adb
│   └── grub.cfg.template       # GRUB config template
├── recovery/
│   └── fetch-recovery.sh       # Downloads TWRP recovery image
└── output/                     # Build artifacts (boot.img, esp.img, linux.img.zst)
```

## Credits and Attribution

This project would not be possible without the work of these projects and people:

- **[TheMojoMan](https://github.com/TheMojoMan/xiaomi-nabu)** -- UEFI boot.img (EDK2 firmware) and kernel builds for nabu. The Ubuntu 25.04 nabu image is the source for Qualcomm userspace binaries (rmtfs, tqftpserv, qrtr-ns) that are not available in Arch repos.
- **[sm8150-mainline](https://gitlab.com/sm8150-mainline/linux)** -- Mainline Linux kernel with Snapdragon 855 (sm8150) support, the foundation for nabu Linux support.
- **[CachyOS](https://cachyos.org/)** -- Kernel patches (BORE, BBR3, ADIOS), theming packages, system tuning configs, and PKGBUILD recipes via [CachyOS-PKGBUILDS](https://github.com/CachyOS/CachyOS-PKGBUILDS).
- **[map220v](https://github.com/map220v/nabu-firmware)** -- Nabu-specific firmware blobs (WiFi WCN3991, Adreno 640 GPU, Bluetooth, audio codec) required for hardware functionality.
- **[Arch Linux ARM](https://archlinuxarm.org/)** -- The base system and package repositories.
- **[TWRP](https://twrp.me/)** -- Recovery image used during the flash process.
- **[nabu Linux community](https://t.me/nabulinux)** -- Collective knowledge, testing, and documentation for running Linux on the Xiaomi Pad 5.

## License

The build scripts in this repository are provided as-is. The components they download, build, and assemble are subject to their own respective licenses (GPL for the kernel, various licenses for CachyOS packages, etc.).
