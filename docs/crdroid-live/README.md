# Live crDroid reference artifacts (2026-05-25)

Captured from the running crDroid 12 install on slot A of this tablet. These are the **ground-truth references** for the kernel-parity work tracked under the "Kernel parity with downstream — sm8150 mainline gaps" Linear milestone. Pulled with adb + Magisk root.

## What's here

| File | Source on tablet | Use for |
|---|---|---|
| `kernel-config.gz` / `kernel-config.txt` | `/proc/config.gz` (decompressed) | Diff against our CachyOS kernel config to find missing CONFIG_* |
| `kernel-config-relevant.txt` | Filtered to FASTRPC/ADSPRPC/SUSPEND/PM_/CPU_IDLE/MSM_/LPM/QCOM_/SCM/RPMSG/QRTR | Quick survey of the downstream-only pieces |
| `kernel-cmdline.txt` | `/proc/cmdline` | LPM hints, bootdevice, slot-suffix |
| `dmesg-boot-head.txt` | first 200 lines of `dmesg` | Boot sequence — remoteproc load order, regulator init, etc. |
| `mixer_paths.xml` | `/vendor/etc/mixer_paths.xml` | **NAS-219 mic** — ALSA mixer-control routing per use-case |
| `audio_platform_info.xml` | `/vendor/etc/audio_platform_info.xml` | Per-stream sample rates + bit width policies |
| `audio_io_policy.conf` | `/vendor/etc/audio_io_policy.conf` | Output flags + topology selection |
| `audio_policy_volumes.xml` | `/vendor/etc/audio_policy_volumes.xml` | Volume curves |
| `audio_effects.xml` | `/vendor/etc/audio_effects.xml` | Effect chain config |
| `CAMERA_ICP.elf` | `/vendor/firmware/CAMERA_ICP.elf` | **NAS-243 camera** — Hexagon-side ICP firmware (3.4 MB) |
| `camxoverridesettings.txt` | `/vendor/etc/camera/camxoverridesettings.txt` | CamX tuning override knobs |
| `vendor-firmware-listing.txt` | `ls /vendor/firmware/` | Inventory of vendor-side firmware files (for shipping the right ones) |
| `vendor-dsp-libs.txt` | `ls /vendor/lib/rfsa/adsp/` | Inventory of Hexagon-side `.so` skel files loaded into the ADSP |
| `dumpsys-sensorservice.txt` | `dumpsys sensorservice` | All 49 sensors with HAL/vendor/type/rate metadata |
| `iio-devices.txt` | iio devices on running Android | IIO device names + channels |
| `sns_reg_config` | `/vendor/etc/sensors/sns_reg_config` | Default sensor registry config (template) |
| `hals.conf` | `/vendor/etc/sensors/hals.conf` | Sensor HALs registered (ssc + touch) |
| `sensor-init-scripts.txt` | concat of `/vendor/etc/init/vendor.sensors.*.rc` + `init.vendor.sensors.rc` | Android boot-time sensor bring-up order |
| `sensors-etc-listing.txt` | `ls /vendor/etc/sensors/` | Inventory |
| `power-state.txt` | `/sys/power/state` + `mem_sleep` + `pm_freeze_timeout` | Confirms downstream has `[deep]` |
| `suspend-stats-detail.txt` | (it's a directory on this kernel — placeholder) | |
| `kernel-adsprpc-sysfs.txt` | `/sys/module/adsprpc/parameters/` etc. | Module parameters of the downstream adsprpc driver |
| `soc0-info.txt` | `/sys/devices/soc0/*` (each file: 1-line content) | hw_platform, soc_id, platform_version — used by sensor configs |

## Hard headline finding

`grep ADSPRPC kernel-config.txt`:

```
CONFIG_MSM_ADSPRPC=y
```

No `CONFIG_FASTRPC` (mainline) anywhere. **Downstream uses an entirely separate driver** — confirms the NAS-218 ABI-mismatch conclusion. The kernel-parity work for sensors is essentially porting the listener-PD-create logic from `drivers/char/adsprpc.c` (downstream) into `drivers/misc/fastrpc.c` (mainline).

## Companion docs

- [`crdroid-reference-2026-05-24.md`](../crdroid-reference-2026-05-24.md) — narrative writeup of the four subsystems' deltas + path-to-fix per subsystem.
- crDroid kernel source: https://github.com/crdroidandroid/android_kernel_xiaomi_sm8150 (4.14 downstream, includes `drivers/char/adsprpc.c` + `drivers/cpuidle/lpm-levels*.c`)
- Mainline sm8150 fork we build against: https://gitlab.com/sm8150-mainline/linux (branch `sm8150/6.17-wifi-fix` per our `KERNEL_VERSION`)
