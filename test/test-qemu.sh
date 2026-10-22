#!/usr/bin/env bash
#
# Boot and test the nabu-cachyos rootfs (or a smoke-test initramfs) under
# QEMU on your Mac, without touching the tablet. Companion to
# test/build-test-kernel.sh, which builds the QEMU kernel image.
#
# Two modes:
#
#   ./test/test-qemu.sh --smoke
#       Boots the kernel with a tiny marker initramfs. Proves the QEMU tool
#       chain (hvf accelerator, arm64 kernel boot, serial console) works.
#       Marker NABU-QEMU-SMOKE-OK on the serial log = pass, then the guest
#       powers off by itself.
#
#   ./test/test-qemu.sh [--rootfs FILE]
#       Boots the kernel with a prepared ext4 rootfs disk attached as a
#       virtio-blk device. Without --rootfs, this fetches the SAME verified
#       ArchLinuxARM base rootfs the build pipeline uses, GPG-verifies it
#       with the repo's tools/verify-alarm-tarball.sh, and turns it into a
#       4 GB ext4 image (in a container; mkfs.ext4 -d from an unpacked tree).
#       Pass when a getty prints "login:" on the serial console.
#
# What this CAN test: the rootfs contents -- packages, systemd units, SSH
# config, shells, boot ordering -- all userspace. What it CANNOT test: any
# real Qualcomm SoC hardware - QEMU's "virt" machine is a generic ARM
# virtual platform, so there is no sm8150 DTS, no WiFi/ touchscreen/
# audio/SLPI. Those still need the tablet.
#
# CLI mapping differences vs the tablet (by design):
#   - root= is /dev/vda here, not PARTLABEL=linux (that label is an
#     Android-GPT artifact; the QEMU disk has no Android partition table).
#   - console= is ttyAMA0 (QEMU virt PL011), not the tablet serial gadget.
#   - The kernel Image is `virtconfig`, not the sm8150 tablet kernel.
#
# Flags:
#   --kernel FILE      use this kernel Image (default: output/qemu-test/Image,
#                      built by test/build-test-kernel.sh)
#   --rootfs FILE      use this ext4 raw image as the root disk (default:
#                      output/qemu-test/linux-qemu.img, prepared here if
#                      missing; 4 GB, label "linux")
#   --smoke            run the initramfs smoke test instead of a rootfs
#   --timeout SECONDS  stop the guest after this long (rootfs default 300,
#                      smoke 120)
#   --accel ACCEL      qemu accelerator: hvf (Apple Silicon default) or tcg
#   --prepare-only     fetch+verify+prepare the rootfs image, do not boot
#   --size SIZE        rootfs image size for preparation (default 4G)
#
# Serial transcripts are written to test/log/ (gitignored) and the last one
# is echoed here on failure.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${REPO_ROOT}/output/qemu-test"
CACHE_DIR="${TEST_SCRATCH:-${REPO_ROOT}/.cache/qemu-test}"
LOG_DIR="${SCRIPT_DIR}/log"

KERNEL_IMG="${OUT_DIR}/Image"
ROOTFS_IMG="${OUT_DIR}/linux-qemu.img"
ROOTFS_SIZE="${ROOTFS_SIZE:-4G}"
ALARM_MIRROR="${ALARM_MIRROR:-https://ca.us.mirror.archlinuxarm.org}"
ALARM_TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"
PREPARE_IMAGE="${BUILD_TEST_IMAGE:-arm64v8/ubuntu:24.04}"
MODE="rootfs"
TIMEOUT=""
ACCEL=""
PREPARE_ONLY=0

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '/^# Flags:/,/^# Serial transcripts/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel)       KERNEL_IMG="$2"; shift 2 ;;
        --rootfs)       ROOTFS_IMG="$2"; MODE="rootfs"; shift 2 ;;
        --smoke)        MODE="smoke"; shift ;;
        --timeout)      TIMEOUT="$2"; shift 2 ;;
        --accel)        ACCEL="$2"; shift 2 ;;
        --prepare-only) PREPARE_ONLY=1; shift ;;
        --size)         ROOTFS_SIZE="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *)              die "unknown argument: $1 (use --help)" ;;
    esac
done

ACCEL_ARGS=()
if [ -n "${ACCEL}" ]; then
    ACCEL_ARGS=(-accel "${ACCEL}")
