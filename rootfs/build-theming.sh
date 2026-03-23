#!/usr/bin/env bash
set -euo pipefail

ROOTFS="${1:?Usage: build-theming.sh <rootfs-path>}"
THEME_BUILD="/tmp/theming-build"
PKGBUILDS_REPO="https://github.com/CachyOS/CachyOS-PKGBUILDS.git"

echo "--- Building CachyOS theming packages ---"

# IMPORTANT: All CachyOS PKGBUILDs live in the CachyOS-PKGBUILDS repo, NOT
# in the individual asset repos (cachyos-kde-settings, cachyos-wallpapers, etc).
# The asset repos contain the source files; CachyOS-PKGBUILDS contains the
# packaging recipes that reference those sources. We clone PKGBUILDS once and
# build each package from its subdirectory.

mkdir -p "${THEME_BUILD}"
cd "${THEME_BUILD}"

if [ ! -d "CachyOS-PKGBUILDS" ]; then
    echo "Cloning CachyOS-PKGBUILDS..."
    git clone --depth 1 "${PKGBUILDS_REPO}" CachyOS-PKGBUILDS
fi

# Helper: build a PKGBUILD from CachyOS-PKGBUILDS/<subdir> and install to rootfs
build_and_install() {
    local subdir="$1"
    echo "  Building ${subdir}..."
    cd "${THEME_BUILD}/CachyOS-PKGBUILDS/${subdir}"

    # Build as non-root user (makepkg requirement)
    sudo -u builder makepkg -f --noconfirm --syncdeps 2>&1 || {
        echo "    WARNING: makepkg failed for ${subdir}, attempting without deps..."
        sudo -u builder makepkg -f --noconfirm 2>&1 || true
    }

    # Install into target rootfs (use arch-chroot so install hooks run correctly)
    local pkg
    pkg=$(ls -1 *.pkg.tar* 2>/dev/null | head -1)
    if [ -n "${pkg}" ]; then
        cp "${pkg}" "${ROOTFS}/tmp/"
        arch-chroot "${ROOTFS}" pacman -U --noconfirm "/tmp/$(basename "${pkg}")"
        rm "${ROOTFS}/tmp/$(basename "${pkg}")"
        echo "    Installed ${pkg}"
    else
        echo "    WARNING: No package produced for ${subdir}"
    fi
}

# All packages from CachyOS-PKGBUILDS repo
build_and_install "cachyos-kde-settings"
build_and_install "cachyos-wallpapers"
build_and_install "cachyos-themes-sddm"
build_and_install "cachyos-nord-kde"
build_and_install "char-white"
build_and_install "cachyos-plymouth-bootanimation"
build_and_install "cachyos-fish-config"
build_and_install "cachyos-zsh-config"

echo "--- Theming packages installed ---"
