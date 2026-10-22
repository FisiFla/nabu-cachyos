#!/usr/bin/env bash
set -euo pipefail

# Rootfs is built in container-local filesystem (not on bind mount)
ROOTFS="/tmp/rootfs-build"
OUTPUT="/build/output"

echo "--- Building flashable images ---"

# 1. Verify boot.img was created by kernel build
if [ ! -f "${OUTPUT}/boot.img" ]; then
    echo "ERROR: boot.img not found. Kernel build should have created it."
    exit 1
fi

# 2. Build ext4 rootfs image for the fastboot-flashed linux partition.
# The release path direct-boots the Android boot.img and does not use the
# legacy GRUB/ESP flow anymore, so we intentionally do not build esp.img here.
echo "Building ext4 rootfs image..."
LINUX_IMG="${OUTPUT}/linux.img"

# Calculate image size with GNU du:
#   --apparent-size  file *content* in bytes (what mkfs.ext4 -d materializes),
#                    not allocated blocks (allocated over-reports sparse/file
#                    slack and would make the image bigger than needed)
#   --count-links    do NOT dedup hardlinks (mkfs.ext4 -d copies every
#                    directory entry, so Arch's hardlinked man pages land
#                    once per link, not once per inode)
ROOTFS_SIZE_KB=$(du -sk --apparent-size --count-links "${ROOTFS}" | awk '{print $1}')
IMG_SIZE_MB=$(( ROOTFS_SIZE_KB * 120 / 100 / 1024 ))
echo "  Rootfs content is ${ROOTFS_SIZE_KB}kB, creating ${IMG_SIZE_MB}MB image..."

# Populate the filesystem from the rootfs tree at mkfs time. Avoids needing
# a loopback mount, which Docker containers (even --privileged) can't always
# allocate — `mount -o loop` fails with "failed to set up loop device" on
# hosts where /dev/loop-control isn't exposed.
truncate -s "${IMG_SIZE_MB}M" "${LINUX_IMG}"
mkfs.ext4 -F -L linux -d "${ROOTFS}" "${LINUX_IMG}"

# Verify the populated filesystem now, not after a 4-minute flash on the
# tablet. mkfs.ext4 -d does not fail reliably when the declared image is
# smaller than the content, and a silent under-copy shows up later as a
# broken first boot.
STAT_OUT=$(debugfs -R "stat /etc/os-release" "${LINUX_IMG}" 2>&1 || true)
if echo "${STAT_OUT}" | grep -qi "not found"; then
    echo "ERROR: /etc/os-release is missing from ${LINUX_IMG} — the filesystem was not populated."
    exit 1
fi
FREE_BLOCKS=$(dumpe2fs -h "${LINUX_IMG}" 2>/dev/null | awk '/^Free blocks:/ {print $3}')
TOTAL_BLOCKS=$(dumpe2fs -h "${LINUX_IMG}" 2>/dev/null | awk '/^Block count:/ {print $3}')
if [ -z "${FREE_BLOCKS}" ] || [ -z "${TOTAL_BLOCKS}" ]; then
    echo "ERROR: cannot read filesystem geometry from ${LINUX_IMG}."
    exit 1
fi
FREE_RATIO=$(( FREE_BLOCKS * 100 / TOTAL_BLOCKS ))
if [ "${FREE_RATIO}" -lt 5 ]; then
    echo "ERROR: image is only ${FREE_RATIO}% free (< 5%) — content does not fit with headroom."
    echo "       Increase the 120% multiplier in build-image.sh."
    exit 1
fi
echo "  Filesystem populated (/etc/os-release present, ${FREE_RATIO}% free)."

# Record how big the 'linux' partition must be, so release/flash.sh can
# compare it against `fastboot getvar partition-size:linux` before flashing
# (fastboot cannot grow partitions — a mismatch has to abort up front).
#
# IMG_SIZE_MB is a CEILING (content + headroom), IMG_SIZE_BYTES is the exact
# file size. flash.sh needs both: the ceiling to validate the partition, the
# exact size to tell a stale linux.img from the one this bundle produced.
IMG_SIZE_BYTES=$(wc -c < "${LINUX_IMG}")
printf 'IMG_SIZE_MB=%s\nIMG_SIZE_BYTES=%s\n' "${IMG_SIZE_MB}" "${IMG_SIZE_BYTES}" \
    > "${OUTPUT}/image-size.txt"

# Compress with zstd
echo "  Compressing rootfs image..."
zstd -f -T0 -9 "${LINUX_IMG}" -o "${OUTPUT}/linux.img.zst"
rm "${LINUX_IMG}"

echo "  Rootfs image: ${OUTPUT}/linux.img.zst ($(du -h "${OUTPUT}/linux.img.zst" | cut -f1))"

# 3. Generate SHA256 checksums
echo "Generating checksums..."
cd "${OUTPUT}"
sha256sum ./*.img ./*.zst 2>/dev/null > SHA256SUMS || true
cat SHA256SUMS

echo ""
echo "--- Image build complete ---"
echo "Artifacts:"
ls -lh "${OUTPUT}/"*.img "${OUTPUT}/"*.zst "${OUTPUT}/SHA256SUMS" 2>/dev/null || true
