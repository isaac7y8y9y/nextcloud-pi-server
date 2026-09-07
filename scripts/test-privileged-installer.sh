#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/privileged/nextcloud-pi-bundle-installer"; MANAGER="$ROOT/scripts/manage-pi-privileged-interface.sh"
bash -n "$INSTALLER" "$MANAGER"
grep -Fq 'visudo -cf' "$INSTALLER"; grep -Fq 'sudo -u "$user" sudo -n /usr/local/libexec/nextcloud-pi-ops check' "$INSTALLER"
grep -Fq 'rollback_install' "$INSTALLER"; grep -Fq 'nextcloud-pi-bundle-installer' "$MANAGER"
printf 'privileged installer lifecycle tests passed\n'
