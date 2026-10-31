# nabu-torch / torch (Flashlight & Torch Control)

Full-featured hardware camera flashlight and torch controller for Linux and Xiaomi Pad 5 (`nabu`) with modern Libadwaita touch UI, real-time intensity slider, quick presets, strobe beacon, emergency SOS, auto-off timer, and command-line interface.

## Installation

Install via pacman using either package name:

```bash
# Conflict-free hardware package name
sudo pacman -S nabu-torch

# Or short package name alias
sudo pacman -S torch
```

## Features

- **Hardware Sysfs Integration**: Automatically detects and drives `/sys/class/leds/white:flash` (and standard mobile Linux torch nodes) with zero overhead.
- **Intensity & Brightness Control**: Full 1–255 (0–100%) granular brightness slider with live adjustment.
- **Quick Preset Pills**: 25% (reading/low), 50% (medium), 75% (high), and Max (100%).
- **Interactive Power Button**: Large, touch-friendly circular button with ambient glowing illumination feedback when active.
- **Strobe Beacon**: Adjustable frequency stroboscope (1 Hz to 10 Hz) for signaling.
- **Emergency SOS**: Standard Morse code `... --- ...` optical distress signal.
- **Auto-Off Timer**: Configurable safety timeout (1 to 15 minutes) to protect battery and prevent device heating.
- **Screen Light Mode**: Soft full-screen reading light with adjustable color warmth.
- **Fast CLI & Keybinding Ready**: Direct terminal subcommands for scripts, hardware buttons, and desktop shortcut bindings.

## CLI Usage

```bash
# Toggle flashlight on/off
torch toggle
# (or nabu-torch toggle)

# Turn on at full power or specific intensity
torch on
torch on 50%
torch on 180

# Turn off
torch off

# Check hardware status
torch status

# Set brightness without altering on/off state
torch set 75%

# Run stroboscope at 5 Hz
torch strobe 5

# Transmit emergency SOS beacon
torch sos
```
