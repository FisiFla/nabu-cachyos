#!/usr/bin/env bash
#
# Carve a new partition out of the tail of an existing one (dual boot).
#
# The stock nabu GPT has no unallocated space: `userdata` runs to the last
# usable LBA.  To keep the Android install AND have a rootfs partition for
# this project, the `linux` partition has to be carved out of userdata's end.
# This shrinks the userdata entry, appends a new `linux` entry into the first
# free slot and rewrites BOTH GPT copies (each with fresh array CRC32 and
# header CRC32).
#
# What is preserved: the Android ROM, its boot image (slot A) and Magisk are
# untouched.  What is lost: the *contents* of userdata — it is block-encrypted
# and spans the whole partition, so after the carve the smaller partition has
# to be reformatted, and that wipes the (unreadable-from-outside) app data.
# Boot Android once and let its vold format the partition; or do it here with
# make_f2fs.
#
# Root access modes: works from a custom recovery whose adbd runs as root
# already (TWRP/OrangeFox: `adb shell id -u` is 0, no su binary) and from a
# rooted ROM via `su -c`.  The mode is detected.
#
# Usage:
#   ./carve-linux-partition.sh                 # 30 GiB userdata -> linux
#   ./carve-linux-partition.sh --gib 50
#   ./carve-linux-partition.sh --dry-run
#
# Environment:
#   NABU_BLOCK_DEV     block device of the UFS LUN 0 (default: auto-detect)
#   NABU_SOURCE_LABEL  partition whose tail is carved (default: userdata)
#   NABU_NEW_LABEL     new partition label (default: linux)
#   NABU_CARVE_GIB     size of the new partition in GiB (default: 30)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_LABEL="${NABU_SOURCE_LABEL:-userdata}"
NEW_LABEL="${NABU_NEW_LABEL:-linux}"
CARVE_GIB="${NABU_CARVE_GIB:-30}"
BLOCK_DEV="${NABU_BLOCK_DEV:-}"
DRY_RUN=0
WORK_DIR=""
TMP_PREFIX="/data/local/tmp/nabu-gpt"
ROOT_MODE=""

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

NEW_FIRST_LBA=""
while [ $# -gt 0 ]; do
    case "${1}" in
        --dry-run) DRY_RUN=1 ;;
        --gib) [ $# -ge 2 ] || die "--gib needs a value"; CARVE_GIB="${2}"; shift ;;
        --new-first-lba)
            [ $# -ge 2 ] || die "--new-first-lba needs a value"
            NEW_FIRST_LBA="${2}"; shift ;;
        -h|--help) usage 0 ;;
        *) die "unknown argument: ${1}" ;;
    esac
    shift
done
if [ -n "${NEW_FIRST_LBA}" ] && [ "${CARVE_GIB}" != "${NABU_CARVE_GIB:-30}" ] \
        && [ "${CARVE_GIB}" != "30" ]; then
    warn "--gib is ignored when --new-first-lba is given"
fi

