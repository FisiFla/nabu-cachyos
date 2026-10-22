#!/usr/bin/env bash
#
# Build a tiny initramfs used by test/test-qemu.sh --smoke.
#
# Base: an Alpine minirootfs (about 3 MB) because it ships a working ARM64
# busybox+musl userland already laid out for boot, and it is a plain static
# release tarball that needs no package manager. The Alpine init system
# (openrc) is discarded; our own minimal /init drives the smoke test:
#
#   mount proc          (so the kernel's /proc shows up, some tooling wants it)
#   echo marker         (the string test-qemu.sh greps for in the serial log)
#   poweroff -f         (busybox reboot(RB_POWER_OFF); QEMU exits cleanly)
#
# Packing runs inside the arm64 container for tidy root ownership and a
# reproducible newc cpio; nothing is installed on the host.
#
# Usage: test/build-smoke-initramfs.sh [--out FILE] [--force]
# Output: output/qemu-test/smoke-initramfs.cpio.gz (gitignored)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/output/qemu-test"
CACHE_DIR="${REPO_ROOT}/.cache/qemu-test"
INITRAMFS="${OUT_DIR}/smoke-initramfs.cpio.gz"
STAGE_IMAGE="${BUILD_TEST_IMAGE:-arm64v8/ubuntu:24.04}"

# Pinned Alpine release so the smoke test stays reproducible.
ALPINE_BASE_URL="${ALPINE_BASE_URL:-https://dl-cdn.alpinelinux.org}"
ALPINE_VERSION="${ALPINE_VERSION:-3.24.3}"
ALPINE_ARCH="${ALPINE_ARCH:-aarch64}"
ALPINE_TARBALL="alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"

# This exact string is the pass criteria test-qemu.sh --smoke greps for.
MARKER="NABU-QEMU-SMOKE-OK"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^# Packing/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out)    INITRAMFS="$2"; shift 2 ;;
        --force)  FORCE=1; shift ;;
        -h|--help) usage ;;
        *)        die "unknown argument: $1 (use --help)" ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    die "docker is required (macOS: brew install docker colima && colima start)"
fi
if ! docker info >/dev/null 2>&1; then
    die "docker daemon is not running (macOS with Colima: colima start)"
fi

mkdir -p "${OUT_DIR}" "${CACHE_DIR}"
if [ -f "${INITRAMFS}" ] && [ "${FORCE}" -eq 0 ]; then
    log "Already built: ${INITRAMFS} (pass --force to rebuild)"
    exit 0
fi

if [ ! -f "${CACHE_DIR}/${ALPINE_TARBALL}" ]; then
    log "Fetching ${ALPINE_TARBALL} ..."
    curl -fL --retry 3 -o "${CACHE_DIR}/${ALPINE_TARBALL}" \
        "${ALPINE_BASE_URL}/alpine/v3.24/releases/${ALPINE_ARCH}/${ALPINE_TARBALL}"
fi

# Extract and repack inside the container (root-owned files, newc cpio, no
# host cpio installed). The bind mount backs the cache dir on the host;
# the final initramfs is a single regular file, which rides the mount fine.
# The pack payload is written to the cache as a file so there is no nested
# quoting through `docker ... bash -c`.
PAYLOAD="${CACHE_DIR}/pack-initramfs.sh"
cat > "${PAYLOAD}" <<'PAYLOAD_EOF'
#!/bin/bash
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends cpio gzip >/dev/null
mkdir -p /stage /stage/proc /stage/dev
tar -C /stage -xzf "/work/${ALPINE_TARBALL}"
cat > /stage/init <<'INIT_EOF'
#!/bin/sh
# Smoke-test initramfs payload for nabu-cachyos test-qemu.sh.
mount -t proc none /proc
echo NABU-QEMU-SMOKE-OK
sync
poweroff -f
INIT_EOF
chmod 0755 /stage/init
cd /stage
find . | cpio -o -H newc | gzip -9 > /work/smoke-initramfs.cpio.gz
echo "packed initramfs with marker NABU-QEMU-SMOKE-OK"
PAYLOAD_EOF

log "Repacking initramfs (marker: ${MARKER}) ..."
docker run --rm \
    --platform linux/arm64 \
    -v "${CACHE_DIR}:/work" -w /work \
    -e ALPINE_TARBALL="${ALPINE_TARBALL}" \
    "${STAGE_IMAGE}" /bin/bash /work/pack-initramfs.sh

# The container wrote the result into the cache dir.
if [ ! -s "${CACHE_DIR}/smoke-initramfs.cpio.gz" ]; then
    die "initramfs pack failed: no output from container"
fi
mv "${CACHE_DIR}/smoke-initramfs.cpio.gz" "${INITRAMFS}"

if [ ! -s "${INITRAMFS}" ]; then
    die "initramfs pack failed: ${INITRAMFS} missing or empty"
fi

log "Initramfs built: ${INITRAMFS}"
