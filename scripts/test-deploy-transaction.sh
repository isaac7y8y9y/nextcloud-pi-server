#!/usr/bin/env bash
set -euo pipefail

# Approved disposable proof of the helper-embedded deployment rollback drill.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
load_deployment_config "$ROOT"
readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
readonly ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
MODE="${1:---check}"; ARMED=0
die() { printf 'Deployment transaction drill failed: %s\n' "$1" >&2; exit 1; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"; }
cleanup() { local status=$?; if (( ARMED )); then remote "sudo -n /usr/local/libexec/nextcloud-pi-ops deployment-drill cleanup '$ID'" >/dev/null || printf 'Retry cleanup with deployment-drill ID: %s\n' "$ID" >&2; fi; exit "$status"; }
[[ "$MODE" == --check || "$MODE" == --apply ]] || die 'usage: --check|--apply'
remote "sudo -n /usr/local/libexec/nextcloud-pi-ops check" >/dev/null || die "privileged interface check failed"
remote "sudo -n /usr/local/libexec/nextcloud-pi-ops deployment-drill check '$ID'" >/dev/null || die "drill prerequisites failed"
if [[ "$MODE" == --check ]]; then printf 'CHECK: deployment drill is available; no changes were made\n'; exit 0; fi
printf 'Deployment-drill ID: %s\nType the ID to approve: ' "$ID"; read -r approval; [[ "$approval" == "$ID" ]] || die "approval did not match"
ARMED=1; trap cleanup EXIT HUP INT TERM
remote "sudo -n /usr/local/libexec/nextcloud-pi-ops deployment-drill apply '$ID'" >/dev/null || die "drill failed"
remote "sudo -n /usr/local/libexec/nextcloud-pi-ops deployment-drill cleanup '$ID'" >/dev/null || die "drill cleanup failed"
ARMED=0; trap - EXIT HUP INT TERM; printf 'Deployment transaction drill passed\n'