# --- locate the tool -------------------------------------------------------
find_tool() {
    local candidate
    for candidate in \
        "${SCRIPT_DIR}/gpt-carve.py" \
        "${SCRIPT_DIR}/../tools/gpt-carve.py" \
        "${SCRIPT_DIR}/tools/gpt-carve.py"; do
        if [ -f "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

CARVE_TOOL="$(find_tool)" || die "gpt-carve.py not found (expected next to this script or in tools/)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v adb    >/dev/null 2>&1 || die "adb is required (platform-tools)"

# --- root mode: adbd-root (recovery) or su (rooted ROM) --------------------
if [ "$(adb shell 'id -u' 2>/dev/null | tr -d '\r')" = "0" ]; then
    ROOT_MODE="adb"
    log "root mode: adbd already runs as uid 0 (custom recovery)"
else
    if [ "$(adb shell "su -c 'id -u'" 2>/dev/null | tr -d '\r')" = "0" ]; then
        ROOT_MODE="su"
        log "root mode: su (rooted ROM)"
    else
        echo "ERROR: cannot obtain root on the device." >&2
        echo "Boot a custom recovery (TWRP/OrangeFox) or root the ROM first." >&2
        exit 1
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
    done < <(dev_exec "ls -1 /dev/block/sd*")
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

region_list() {
    local dump="$1" base_lba="$2" header_lba="$3"
    python3 "${CARVE_TOOL}" \
        --sector-size "${SECTOR_SIZE}" \
        --dump-base-lba "${base_lba}" \
        --header-lba "${header_lba}" \
        --list "${dump}"
}

log "pulling the primary GPT (LBA ${PRIMARY_SKIP}..$(( PRIMARY_SKIP + PRIMARY_SECTORS - 1 )))..."
pull_region "${PRIMARY_SKIP}" "${PRIMARY_SECTORS}" "${WORK_DIR}/primary.bin"
log "pulling the backup GPT (LBA ${BACKUP_SKIP}..$(( BACKUP_SKIP + BACKUP_SECTORS - 1 )))..."
pull_region "${BACKUP_SKIP}" "${BACKUP_SECTORS}" "${WORK_DIR}/backup.bin"

# Record the pre-carve geometry so the post-write verification can prove that
# exactly the intended range moved (source keeps its head, new partition gets
# the tail, nothing else changes).
ORIGINAL_FIRST=$(region_list "${WORK_DIR}/primary.bin" "${PRIMARY_SKIP}" 1 \
    | awk -v src="${SOURCE_LABEL}" '$2 == src { print $3; exit }')
ORIGINAL_LAST=$(region_list "${WORK_DIR}/primary.bin" "${PRIMARY_SKIP}" 1 \
    | awk -v src="${SOURCE_LABEL}" '$2 == src { print $4; exit }')
if [ -z "${ORIGINAL_FIRST}" ] || [ -z "${ORIGINAL_LAST}" ]; then
    die "partition '${SOURCE_LABEL}' not found in the device's GPT"
fi
log "${SOURCE_LABEL} spans LBA ${ORIGINAL_FIRST}..${ORIGINAL_LAST}"

# One GUID for both GPT copies: the partial-dump flow runs the tool twice,
# and the two entry arrays have to byte-match.
UNIQUE_GUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"

carve_region() {
    local dump="$1" base_lba="$2" header_lba="$3" what="$4"
    local extra=()
    if [ "${DRY_RUN}" -eq 1 ]; then
        extra+=(--dry-run)
    fi
    if [ -n "${NEW_FIRST_LBA}" ]; then
        extra+=(--new-first-lba "${NEW_FIRST_LBA}")
    else
        extra+=(--carve-gib "${CARVE_GIB}")
    fi
    log "carving the ${what} GPT (header at LBA ${header_lba})..."
    python3 "${CARVE_TOOL}" \
        --sector-size "${SECTOR_SIZE}" \
        --dump-base-lba "${base_lba}" \
        --header-lba "${header_lba}" \
        --primary-only \
        --unique-guid "${UNIQUE_GUID}" \
        ${extra[@]+"${extra[@]}"} \
        "${dump}" --carve "${NEW_LABEL}" --carve-source "${SOURCE_LABEL}"
}

carve_region "${WORK_DIR}/primary.bin" "${PRIMARY_SKIP}" 1 "primary"
carve_region "${WORK_DIR}/backup.bin" "${BACKUP_SKIP}" "${BACKUP_HEADER_LBA}" "backup"

if [ "${DRY_RUN}" -eq 1 ]; then
    log "dry run — nothing was written to the device."
    exit 0
fi

log "writing the carved GPTs back..."
push_region "${WORK_DIR}/primary.bin" "${PRIMARY_SKIP}" "${PRIMARY_SECTORS}" "${TMP_PREFIX}-primary.bin"
push_region "${WORK_DIR}/backup.bin" "${BACKUP_SKIP}" "${BACKUP_SECTORS}" "${TMP_PREFIX}-backup.bin"

# --- verify by reading the device back -------------------------------------
log "verifying..."
pull_region "${PRIMARY_SKIP}" "${PRIMARY_SECTORS}" "${WORK_DIR}/primary.verify.bin"
pull_region "${BACKUP_SKIP}" "${BACKUP_SECTORS}" "${WORK_DIR}/backup.verify.bin"

for region in primary backup; do
    if [ "${region}" = "primary" ]; then
        verify_base_lba="${PRIMARY_SKIP}"; verify_header_lba=1
    else
        verify_base_lba="${BACKUP_SKIP}"; verify_header_lba="${BACKUP_HEADER_LBA}"
    fi
    python3 "${CARVE_TOOL}" \
        --sector-size "${SECTOR_SIZE}" \
        --dump-base-lba "${verify_base_lba}" \
        --header-lba "${verify_header_lba}" \
        --verify "${WORK_DIR}/${region}.verify.bin" >/dev/null \
        || die "the ${region} GPT failed its CRC check after the write"

    region_list "${WORK_DIR}/${region}.verify.bin" "${verify_base_lba}" "${verify_header_lba}" \
        > "${WORK_DIR}/${region}.listing.txt"

    grep -qE "^[[:space:]]*[0-9]+[[:space:]]+${NEW_LABEL}[[:space:]]" \
        "${WORK_DIR}/${region}.listing.txt" \
        || die "the ${region} GPT does not contain a partition named '${NEW_LABEL}'"
    grep -qE "^[[:space:]]*[0-9]+[[:space:]]+${SOURCE_LABEL}[[:space:]]" \
        "${WORK_DIR}/${region}.listing.txt" \
        || die "the ${region} GPT no longer contains '${SOURCE_LABEL}'"

    src_first=$(awk -v src="${SOURCE_LABEL}" '$2 == src { print $3; exit }' "${WORK_DIR}/${region}.listing.txt")
    src_last=$(awk -v src="${SOURCE_LABEL}" '$2 == src { print $4; exit }' "${WORK_DIR}/${region}.listing.txt")
    new_first=$(awk -v lbl="${NEW_LABEL}" '$2 == lbl { print $3; exit }' "${WORK_DIR}/${region}.listing.txt")
    new_last=$(awk -v lbl="${NEW_LABEL}" '$2 == lbl { print $4; exit }' "${WORK_DIR}/${region}.listing.txt")

    [ "${src_first}" = "${ORIGINAL_FIRST}" ] \
        || die "${SOURCE_LABEL} first LBA changed (was ${ORIGINAL_FIRST}, now ${src_first})"
    [ "${src_last}" = "$((new_first - 1))" ] \
        || die "${SOURCE_LABEL}/new partition boundary mismatch (${src_last} vs $((new_first - 1)))"
    [ "${new_last}" = "${ORIGINAL_LAST}" ] \
        || die "${NEW_LABEL} last LBA changed (was ${ORIGINAL_LAST}, now ${new_last})"
    log "  ${region} GPT: CRCs OK; ${SOURCE_LABEL}=${src_first}..${src_last}, ${NEW_LABEL}=${new_first}..${new_last}"
done

log "done. New layout: ${SOURCE_LABEL} = LBA ${ORIGINAL_FIRST}..${src_last}, ${NEW_LABEL} = LBA ${new_first}..${new_last}"
log "${SOURCE_LABEL} still holds the old (stale, encrypted) filesystem inside a smaller partition."
log "Boot Android and let its vold format it, or run 'make_f2fs -n ${SOURCE_LABEL} ${BLOCK_DEV}p...'"
