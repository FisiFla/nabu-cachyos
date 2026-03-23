# CachyOS on Xiaomi Pad 5 (nabu)

> **This file mirrors CLAUDE.md.** See CLAUDE.md for the canonical project context. Both files are kept in sync.

## Project Status

**Current phase:** Implementation plan approved, ready for execution.

**Plan:** `docs/superpowers/plans/2026-03-23-cachyos-nabu-build.md`
- Phase 1 (Tasks 1-9): Build system — runs entirely on MacBook, no tablet needed
- Phase 2 (Task 10): Flash — needs tablet connected via USB-C in fastboot mode
- To start: invoke `superpowers:subagent-driven-development` or `superpowers:executing-plans` skill

The design spec is at `docs/superpowers/specs/2026-03-23-cachyos-nabu-design.md` — read it first, it's the source of truth. It passed spec review (2 rounds, all 16 issues fixed) plus 3 rounds of user review. The user has approved it.

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
5. **Vivaldi** browser (user preference, replaces Firefox. AUR package: `vivaldi-multiarch-bin` which ships pre-built aarch64 binaries. NOT plain `vivaldi` which is x86_64 only.)
6. **Btrfs** root filesystem with zstd compression, subvolumes (@, @home, @snapshots) for snapshot-based rollback
7. **UEFI + GRUB boot chain** (TheMojoMan's EDK2 firmware), not raw mkbootimg — allows kernel updates without reflashing boot.img
8. **Docker builds on ALARM rootfs tarball**, not official `archlinux:latest` (which is x86_64 only)
9. **pacstrap uses ALARM mirrors** (`mirror.archlinuxarm.org`), not mainline Arch repos
10. **Nabu firmware blobs** from `map220v/nabu-firmware` — required for WiFi, GPU, BT, audio. Not in upstream `linux-firmware`.
11. **Pre-built TWRP recovery** (not custom initramfs) — TWRP provides adbd (required for adb shell/push during flash), plus parted, sgdisk, dd, mkfs.
12. **Kernel artifacts on ESP** (`/boot/efi/`) — GRUB, mkinitcpio, and kernel-update all read/write the same path.

## AUR packages needed

- `vivaldi-multiarch-bin` — Chromium-based browser (aarch64 pre-built binaries, NOT plain `vivaldi` which is x86_64 only). Note: this package has had maintenance churn — verify it still exists before building. Fallback: `chromium` from official repos.
- `maliit-keyboard` + `maliit-framework` — on-screen keyboard (not in official ALARM repos)

## For full technical details

See `CLAUDE.md` — it contains kernel source details, CachyOS patch locations, boot chain, theming packages, system tuning, and all repository links.
