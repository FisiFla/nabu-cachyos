# Session Context

## Current State
CachyOS ARM running on Xiaomi Pad 5 with GNOME + working on-screen keyboard.
Rebuilt from clean GitHub repo + all live fixes reapplied.

## What's Working
- CachyOS kernel (BORE v5.9.6 + ADIOS + 1000Hz + PREEMPT)
- GNOME Shell on Wayland with touch + on-screen keyboard
- WiFi (ath10k via Qualcomm QMI — rmtfs -r -P -s flag critical)
- Audio speakers (CS35L41 via UCM profiles)
- GDM auto-login, no lock screen
- SSH access (root@nabu-cachyos.local)
- CachyOS branding, ADIOS I/O, MGLRU, performance governor
- Power button = freeze suspend (screen off, system stays alive)
- 105GB storage expanded

## Critical Build Script Bugs Found & Fixed
- rmtfs flags: must be `-r -P -s` NOT `-o /boot/efi -P -r`
- fstab: ESP mount must be commented out (causes emergency mode)
- dbus.service: is a SYMLINK — must rm + write real file
- Firmware: nabu-firmware blobs must be installed to rootfs
- Kernel: must build inside container /tmp (macOS case-insensitive)
- .dockerignore: was excluding needed files

## Next Steps
- Snapshot working rootfs as golden release image
- Properly fix ALL build scripts to match live state
- Create GitHub Release with pre-built images
- Make repo public
