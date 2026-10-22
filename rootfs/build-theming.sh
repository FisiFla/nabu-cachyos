#!/usr/bin/env bash
set -euo pipefail

ROOTFS="${1:?Usage: build-theming.sh <rootfs-path>}"
THEME_BUILD="/tmp/theming-build"
PKGBUILDS_REPO="https://github.com/CachyOS/CachyOS-PKGBUILDS.git"
PINS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rootfs/upstream-pins.sh
source "${PINS_DIR}/upstream-pins.sh"

echo "--- Building CachyOS theming packages ---"

# IMPORTANT: All CachyOS PKGBUILDs live in the CachyOS-PKGBUILDS repo, NOT
# in the individual asset repos (cachyos-kde-settings, cachyos-wallpapers, etc).
# The asset repos contain the source files; CachyOS-PKGBUILDS contains the
# packaging recipes that reference those sources. We clone PKGBUILDS once and
# build each package from its subdirectory.

mkdir -p "${THEME_BUILD}"
chown builder:builder "${THEME_BUILD}"
cd "${THEME_BUILD}"

if [ ! -d "CachyOS-PKGBUILDS" ]; then
    echo "Cloning CachyOS-PKGBUILDS..."
    sudo -u builder bash -c "set -euo pipefail
        git init --quiet CachyOS-PKGBUILDS
        git -C CachyOS-PKGBUILDS remote add origin '${PKGBUILDS_REPO}'
        git -C CachyOS-PKGBUILDS fetch --quiet --depth 1 origin '${CACHYOS_PKGBUILDS_COMMIT}'
        git -C CachyOS-PKGBUILDS checkout --quiet FETCH_HEAD"
fi

# Helper: build a PKGBUILD from CachyOS-PKGBUILDS/<subdir> and install to rootfs
build_and_install() {
    local subdir="$1"
    echo "  Building ${subdir}..."
    # set -e: a renamed upstream directory would abort the WHOLE build here.
    cd "${THEME_BUILD}/CachyOS-PKGBUILDS/${subdir}" || {
        echo "    WARNING: ${subdir} not found in CachyOS-PKGBUILDS (renamed upstream?), skipping"
        return 0
    }

    # Build as non-root user. These are arch=any theming packages so deps are
    # already in the rootfs from pacstrap. Use --nodeps to skip host dep checks.
    sudo -u builder makepkg -f --noconfirm --nodeps --skipinteg 2>&1 || {
        echo "    WARNING: makepkg failed for ${subdir}, skipping"
        return 0
    }

    # Install into target rootfs.
    # `--nodeps --nodeps` (a.k.a. `-dd`) is required: single `--nodeps` only
    # skips dep *version* checks but still validates dep package names. Some
    # CachyOS PKGBUILDs reference AUR-only deps that don't exist in ALARM
    # (e.g. cachyos-fish-config -> fish-autopair, fish-pure-prompt as of
    # May 2026), and pacman bails with an interactive "skip package?" prompt
    # that kills a non-tty build. Double `--nodeps` skips all dep checks —
    # safe for theming because the missing deps are cosmetic plugins.
    local pkg
    pkg=$(find "${THEME_BUILD}/CachyOS-PKGBUILDS/${subdir}" -maxdepth 1 -name '*.pkg.tar*' -print -quit 2>/dev/null)
    if [ -n "${pkg}" ]; then
        pacman -U --noconfirm --nodeps --nodeps --root "${ROOTFS}" --dbpath "${ROOTFS}/var/lib/pacman" \
            "${pkg}"
        echo "    Installed ${pkg}"
    else
        echo "    WARNING: No package produced for ${subdir}"
    fi
}

# All packages from CachyOS-PKGBUILDS repo
# NOTE: using cachyos-gnome-settings (not kde-settings) for GNOME desktop
build_and_install "cachyos-gnome-settings"
build_and_install "cachyos-wallpapers"
build_and_install "char-white"
build_and_install "cachyos-plymouth-bootanimation"
build_and_install "cachyos-fish-config"
build_and_install "cachyos-zsh-config"

echo "--- Theming packages installed ---"
