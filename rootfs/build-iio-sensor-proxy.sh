#!/usr/bin/env bash
set -euo pipefail

# Build libssc and a patched iio-sensor-proxy for the Snapdragon SSC sensor
# stack (issues: sensors "races, finds no sensors, and exits" + no Xiaomi sar
# proximity).
#
# What we build:
#   libssc           post-v0.4.4 master (4e4c6c8c) — upstream already includes
#                    the report-handler lifecycle fixes; no patch needed
#                    (see upstream-pins.sh + issue #30)
#   iio-sensor-proxy tag 3.9   + SSC race-condition patch + Xiaomi sar
#                                proximity ("ssc-proximity") patches
#
# Both are installed into the target rootfs the same way build-qualcomm.sh
# installs its daemons: meson install into the container first (linking), then
# a DESTDIR pass into the rootfs. Ownership note: the base rootfs already has
# stock iio-sensor-proxy (pacstrap) and possibly libssc from ALARM repos. We
# deliberately overwrite those files WITHOUT touching the pacman database:
# pacman replaces its own package's paths silently on any future repo update,
# and the files that only WE ship (the sar udev tags, patched-built bits) stay
# unowned and untouched. Same-version pins (tag 3.9) mean the pin and the
# repo agree on the upstream content — only our two patches differ.

ROOTFS="${1:?Usage: build-iio-sensor-proxy.sh <rootfs-path>}"
BUILD_DIR="/tmp/iio-build"
PINS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=rootfs/upstream-pins.sh
source "${PINS_DIR}/upstream-pins.sh"

echo "--- Building libssc + iio-sensor-proxy (SSC/sar patches) ---"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Build env: gobject-introspection for libssc's gir generation; libqmi and
# protobuf-c so libssc links (the rootfs side gets the same from packages.txt).
# polkit provides polkit-gobject-1.pc that iio-sensor-proxy links against;
# libqmi provides libqmi-glib.pc for libssc; protobuf-c provides protoc-gen-c
# (libssc regenerates .pb-c.c from .proto at build time).
pacman -S --needed --noconfirm gobject-introspection libqmi protobuf-c polkit >/dev/null

# 1. libssc — the library SSC-support builds against, and the runtime lib the
#    daemon loads (libqmi/glib are runtime deps). Pinned to the master commit
#    that already carries the report-handler lifecycle fixes — do NOT apply
#    nabu-pkgs' patch here: it was written against this state, and fuzzily
#    half-applying it onto the v0.4.4 tag breaks the build.
echo "  [1/2] Building libssc (${LIBSSC_COMMIT:0:12})..."
clone_pinned "https://codeberg.org/DylanVanAssche/libssc.git" \
    libssc "${LIBSSC_COMMIT}"
meson setup libssc/builddir libssc --prefix=/usr --libdir=/usr/lib --buildtype=release
meson compile -C libssc/builddir
meson install -C libssc/builddir             # into the builder container
DESTDIR="${ROOTFS}" meson install -C libssc/builddir     # into the target rootfs

# 2. iio-sensor-proxy with the two nabu patches and SSC support enabled.
echo "  [2/2] Building iio-sensor-proxy 3.9 + SSC/sar patches..."
clone_pinned "https://gitlab.freedesktop.org/hadess/iio-sensor-proxy.git" \
    iio-sensor-proxy "${IIO_SENSOR_PROXY_COMMIT}"
# Patches via strict `git apply` (all-or-nothing): `patch`'s fuzzy fallback can
# half-apply a mismatched patch and preserve the illusion of success (issue #30).
git -C iio-sensor-proxy apply -v \
    "${PINS_DIR}/patches/iio-sensor-proxy/0001-fix-ssc-race-condition.patch"
git -C iio-sensor-proxy apply -v \
    "${PINS_DIR}/patches/iio-sensor-proxy/0002-ssc-proximity-nabu-sar-fallback.patch"
meson setup iio-sensor-proxy/builddir iio-sensor-proxy \
    --prefix=/usr --libdir=/usr/lib --buildtype=release \
    -Dsystemdsystemunitdir=/usr/lib/systemd/system \
    -Dudevrulesdir=/usr/lib/udev/rules.d \
    -Dsysconfdir=/usr/share \
    -Dssc-support=enabled
meson compile -C iio-sensor-proxy/builddir
DESTDIR="${ROOTFS}" meson install -C iio-sensor-proxy/builddir

echo "--- libssc + patched iio-sensor-proxy installed into ${ROOTFS} ---"
