# CachyOS ARM Parity Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring CachyOS ARM (nabu) to maximum feature parity with CachyOS x86_64 KDE desktop edition, adapting x86-specific features to ARM equivalents where possible.

**Architecture:** CachyOS ARM is Arch Linux ARM + CachyOS kernel patches + CachyOS theming/tuning + CachyOS tools. Packages that are `arch=any` work directly. Packages with x86-specific optimizations (LTO, PGO, -march) are rebuilt from source with ARMv8.2-A equivalents.

**Tech Stack:** Arch Linux ARM, KDE Plasma 6, CachyOS kernel patches, makepkg with aarch64 LTO flags, Docker build system.

**Current state:** CachyOS kernel (BORE+ADIOS) running, KDE Plasma working, WiFi working, basic theming applied. Mesa LTO rebuild in progress.

---

## Phase 1: System Foundation (achievable now)

### Task 1: Complete system tuning parity

CachyOS system tuning is already partially applied. Fill in the gaps.

**Files:**
- Modify: `rootfs/overlay/etc/sysctl.d/70-cachyos.conf` — verify all CachyOS values present
- Create: `rootfs/overlay/etc/modprobe.d/cachyos.conf` — audio power-save bypass
- Modify: `rootfs/overlay/etc/systemd/system.conf.d/10-cachyos.conf` — cgroup delegation
- Create: `rootfs/overlay/etc/systemd/coredump.conf.d/10-cachyos.conf` — coredump limits

- [ ] **Step 1: Verify sysctl values match CachyOS-Settings repo**

Compare our `70-cachyos.conf` against https://github.com/CachyOS/CachyOS-Settings and fill any gaps:
- `vm.swappiness = 100` (have)
- `vm.vfs_cache_pressure = 50` (have)
- `vm.dirty_bytes = 268435456` (have)
- `vm.page-cluster = 0` (have)
- `kernel.nmi_watchdog = 0` (have)
- `net.core.netdev_max_backlog = 4096` (have)
- `fs.file-max = 2097152` (have)
- Add any missing: `kernel.split_lock_mitigate = 0` (x86-only, skip)

- [ ] **Step 2: Audio power-save bypass**

