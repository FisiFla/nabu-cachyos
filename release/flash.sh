#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY_HELPER="${SCRIPT_DIR}/inject-ssh-key.sh"
RELABEL_HELPER="${SCRIPT_DIR}/relabel-partition.sh"

echo "=== CachyOS Nabu Flasher ==="
echo ""
echo "This will install CachyOS ARM on your Xiaomi Pad 5."
echo "Android data will be erased. Slot A (Android) is preserved as fallback."
echo ""

# Check prerequisites
command -v fastboot >/dev/null || { echo "ERROR: fastboot not found. Install: brew install android-platform-tools"; exit 1; }

for f in boot.img linux.img.zst vbmeta_disabled.img; do
    [ -f "${SCRIPT_DIR}/${f}" ] || { echo "ERROR: ${f} not found in ${SCRIPT_DIR}/"; exit 1; }
done

# Verify the bundle against the shipped SHA256SUMS before touching the
# device: a truncated download flashes a corrupt rootfs and the tablet
# round-trip makes recovery awkward. SHA256SUMS covers the split archive
# parts (linux.img.zst is derived from them); a bundle without the file,
# or a host without a sha256 tool, only warns.
verify_bundle() {
    if [ "${SKIP_SHA256_CHECK:-0}" = "1" ]; then
        echo "SKIP_SHA256_CHECK=1 set — skipping SHA256SUMS verification."
        return 0
    fi
    if [ ! -f "${SCRIPT_DIR}/SHA256SUMS" ]; then
        echo "WARNING: SHA256SUMS missing — skipping integrity verification. Re-download the release if anything misbehaves."
        return 0
    fi
    local rc=0
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "${SCRIPT_DIR}" && sha256sum --quiet -c SHA256SUMS) || rc=1
    elif command -v shasum >/dev/null 2>&1; then
        (cd "${SCRIPT_DIR}" && shasum -a 256 --quiet -c SHA256SUMS) || rc=1
    else
        echo "WARNING: neither sha256sum nor shasum found — skipping integrity verification."
        return 0
    fi
    if [ "${rc}" != "0" ]; then
        echo "ERROR: SHA256SUMS verification failed — the bundle is incomplete or corrupted."
        echo "Re-download the release. To flash anyway (NOT recommended): SKIP_SHA256_CHECK=1"
        exit 1
    fi
    echo "  SHA256SUMS verified."
}
verify_bundle

# Check device
echo "Checking device connection..."
fastboot devices | grep -q . || { echo "ERROR: No device found. Boot tablet into fastboot (Vol Down + Power)."; exit 1; }
echo "  Device found."
echo ""

# nabu's ABL firmware blocks forever on `fastboot getvar all`, and can wedge
# the whole fastboot interface after repeated probes. Every getvar therefore
# goes through a watchdog: run fastboot in the background, poll, kill -9 on
# timeout. There is no `timeout` on macOS, so this is plain bash.
# Prints whatever the bootloader said; returns fastboot's own status, or 124
# when nothing came back within `secs`.
fastboot_getvar_timed() {
    local var="$1" secs="${2:-10}" out pid deadline rc
    out=$(mktemp "${TMPDIR:-/tmp}/nabu-getvar.XXXXXX") || return 1
    fastboot getvar "${var}" >"${out}" 2>&1 &
    pid=$!
    deadline=$(( $(date +%s) + secs ))
    while kill -0 "${pid}" 2>/dev/null; do
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            kill -9 "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
            cat "${out}"
            rm -f "${out}"
            return 124
        fi
        sleep 1
    done
    wait "${pid}"
    rc=$?
    cat "${out}"
    rm -f "${out}"
    return "${rc}"
}

# The kernel boots with `root=PARTLABEL=linux`, so the GPT has to name the
# root partition "linux".  A stock Xiaomi table calls it "userdata" — that
# rename is a GPT surgery and has to happen before fastboot is entered.
# Detect it here instead of flashing a 9 GB image into a partition the
# kernel cannot find.
# Returns 0 = present, 1 = absent, 2 = the bootloader did not answer.
# Targeted probes only: `getvar all` hangs on this firmware.
fastboot_has_partition() {
    local name="$1" var out rc
    for var in "partition-size:${name}" "partition-type:${name}"; do
        out=$(fastboot_getvar_timed "${var}" 10)
        rc=$?
        if [ "${rc}" -eq 124 ]; then
            return 2
        fi
        case "${out}" in
            *FAILED*|*"not found"*) continue ;;
        esac
        # "(bootloader) " prefix or a space after the colon are both common.
        if printf '%s\n' "${out}" | grep -qE "partition-(size|type): *${name} *:"; then
            return 0
        fi
    done
    return 1
}

PART_CHECK=0
fastboot_has_partition linux || PART_CHECK=$?
if [ "${PART_CHECK}" -eq 2 ]; then
    echo "WARNING: the bootloader did not answer 'fastboot getvar'."
    echo "         Skipping the partition-table check — fastboot itself fails"
    echo "         loudly if the 'linux' partition is missing. If the flash"
    echo "         below names an unknown partition, reboot to fastboot and retry."
    echo ""
