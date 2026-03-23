# CachyOS on Xiaomi Pad 5 (nabu)

## Project Status

**Current phase:** Spec approved, ready for implementation planning (writing-plans skill).

The design spec is at `docs/superpowers/specs/2026-03-23-cachyos-nabu-design.md` — read it first, it's the source of truth. It passed spec review (2 rounds, all 16 issues fixed). The user has approved it.

## What This Project Is

A Docker-based build system that produces a flashable CachyOS-flavored Arch Linux ARM image for the Xiaomi Pad 5 tablet. Not a port of CachyOS — most CachyOS packages are x86-only. Instead: nabu kernel + architecture-neutral CachyOS patches + CachyOS theming + CachyOS system tuning.

## User Setup

- **Build machine:** MacBook Pro M4 Pro (aarch64 Docker runs natively — no emulation)
- **Target device:** Xiaomi Pad 5 (nabu), 128GB, currently running HyperOSPro (custom ROM), bootloader already unlocked
- **Connection:** Direct USB-C cable between MacBook and tablet. User can run fastboot/adb commands.
- **No USB keyboard available** — first boot must work headlessly (auto-WiFi + auto-login + SSH). User will SSH in from MacBook.
- **Going Linux-only** — no Android dual-boot. User barely uses the tablet and is fine with bricking risk.
- **Use case:** General-purpose tablet (touch, browsing, media) + tinkering playground (dev tools, experiments)

## Key Design Decisions

1. **Approach A chosen:** Build flashable image from scratch via Docker (not layering on nabu-alarm, not forking nabu-fedora-builder)
2. **Kernel 6.14.11** from `gitlab.com/sm8150-mainline/linux` branch `sm8150/6.14.11` — latest working version. 6.16 doesn't boot on some devices.
3. **CachyOS patches (ARM-compatible only):** BORE scheduler, BBR3 TCP, ADIOS I/O scheduler, v4l2loopback. All x86-specific patches (AMD P-State, TLB broadcast, x86 crypto, ASUS ROG, Apple T2) are excluded.
4. **KDE Plasma** with CachyOS theming (Nord theme, dark mode, reduced animations, floating panel)
5. **Vivaldi** browser (user preference, replaces Firefox. Available in AUR, good touch/tablet support on Wayland)
6. **Btrfs** root filesystem with zstd compression, subvolumes (@, @home, @snapshots) for snapshot-based rollback
7. **UEFI + GRUB boot chain** (TheMojoMan's EDK2 firmware), not raw mkbootimg — allows kernel updates without reflashing boot.img
8. **Docker builds on ALARM rootfs tarball**, not official `archlinux:latest` (which is x86_64 only)
9. **pacstrap uses ALARM mirrors** (`mirror.archlinuxarm.org`), not mainline Arch repos
10. **Nabu firmware blobs** from `map220v/nabu-firmware` — required for WiFi, GPU, BT, audio. Not in upstream `linux-firmware`.

## Key Technical Details (from research)

### Kernel source
- **Repo:** `https://gitlab.com/sm8150-mainline/linux` (GitLab, NOT the old GitHub `map220v/sm8150-mainline` which stopped at 6.11)
- **Config:** `defconfig` + `sm8150.config` (config fragment at `arch/arm64/configs/sm8150.config`)
- **Build:** `make -j$(nproc) ARCH=arm64 Image.gz dtbs modules`
- **Device tree:** `arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dts`
- **No nabu-specific defconfig** — uses generic arm64 defconfig + sm8150 fragment

### CachyOS patches location
- BORE: `CachyOS/kernel-patches/6.14/sched/0001-bore.patch` (686 lines, arch-neutral, modifies kernel/sched/)
- BBR3: `CachyOS/kernel-patches/6.14/0004-bbr3.patch` (2231 lines in net/ipv4/)
- ADIOS: Inside `CachyOS/kernel-patches/6.14/0005-cachy.patch` (extract block/adios.c, ~1339 lines)
- cachy-arm: Arch-neutral bits from same `0005-cachy.patch` (HZ options, PREEMPT_LAZY, THP tuning, v4l2loopback)
- sched-ext is already in mainline 6.14, just needs CONFIG_SCHED_CLASS_EXT=y

### Boot chain
- PBL (ROM) → XBL (UFS Boot LUN) → ABL (boot slot) → UEFI (EDK2 disguised as boot.img) → GRUB (from ESP) → kernel
- UEFI firmware: pre-built `boot_6.14.11-nabu-tmm_linux.img` from TheMojoMan's mega.nz
- Slot switching: flash UEFI to boot_b, set_active b. Fastboot always accessible via Vol Down + Power.

### CachyOS theming (all arch=any, no compilation needed)
- `cachyos-kde-settings` — dark mode, floating panel, capitaine-cursors, reduced animations
- `cachyos-wallpapers` — ~40 wallpapers, default: north.png
- `cachyos-themes-sddm` — SimplyBlack and SoftGrey SDDM themes
- `cachyos-nord-kde-theme` — Nord color scheme + Plasma theme
- `cachyos-fish-config`, `cachyos-zsh-config` — shell configs
- `char-white` — cursor theme
- `cachyos-plymouth-bootanimation` — boot animation

### CachyOS system tuning (from CachyOS-Settings repo)
- sysctl: swappiness=100 (ZRAM), vfs_cache_pressure=50, dirty_bytes=256MB, page-cluster=0
- ZRAM: zstd compression, size=full RAM, priority=100
- I/O: UFS → ADIOS scheduler, fallback → mq-deadline
- systemd: reduced timeouts, increased file limits, journal max 50MB, cgroup delegation

### What doesn't work on nabu (any distro)
- Camera (no mainline driver)
- Microphone (no mainline driver)
- Suspend/resume (unreliable)
- Pen pressure sensitivity in landscape mode

### AUR packages needed
- `vivaldi` — Chromium-based browser
- `maliit-keyboard` + `maliit-framework` — on-screen keyboard (not in official ALARM repos)

## Build Commands (for reference)

```bash
# Build everything
./build.sh

# Flash to tablet (tablet must be in fastboot mode)
./image/flash.sh

# Enter fastboot on tablet
# Hold Volume Down + Power until fastboot screen appears
```

## Repository Links

| What | URL |
|------|-----|
| Kernel source | https://gitlab.com/sm8150-mainline/linux |
| CachyOS kernel patches | https://github.com/CachyOS/kernel-patches |
| CachyOS settings | https://github.com/CachyOS/CachyOS-Settings |
| CachyOS KDE settings | https://github.com/CachyOS/cachyos-kde-settings |
| CachyOS wallpapers | https://github.com/CachyOS/cachyos-wallpapers |
| CachyOS Nord theme | https://github.com/CachyOS/CachyOS-Nord-KDE |
| CachyOS SDDM themes | https://github.com/StarterX4/cachyos-themes-sddm |
| UEFI firmware | https://github.com/map220v/MU-sm8150pkg |
| TheMojoMan images | https://github.com/TheMojoMan/xiaomi-nabu |
| Nabu firmware blobs | https://github.com/map220v/nabu-firmware |
| nabu-fedora-builder | https://github.com/nik012003/nabu-fedora-builder |
| Dual boot installers | https://github.com/rodriguezst/nabu-dualboot-img |
| qbootctl | https://github.com/linux-msm/qbootctl |
| CachyOS PKGBUILDS | https://github.com/CachyOS/CachyOS-PKGBUILDS |
| CachyOS char-white cursor | https://github.com/CachyOS/char-white |
| CachyOS fish config | https://github.com/CachyOS/CachyOS-PKGBUILDS |
| Telegram community | https://t.me/nabulinux |
