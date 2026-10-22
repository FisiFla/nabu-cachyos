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
# Usage:
#   ./relabel-partition.sh              # userdata -> linux
#   ./relabel-partition.sh --dry-run    # show what would change
#   NABU_OLD_LABEL=linux NABU_NEW_LABEL=userdata ./relabel-partition.sh
#
# Environment:
#   NABU_BLOCK_DEV    block device of the UFS LUN 0 (default: auto-detect)
#   NABU_OLD_LABEL    current partition label (default: userdata)
#   NABU_NEW_LABEL    new partition label (default: linux)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OLD_LABEL="${NABU_OLD_LABEL:-userdata}"
NEW_LABEL="${NABU_NEW_LABEL:-linux}"
BLOCK_DEV="${NABU_BLOCK_DEV:-}"
DRY_RUN=0
WORK_DIR=""
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
adb shell 'su -c "id -u"' 2>/dev/null | tr -d '\r' | grep -qE '^[0-9]+$' \
    || die "cannot obtain root on the device (is Magisk/root available?)"

log "adb device: $(adb shell get-serialno 2>/dev/null | tr -d '\r')"

# --- find the UFS LUN 0 block device ---------------------------------------
has_gpt_signature() {
    local dev="$1"
    # The whole command has to be a single argument: adb joins its arguments
    # with spaces before handing them to the device shell, so an unquoted
    # `su -c dd if=...` would run dd with the arguments as positional
    # parameters instead of as options.
    adb exec-out "su -c 'dd if=${dev} bs=4096 skip=1 count=1 2>/dev/null'" \
        2>/dev/null | head -c 8 | cmp -s - <(printf 'EFI PART')
}

detect_block_dev() {
    local dev
    while read -r dev; do
        [ -n "${dev}" ] || continue
        if has_gpt_signature "${dev}"; then
            printf '%s\n' "${dev}"
            return 0
        fi
    done < <(adb shell 'ls -1 /dev/block/sd* 2>/dev/null' | tr -d '\r')
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
    adb shell "su -c 'blockdev $1 ${BLOCK_DEV}'" 2>/dev/null | tr -d '\r' | tr -d '[:space:]'
}

SECTOR_SIZE="$(read_blockdev --getss)"
SIZE_512="$(read_blockdev --getsz)"
[ -n "${SECTOR_SIZE}" ] && [ -n "${SIZE_512}" ] || die "could not read the device geometry (blockdev)"

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
    adb exec-out "su -c 'dd if=${BLOCK_DEV} bs=${SECTOR_SIZE} skip=${skip} count=${count} 2>/dev/null'" \
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
    adb shell "su -c 'dd if=${remote} of=${BLOCK_DEV} bs=${SECTOR_SIZE} seek=${skip} count=${count} conv=notrunc 2>/dev/null'" \
        >/dev/null
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
log "You can now flash the rootfs: fastboot flash linux linux.img"
