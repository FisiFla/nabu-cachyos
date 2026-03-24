# Session Context

## Current Task
CachyOS boots on nabu with WiFi + KDE Plasma desktop working!

## Key Decisions
- TheMojoMan's boot.img for direct-boot (not UEFI+GRUB)
- ext4 rootfs (not Btrfs)
- dbus-daemon instead of dbus-broker (kernel namespace limitations)
- Qualcomm userspace (rmtfs, tqftpserv, qrtr-ns) copied from Ubuntu — critical for WiFi
- fw_devlink=permissive in kernel cmdline

## What's Working (live on tablet now)
- KDE Plasma desktop via SDDM
- WiFi (wlan0 connected to FUMagenta at 192.168.0.228)
- SSH access (root@192.168.0.228 with ed25519 key)
- USB serial gadget (/dev/cu.usbmodemnabu_cachyos1)
- Bluetooth hardware detected (hci0)
- Touch screen (NVT firmware loaded)

## Next Steps
- Bake all live fixes into build scripts so rootfs image is correct from first boot
- Test touch input on KDE Plasma
- Apply CachyOS theming (Nord theme, wallpapers installed but may need config)
- Test Vivaldi browser
- Commit all fixes and update documentation
