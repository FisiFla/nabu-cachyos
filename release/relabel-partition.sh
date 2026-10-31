#!/usr/bin/env bash
#
# Relabel the nabu root partition from "userdata" to "linux".
#
# The nabu kernel boots with `root=PARTLABEL=linux`.  A stock Xiaomi GPT calls
# that partition "userdata", so the partition table has to be patched before
# the flashed rootfs will mount.  This is GPT surgery: the partition name
# lives in the partition-entry array and both the array CRC32 and the GPT
# header CRC32 have to be recomputed.  Both GPT copies (primary at LBA 1 and
# the backup at the end of the disk) are patched, otherwise the firmware can
# fall back to the unpatched copy and undo the change.
#
# The device is never repartitioned and no data is moved: only the name of an
# existing partition changes.  The stock Android slot A is left untouched, so
# `fastboot set_active a` is still a valid way back into Android.
#
# Root access modes: works from a custom recovery whose adbd runs as root
# already (TWRP/OrangeFox booted with `fastboot boot`: `adb shell id -u` is
# 0, no su binary) and from a rooted ROM via `su -c`.  The mode is detected.
#
# Before anything is patched, the untouched GPT regions are copied next to
# this script as gpt-backups/<timestamp>/*-pristine.bin (+ metadata.txt with
# the exact geometry needed to write them back).  A run that cannot save
# that backup does not touch the device.
#
# Usage:
#   ./relabel-partition.sh              # userdata -> linux
#   ./relabel-partition.sh --dry-run    # show what would change
#   NABU_OLD_LABEL=linux NABU_NEW_LABEL=userdata ./relabel-partition.sh
#
# Environment:
#   NABU_BLOCK_DEV      block device of the UFS LUN 0 (default: auto-detect)
#   NABU_OLD_LABEL      current partition label (default: userdata)
#   NABU_NEW_LABEL      new partition label (default: linux)
#   NABU_GPT_BACKUP_DIR directory for the pristine GPT copies
#                       (default: <script dir>/gpt-backups/<timestamp>)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OLD_LABEL="${NABU_OLD_LABEL:-userdata}"
NEW_LABEL="${NABU_NEW_LABEL:-linux}"
BLOCK_DEV="${NABU_BLOCK_DEV:-}"
DRY_RUN=0
WORK_DIR=""
BACKUP_DIR=""
ROOT_MODE=""
TMP_PREFIX="/data/local/tmp/nabu-gpt"

# Number of sectors pulled for the primary GPT (LBA 0..5: protective MBR,
# primary header, entry array).  The backup GPT lives at the very end of the
# disk, so it is pulled separately.
PRIMARY_SECTORS=6
BACKUP_SECTORS=5

usage() {
    awk 'NR > 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}"
    fi
    adb shell "rm -f ${TMP_PREFIX}-primary.bin ${TMP_PREFIX}-backup.bin" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage 0 ;;
        *) die "unknown argument: ${arg}" ;;
    esac
done

