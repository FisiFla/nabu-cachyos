#!/usr/bin/env bash
# verify-patches.sh — prove every patch in patches/ still applies, in order,
# to a given kernel tree. Non-destructive: applies in a throwaway git
# worktree of the target tree and removes it again.
#
# Usage: ./verify-patches.sh /path/to/kernel-tree
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="${1:-}"
if [ -z "${TREE}" ] || [ ! -d "${TREE}/.git" ]; then
    echo "usage: $0 /path/to/kernel-tree (a git checkout)" >&2
    exit 2
fi

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
    git -C "${TREE}" worktree remove --force "${WORK_DIR}/wt" >/dev/null 2>&1 || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

git -C "${TREE}" worktree add --detach --force "${WORK_DIR}/wt" HEAD >/dev/null
echo "Verifying ${SCRIPT_DIR}/patches/*.patch against ${TREE} @ $(git -C "${TREE}" rev-parse --short HEAD)"
fail=0
for patch in "${SCRIPT_DIR}"/patches/*.patch; do
    name="$(basename "${patch}")"
    if git -C "${WORK_DIR}/wt" apply --check "${patch}" 2>/dev/null \
        && git -C "${WORK_DIR}/wt" apply "${patch}" 2>/dev/null; then
        echo "  OK   ${name}"
    else
        echo "  FAIL ${name}"
        git -C "${WORK_DIR}/wt" apply --check "${patch}" 2>&1 | head -n 5 || true
        fail=1
        break
    fi
done
[ "${fail}" -eq 0 ] && echo "All patches apply in order."
exit "${fail}"
