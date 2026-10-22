#!/usr/bin/env bash
# upstream-pins.sh — source of truth for every upstream repo cloned during
# the build. Clones fetch exact commits so a rebuild reproduces the same
# artifacts and an upstream force-push cannot silently change what ends up
# on the tablet.
#
# To bump a pin: `git ls-remote <url> | awk '/heads\/main/{print $1}'`,
# paste the commit next to the same variable, and note the date/reason.
# shellcheck shell=bash
# Pins are consumed by the scripts that source this file; standalone
# checks of this file flag them as unused by design.
# shellcheck disable=SC2034

# https://github.com/linux-msm/qrtr (v1.2 line, used by rmtfs/tqftpserv/...)
QRTR_COMMIT="29e36ae164389580a0f8ea7a7fdb728140ae978d"
# https://github.com/linux-msm/qmic (QMI compiler)
QMIC_COMMIT="4574736afce75aa5eec1e1069a19563410167c9f"
# https://github.com/linux-msm/rmtfs (remote filesystem service)
RMTFS_COMMIT="b30a3eb38f9af283f18dbd3c7755653efc52c094"
# https://github.com/linux-msm/tqftpserv (TFTP service, modem firmware)
TQFTPSERV_COMMIT="0bf5b98c24229b0042554d99bb1509d813219f36"
# https://github.com/linux-msm/qbootctl (A/B slot HAL)
QBOOTCTL_COMMIT="39a6e6daaf029fb0a083777679a15ea2c18f72de"
# https://github.com/linux-msm/hexagonrpc (SLPI FastRPC bridge)
# da7a374 = v0.5.0 line (interp4 protobuf work, 2026-09-15). Adds no new
# kernel ioctls — safe bump on the sm8150/6.17 kernel. The -S static-PD
# patch in tools/ is rebased on top of this commit.
HEXAGONRPC_COMMIT="da7a3742ab8d5273a281b70ee11f16fb2cb6a690"
# https://github.com/CachyOS/CachyOS-PKGBUILDS (theming + tools recipes)
CACHYOS_PKGBUILDS_COMMIT="4acf89f06990f13ce43c74ef6bb2f0a9cf496a8c"
# https://github.com/ohmyzsh/ohmyzsh (zsh plugins)
OHMYZSH_COMMIT="2100c630ba4bd67bb48802c3e7da893a4fdaa1a0"
# https://github.com/romkatv/powerlevel10k
POWERLEVEL10K_COMMIT="d05a1b00f9a61f9578bf9dc19b8451942dde8734"
# https://github.com/zsh-users/zsh-history-substring-search
HISTORY_SUBSTRING_COMMIT="a0bdb0d47dbaba31dba2db7af8c48a5d9c74049a"
# AUR: vivaldi-multiarch-bin
VIVALDI_MULTIARCH_BIN_COMMIT="22e1863fa6af955674db3ef958f93104db2862e9"
# AUR: paru-bin
PARU_BIN_COMMIT="92a55429afbec4fceeb2cef843245105307444d2"

# iio-sensor-proxy + libssc (rootfs/build-iio-sensor-proxy.sh — issue #24,
# updated by issue #30).
#   iio-sensor-proxy tag 3.9 (annotated) → 0085ddf8ecb1…; patched by
#   rootfs/patches/iio-sensor-proxy/{0001-fix-ssc-race-condition,
#   0002-ssc-proximity-nabu-sar-fallback}.patch (source:
#   github.com/Kumar-Jy/nabu-pkgs (HEAD fec1080 2026-10-21)/packages/iio-sensor-proxy @ master,
#   fetched 2026-10-22). Both patches verified to apply cleanly to the 3.9 tag.
#   libssc → post-v0.4.4 master 4e4c6c8c (2026-09-11). NO vendored patch:
#   nabu-pkgs' report-handler-lifecycle patch was written against this master
#   state (not v0.4.4), so it half-applied with `patch -Np1` fuzz on the tag
#   and left the build broken under strict GLib macro checking (see issue
#   #30). Everything the patch did is already upstream here — the "guint"
#   report-handler fields that matter are `gulong` and
#   g_clear_signal_handler() is only used where the field is gulong.
IIO_SENSOR_PROXY_COMMIT="0085ddf8ecb173a1c5fcf2344aa40e561125354f"
LIBSSC_COMMIT="4e4c6c8cc702a754bd700506c01961aaf971a23b"

# clone_pinned <url> <dir> <commit>
# Fetch exactly one depth-1 commit and check it out. Works for any commit
# reachable from the remote (GitHub and the AUR both allow fetch-by-SHA),
# which is the point: `git clone --depth 1` + `checkout <pin>` only works
# when the pin happens to be the branch head.
clone_pinned() {
    local url="$1" dir="$2" commit="${3:-}"
    if [ -z "${commit}" ]; then
        echo "ERROR: no pin recorded for ${url} — refusing a HEAD clone" >&2
        return 1
    fi
    git init --quiet "${dir}"
    git -C "${dir}" remote add origin "${url}"
    git -C "${dir}" fetch --quiet --depth 1 origin "${commit}"
    git -C "${dir}" checkout --quiet FETCH_HEAD
}