elif [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
    # Native on Apple Silicon: hypervisor.framework | fallback tcg everywhere else.
    ACCEL_ARGS=(-accel hvf -cpu host)
else
    ACCEL_ARGS=(-accel tcg -cpu max)
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "${LOG_DIR}"
TRANSCRIPT="${LOG_DIR}/${TIMESTAMP}-${MODE}.log"

prepare_rootfs() {
    if [ -s "${ROOTFS_IMG}" ]; then
        log "Rootfs image already present: ${ROOTFS_IMG}"
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        die "docker is needed to prepare the rootfs image (or pass --rootfs <file>)"
    fi
    mkdir -p "${CACHE_DIR}"
    if [ ! -f "${CACHE_DIR}/${ALARM_TARBALL}" ]; then
        log "Fetching ${ALARM_TARBALL} from ALARM mirror ..."
        curl -fL --retry 3 -o "${CACHE_DIR}/${ALARM_TARBALL}" \
            "${ALARM_MIRROR}/os/${ALARM_TARBALL}"
        curl -fL --retry 3 -o "${CACHE_DIR}/${ALARM_TARBALL}.sig" \
            "${ALARM_MIRROR}/os/${ALARM_TARBALL}.sig"
    fi
    if [ "${ALARM_ALLOW_UNVERIFIED:-0}" != "1" ]; then
        log "GPG-verifying tarball (tools/verify-alarm-tarball.sh) ..."
        bash "${REPO_ROOT}/tools/verify-alarm-tarball.sh" \
            "${CACHE_DIR}/${ALARM_TARBALL}" "${CACHE_DIR}/${ALARM_TARBALL}.sig"
    else
        log "WARNING: skipping tarball signature check (ALARM_ALLOW_UNVERIFIED=1)"
    fi

    log "Preparing ${ROOTFS_SIZE} ext4 image (label 'linux') in a container ..."
    cat > "${CACHE_DIR}/prepare-rootfs.sh" <<'PREP_EOF'
#!/bin/bash
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends e2fsprogs >/dev/null
# Staging stays in the container filesystem: the ALARM tarball contains
# dangling symlinks (var/run, ...) which do not survive a virtiofs
# round-trip on macOS, and mkfs.ext4 -d populates from the unpacked tree
# directly (no loop mount needed). Only the finished image crosses the
# mount back to the host.
rm -rf /stage /work/out.img
mkdir -p /stage
tar -C /stage -xpzf "/work/${ALARM_TARBALL}" --numeric-owner
truncate -s "${ROOTFS_SIZE:-4G}" /work/out.img
mkfs.ext4 -q -L linux -d /stage /work/out.img
e2fsck -f -p /work/out.img
echo "rootfs image ready"
PREP_EOF
    # shellcheck source=/dev/null
    docker run --rm \
        --platform linux/arm64 \
        -v "${CACHE_DIR}:/work" \
        -e ROOTFS_SIZE="${ROOTFS_SIZE}" \
        -e ALARM_TARBALL="${ALARM_TARBALL}" \
        "${PREPARE_IMAGE}" /bin/bash /work/prepare-rootfs.sh > \
        "${LOG_DIR}/${TIMESTAMP}-prepare-rootfs.log" 2>&1 || {
            tail -20 "${LOG_DIR}/${TIMESTAMP}-prepare-rootfs.log" >&2
            die "rootfs preparation failed (log: ${LOG_DIR}/${TIMESTAMP}-prepare-rootfs.log)"
        }
    mv "${CACHE_DIR}/out.img" "${ROOTFS_IMG}"
    log "Rootfs image ready: ${ROOTFS_IMG}"
}

run_qemu() {
    # run_qemu <marker> <timeout> <extra qemu args...>
    MARKER="$1"; shift
    RUN_TIMEOUT="$1"; shift

    log "Running QEMU (timeout: ${RUN_TIMEOUT}s, transcript: ${TRANSCRIPT}) ..."
    log "  qemu-system-aarch64 ${ACCEL_ARGS[*]} -machine virt ... $*"

    QEMU_RC=0
    qemu-system-aarch64 \
        "${ACCEL_ARGS[@]}" \
        -machine virt \
        -m 2G \
        -smp 2 \
        -no-reboot \
        -nographic \
        "$@" > "${TRANSCRIPT}" 2>&1 < /dev/null &
    QEMU_PID=$!

    (
        sleep "${RUN_TIMEOUT}"
        kill "${QEMU_PID}" >/dev/null 2>&1
    ) &
    WATCHDOG_PID=$!

    if wait "${QEMU_PID}"; then
        QEMU_RC=0
    else
        QEMU_RC=$?
    fi
    kill "${WATCHDOG_PID}" >/dev/null 2>&1 || true
    wait "${WATCHDOG_PID}" 2>/dev/null || true

    if grep -q "${MARKER}" "${TRANSCRIPT}"; then
        log "PASS (serial log contains '${MARKER}')"
        return 0
    fi

    log "FAIL: '${MARKER}' not found in the serial transcript (guest exit: ${QEMU_RC})."
    tail -30 "${TRANSCRIPT}" | sed 's/^/  | /'
    return 1
}

check_kernel() {
    if [ ! -s "${KERNEL_IMG}" ]; then
        die "kernel image not found: ${KERNEL_IMG}
Run ./test/build-test-kernel.sh first, or pass --kernel <Image>."
    fi
}

case "${MODE}" in
    smoke)
        check_kernel
        INITRAMFS="${OUT_DIR}/smoke-initramfs.cpio.gz"
        if [ ! -s "${INITRAMFS}" ]; then
            "${SCRIPT_DIR}/build-smoke-initramfs.sh" --out "${INITRAMFS}"
        fi
        SMOKE_TIMEOUT="${TIMEOUT:-120}"
        log "=== QEMU smoke test (kernel boot + initramfs) ==="
        run_qemu "NABU-QEMU-SMOKE-OK" "${SMOKE_TIMEOUT}" \
            -kernel "${KERNEL_IMG}" \
            -initrd "${INITRAMFS}" \
            -append "console=ttyAMA0 panic=-1"
        ;;
    rootfs)
        check_kernel
        if [ "${PREPARE_ONLY}" -eq 1 ]; then
            prepare_rootfs
            exit 0
        fi
        if [ ! -s "${ROOTFS_IMG}" ]; then
            die "rootfs image not found: ${ROOTFS_IMG}
Run ./test/test-qemu.sh --prepare-only first, or pass --rootfs <file>."
        fi
        ROOTFS_TIMEOUT="${TIMEOUT:-300}"
        log "=== QEMU rootfs boot test (login prompt) ==="
        run_qemu "login:" "${ROOTFS_TIMEOUT}" \
            -kernel "${KERNEL_IMG}" \
            -drive "if=none,format=raw,id=hd0,file=${ROOTFS_IMG}" \
            -device virtio-blk-device,drive=hd0 \
            -append "console=ttyAMA0 root=/dev/vda rw"
        ;;
    *)
        die "internal: unknown mode ${MODE}"
        ;;
esac

log "Serial transcript: ${TRANSCRIPT}"
log "Done."