Create `rootfs/overlay/etc/modprobe.d/cachyos.conf`:
```
options snd_hda_intel power_save=0
```
(Skip on ARM — this is for Intel HDA. Our CS35L41 speakers don't need it.)

- [ ] **Step 3: Systemd cgroup delegation**

Append to `rootfs/overlay/etc/systemd/system.conf.d/10-cachyos.conf`:
```ini
[Manager]
DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
DefaultIOAccounting=yes
```

- [ ] **Step 4: Coredump limits**

Create `rootfs/overlay/etc/systemd/coredump.conf.d/10-cachyos.conf`:
```ini
[Coredump]
Storage=none
ProcessSizeMax=0
```

- [ ] **Step 5: Enable MGLRU at boot**

Create `rootfs/overlay/etc/tmpfiles.d/mglru.conf`:
```
w /sys/kernel/mm/lru_gen/enabled - - - - 5
```

- [ ] **Step 6: Commit**

---

### Task 2: CachyOS tools and utilities

Install CachyOS-specific tools that work on ARM.

- [ ] **Step 1: Install cachyos-hello (if arch=any)**

Check if `cachyos-hello` from CachyOS-PKGBUILDS is arch=any. If so, build and install it. If x86-only, skip.

- [ ] **Step 2: Install cachyos-hooks**

From CachyOS-PKGBUILDS, `cachyos-hooks` provides pacman hooks for system maintenance. Build and install.

- [ ] **Step 3: Install cachyos-rate-mirrors**

Mirror ranking tool. Check AUR/CachyOS-PKGBUILDS for aarch64 availability.

- [ ] **Step 4: Commit**

---

### Task 3: Shell configuration parity

CachyOS ships pre-configured fish and zsh.

- [ ] **Step 1: Verify cachyos-fish-config installed**

Already built during theming stage. Verify it's active for the nabu user.

- [ ] **Step 2: Verify cachyos-zsh-config installed**

Already built during theming stage. Verify zsh is the default shell for nabu user.

- [ ] **Step 3: Set default shell to zsh for new users**

```bash
chsh -s /usr/bin/zsh nabu
```

- [ ] **Step 4: Commit**

---

## Phase 2: Optimized Package Rebuilds

### Task 4: Mesa with LTO (in progress)

Rebuild Mesa from Arch PKGBUILD with CachyOS-style optimizations.

**Build flags:** `-march=armv8.2-a+crypto -O3 -pipe -flto=auto`

- [ ] **Step 1: Complete Mesa build on tablet** (already running -j4)
- [ ] **Step 2: Install built mesa packages**
- [ ] **Step 3: Verify GPU acceleration with `glxinfo` or `es2_info`**
- [ ] **Step 4: Commit build recipe to repo**

---

### Task 5: PipeWire with LTO

Rebuild PipeWire for optimized audio performance.

- [ ] **Step 1: Get PipeWire PKGBUILD**

```bash
asp export pipewire
```

- [ ] **Step 2: Patch for aarch64 + build with LTO flags**
- [ ] **Step 3: Install and verify audio still works**
- [ ] **Step 4: Commit**

---

### Task 6: systemd with LTO (optional, risky)

Rebuild systemd with LTO. This is risky — if it breaks, the system won't boot.

- [ ] **Step 1: Build in Docker container first for safety**
- [ ] **Step 2: Test in chroot before installing live**
- [ ] **Step 3: Install with fallback plan**
- [ ] **Step 4: Commit**

---

## Phase 3: Desktop Parity

### Task 7: KDE Plasma configuration parity

Match CachyOS KDE defaults exactly.

**Reference:** https://github.com/CachyOS/cachyos-kde-settings

- [ ] **Step 1: Verify cachyos-kde-settings package is applied**

Check that Nord theme, dark mode, floating panel, reduced animations, Capitaine cursors are all active.

- [ ] **Step 2: Set CachyOS wallpaper (north.png) as default**

```bash
sudo -u nabu kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
    --group 'Containments' --group '1' --group 'Wallpaper' \
    --group 'org.kde.image' --group 'General' \
    --key Image "/usr/share/wallpapers/cachyos-wallpapers/north.png"
```

- [ ] **Step 3: Set SDDM theme to cachyos-simplyblack**

```ini
# /etc/sddm.conf.d/theme.conf
[Theme]
Current=cachyos-simplyblack
```

- [ ] **Step 4: Verify char-white cursor theme active**
- [ ] **Step 5: Commit**

---

### Task 8: Browser optimization

Configure Vivaldi/Firefox with hardware acceleration.

- [ ] **Step 1: Create Vivaldi Wayland + GPU flags** (already done)
- [ ] **Step 2: Install Firefox as alternative browser**

```bash
pacman -S firefox
```

- [ ] **Step 3: Create Firefox Wayland flags**

```bash
# /etc/environment.d/firefox-wayland.conf
MOZ_ENABLE_WAYLAND=1
```

- [ ] **Step 4: Commit**

---

## Phase 4: Tablet-Specific Enhancements (beyond x86 CachyOS)

### Task 9: On-screen keyboard (critical for tablet)

This is the biggest UX gap. CachyOS x86 doesn't need this, but nabu is unusable without it.

- [ ] **Step 1: Research KDE 6 Wayland virtual keyboard solutions**

Options:
- `qt6-virtualkeyboard` (installed but crashes when activated via QT_IM_MODULE)
- `maliit-framework` + `maliit-keyboard` (not available for aarch64 in AUR)
- `squeekboard` (GNOME/Phosh keyboard, might work on KDE)
- Custom build of maliit from source

- [ ] **Step 2: Try squeekboard as alternative**

```bash
pacman -S squeekboard  # if available in ALARM
```

- [ ] **Step 3: Test and configure whichever works**
- [ ] **Step 4: Commit**

---

### Task 10: Display scaling and touch optimization

- [ ] **Step 1: Set 150% display scaling for 11" 2560x1600**

Via KDE settings or `kscreen-doctor output.1.scale 1.5`

- [ ] **Step 2: Increase touch target sizes in KDE**
- [ ] **Step 3: Commit**

---

### Task 11: Power management

- [ ] **Step 1: Install and configure powertop** (already in packages)
- [ ] **Step 2: Set CPU governor to schedutil when on battery, performance when charging**

Create udev rule or systemd service that watches power supply status.

- [ ] **Step 3: Commit**

---

## Phase 5: Build System Integration

### Task 12: Bake all parity changes into build scripts

All live fixes and new configs need to be reflected in the Docker build system so `./build.sh` produces a complete CachyOS ARM image from scratch.

- [ ] **Step 1: Update rootfs/build-rootfs.sh with all new configs**
- [ ] **Step 2: Update rootfs/overlay/ with all new files**
- [ ] **Step 3: Add CachyOS kernel boot.img building to build.sh**
- [ ] **Step 4: Test full clean build**
- [ ] **Step 5: Commit and push**

---

## What's NOT achievable (x86-only)

These CachyOS features cannot be ported to ARM and should be documented as known differences:

| Feature | Why |
|---------|-----|
| x86-64-v3/v4 package variants | Different CPU architecture |
| Proton/Wine gaming | x86 binary translation too slow |
| systemd-boot | x86 UEFI only (we use direct boot) |
| Intel/AMD microcode | x86 CPU only |
| AMD Anti-Lag 2 | AMD GPU only |
| Multiple kernel variants (LTS/RT/Hardened) | Tied to sm8150-mainline tree |
| AutoFDO kernel profiling | Requires PGO infrastructure |

---

## Parity Score Estimate

| Category | x86 Features | ARM Achievable | Parity % |
|----------|-------------|----------------|----------|
| Kernel patches | 6 | 4 (BORE, ADIOS, sched-ext, 1000Hz) | 67% |
| System tuning | 12 | 11 | 92% |
| KDE theming | 10 | 10 | 100% |
| CachyOS tools | 6 | 3-4 | 50-67% |
| Shell config | 3 | 3 | 100% |
| Browser | 2 | 2 | 100% |
| Optimized packages | 5 | 2-3 (Mesa, PipeWire) | 40-60% |
| **Overall** | **44** | **35-37** | **~80-84%** |
