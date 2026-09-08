#!/usr/bin/env bash
set -euo pipefail

# The root dispatcher owns every isolated-daemon path, process, and cleanup.
# This script owns only the approval-safe Mac-side tunnel and attestation.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
load_deployment_config "$ROOT"
readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
MODE="${1:-}"; ARGUMENT="${2:-}"; ID=""; REMOTE_SOCKET=""; LOCAL_SOCKET=""; TUNNEL_PID=""; ARMED=0
die() { printf 'Image restore-readiness lifecycle failed: %s\n' "$1" >&2; exit 1; }
usage() {
  printf 'Usage:\n  ./scripts/run-image-restore-readiness.sh --check <recovery-directory>\n  ./scripts/run-image-restore-readiness.sh --apply <recovery-directory>\n  ./scripts/run-image-restore-readiness.sh --cleanup <readiness-id>\n' >&2
}
valid_id() { [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=12 "$REMOTE" "$@"; }
set_id() { valid_id "$1" || die "readiness ID is invalid"; ID="$1"; REMOTE_SOCKET="/run/nextcloud-pi-ops/image-readiness-$ID.sock"; LOCAL_SOCKET="/tmp/nextcloud-image-readiness-$ID.sock"; }
stop_tunnel() { if [[ -n "$TUNNEL_PID" ]]; then kill "$TUNNEL_PID" 2>/dev/null || true; wait "$TUNNEL_PID" 2>/dev/null || true; fi; [[ -z "$LOCAL_SOCKET" ]] || rm -f -- "$LOCAL_SOCKET"; }
cleanup() { local status=$?; trap - EXIT HUP INT TERM; stop_tunnel; if (( ARMED )); then remote "sudo -n /usr/local/libexec/nextcloud-pi-ops image-readiness stop '$ID'" >/dev/null 2>&1 || true; remote "sudo -n /usr/local/libexec/nextcloud-pi-ops image-readiness cleanup '$ID'" >/dev/null 2>&1 || printf 'Retry cleanup with readiness ID: %s\n' "$ID" >&2; fi; exit "$status"; }
start_tunnel() {
  [[ ! -e "$LOCAL_SOCKET" && ! -L "$LOCAL_SOCKET" ]] || return 1
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=12 -o ExitOnForwardFailure=yes -N -L "$LOCAL_SOCKET:$REMOTE_SOCKET" "$REMOTE" & TUNNEL_PID=$!
  local attempt=0
  while (( attempt < 30 )); do
    ((attempt++)); [[ -S "$LOCAL_SOCKET" ]] && docker -H "unix://$LOCAL_SOCKET" info >/dev/null 2>&1 && return 0
    kill -0 "$TUNNEL_PID" 2>/dev/null || return 1; sleep 1
  done
  return 1
}
check() {
  local recovery="$1" bytes
  [[ ! -e "$recovery/restore-attestation.tsv" && ! -L "$recovery/restore-attestation.tsv" ]] || die "recovery already has an attestation"
  "$SCRIPT_DIR/verify-image-recovery.sh" "$recovery" >/dev/null
  bytes="$(wc -c <"$recovery/images.tar" | tr -d '[:space:]')"; set_id "$(date -u +%Y%m%dT%H%M%SZ)-$$"
  remote "sudo -n /usr/local/libexec/nextcloud-pi-ops image-readiness check '$ID' '$bytes'" >/dev/null || die "isolated-daemon prerequisites failed"
  printf 'CHECK: isolated image readiness is available; ID: %s\n' "$ID"
}
apply() {
  local recovery="$1"
  check "$recovery"; printf 'Image readiness ID: %s\n' "$ID"; ARMED=1; trap cleanup EXIT HUP INT TERM
  remote "sudo -n /usr/local/libexec/nextcloud-pi-ops image-readiness start '$ID'" >/dev/null
  remote "sudo -n /usr/local/libexec/nextcloud-pi-ops image-readiness status '$ID'" >/dev/null
  start_tunnel || die "could not forward isolated daemon socket"
  NEXTCLOUD_IMAGE_READINESS_SOCKET="$LOCAL_SOCKET" "$SCRIPT_DIR/test-image-restore-readiness.sh" "$recovery"
  stop_tunnel
  remote "sudo -n /usr/local/libexec/nextcloud-pi-ops image-readiness stop '$ID'" >/dev/null
  remote "sudo -n /usr/local/libexec/nextcloud-pi-ops image-readiness cleanup '$ID'" >/dev/null
  ARMED=0; trap - EXIT HUP INT TERM
  printf 'Image restore-readiness passed and isolated state was removed\n'
}
case "$MODE" in
  --check) [[ $# == 2 ]] || { usage; exit 2; }; check "$ARGUMENT";;
  --apply) [[ $# == 2 ]] || { usage; exit 2; }; apply "$ARGUMENT";;
  --cleanup) [[ $# == 2 ]] || { usage; exit 2; }; set_id "$ARGUMENT"; remote "sudo -n /usr/local/libexec/nextcloud-pi-ops image-readiness stop '$ID'" >/dev/null || true; remote "sudo -n /usr/local/libexec/nextcloud-pi-ops image-readiness cleanup '$ID'" >/dev/null;;
  *) usage; exit 2;;
esac
