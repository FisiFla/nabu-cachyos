# CachyOS Nabu

CachyOS ARM for the **Xiaomi Pad 5 (nabu)** — Arch Linux ARM + GNOME on Wayland,
running on the mainline-derived nabu kernel with CachyOS tuning.

---

## What this is

- **Arch Linux ARM** rootfs, bootstrapped with `pacstrap` inside Docker
- **Kernel** from [Kumar-Jy's nabu tree](https://github.com/Kumar-Jy/linux) (`nabu/7.3.y`) plus the CachyOS config fragment (1000 Hz, full preemption, Btrfs, zram/zstd, THP)
- **GNOME Shell 51 on Wayland** with a working on-screen keyboard, CachyOS theming and dconf tuning
- **Verified on device:** WiFi + Bluetooth, Adreno 640 GPU, touchscreen and pen, **auto-rotation**, ambient light + proximity + accelerometer, USB serial console, **suspend/resume**, **battery reporting**
- **Supported by the kernel, not yet verified end to end:** quad speakers (CS35L41), charger, magnetic keyboard/cover, stylus buttons
- **Known broken:** hardware video decode (Iris) — see [Known limitations](#known-limitations)
- **Tablet UX:** GDM auto-login, no lock screen, tablet-sized UI, power button ignored on short press (long press still powers off)
- `paru` + the CachyOS tool set (`cachyos-settings`, wallpapers, Plymouth animation, zsh/fish configs, Alacritty)
- **Direct boot** — Android bootimg format, no GRUB, no UEFI

## What this is not

- **Not a port of CachyOS x86.** Most CachyOS packages are x86-only; only the architecture-neutral kernel/settings work is applied.
- **Not a prebuilt kernel.** `boot.img` is always compiled from source during the build.
- **Not tied to one install style.** You can replace Android (partition rename) *or* keep it side by side (partition carve). See [Installing](#installing).

---

## Installing

Two install paths. Both start from a **release bundle** (or your own build) and an
**unlocked bootloader**.

### 0. Get the files

Download every asset from the [latest release](https://github.com/FisiFla/nabu-cachyos/releases/latest)
into one folder (or build your own — see [Building](#building)).

You need on the host: `fastboot`, `zstd`, `adb`, and on macOS `simg2img`
(`brew install android-platform-tools zstd simg2img`).

### 1. Prepare the partition table (choose one)

The kernel boots with `root=PARTLABEL=linux`, but the stock Xiaomi table calls
that partition `userdata`. Both options below rewrite the GPT with
`tools/gpt-*.py` (both GPT copies, fresh CRC32s, verified by re-reading the
table). The tablet must be in **Android with root** for the relabel, or in a
**root-capable recovery** (TWRP booted with `fastboot boot`) / rooted ROM for the
carve. Nothing about the carve touches Android's own partitions.

**Option A — replace Android** (simplest, keeps nothing from Android):

```bash
bash relabel-partition.sh          # renames userdata -> linux in place
```

**Option B — keep Android (dual boot)**:

```bash
bash carve-linux-partition.sh --dry-run   # show the plan
bash carve-linux-partition.sh             # carve 30 GiB: --gib 50 for more
```

The carve shortens `userdata` and appends a new `linux` partition out of its
tail. The stock table has no free space, so this is the only way to keep
Android. Both GPT regions are saved as `*-pristine.bin` first, so the operation
is reversible.

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

Optional SSH key injection (needs Docker locally) puts your `~/.ssh/id_ed25519.pub`
into the image before flashing:

```bash
SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub bash flash.sh
SKIP_SSH_KEY_INJECTION=1 bash flash.sh     # skip it
```

### 3. First boot

- Auto-login as `nabu` (no password, passwordless `sudo`)
- Connect to WiFi in GNOME Settings — touch-friendly, no keyboard needed
- `ssh nabu@nabu-cachyos.local` (key-only by default; see [SSH](#ssh))
- The root filesystem grows to fill the `linux` partition on first boot
  (`nabu-growroot.service`); a carve gives it 30 GiB, a relabel the whole old
  `userdata`

### Switching between the two systems (dual boot only)

There is no boot menu; nabu boots the *active slot*.

| Direction | Commands |
|---|---|
| CachyOS → Android | `sudo qbootctl -s a` then `sudo reboot` |
| Android → CachyOS | `adb reboot bootloader` · `fastboot set_active b` · `fastboot reboot` |

A slot that fails to boot a few times is marked unbootable by the bootloader and
the other slot is used, so a broken install falls back instead of looping.

### Rolling back

- **Android**: `fastboot set_active a` (or the bootloader's own fallback).
- **Old kernel/rootfs**: keep the previous `boot.img` and reflash it to `boot_b`.
- **Partition table**: write the saved `*-pristine.bin` regions back, or run the
  relabel in reverse (`NABU_OLD_LABEL=linux NABU_NEW_LABEL=userdata`).

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
- **Hardware video decode (Iris)** — the `qcom_iris` driver binds and the VPU
  firmware boots, but every session open ends in `HFI session open failed`
  (no response to `HFI_CMD_SYS_SESSION_INIT` within 1 s), so `h264_v4l2m2m`
  cannot decode. Playing video works via the CPU (mpv/ffmpeg software decode).
  The node is additionally gated behind `qcom_iris.allow_fw_boot=1`
  (`/etc/modprobe.d/qcom-iris.conf`), which is *not* shipped since decode does
  not work yet. Tracked in issue #41.
- **Suspend** — `s2idle` works and sensors survive it: `hexagonrpcd-{suspend,resume}.service`
  stop and restart the live bridge (sdsp on 7.3, the adsp pair on older kernels) and a
  sleep hook re-probes `iio-sensor-proxy`, so accelerometer, light, proximity and
  auto-rotation come back after wake without a reboot. The SLPI `sensor_process` PD
  usually crashes once on resume and recovers by itself. The power button is not wired
  to suspend: short press is ignored, long press powers off, so suspend it from the
  session menu or `systemctl suspend`.
- **Warm-reboot black screen** — after `fastboot reboot` the panel occasionally
  stays dark with no USB; a cold power cycle (hold Power ~15 s) recovers.
- **`cachyos-packageinstaller`** — its AUR PKGBUILD fails on aarch64; the build
  skips it. `paru` is the supported way to install packages.
- **`dbus-broker` → `dbus-daemon`** — the kernel lacks a namespace feature
  dbus-broker needs.
- **Pen pressure** — not reported in landscape orientation.
- **CachyOS kernel patches** — BORE/BBR3/ADIOS/cachy-arm are tuned for
  kernel 6.16/6.17 and do **not** apply to the 7.3 nabu tree; the build skips
  them and applies only `kernel/cachyos.config`. Set `KERNEL_URL`/`KERNEL_REF` to
  the old tree if you want them.
- **MGLRU / ADIOS / 1000 Hz** — MGLRU, zram/zstd, sysctl and systemd tuning are
  applied; the ADIOS scheduler is not available on 7.3 (mq-deadline is used).

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
- **Proximity** uses the Xiaomi SAR sensor through a fallback patch, since the SSC
  registry exposes no standard proximity datatype.
- **USB serial console** is opt-in: `sudo nabu-serial-gadget enable` exposes an
  ACM console on `/dev/ttyGS0`.

## Repository layout

```
build.sh                  # orchestrator (6 stages)
Dockerfile                # ALARM-based build environment
firmware/fetch-firmware.sh
kernel/                   # build-kernel.sh, cachyos.config, patches/, enable-slpi.sh
rootfs/                   # build-rootfs.sh, build-qualcomm.sh, build-iio-sensor-proxy.sh,
                          # build-theming.sh, packages*.txt, upstream-pins.sh, overlay/
image/build-image.sh
release/                  # create-release.sh, flash.sh, join-and-flash.sh, inject-ssh-key.sh,
                          # relabel-partition.sh, carve-linux-partition.sh
tools/                    # gpt-relabel.py, gpt-carve.py, verify-alarm-tarball.sh
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
