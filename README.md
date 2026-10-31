# CachyOS Nabu

CachyOS ARM for the **Xiaomi Pad 5 (nabu)** — Arch Linux ARM + GNOME on Wayland,
running on the mainline-derived nabu kernel with CachyOS tuning.

---

## What this is

- **Arch Linux ARM** rootfs, bootstrapped with `pacstrap` inside Docker
- **Kernel** from [Kumar-Jy's nabu tree](https://github.com/Kumar-Jy/linux) (`nabu/7.3.y`) plus the CachyOS 7.3 patch set (BORE, BBR3, ADIOS, v4l2loopback) and config fragment — every patch is build-critical, no silent skips; see `kernel/patches/SOURCES.md` and `kernel/verify-patches.sh`
- **GNOME Shell 51 on Wayland** with a working on-screen keyboard, CachyOS theming and dconf tuning
- **Verified on device:** WiFi + Bluetooth, Adreno 640 GPU, touchscreen and pen, **auto-rotation**, ambient light + proximity + accelerometer, USB serial console, **suspend/resume**, **battery reporting**, **hardware video decode (Iris VPU)**
- **Supported by the kernel, not yet verified end to end:** quad speakers (CS35L41), charger, magnetic keyboard/cover, stylus buttons
- **Known broken:** none that we know of — see [Known limitations](#known-limitations) for the rough edges
- **Tablet UX:** GDM auto-login, no lock screen, tablet-sized UI, power button ignored on short press (long press still powers off)
- `paru` + the CachyOS tool set (`cachyos-settings`, Ananicy + CachyOS rules, `cachy-update`, wallpapers, Plymouth animation, zsh/fish configs, Alacritty)
- **Direct boot** — Android bootimg format, no GRUB, no UEFI

## What this is not

- **Not a port of CachyOS x86.** Most CachyOS packages are x86-only; only the architecture-neutral kernel/settings work is applied.
- **Not a prebuilt kernel.** `boot.img` is always compiled from source during the build.
- **Not tied to one install style.** You can replace Android (partition rename), keep it side by side (partition carve), or reuse a `linux` partition another nabu installer already created. See [Installing](#installing).

---

## Installing

Three install paths, differing only in how the `linux` partition comes to
exist. All start from a **release bundle** (or your own build) and an
**unlocked bootloader**.

### 0. Get the files

Download every asset from the [latest release](https://github.com/FisiFla/nabu-cachyos/releases/latest)
into one folder (or build your own — see [Building](#building)).

You need on the host: `fastboot`, `zstd`, `adb`, and on macOS `simg2img`
(`brew install android-platform-tools zstd simg2img`). The partition scripts
also need `python3` (preinstalled on most Linux/macOS setups; on macOS,
`brew install python` if `python3 --version` fails). Windows hosts can only
flash an already-prepared tablet — see
[Windows hosts (flash only)](#windows-hosts-flash-only).

### 1. Prepare the partition table (choose one)

The kernel boots with `root=PARTLABEL=linux`, but the stock Xiaomi table calls
that partition `userdata`. Options A and B below rewrite the GPT with
`tools/gpt-*.py` (both GPT copies, fresh CRC32s, verified by re-reading the
table). Both scripts run from a **rooted ROM** (`su`/Magisk in Android) or a
**root-capable recovery** (TWRP/OrangeFox booted with `fastboot boot`) and
detect which. Both refuse to run when a partition named `linux` already
exists — that tablet wants Option C, and a duplicate `PARTLABEL=linux` would
leave the kernel and fastboot guessing which partition is meant. Before
patching, both save the untouched GPT regions to
`gpt-backups/<timestamp>/*-pristine.bin` next to the script, with a
`metadata.txt` holding the exact geometry needed to write them back; a run
that cannot save that backup does not touch the device.

**Option A — replace Android** (simplest, keeps nothing from Android):

```bash
bash relabel-partition.sh          # renames userdata -> linux in place
```

This is the same physical partition postmarketOS flashes to, under a new
name: pmOS's kernel looks for `userdata`, this kernel looks for `linux`, so
flashing this image to a partition still *named* `userdata` would not boot.
Android's slot A images are untouched, but its data partition is gone (see
[Rolling back](#rolling-back)).

**Option B — keep Android (dual boot)**:

```bash
bash carve-linux-partition.sh --dry-run   # show the plan
bash carve-linux-partition.sh             # carve 30 GiB: --gib 50 for more
```

The carve shortens `userdata` and appends a new `linux` partition out of its
tail. The stock table has no free space, so this is the only way to keep
Android. Nothing about the carve touches Android's own partitions.

**Option C — reuse an existing `linux` partition** (coming from another nabu
Linux, e.g. Kumar-Jy's Arch images, whose partition tool already created
`linux` + `esp`): run **neither** partition script. Go straight to step 2.

- Flashing overwrites the rootfs currently on `linux`. Back up `/home` and
  anything else you want from the old install first.
- Android's `userdata` is untouched, so Android stays bootable from slot A.
- The old `esp`/UEFI/rEFInd boot chain is left in place but unused: this
  image boots directly from `boot_b`, so the old boot menu's Linux entry
  will no longer work. Leaving `esp` in place is harmless.
- The flasher aborts before writing anything when `linux` is smaller than
  `image-size.txt` requires; on first boot `/` grows to fill the partition.
  A too-small partition has to be enlarged with the partition tool that
  created it (destructive) — relabelling or carving again will refuse.
- To check what you have, use targeted probes only (`fastboot getvar all`
  hangs on this firmware): `fastboot getvar partition-size:linux` and
  `fastboot getvar current-slot`. The flasher writes slot B, so if Android
  currently boots from slot B, stop and ask before flashing.

> `userdata` is block-encrypted and was sized for the whole disk. Our test
> device kept all its data after the carve, but Android may also decide the
> resized partition is unusable and format it on the next boot. Back up what
> you care about first — the ROM and Magisk survive either way.

### 2. Flash

Boot the tablet into fastboot (**Vol Down + Power**), then:

```bash
bash join-and-flash.sh      # splits release bundle; or `bash flash.sh` when unsplit
```

The installer verifies `SHA256SUMS`, checks that a `linux` partition exists and
is large enough, erases `dtbo_b`, flashes `vbmeta_disabled.img`, `boot.img` to
`boot_b`, decompresses and flashes the rootfs, sets slot B active and reboots.

CachyOS boots in about a minute.

Optional SSH key injection (macOS/Linux flasher only; needs Docker locally)
puts your `~/.ssh/id_ed25519.pub` into the image before flashing:

```bash
SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub bash flash.sh
SKIP_SSH_KEY_INJECTION=1 bash flash.sh     # skip it
```

### Windows hosts (flash only)

> **Tested once on hardware.** Release v1.5.0 was successfully flashed to a
> real nabu from Windows 11 / PowerShell 5.1 with Google platform-tools
> 37.0.1 on 31 Oct 2026. This is still new code, so reports — working or
> not — are welcome in an issue.

There are **no Windows partition scripts**: Options A and B still need a
macOS/Linux host. What works on Windows is step 2 alone, once a `linux`
partition already exists — Option C tablets, or a tablet prepared earlier
on another host.

Prerequisites: Google *platform-tools* (`fastboot` on `PATH`), `zstd` on
`PATH` (or `zstd.exe` next to the scripts), Windows PowerShell 5.1
(preinstalled), and a working fastboot USB driver. Verify the driver
before running the installer: with the tablet in fastboot mode,
`fastboot devices` must list it.

If that prints nothing and Device Manager shows **Android** with **Code
28**, this is a driver problem, not a script problem. Nabu uses USB
`VID_18D1&PID_D00D`, which Google's current standalone USB-driver INF does
not list. Install the **Google Android Bootloader Interface** driver from
Windows Update → Advanced options → Optional updates → Driver updates if
offered. Otherwise use Device Manager → Android → Update driver → Browse
my computer → Let me pick → Have Disk, select Google's
`android_winusb.inf`, choose **Android Bootloader Interface**, and accept
the compatibility warning. Re-check `fastboot devices` afterwards.

From the release-bundle folder, in `cmd`:

```
join-and-flash.bat
```

The `.bat` files are thin launchers for `join-and-flash.ps1` / `flash.ps1`;
running the `.ps1` directly from PowerShell works too. The same switches
apply (`FORCE_FLASH=1`, `SKIP_SHA256_CHECK=1` — `set NAME=1` in cmd,
`$env:NAME=1` in PowerShell). Differences from the macOS/Linux flasher: SSH
key injection is skipped (add a key after first boot instead), and the
Windows script converts the rootfs to Android sparse format in-script
because Google's 32-bit Windows fastboot cannot buffer the ~10 GB raw
image for `-S` sparsing. If any step before slot selection fails, slot B
has not been set active, so slot A still boots.

### 3. First boot

- Auto-login as `nabu` (no password, passwordless `sudo`)
- Connect to WiFi in GNOME Settings — touch-friendly, no keyboard needed
- `ssh nabu@nabu-cachyos.local` (key-only by default; see [SSH](#ssh))
- `/` grows to fill the `linux` partition on first boot, so you end up with
  30 GiB (carve) or the whole old `userdata` (relabel)

### Switching between the two systems (dual boot only)

There is no boot menu; nabu boots the *active slot*.

| Direction | Commands |
|---|---|
| CachyOS → Android | `sudo qbootctl -s a` then `sudo reboot` |
| Android → CachyOS | `adb reboot bootloader` · `fastboot set_active b` · `fastboot reboot` |

A slot that fails to boot a few times is marked unbootable by the bootloader and
the other slot is used, so a broken install falls back instead of looping.

### Rolling back

- **Android, dual boot (Options B and C)**: `fastboot set_active a` (or the
  bootloader's own fallback). Android data is intact, except that Option B
  may have made Android reformat `userdata` (see the carve warning above).
- **Android after Option A**: `fastboot set_active a` boots the Android
  images, but `userdata` was renamed and overwritten, so expect a factory
  reset — Android data does not come back. For a clean stock system, use the
  full-stock route below.
- **Full stock ROM**: download the official nabu *fastboot* ROM (`.tgz`) for
  your region and flash it from fastboot mode with MiFlash **Clean all** or
  the package's `flash_all` script. This wipes everything. Never pick
  **Clean all and lock**, and do not relock the bootloader until stock is
  confirmed booting. If stock flashing errors on the partition table, stop:
  restore the GPT first (next bullet) instead of forcing it.
- **Old kernel/rootfs**: keep the previous `boot.img` and reflash it to `boot_b`.
- **Partition table**: write back the `gpt-backups/<timestamp>/*-pristine.bin`
  regions both partition scripts saved — `metadata.txt` next to them has the
  exact `dd` commands (root adb, recovery or rooted ROM). After Option A you
  can instead run the relabel in reverse
  (`NABU_OLD_LABEL=linux NABU_NEW_LABEL=userdata`). There is no un-carve
  script, so after Option B the pristine restore (or the full stock flash)
  is the way back. Keep the `gpt-backups/` folder: deleting it deletes this
  rollback.

---

## Building

```bash
./build.sh                                        # ~40-60 min cold, minutes warm
VBMETA_SOURCE=/path/to/vbmeta_disabled.img bash release/create-release.sh
cd release/dist && bash join-and-flash.sh         # or flash.sh
```

`build.sh` runs six stages in a Docker container built from the Arch Linux ARM
tarball:

| Stage | Script | What it does |
|---|---|---|
| 1/6 | `build.sh` | Downloads the ALARM rootfs over HTTPS and verifies its GPG signature |
| 2/6 | `build.sh` | Builds the Docker image |
| 3/6 | `firmware/fetch-firmware.sh` | Fetches pinned nabu firmware blobs |
| 4/6 | `kernel/build-kernel.sh` | Clones/patches the kernel, builds `Image.gz` + DTB + modules, assembles `boot.img` |
| 5/6 | `rootfs/build-rootfs.sh` | `pacstrap`, packages, Qualcomm userspace, patched `iio-sensor-proxy`, theming, system config |
| 6/6 | `image/build-image.sh` | Builds the ext4 rootfs image and checksums |

Useful switches:

| Variable | Default | Purpose |
|---|---|---|
| `KERNEL_URL` / `KERNEL_REF` | `Kumar-Jy/linux` · `nabu/7.3.y` | Kernel tree and branch (`KERNEL_COMMIT` pins a commit) |
| `KERNEL_DEFCONFIG` / `KERNEL_FRAGMENTS` | `nabu_defconfig` · `sm8150.config` | Kernel config |
| `WIFI_SSID` / `WIFI_PASSWORD` | — | Pre-seed a WiFi profile |
| `VBMETA_SOURCE` | — | Path to `vbmeta_disabled.img` for release packaging |

**Kernel release string** is derived by the build (`make kernelrelease`, e.g.
`7.3.0-sm8150+`) and recorded in `output/kernel/kernel-release`; the rootfs uses
the same string for `/lib/modules`, the kernel image name and the initramfs, so
kernel and rootfs can never disagree.

**Caches:** pacstrap rootfs tarball and `output/kernel/` persist across builds.
Docker builds also keep the kernel tree and ccache in the named volumes
`nabu-kernel-build` and `nabu-ccache` (`docker volume rm …` forces a rebuild).

**Integrity:** the ALARM tarball is the base of the whole OS, so it is fetched
over HTTPS together with the publisher's detached signature and verified by
`tools/verify-alarm-tarball.sh` against a keyring extracted from the tarball and
a **fingerprint pinned in the repo**. Bad signature = failed build. Air-gapped
and trust-me cases can pass `ALARM_ALLOW_UNVERIFIED=1`.

---

## Updating a running system

- Packages: `pacman -Syu` (or `cachy-update`, which also handles Chaotic-AUR).
- Kernel from the tablet itself (new, on-device): stage a freshly built
  `Image.gz` + DTB into `/boot/efi/`, then
  `nabu-kernel-flash stage` to preview, `sudo nabu-kernel-flash flash --yes`
  to write `boot_b`. It backs up the current partition first and never
  touches Android slot A. `~/bin/kernel-update` covers the host-PC path.
- A signed `[nabu-cachyos]` pacman repo for one-command kernel updates is
  implemented but not live yet — the stanza ships commented in
  `/etc/pacman.conf`. Maintainer steps: `packaging/README.md`.

## Credentials and SSH

| Account | Password | Notes |
|---|---|---|
| `nabu` | none | GDM auto-login, passwordless `sudo` (`/etc/sudoers.d/zz-nabu-nopasswd`), in `wheel/video/audio/input` |
| `root` | none (`*` hash) | Cannot authenticate with a password; SSH root login is key-only |

`passwd` sets a password for `nabu` (for the GNOME lock screen, if you enable
one). PAM has no `nullok`, so an empty password can never be used to log in.

**SSH is key-only** out of the box (`/etc/ssh/sshd_config.d/nabu.conf`:
`PermitRootLogin prohibit-password`, `PasswordAuthentication no`,
`KbdInteractiveAuthentication no`, `PermitEmptyPasswords no`). To allow password
logins for `nabu`:

```bash
sudo nabu-ssh-password on      # adds 10-nabu-password.conf, restarts sshd
sudo nabu-ssh-password off
```

Root uses a `*` hash rather than `passwd -l`, because ALARM's `sshd_config`
leaves `UsePAM no`: without PAM, OpenSSH refuses *key* logins for `!`-prefixed
accounts, so `passwd -l root` would break root over SSH.

---

## Known limitations

- **Camera** — no mainline driver on nabu.
- **Video decode** is hardware-accelerated but opt-in per player — see
  [Hardware notes](#hardware-notes). 10-bit and DRM-Prime paths are untested.
- **Suspend** — `s2idle` works and sensors survive it: `hexagonrpcd-{suspend,resume}.service`
  stop and restart the live bridge (sdsp on 7.3, the adsp pair on older kernels) and a
  sleep hook re-probes `iio-sensor-proxy`, so accelerometer, light, proximity and
  auto-rotation come back after wake without a reboot. The SLPI `sensor_process` PD
  usually crashes once on resume and recovers by itself. The power button is not wired
  to suspend: short press is ignored, long press powers off, so suspend it from the
  session menu or `systemctl suspend`.
- **Warm-reboot black screen** — after `fastboot reboot` the panel occasionally
  stays dark with no USB; a cold power cycle (hold Power ~15 s) recovers.
- **`cachyos-packageinstaller`** — still best-effort on aarch64 (upstream AUR
  packaging gaps); the builder now ships its Qt6/Polkit makedepends, and the
  build skips it with a warning if it fails. `paru` remains the supported way.
- **`dbus-broker` → `dbus-daemon`** — the kernel lacks a namespace feature
  dbus-broker needs.
- **Pen pressure** — not reported in landscape orientation.
- **CachyOS parity** — the 7.3 patch set (BORE, BBR3, ADIOS, v4l2loopback)
  now applies to the nabu tree and is enforced (a drifting patch fails the
  build). Desktop tuning constants are still not copied wholesale onto the
  tablet. Full notes: `docs/cachyos-parity.md`; SCX experiments:
  `docs/scx-scheds.md`.

## Why GNOME

The on-screen keyboard works on Wayland touch devices; KDE's Qt Virtual Keyboard
has a focus loop that makes it unusable here. GNOME also gives large tap targets
and gesture navigation for free.

## Hardware notes

- **Sensors** live on the SLPI (`sns_reg` registry on `/mnt/vendor/persist`, served
  by `hexagonrpcd` over FastRPC → `libssc`/`QRTR` → patched `iio-sensor-proxy`).
- **Auto-rotation** needs two fixes that ship in the image: the detached keyboard
  cover exposes phantom pointer devices (which made mutter treat the tablet as a
  desktop and drop the accelerometer), and the SSC frame is 180° rotated relative
  to the panel (`ACCEL_MOUNT_MATRIX` on the fastrpc nodes).
- **Hardware video decode** goes through the Iris VPU (`/dev/video0` decoder,
  `/dev/video1` encoder). It is a V4L2 mem2mem device, so the player has to ask
  for it: `ffmpeg -c:v h264_v4l2m2m -i in.mp4 …` (also `hevc_v4l2m2m`,
  `vp9_v4l2m2m`); with mpv, `--hwdec=v4l2m2m-copy`. Software decoding still
  works and is what you get by default.
- **Proximity** uses the Xiaomi SAR sensor through a fallback patch, since the SSC
  registry exposes no standard proximity datatype.
- **USB serial console** is opt-in: `sudo nabu-serial-gadget enable` exposes an
  ACM console on `/dev/ttyGS0`.

## Repository layout

```
build.sh                  # orchestrator (6 stages)
Dockerfile                # ALARM-based build environment
firmware/fetch-firmware.sh
kernel/                   # build-kernel.sh, cachyos.config, patches/, enable-slpi.sh, verify-patches.sh
packaging/                # linux-nabu-cachyos, nabu-boot-tools, keyring, pmac, torch + repo publishing
rootfs/                   # build-rootfs.sh, build-qualcomm.sh, build-iio-sensor-proxy.sh,
                          # build-theming.sh, packages*.txt, upstream-pins.sh, overlay/
image/build-image.sh
release/                  # create-release.sh, flash.sh, join-and-flash.sh, inject-ssh-key.sh,
                          # flash.ps1, join-and-flash.ps1 (+ .bat launchers; Windows),
                          # relabel-partition.sh, carve-linux-partition.sh
tools/                    # gpt-relabel.py, gpt-carve.py, test_gpt_tools.py, verify-alarm-tarball.sh
test/                     # QEMU harness (see below)
docs/                     # hardware reference dumps from a working Android build
```

## Testing without the tablet (QEMU)

Userspace can be sanity-checked on any Apple Silicon Mac before flashing:

```bash
brew install qemu docker colima && colima start
./test/build-test-kernel.sh         # kernel for QEMU's virt machine
./test/test-qemu.sh --smoke         # kernel + initramfs
./test/test-qemu.sh --prepare-only  # GPG-verified ALARM rootfs -> ext4 image
./test/test-qemu.sh                 # boot the rootfs to a login prompt
```

This exercises packages, systemd ordering, sshd and the shells. It cannot test
nabu hardware (QEMU `-M virt` has no sm8150 devices), so touch, WiFi, audio,
sensors and the like still need the real tablet.

The GPT surgery tools have plain unit tests that run anywhere (synthetic GPT
dumps, no tablet, no root): `python3 tools/test_gpt_tools.py`.

## Credits

- [TheMojoMan](https://github.com/TheMojoMan/xiaomi-nabu) — boot image format and early nabu work
- [Kumar-Jy/linux](https://github.com/Kumar-Jy/linux) — nabu kernel tree
- [linux-msm](https://github.com/linux-msm) — qrtr, rmtfs, tqftpserv, qbootctl, hexagonrpc
- [sm8150-mainline](https://gitlab.com/sm8150-mainline/linux) — previous kernel base
- [CachyOS](https://cachyos.org/) and [CachyOS-PKGBUILDS](https://github.com/CachyOS/CachyOS-PKGBUILDS) — tuning, theming, PKGBUILDs
- [map220v](https://github.com/map220v/nabu-firmware) — nabu firmware blobs
- [Arch Linux ARM](https://archlinuxarm.org/) — base system
- [nabu Linux community](https://t.me/nabulinux) — knowledge and testing

## License

GPL-2.0 (see [LICENSE](LICENSE)); bundled components keep their own licenses.
