# crDroid 12 on nabu — reference snapshot for CachyOS feature bring-up

Captured live from crDroid Android 16 (v12.10, kernel `4.14.357-perf-g3d4420cd4e65`, sm8150 downstream) running on the same Xiaomi Pad 5 we target with CachyOS. Use this as the canonical "what's needed to make X work" reference when porting subsystems to mainline.

**Big picture**: nearly every "broken on CachyOS" feature works on crDroid because crDroid runs the **downstream Qualcomm 4.14 kernel** with all the proprietary drivers + Qualcomm userspace. Our CachyOS runs **mainline kernel 6.17 (sm8150-mainline)** which has *partial* hardware enablement upstream. The deltas below describe what each subsystem needs.

How to switch between the two on the tablet:

```bash
# Active slot A = crDroid Android, slot B = CachyOS
fastboot --set-active=a   # crDroid
fastboot --set-active=b   # CachyOS
fastboot reboot
```

The tablet's GPT was edited to relabel partition `linux` (CachyOS rootfs) back to `userdata` (Android expectation) — see "GPT surgery notes" at bottom.

## 1. Suspend / power management (NAS-217)

### Live crDroid state
- `/sys/power/state` = `freeze mem` (both s2idle AND deep available)
- `/sys/power/mem_sleep` = `s2idle [deep]` — **deep is default**
- `/proc/cmdline` includes `lpm_levels.sleep_disabled=1` (Qualcomm low-power-mode override hint)
- `/sys/power/wake_lock` + `wake_unlock` present (Android wakelock interface, downstream-only)
- Power HAL: `/vendor/lib64/hw/power.default.so`

### CachyOS mainline state
Per `nabu_cachyos.md` memory: only `[s2idle]` in `/sys/power/mem_sleep`, no `deep`. `msm_mdss` display IRQ wakes the system within ~1 s of s2idle entry. Current workaround: `HandlePowerKey=ignore` so power button does nothing.

### Gap
- Mainline `arch/arm64/boot/dts/qcom/sm8150.dtsi` does not expose Qualcomm's "low-power mode" (LPM) levels needed for proper `mem` (deep) suspend.
- The downstream kernel has `drivers/cpuidle/lpm-levels-qcom.c` (Qualcomm proprietary) that orchestrates SoC-level power-down. Mainline has nothing equivalent.
- DRM IRQ masking during suspend is needed to prevent `msm_mdss` from waking the SoC.

### Path to "fixed"
Multi-week kernel work: backport / re-implement LPM levels + DRM IRQ quiesce for sm8150 in mainline. Or wait for upstream Linaro/Qualcomm contributions. This is the same flavor of blocker as NAS-218 sensors — *downstream kernel only*.

## 2. Audio / microphone (NAS-219)

### Live crDroid state
- Sound card: `sm8150-tavil-snd-card` (codec: **WCD9341 "Tavil"**, sm8150 reference)
- PCM nodes: `card0/pcm0c..pcm13c` (capture) + `pcm0p..pcm13p` (playback) + compressed streams `compr8..compr41`
- Speaker amps in DT: **cs35l41** (Cirrus Logic, already in our CachyOS build), plus TAS2557 / TAS256X / TFA9874 fallback support compiled in kernel
- Mixer config: `/vendor/etc/mixer_paths.xml` (direct ALSA mixer-control routing)
- Audio policy: `/vendor/etc/audio_platform_info.xml` + `/vendor/etc/audio_io_policy.conf`
- HAL: `/vendor/lib/hw/audio.primary.msmnile.so` (Qualcomm proprietary, msmnile = sm8150 codename)

### CachyOS mainline state
- WCD9340/WCD9341 (Tavil) **driver exists** in mainline (`sound/soc/codecs/wcd934x.c`)
- We already ship `/usr/share/alsa/ucm2/Xiaomi/nabu/HiFi.conf` (UCM verb file)
- Mic doesn't capture (NAS-219 still open)

### Gap
- crDroid uses `mixer_paths.xml` (a sequence of mixer-control writes per use-case) for capture path activation. Our UCM `HiFi.conf` probably activates a different control sequence.
- Action: cross-reference `mixer_paths.xml` paths for `audio-record` or `voice-call-record` against our UCM `Capture.SectionVerb` mixer ops.

