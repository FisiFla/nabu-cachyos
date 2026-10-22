#!/usr/bin/env bash
#
# Verify an Arch Linux ARM rootfs tarball against the publisher's detached
# GPG signature.
#
# Why this matters: the ALARM tarball is the *base of the whole OS*. It is
# ADDed straight into the container image (see Dockerfile) and every package,
# initramfs and userspace file ends up on the tablet. A tampered download
# would be a tampered OS, silently.
#
# The signature is the trust anchor, not the transport:
#   * the detached .sig is fetched next to the tarball,
#   * the publisher keyring is extracted from the tarball itself (so we never
#     depend on a keyring served by the same mirror we are validating),
#   * the *primary key fingerprint* is pinned in this repository, so a swapped
#     or mirrored keyring cannot change the outcome.
#
# Usage: tools/verify-alarm-tarball.sh <tarball> [signature]
#
# Environment:
#   ALARM_KEYRING_FPR      expected primary key fingerprint
#                           (default: Arch Linux ARM Build System)
#   ALARM_ALLOW_UNVERIFIED=1
#                           skip the signature check and only warn. Intended
#                           for air-gapped builds that already trust the
#                           local copy of the tarball. Never set by CI.
#
set -euo pipefail

# Arch Linux ARM Build System <builder@archlinuxarm.org>
# Primary key 68B3537F39A313B3E574D06777193F152BDBE6A6
ALARM_KEYRING_FPR="${ALARM_KEYRING_FPR:-68B3537F39A313B3E574D06777193F152BDBE6A6}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${ALARM_KEYRING_CACHE_DIR:-${SCRIPT_DIR}/../.cache}"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: verify-alarm-tarball.sh <tarball> [signature]

Verifies <tarball> against the detached GPG signature <signature>
(default: <tarball>.sig). The publisher keyring is extracted from the
tarball and the signing key fingerprint is checked against the pin.

Environment:
  ALARM_KEYRING_FPR       expected primary key fingerprint
  ALARM_KEYRING_CACHE_DIR where the extracted keyring is cached
  ALARM_ALLOW_UNVERIFIED  set to 1 to downgrade to a warning
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

if [ "$#" -lt 1 ]; then
    usage >&2
    exit 2
fi

TARBALL="$1"
SIGNATURE="${2:-${TARBALL}.sig}"

[ -f "${TARBALL}" ] || die "tarball not found: ${TARBALL}"

if [ ! -f "${SIGNATURE}" ]; then
    if [ "${ALARM_ALLOW_UNVERIFIED:-0}" = "1" ]; then
        warn "signature not found (${SIGNATURE}) — ALARM_ALLOW_UNVERIFIED=1 is set, skipping verification"
        exit 0
    fi
    die "signature not found: ${SIGNATURE}
  The mirror must serve '${SIGNATURE##*/}' next to the tarball.
  Set ALARM_ALLOW_UNVERIFIED=1 to skip verification (not recommended)."
fi

if [ "${ALARM_ALLOW_UNVERIFIED:-0}" = "1" ]; then
    warn "ALARM_ALLOW_UNVERIFIED=1 — skipping signature verification of ${TARBALL}"
    exit 0
fi

command -v gpg >/dev/null 2>&1 || die "gpg is required to verify the rootfs tarball.
  macOS: brew install gnupg
  Debian/Ubuntu: apt install gnupg
  Fedora: dnf install gnupg2"

# ── Fingerprint of the tarball (cache key + build log) ────────────────

if command -v sha256sum >/dev/null 2>&1; then
    TARBALL_SHA256="$(sha256sum "${TARBALL}" | awk '{print $1}')"
else
    TARBALL_SHA256="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
fi

# ── Extract the publisher keyring from the tarball ───────────────────
#
# The keyring lives in the tarball we are validating; pinning the primary
# fingerprint below is what actually establishes trust.

KEYRING_MEMBER_PATTERN='usr/share/pacman/keyrings/.*\.gpg$'
KEYRING_CACHE="${CACHE_DIR}/alarm-keyring-${TARBALL_SHA256}.gpg"

