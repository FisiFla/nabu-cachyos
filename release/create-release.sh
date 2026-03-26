#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_DIR}/output}"
DIST_DIR="${1:-${SCRIPT_DIR}/dist}"
PART_SIZE="${PART_SIZE:-1500m}"
VBMETA_SOURCE="${VBMETA_SOURCE:-${OUTPUT_DIR}/vbmeta_disabled.img}"

if command -v sha256sum >/dev/null 2>&1; then
    SHA256_CMD=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    SHA256_CMD=(shasum -a 256)
else
    echo "ERROR: sha256sum or shasum is required."
    exit 1
fi

for f in \
    "${OUTPUT_DIR}/boot.img" \
    "${OUTPUT_DIR}/linux.img.zst" \
    "${VBMETA_SOURCE}" \
    "${SCRIPT_DIR}/flash.sh" \
    "${SCRIPT_DIR}/join-and-flash.sh" \
    "${SCRIPT_DIR}/inject-ssh-key.sh"; do
    [ -f "${f}" ] || { echo "ERROR: missing required file: ${f}"; exit 1; }
done

rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

echo "Creating release bundle in ${DIST_DIR}"

cp "${OUTPUT_DIR}/boot.img" "${DIST_DIR}/"
cp "${VBMETA_SOURCE}" "${DIST_DIR}/vbmeta_disabled.img"
cp "${SCRIPT_DIR}/flash.sh" "${DIST_DIR}/"
cp "${SCRIPT_DIR}/join-and-flash.sh" "${DIST_DIR}/"
cp "${SCRIPT_DIR}/inject-ssh-key.sh" "${DIST_DIR}/"
chmod +x "${DIST_DIR}/flash.sh" "${DIST_DIR}/join-and-flash.sh" "${DIST_DIR}/inject-ssh-key.sh"

split -b "${PART_SIZE}" "${OUTPUT_DIR}/linux.img.zst" "${DIST_DIR}/linux.img.zst.part-"

(
    cd "${DIST_DIR}"
    "${SHA256_CMD[@]}" \
        boot.img \
        flash.sh \
        inject-ssh-key.sh \
        join-and-flash.sh \
        linux.img.zst.part-* \
        vbmeta_disabled.img \
        > SHA256SUMS
)

echo ""
echo "Release bundle ready:"
ls -lh "${DIST_DIR}"