### Concrete next step for NAS-219
1. Pull `/vendor/etc/mixer_paths.xml` + `/vendor/etc/audio_platform_info.xml` from crDroid (`adb pull`).
2. On crDroid: start a recording app, then `tinymix -D 0` (we'd need to push it — same approach as strace) snapshots the mixer state at the moment recording works.
3. Diff that mixer state against what our UCM produces. Apply the missing controls.

`tinymix` not present in crDroid stock — push from external. Or write a small ADB script that does `tinyplay`/`tinycap` directly.

## 3. Camera (NAS-243)

### Live crDroid state
- HAL: `/vendor/lib64/hw/camera.qcom.so` + `/vendor/etc/camera/camxoverridesettings.txt` (Qualcomm CamX-CHI)
- Hardware (matches Linear NAS-243 research): rear **OV13B10**, front **OV8856** (both with mainline V4L2 drivers existing)
- Vendor config tree at `/vendor/etc/camera/` — proprietary tuning data (Morpho lowlight, Almalence SR, MegVii FacePP, Mi bokeh) plus the standard Qualcomm CamX config
- ICP firmware: `CAMERA_ICP.elf` (also in postmarketOS nabu-firmware bundle)
- camxoverridesettings flags worth noting: `multiCameraEnable=FALSE`, `disablePDAF=FALSE`, `disableFocusIndication=1`

### CachyOS mainline state
- README §Known Limitations: "Camera — no mainline driver, does not work on any Linux distro for nabu"
- Mainline `drivers/media/platform/qcom/camss/` has partial sm8150 support but no nabu DT bring-up for ov13b10/ov8856

### Gap
- Need DT nodes for OV13B10 + OV8856 on the CCI/I2C bus (similar pattern to our `kernel/enable-slpi.sh` DT patch).
- Need `CAMERA_ICP.elf` shipped at `/usr/lib/firmware/qcom/sm8150/xiaomi/nabu/`.
- libcamera + libcamera-tools userspace.
- Tuning data (Morpho/Almalence/MegVii) is **Qualcomm-proprietary and non-redistributable** — we get raw frames without any post-processing.

### Concrete next step for NAS-243
Per NAS-243 ticket: DT-patch enabling sensor nodes, ship `CAMERA_ICP.elf`, install `libcamera`. Acceptance tier 2 (rear-only JPEG capture) is realistic. Tier 4 (anything Android-quality) requires the proprietary tuning data and CamX HAL, which we can't ship.

## 4. Sensors (NAS-218) — DEFINITIVE blocker writeup

### Live crDroid state
- `sscrpcd sensorspd` running as user `system` (PID 742) — Qualcomm Sensor Subsystem RPC daemon
- `sensors.qti` running — Android sensors HAL bridge
- 49 sensors visible in `dumpsys sensorservice`: LSM6DSO accel+gyro, AK991x mag, TCS3701 + BU27030 (front + back) ambient light, ADUX1050 SAR/prox, plus 20+ virtual sensors (orient, AOD, pedometer, pickup, tilt_to_wake, etc.)
- sscrpcd opens **`/dev/adsprpc-smd-secure`** (file descriptor 7 in `/proc/742/fd/`)
- Loads `libssc_default_listener.so` + `libadsp_default_listener.so` from `/vendor/lib64/`

### The hard truth
- **Downstream kernel** uses `drivers/char/adsprpc.c` (a Qualcomm-internal driver) which exposes `/dev/adsprpc-smd*` device nodes
- **Mainline kernel 6.17** uses `drivers/misc/fastrpc.c` (the upstreamed-by-Linaro driver) which exposes `/dev/fastrpc-*` device nodes
- **Both drivers speak the same FastRPC wire protocol to the DSP**, but the userspace ABIs (ioctl numbers, struct layouts, attach/create semantics) are DIFFERENT
- `sscrpcd` is dynamically linked to bionic + uses downstream ioctls — cannot run as-is on mainline kernel even via libhybris
- `hexagonrpcd` (mainline-friendly equivalent) supports `INIT_ATTACH`, `INIT_ATTACH_SNS`, `INIT_CREATE`. We patched it in this session to add `INIT_CREATE_STATIC` (kernel UAPI supports it as `_IOWR('R', 9, struct fastrpc_init_create_static)`). Patch ioctl returns `EPIPE` — the post-CREATE handshake to the SLPI firmware fails because the mainline driver doesn't do the additional setup the downstream driver does
- SLPI co-processor *boots* (we confirmed: 6.1 MB slpi_nb.mbn loads via `qcom_q6v5_pas`, Sensor Core service appears on QRTR 9:13 service 400) but crashes every ~40 s in a PD-recovery loop because no AP-side file server is satisfying its sns.reg config requests

### Path to "fixed"
Multi-week kernel work: contribute the missing INIT_CREATE_STATIC + listener-PD-create handshake to mainline `fastrpc.c`. linux-arm-msm mailing list territory.

## 5. GPT surgery notes (for re-doing later)

CachyOS's original installer repartitioned Xiaomi's `userdata` partition into `linux` (PARTLABEL change, same sectors). crDroid's recovery refuses to install without a `userdata` partition, so:

1. Pull primary GPT (LBA 1, 4K sectors): `dd if=/dev/block/sda bs=4096 skip=1 count=5`
2. Pull backup GPT (last 5 LBAs): `dd ... skip=$((total_lbas - 5)) count=5`
3. nabu UFS LUN 0: logical block size = **4096 bytes**, **64 partition entries**, entry size 128 bytes, primary entries at LBA 2 (4 LBAs = 8 KB array)
4. Python script: locate entry by UTF-16LE name match, rewrite name field, recompute partition-array CRC32, recompute header CRC32
5. Write modified bytes back via `dd ... conv=notrunc`
6. Repeat for backup GPT (header at last LBA, entries at LBA `total-5`..`total-2`)
7. Reboot to force kernel re-read

Scripts produced in this session — keep them in `/tmp/gpt-rename*.py` if we need to do it again or invert (rename `userdata` back to `linux` for CachyOS install).

## 6. Strategic implication for "all-working CachyOS build"

Three of the four "broken on CachyOS" subsystems (suspend, sensors, camera) hit the same root cause: **the mainline Linux kernel doesn't have feature parity with the downstream Qualcomm 4.14 kernel** for sm8150-class chipsets. Patches exist for some pieces (CAMSS partial, fastrpc mostly upstreamed) but the SLPI sensor manager, LPM-based deep suspend, and full CamX HAL bring-up are downstream-only.

Realistic options:

| Option | Outcome | Trade-off |
|---|---|---|
| **Stay on mainline 6.17, accept gaps** | Current state | Camera/sensors/suspend stay broken; long-term maintainability |
| **Backport downstream pieces** | Multi-month per-feature kernel work | Hard to maintain across mainline rebases |
| **Switch CachyOS to downstream 4.14** | Full hardware support overnight | Old kernel, security updates harder, doesn't fit CachyOS's mainline-first philosophy |
| **Hybrid: mainline + selective downstream drivers as modules** | Each driver ported as out-of-tree module | Same cost as backport per-feature; hard to ship |

No upstream nabu Linux distro (postmarketOS, Manjaro ARM, etc.) has solved this. The "everything works" image on nabu currently exists only on Android (downstream kernel). That's not a defect of our build — that's the state of the art.

## 7. Actual tablet state after this session

- **Slot B** = working **crDroid 12 + Magisk root**. This is where we are now. `current-slot=b`. Boot to it normally.
- **Slot A** = crDroid boot images flashed but no `system_a` / `vendor_a` populated (we never sideloaded to slot A). Will bootloop if set_active. To make slot A a working OS, sideload the OTA again from slot-B's recovery (would target the inactive slot A).
- **CachyOS is gone**: its rootfs lived on the `linux` partition which we GPT-renamed to `userdata` for crDroid; crDroid then formatted it as f2fs. To get CachyOS back we'd need to rename `userdata` back to `linux` (re-do the GPT surgery in reverse) and re-flash our CachyOS image.
- ROM artifacts on disk: `/Users/flaviofisicaro/Downloads/nabu-rom/` — boot.img, vendor_boot.img, dtbo.img, vbmeta.img, the full payload-extracted partition images, Magisk-patched boot, TWRP image.
- CachyOS build artifacts on disk: `/Users/flaviofisicaro/Downloads/nas-stuff/nabu-cachyos/output/` — boot.img, linux.img.zst, vbmeta_disabled.img, etc. — ready to flash back whenever we want CachyOS again.

## 8. What this session shipped (code)

- Commit [`f93428b`](https://github.com/FisiFla/nabu-cachyos/commit/f93428b) on `main` of `FisiFla/nabu-cachyos` — full SLPI integration scaffolding (firmware fetch from postmarketOS, kernel DT enable via `kernel/enable-slpi.sh`, hexagonrpcd build from `linux-msm/hexagonrpc`, userspace wiring) + spillover wins (mDNS via nsswitch.conf sed, SSH injection alpine fallback, macOS sparse-flash via img2simg, build pipeline fixes for `--nodeps --nodeps` + orphan `chmod` removal).
- Locally on host (not yet committed): `/tmp/gpt-rename.py` + `/tmp/gpt-fix-backup.py` — Python GPT-label rename utility, useful if we ever want to rename `userdata` ↔ `linux` again.
- Patched `hexagonrpcd` binary with `-S NAME` option (INIT_CREATE_STATIC support) at `/Users/flaviofisicaro/Downloads/nas-stuff/nabu-cachyos/output/hexagonrpcd-patched`. Patch is upstreamable to `linux-msm/hexagonrpc` once we understand the post-CREATE handshake the SLPI firmware expects.
- This document.