extract_keyring() {
    local member
    member="$(tar -tzf "${TARBALL}" | grep -E "${KEYRING_MEMBER_PATTERN}" | head -n 1)"
    [ -n "${member}" ] || return 1
    tar -xzOf "${TARBALL}" "${member}"
}

KEYRING="${KEYRING_CACHE}"
if [ -f "${KEYRING}" ]; then
    log "Using cached publisher keyring (${KEYRING})"
else
    mkdir -p "${CACHE_DIR}"
    log "Extracting publisher keyring from ${TARBALL##*/}..."
    if ! extract_keyring > "${KEYRING}.tmp"; then
        rm -f "${KEYRING}.tmp"
        die "could not find the publisher keyring inside the tarball
  expected a member matching ${KEYRING_MEMBER_PATTERN}
  The tarball may be truncated or not an Arch Linux ARM rootfs snapshot."
    fi
    mv "${KEYRING}.tmp" "${KEYRING}"
fi

[ -s "${KEYRING}" ] || die "extracted keyring is empty: ${KEYRING}"

# ── Verify ────────────────────────────────────────────────────────────

GNUPGHOME="$(mktemp -d "${TMPDIR:-/tmp}/alarm-gnupg.XXXXXX")"
chmod 700 "${GNUPGHOME}"
# shellcheck disable=SC2329  # invoked through the EXIT trap below
cleanup() { rm -rf "${GNUPGHOME}"; }
trap cleanup EXIT

export GNUPGHOME
gpg --batch --no-tty --quiet --import "${KEYRING}" 2>/dev/null \
    || die "could not import the publisher keyring: ${KEYRING}"

STATUS="$(gpg --batch --no-tty --status-fd 1 --verify "${SIGNATURE}" "${TARBALL}" 2>/dev/null || true)"

GOODSIG="$(printf '%s\n' "${STATUS}" | awk '/^\[GNUPG:\] GOODSIG /{print $3; exit}')"
SIGNING_FPR="$(printf '%s\n' "${STATUS}" | awk '/^\[GNUPG:\] VALIDSIG /{print $3; exit}')"
PRIMARY_FPR="$(printf '%s\n' "${STATUS}" | awk '/^\[GNUPG:\] VALIDSIG /{print $12; exit}')"

if printf '%s\n' "${STATUS}" | grep -q '^\[GNUPG:\] \(BADSIG\|ERRSIG\|EXPSIG\) '; then
    printf '%s\n' "${STATUS}" >&2
    die "signature verification FAILED for ${TARBALL} (bad signature)
  The download does not match what the publisher signed.
  The file may be corrupt, truncated, or tampered with."
fi

if [ -z "${GOODSIG}" ] || [ -z "${PRIMARY_FPR}" ]; then
    printf '%s\n' "${STATUS}" >&2
    die "signature verification FAILED for ${TARBALL}
  Expected GOODSIG + VALIDSIG from gpg, got neither.
  The download may be corrupt, the mirror may be compromised, or the
  publisher rotated their signing key."
fi

if printf '%s\n' "${STATUS}" | grep -q '^\[GNUPG:\] EXPKEYSIG '; then
    die "the publisher signing key ${GOODSIG} has expired
  The signature itself is intact, but the key is no longer valid.
  Re-pin ALARM_KEYRING_FPR after checking the publisher's announcement."
fi

if [ "${PRIMARY_FPR}" != "${ALARM_KEYRING_FPR}" ]; then
    if [ "${SIGNING_FPR}" = "${PRIMARY_FPR}" ]; then
        SUBKEY_NOTE="signed by the primary key itself"
    else
        SUBKEY_NOTE="signed by subkey ${SIGNING_FPR} of that primary key"
    fi
    die "unexpected signing key
  expected primary fingerprint: ${ALARM_KEYRING_FPR}
  got:                           ${PRIMARY_FPR}
  (${SUBKEY_NOTE})
  Refusing to build. If the publisher legitimately rotated their key,
  update ALARM_KEYRING_FPR in tools/verify-alarm-tarball.sh after
  verifying the new fingerprint out of band."
fi

log "OK: ${TARBALL##*/} verified"
log "  sha256:    ${TARBALL_SHA256}"
log "  key id:    ${GOODSIG}"
log "  primary:   ${PRIMARY_FPR}"
exit 0
