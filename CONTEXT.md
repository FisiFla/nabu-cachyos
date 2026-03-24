# Session Context

## Current State
CachyOS ARM running on Xiaomi Pad 5 with GNOME + working on-screen keyboard.

## What's Working
- CachyOS kernel (BORE v5.9.6 + ADIOS + 1000Hz + PREEMPT)
- GNOME Shell 49 on Wayland with touch + on-screen keyboard
- WiFi (ath10k via Qualcomm QMI stack)
- Audio speakers (CS35L41 via UCM profiles)
- GDM auto-login
- SSH access
- CachyOS branding + 11 CachyOS packages
- Mesa -O3 ARMv8.2-A optimized
- Full zsh stack (oh-my-zsh, powerlevel10k, fzf)
- Dynamic CPU governor, ADIOS I/O, MGLRU, ZRAM
- 105GB storage, 852 packages

## Next Steps
- Auto-rotation (needs accelerometer kernel driver)
- CachyOS ARM image for Parallels Desktop (future project, easy)
- Clean up KDE overlay files still in repo (SDDM configs etc)
- Consider building more packages with LTO (PipeWire, systemd)
