#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_PATH="${1:?Usage: inject-ssh-key.sh <linux.img> [pubkey-file]}"
PUBKEY_FILE="${2:-}"
DOCKER_IMAGE="${DOCKER_IMAGE:-nabu-cachyos-builder}"

pick_default_pubkey() {
    local candidates=(
        "${HOME}/.ssh/id_ed25519.pub"
        "${HOME}/.ssh/id_ecdsa.pub"
        "${HOME}/.ssh/id_rsa.pub"
        "${HOME}/.ssh/google_compute_engine.pub"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [ -f "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    local pubkeys=()
    while IFS= read -r line; do
        pubkeys+=("${line}")
    done < <(find "${HOME}/.ssh" -maxdepth 1 -type f -name '*.pub' | sort)

    if [ "${#pubkeys[@]}" -eq 1 ]; then
        printf '%s\n' "${pubkeys[0]}"
        return 0
    fi

    return 1
}

if [ -z "${PUBKEY_FILE}" ]; then
    PUBKEY_FILE="$(pick_default_pubkey || true)"
fi

if [ -z "${PUBKEY_FILE}" ]; then
    echo "  No SSH public key found under ~/.ssh; skipping key injection."
    exit 0
fi

[ -f "${PUBKEY_FILE}" ] || { echo "ERROR: SSH public key not found: ${PUBKEY_FILE}"; exit 1; }

command -v docker >/dev/null || {
    echo "  Docker not found; skipping SSH key injection."
    exit 0
}

if ! docker info >/dev/null 2>&1; then
    echo "  Docker is not running; skipping SSH key injection."
    exit 0
fi

WORK_DIR="$(mktemp -d "${SCRIPT_DIR}/.ssh-inject.XXXXXX")"
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

cp "${PUBKEY_FILE}" "${WORK_DIR}/authorized_keys"

cat > "${WORK_DIR}/debugfs.cmds" <<'EOF'
mkdir /home
mkdir /home/nabu
mkdir /home/nabu/.ssh
rm /home/nabu/.ssh/authorized_keys
write /work/authorized_keys /home/nabu/.ssh/authorized_keys
sif /home/nabu/.ssh mode 040700
sif /home/nabu/.ssh uid 1000
sif /home/nabu/.ssh gid 1000
sif /home/nabu/.ssh/authorized_keys mode 0100600
sif /home/nabu/.ssh/authorized_keys uid 1000
sif /home/nabu/.ssh/authorized_keys gid 1000
stat /home/nabu/.ssh/authorized_keys
EOF

echo "  Injecting SSH key from ${PUBKEY_FILE##*/}..."
docker run --rm \
    -v "${WORK_DIR}:/work" \
    -v "${IMAGE_PATH}:/image/linux.img" \
    "${DOCKER_IMAGE}" \
    bash -lc '
        set -euo pipefail
        debugfs -w -f /work/debugfs.cmds /image/linux.img >/work/debugfs.stdout 2>/work/debugfs.stderr || true
        debugfs -R "stat /home/nabu/.ssh/authorized_keys" /image/linux.img >/work/debugfs.verify 2>&1
        status=0
        e2fsck -fy /image/linux.img >/dev/null || status=$?
        if [ "$status" -gt 1 ]; then
            exit "$status"
        fi
    '

echo "  SSH key installed for user nabu."