elif [ "${PART_CHECK}" -ne 0 ]; then
    echo "ERROR: this device has no partition named 'linux'."
    echo ""
    echo "The nabu kernel boots with root=PARTLABEL=linux, but the stock"
    echo "Xiaomi partition table names that partition 'userdata'. Rename it"
    echo "first (from Android, with USB debugging and root enabled):"
    echo ""
    if [ -x "${RELABEL_HELPER}" ]; then
        echo "    ${RELABEL_HELPER}"
    else
        echo "    ./relabel-partition.sh      # from a release bundle"
        echo "    ./release/relabel-partition.sh   # from a git checkout"
    fi
    echo ""
    echo "Then reboot into fastboot (Vol Down + Power) and run this script again."
    exit 1
else
    echo "  Found 'linux' partition."
fi
echo ""

# fastboot prints getvar results as "<name>: <value>" (sometimes behind a
# "(bootloader) " prefix, and it may echo the name canonically with quoted
# spaces). Match the name with optional spaces after each colon, and take
# the value from the last colon-separated field of the matching line. An
# unset/FAILED/timed-out getvar becomes an empty string, not a set -e abort.
fastboot_getvar() {
    local name_pat="${1//:/[: ]*}" out
    out=$(fastboot_getvar_timed "$1" 10)
    case "${out}" in
        '') return 0 ;;
    esac
    printf '%s\n' "${out}" \
        | grep -E "$name_pat" | tail -n 1 | awk -F': *' '{print $NF}'
    return 0
}

# The image has to fit the partition flashed by `fastboot flash linux`:
# fastboot cannot grow partitions, so catch the mismatch BEFORE the
# 4-minute flash instead of after it. image-size.txt records the required
# size and is shipped in every release bundle. Repair it (IMG_SIZE_MB=<n>)
# if you rebuilt the rootfs yourself.
if [ -f "${SCRIPT_DIR}/image-size.txt" ]; then
    REQUIRED_MB=$(sed -n 's/^IMG_SIZE_MB=//p' "${SCRIPT_DIR}/image-size.txt" | tail -n 1)
    case "${REQUIRED_MB}" in
        ''|*[!0-9]*)
            echo "WARNING: image-size.txt does not parse (IMG_SIZE_MB='${REQUIRED_MB}') — skipping the size check."
            ;;
        *)
            PART_SIZE_HEX=$(fastboot_getvar partition-size:linux)
            case "${PART_SIZE_HEX}" in
                0[xX][0-9a-fA-F]*)
                    PART_SIZE_MB=$(( $(printf '%d' "${PART_SIZE_HEX}") / 1024 / 1024 ))
                    if [ "${PART_SIZE_MB}" -lt "${REQUIRED_MB}" ]; then
                        echo "ERROR: the 'linux' partition is ${PART_SIZE_MB}MB but the image needs ${REQUIRED_MB}MB."
                        echo "The partition layout cannot be grown from fastboot — see the README"
                        echo "(Partition relabel) to replace the userdata-sized partition properly."
                        exit 1
                    fi
                    echo "  Size check OK: partition ${PART_SIZE_MB}MB >= image ${REQUIRED_MB}MB."
                    ;;
                *)
                    echo "WARNING: could not read the partition size (got '${PART_SIZE_HEX}') — skipping the size check."
                    ;;
            esac
            ;;
    esac
else
    echo "WARNING: image-size.txt missing — skipping the partition-size check."
fi
echo ""

if [ "${FORCE_FLASH:-0}" = "1" ]; then
    echo "FORCE_FLASH=1 set, skipping confirmation."
else
    read -p "Ready to flash? This will erase Android userdata. [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
fi

echo ""
echo "[1/5] Erasing dtbo_b + flashing vbmeta..."
fastboot erase dtbo_b
fastboot flash vbmeta_b "${SCRIPT_DIR}/vbmeta_disabled.img"

echo "[2/5] Flashing CachyOS kernel..."
fastboot flash boot_b "${SCRIPT_DIR}/boot.img"

echo "[3/5] Preparing rootfs..."
# A stale linux.img from another build must not be reused silently:
# re-decompress when the .zst is newer, and fail the file from image-size.txt
# when it does not match what this bundle declares (auto-recovers by
# re-decompressing, which is exactly the safe answer here).
NEED_DECOMPRESS=0
if [ ! -f "${SCRIPT_DIR}/linux.img" ]; then
    NEED_DECOMPRESS=1
elif [ "${SCRIPT_DIR}/linux.img.zst" -nt "${SCRIPT_DIR}/linux.img" ]; then
    echo "  linux.img is stale (older than linux.img.zst) — re-decompressing."
    NEED_DECOMPRESS=1