# --- locate the tool -------------------------------------------------------
find_tool() {
    local candidate
    for candidate in \
        "${SCRIPT_DIR}/gpt-relabel.py" \
        "${SCRIPT_DIR}/../tools/gpt-relabel.py" \
        "${SCRIPT_DIR}/tools/gpt-relabel.py"; do
        if [ -f "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

RELABEL_TOOL="$(find_tool)" || die "gpt-relabel.py not found (expected next to this script or in tools/)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v adb    >/dev/null 2>&1 || die "adb is required (platform-tools)"

# --- device / root checks --------------------------------------------------
adb get-state >/dev/null 2>&1 || die "no device in adb state. Enable USB debugging and reconnect."

# --- root mode: adbd-root (recovery) or su (rooted ROM) --------------------
if [ "$(adb shell 'id -u' 2>/dev/null | tr -d '\r')" = "0" ]; then
    ROOT_MODE="adb"
    log "root mode: adbd already runs as uid 0 (custom recovery)"
else
    if [ "$(adb shell "su -c 'id -u'" 2>/dev/null | tr -d '\r')" = "0" ]; then
        ROOT_MODE="su"
        log "root mode: su (rooted ROM)"
    else
        die "cannot obtain root on the device. Boot a custom recovery (TWRP/OrangeFox) or root the ROM first."
    fi
fi

# adb joins its arguments with spaces before handing them to the device
# shell, so the whole device command stays ONE shell-string argument
# (device-side commands here contain no single quotes). exec-out merges the
# device-side stderr into the data stream, so every command redirects its
# stderr on the device (2>/dev/null) or dd's summary bytes corrupt the pulls.
dev_exec() {
    if [ "${ROOT_MODE}" = "adb" ]; then
        adb shell "${1} 2>/dev/null"
    else
        adb shell "su -c '${1} 2>/dev/null'"
    fi
}

dev_data() {   # like dev_exec, but for binary output
    if [ "${ROOT_MODE}" = "adb" ]; then
        adb exec-out "${1} 2>/dev/null"
    else
        adb exec-out "su -c '${1} 2>/dev/null'"
    fi
}

log "adb device: $(adb get-serialno 2>/dev/null | tr -d '\r')"

# --- find the UFS LUN 0 block device ---------------------------------------
has_gpt_signature() {
    dev_data "dd if=${1} bs=4096 skip=1 count=1" | head -c 8 | cmp -s - <(printf 'EFI PART')
}

detect_block_dev() {
    local dev
    while read -r dev; do
        [ -n "${dev}" ] || continue
        if has_gpt_signature "${dev}"; then
            printf '%s\n' "${dev}"
            return 0
        fi
    done < <(dev_exec "ls -1 /dev/block/sd*" | tr -d '\r')
    return 1
}

if [ -z "${BLOCK_DEV}" ]; then
    log "auto-detecting the UFS LUN 0 block device..."
    BLOCK_DEV="$(detect_block_dev)" \
        || die "no GPT disk found under /dev/block/sd*. Set NABU_BLOCK_DEV=/dev/block/sdX."
fi
log "block device: ${BLOCK_DEV}"

has_gpt_signature "${BLOCK_DEV}" \
    || die "${BLOCK_DEV} does not look like a GPT disk (no 'EFI PART' signature at LBA 1)"

# --- geometry --------------------------------------------------------------
read_blockdev() {
    dev_exec "blockdev $1 ${BLOCK_DEV}" | tr -d '\r' | tr -d '[:space:]'
}

SECTOR_SIZE="$(read_blockdev --getss)"
SIZE_512="$(read_blockdev --getsz)"
if [ -z "${SECTOR_SIZE}" ] || [ -z "${SIZE_512}" ]; then
    die "could not read the device geometry (blockdev)"
fi

if [ "${SECTOR_SIZE}" -lt 512 ] || [ $((SIZE_512 % (SECTOR_SIZE / 512))) -ne 0 ]; then
    die "unexpected geometry: sector size ${SECTOR_SIZE}, size ${SIZE_512} (512-byte blocks)"
fi
TOTAL_LBAS=$(( SIZE_512 / (SECTOR_SIZE / 512) ))
[ "${TOTAL_LBAS}" -gt $((PRIMARY_SECTORS + BACKUP_SECTORS)) ] \
    || die "device looks too small (${TOTAL_LBAS} sectors)"

log "sector size: ${SECTOR_SIZE} bytes   total LBA: ${TOTAL_LBAS}"

PRIMARY_SKIP=0
BACKUP_SKIP=$(( TOTAL_LBAS - BACKUP_SECTORS ))
BACKUP_HEADER_LBA=$(( TOTAL_LBAS - 1 ))

WORK_DIR="$(mktemp -d)"

# --- pull, patch, push -----------------------------------------------------
pull_region() {
    local skip="$1" count="$2" out="$3"
    dev_data "dd if=${BLOCK_DEV} bs=${SECTOR_SIZE} skip=${skip} count=${count}" \
        > "${out}"
    local expected=$(( count * SECTOR_SIZE ))
    local actual
    actual=$(wc -c < "${out}" | tr -d '[:space:]')
    [ "${actual}" -eq "${expected}" ] \
        || die "short read: got ${actual} bytes, expected ${expected} (sector size mismatch?)"
}

push_region() {
    local local_file="$1" skip="$2" count="$3" remote="$4"
    adb push "${local_file}" "${remote}" >/dev/null
    dev_exec "dd if=${remote} of=${BLOCK_DEV} bs=${SECTOR_SIZE} seek=${skip} count=${count} conv=notrunc" \
        >/dev/null
}

# Persist the untouched GPT regions BEFORE patching: WORK_DIR is a mktemp
# directory deleted on exit, so the only rollback copy is this one. Any
# failure here aborts (set -e) with the device still untouched.
save_pristine() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        return 0
    fi
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="${NABU_GPT_BACKUP_DIR:-${SCRIPT_DIR}/gpt-backups/${stamp}}"
    mkdir -p "${BACKUP_DIR}"
    cp "${WORK_DIR}/primary.bin" "${BACKUP_DIR}/primary-pristine.bin"
    cp "${WORK_DIR}/backup.bin" "${BACKUP_DIR}/backup-pristine.bin"
    {
        printf 'script=relabel-partition.sh\n'
        printf 'old_label=%s\n' "${OLD_LABEL}"
        printf 'new_label=%s\n' "${NEW_LABEL}"
        printf 'root_mode=%s\n' "${ROOT_MODE}"
        printf 'block_dev=%s\n' "${BLOCK_DEV}"
        printf 'sector_size=%s\n' "${SECTOR_SIZE}"
        printf 'total_lbas=%s\n' "${TOTAL_LBAS}"
        printf 'primary_file=primary-pristine.bin\n'
        printf 'primary_skip=%s\n' "${PRIMARY_SKIP}"
        printf 'primary_count=%s\n' "${PRIMARY_SECTORS}"
        printf 'backup_file=backup-pristine.bin\n'
        printf 'backup_skip=%s\n' "${BACKUP_SKIP}"
        printf 'backup_count=%s\n' "${BACKUP_SECTORS}"
        printf '# Restore: adb push both .bin files to the device, then as root:\n'
        printf '#   dd if=primary-pristine.bin of=%s bs=%s seek=%s count=%s conv=notrunc\n' \
            "${BLOCK_DEV}" "${SECTOR_SIZE}" "${PRIMARY_SKIP}" "${PRIMARY_SECTORS}"
        printf '#   dd if=backup-pristine.bin of=%s bs=%s seek=%s count=%s conv=notrunc\n' \
            "${BLOCK_DEV}" "${SECTOR_SIZE}" "${BACKUP_SKIP}" "${BACKUP_SECTORS}"
    } > "${BACKUP_DIR}/metadata.txt"
    log "pristine GPT regions saved to ${BACKUP_DIR}"
}

relabel_region() {
    local dump="$1" base_lba="$2" header_lba="$3" what="$4"
    local extra=()
    if [ "${DRY_RUN}" -eq 1 ]; then
        extra+=(--dry-run)
    fi
    log "patching the ${what} GPT (header at LBA ${header_lba})..."
    python3 "${RELABEL_TOOL}" \
        --sector-size "${SECTOR_SIZE}" \
        --dump-base-lba "${base_lba}" \
        --header-lba "${header_lba}" \
        --primary-only \
        ${extra[@]+"${extra[@]}"} \
        "${dump}" "${OLD_LABEL}" "${NEW_LABEL}"
}

log "pulling the primary GPT (LBA ${PRIMARY_SKIP}..$(( PRIMARY_SKIP + PRIMARY_SECTORS - 1 )))..."
pull_region "${PRIMARY_SKIP}" "${PRIMARY_SECTORS}" "${WORK_DIR}/primary.bin"
log "pulling the backup GPT (LBA ${BACKUP_SKIP}..$(( BACKUP_SKIP + BACKUP_SECTORS - 1 )))..."
pull_region "${BACKUP_SKIP}" "${BACKUP_SECTORS}" "${WORK_DIR}/backup.bin"

save_pristine

relabel_region "${WORK_DIR}/primary.bin" "${PRIMARY_SKIP}" 1 "primary"
relabel_region "${WORK_DIR}/backup.bin" "${BACKUP_SKIP}" "${BACKUP_HEADER_LBA}" "backup"

if [ "${DRY_RUN}" -eq 1 ]; then
    log "dry run — nothing was written to the device."
    exit 0
fi

log "writing the patched GPTs back..."
push_region "${WORK_DIR}/primary.bin" "${PRIMARY_SKIP}" "${PRIMARY_SECTORS}" "${TMP_PREFIX}-primary.bin"
push_region "${WORK_DIR}/backup.bin" "${BACKUP_SKIP}" "${BACKUP_SECTORS}" "${TMP_PREFIX}-backup.bin"

# --- verify by reading the device back -------------------------------------
log "verifying..."
pull_region "${PRIMARY_SKIP}" "${PRIMARY_SECTORS}" "${WORK_DIR}/primary.verify.bin"
pull_region "${BACKUP_SKIP}" "${BACKUP_SECTORS}" "${WORK_DIR}/backup.verify.bin"

for region in primary backup; do
    if [ "${region}" = "primary" ]; then
        base_lba="${PRIMARY_SKIP}"; header_lba=1
    else
        base_lba="${BACKUP_SKIP}"; header_lba="${BACKUP_HEADER_LBA}"
    fi
    python3 "${RELABEL_TOOL}" \
        --sector-size "${SECTOR_SIZE}" \
        --dump-base-lba "${base_lba}" \
        --header-lba "${header_lba}" \
        --verify "${WORK_DIR}/${region}.verify.bin" >/dev/null \
        || die "the ${region} GPT failed its CRC check after the write"
    python3 "${RELABEL_TOOL}" \
        --sector-size "${SECTOR_SIZE}" \
        --dump-base-lba "${base_lba}" \
        --header-lba "${header_lba}" \
        --list "${WORK_DIR}/${region}.verify.bin" \
        | grep -qE "^[[:space:]]*[0-9]+[[:space:]]+${NEW_LABEL}[[:space:]]" \
        || die "the ${region} GPT does not contain a partition named '${NEW_LABEL}'"
    log "  ${region} GPT: CRCs OK, partition '${NEW_LABEL}' present"
done

log "done. Reboot the device so the firmware re-reads the partition table."
log "Pristine GPT backup: ${BACKUP_DIR} (restore steps in its metadata.txt)"
log "You can now flash the rootfs: fastboot flash linux linux.img"
