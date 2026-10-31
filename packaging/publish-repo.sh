#!/usr/bin/env bash
# publish-repo.sh — rebuild the signed [nabu-cachyos] pacman repo from the
# newest *.pkg.tar.zst in REPO_DIR, then optionally copy it to PUBLISH_DEST.
# UNTESTED end-to-end. Signing is mandatory by default; ALLOW_UNSIGNED=1 is
# an explicit local-only escape hatch.
#
# Env: REPO_DIR (default packaging/repo), NABU_GPG_KEY_ID, PUBLISH_DEST
# (local path or rsync target, e.g. user@host:/srv/pacman/nabu-cachyos/).
# See packaging/README.md for one-time key + GitHub secret setup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-${SCRIPT_DIR}/repo}"
mkdir -p "${REPO_DIR}"

pkgs=()
while IFS= read -r pkg; do
  pkgs+=("${pkg}")
done < <(find "${REPO_DIR}" -maxdepth 1 -name '*.pkg.tar.zst' | sort)
if [ "${#pkgs[@]}" -eq 0 ]; then
  echo "ERROR: no *.pkg.tar.zst in ${REPO_DIR} — build packages first" >&2
  exit 1
fi

cd "${REPO_DIR}"
rm -f nabu-cachyos.db nabu-cachyos.db.sig nabu-cachyos.files nabu-cachyos.files.sig \
      nabu-cachyos.db.tar.gz nabu-cachyos.files.tar.gz
if [ "${ALLOW_UNSIGNED:-0}" = "1" ]; then
  echo "WARNING: ALLOW_UNSIGNED=1 — building an unsigned repo (local use only)"
  repo-add nabu-cachyos.db.tar.gz "${pkgs[@]##*/}"
else
  : "${NABU_GPG_KEY_ID:?set NABU_GPG_KEY_ID (or ALLOW_UNSIGNED=1 for local testing)}"
  for pkg in "${pkgs[@]}"; do
    gpg --batch --homedir "${GNUPGHOME:-${HOME}/.gnupg}" --detach-sign \
      --local-user "${NABU_GPG_KEY_ID}" --no-armor -o "${pkg}.sig" "${pkg}"
  done
  repo-add --sign --key "${NABU_GPG_KEY_ID}" nabu-cachyos.db.tar.gz "${pkgs[@]##*/}"
fi
ln -sf nabu-cachyos.db.tar.gz nabu-cachyos.db
ln -sf nabu-cachyos.files.tar.gz nabu-cachyos.files
if [ "${ALLOW_UNSIGNED:-0}" != "1" ]; then
  ln -sf nabu-cachyos.db.tar.gz.sig nabu-cachyos.db.sig
  ln -sf nabu-cachyos.files.tar.gz.sig nabu-cachyos.files.sig
fi

if [ -n "${PUBLISH_DEST:-}" ]; then
  if command -v rsync >/dev/null 2>&1; then
    rsync -av --delete --links "${REPO_DIR}/" "${PUBLISH_DEST}"
  else
    mkdir -p "${PUBLISH_DEST}" && cp -a "${REPO_DIR}/." "${PUBLISH_DEST}/"
  fi
  echo "Published to ${PUBLISH_DEST}"
fi
echo "Repo ready in ${REPO_DIR}: ${#pkgs[@]} packages"
