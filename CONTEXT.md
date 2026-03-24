# Session Context

## Current Task
CachyOS with custom BORE kernel running on Xiaomi Pad 5!

## Key Achievements
- CachyOS kernel (BORE v5.9.6 + ADIOS + 1000Hz + PREEMPT) compiled and booting
- KDE Plasma desktop working with touch
- WiFi working (ath10k via Qualcomm QMI stack)
- Audio speakers detected (CS35L41 via UCM profiles)
- 105GB storage, ZRAM swap, BFQ I/O scheduler
- SSH access, USB serial gadget for debugging

## Next Steps
- Fix on-screen virtual keyboard (KDE 6 Wayland issue — QT_IM_MODULE crashes session)
- Rebuild key packages with aarch64 optimizations (Mesa, PipeWire) for full CachyOS experience
- Auto-rotation needs accelerometer driver in kernel (not currently enabled)
- Update build scripts to use CachyOS kernel by default instead of TheMojoMan's
- CachyOS branding (os-release, etc.)