fi
if [ "${NEED_DECOMPRESS}" = "1" ]; then
    command -v zstd >/dev/null || { echo "ERROR: zstd not found. Install: brew install zstd"; exit 1; }
    zstd -d -f "${SCRIPT_DIR}/linux.img.zst" -o "${SCRIPT_DIR}/linux.img"
fi

if [ -f "${SCRIPT_DIR}/image-size.txt" ]; then
    REQUIRED_MB=$(sed -n 's/^IMG_SIZE_MB=//p' "${SCRIPT_DIR}/image-size.txt" | tail -n 1)
    REQUIRED_BYTES=$(sed -n 's/^IMG_SIZE_BYTES=//p' "${SCRIPT_DIR}/image-size.txt" | tail -n 1)
    case "${REQUIRED_MB}" in
        ''|*[!0-9]*) : ;;
        *)
            if stat -f %z "${SCRIPT_DIR}/linux.img" >/dev/null 2>&1; then
                IMG_BYTES=$(stat -f %z "${SCRIPT_DIR}/linux.img")
            elif stat -c %s "${SCRIPT_DIR}/linux.img" >/dev/null 2>&1; then
                IMG_BYTES=$(stat -c %s "${SCRIPT_DIR}/linux.img")
            fi
            # IMG_SIZE_BYTES is exact, so any mismatch means a stale image.
            # Older bundles only ship IMG_SIZE_MB, which is a ceiling (content
            # + headroom) — only a *smaller* file can be stale there, and an
            # equality test would re-decompress on every run and throw away
            # injected SSH keys.
            STALE=0
            case "${REQUIRED_BYTES}" in
                ''|*[!0-9]*)
                    if [ "${IMG_BYTES:-0}" -lt "$(( REQUIRED_MB * 1024 * 1024 ))" ]; then
                        STALE=1
                    fi
                    ;;
                *)
                    if [ "${IMG_BYTES:-0}" -ne "${REQUIRED_BYTES}" ]; then
                        STALE=1
                    fi
                    ;;
            esac
            if [ "${STALE}" = "1" ]; then
                echo "  linux.img is $(( IMG_BYTES / 1024 / 1024 ))MB but this bundle declares ${REQUIRED_MB}MB${REQUIRED_BYTES:+ (${REQUIRED_BYTES} bytes)} — stale image from another build. Re-decompressing."
                rm -f "${SCRIPT_DIR}/linux.img"
                command -v zstd >/dev/null || { echo "ERROR: zstd not found. Install: brew install zstd"; exit 1; }
                zstd -d -f "${SCRIPT_DIR}/linux.img.zst" -o "${SCRIPT_DIR}/linux.img"
            fi
            ;;
    esac
fi

if [ "${SKIP_SSH_KEY_INJECTION:-0}" != "1" ] && [ -x "${SSH_KEY_HELPER}" ]; then
    "${SSH_KEY_HELPER}" "${SCRIPT_DIR}/linux.img" "${SSH_PUBKEY_FILE:-}" || {
        echo "ERROR: SSH key injection failed."
        echo "Set SKIP_SSH_KEY_INJECTION=1 to flash without this step."
        exit 1
    }
fi

echo "[4/5] Flashing rootfs (this takes ~4 minutes)..."
# macOS fastboot can't auto-sparse files > 256 MB, and the linux rootfs is ~9 GB.
# `fastboot flash linux <raw>` errors with "Failed reading from linux" on Darwin.
# When img2simg is available (`brew install simg2img`) we pre-sparse before
# flashing. On Linux, fastboot handles sparsing internally so we ship the raw
# image directly — keeps the Linux path one-step.
FLASH_IMG="${SCRIPT_DIR}/linux.img"
if [ "$(uname -s)" = "Darwin" ]; then
    if command -v img2simg >/dev/null 2>&1; then
        echo "  Pre-sparsing for macOS fastboot..."
        img2simg "${SCRIPT_DIR}/linux.img" "${SCRIPT_DIR}/linux.sparse.img"
        FLASH_IMG="${SCRIPT_DIR}/linux.sparse.img"
    else
        echo "  WARNING: img2simg not found. fastboot may fail on rootfs > 256 MB."
        echo "  Install with: brew install simg2img"
    fi
fi
fastboot flash linux "${FLASH_IMG}"

echo "[5/5] Setting boot slot and rebooting..."
fastboot set_active b
fastboot reboot

echo ""
echo "=== Flash complete! ==="
echo ""
echo "CachyOS will boot in ~60 seconds."
echo ""
echo "Default login: nabu (no password — SSH is key-only, see README)"
if [ -f "${SCRIPT_DIR}/inject-ssh-key.sh" ]; then
    echo "Root is password-unusable; set one after flashing with:"
    echo "    ssh nabu@nabu-cachyos.local   # inject your key first (see README)"
    echo "    sudo passwd root"
else
    echo "No inject-ssh-key.sh in this bundle — the root key may not be installed."
    echo "Root SSH: set a password first (sudo passwd root) or stay out of root."
fi
echo ""
echo "If it doesn't boot: hold Vol Down + Power → fastboot set_active a"
