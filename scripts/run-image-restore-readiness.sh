#!/usr/bin/env bash
set -euo pipefail

# Run image restore-readiness through a second Docker daemon on the configured
# Pi. The daemon has isolated state and no bridge or iptables authority; its
# Unix socket is forwarded to a protected local /tmp socket for the existing
# offline attestation test.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
load_deployment_config "$REPOSITORY_ROOT"

readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
MODE="${1:-}"
ARGUMENT="${2:-}"
READINESS_ID=""
REMOTE_TEST_ROOT=""
REMOTE_SOCKET=""
LOCAL_SOCKET=""
TUNNEL_PID=""
REMOTE_ARMED=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run-image-restore-readiness.sh --check <image-recovery-directory>
  ./scripts/run-image-restore-readiness.sh --apply <image-recovery-directory>
  ./scripts/run-image-restore-readiness.sh --cleanup <readiness-id>

--check validates the unattested archive, configured Pi, isolated-daemon
prerequisites, and free space without changing the Pi. --apply starts a second
Docker daemon with isolated state and networking controls disabled, forwards
only its disposable Unix socket, creates the restore-readiness attestation,
and removes the daemon and its state.

--cleanup retries removal after a failed or interrupted apply. Use only the
readiness ID printed by that run. The live Docker socket, daemon, containers,
images, volumes, and networks are never targeted.
EOF
}

die() {
  printf 'Image restore-readiness lifecycle failed: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$1" >&2
}

valid_readiness_id() {
  [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]
}

set_targets() {
  local readiness_id="$1"
  valid_readiness_id "$readiness_id" || die "readiness ID has an unexpected format"
  READINESS_ID="$readiness_id"
  REMOTE_TEST_ROOT="$NEXTCLOUD_STORAGE_MOUNT/.nextcloud-image-readiness-$READINESS_ID"
  REMOTE_SOCKET="/tmp/nextcloud-image-readiness-$READINESS_ID.sock"
  LOCAL_SOCKET="/tmp/nextcloud-image-readiness-$READINESS_ID.sock"
}

remote_sh() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" bash -s -- "$@"
}

verify_unattested_recovery() {
  local recovery_dir="$1"
  [[ ! -e "$recovery_dir/restore-attestation.tsv" && ! -L "$recovery_dir/restore-attestation.tsv" ]] ||
    die "recovery directory already contains a restore attestation"
  "$SCRIPT_DIR/verify-image-recovery.sh" "$recovery_dir" >/dev/null
}

check_remote_prerequisites() {
  local archive_bytes="$1" required_bytes available_bytes
  required_bytes=$((archive_bytes * 3 + 1073741824))
  available_bytes="$(remote_sh \
    "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" \
    "$NEXTCLOUD_STORAGE_MOUNT" \
    "$NEXTCLOUD_STORAGE_UUID" \
    "$REMOTE_TEST_ROOT" \
    "$REMOTE_SOCKET" <<'REMOTE_SCRIPT'
set -eu
expected_hostname="$1"
storage_mount="$2"
expected_uuid="$3"
test_root="$4"
daemon_socket="$5"

test "$(hostname)" = "$expected_hostname"
actual_target="$(findmnt -rn --target "$storage_mount" -o TARGET)"
actual_uuid="$(findmnt -rn --target "$storage_mount" -o UUID)"
test "$actual_target" = "$storage_mount"
test "$(printf '%s' "$actual_uuid" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$expected_uuid" | tr '[:upper:]' '[:lower:]')"
command -v bash >/dev/null
command -v docker >/dev/null
command -v dockerd >/dev/null
command -v nohup >/dev/null
sudo -n true
test ! -e "$test_root" && test ! -L "$test_root"
test ! -e "$daemon_socket" && test ! -L "$daemon_socket"
df -B1 --output=avail "$storage_mount" | tail -1 | tr -d '[:space:]'
REMOTE_SCRIPT
)" || die "Pi identity, storage, daemon prerequisites, or disposable paths failed"
  [[ "$available_bytes" =~ ^[0-9]+$ ]] || die "could not determine isolated-daemon free space"
  (( available_bytes > required_bytes )) || die "insufficient Pi space for isolated image restore-readiness"
}

start_remote_daemon() {
  remote_sh \
    "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" \
    "$NEXTCLOUD_STORAGE_MOUNT" \
    "$NEXTCLOUD_STORAGE_UUID" \
    "$REMOTE_TEST_ROOT" \
    "$REMOTE_SOCKET" <<'REMOTE_SCRIPT'
set -eu
expected_hostname="$1"
storage_mount="$2"
expected_uuid="$3"
test_root="$4"
daemon_socket="$5"

test "$(hostname)" = "$expected_hostname"
actual_target="$(findmnt -rn --target "$storage_mount" -o TARGET)"
actual_uuid="$(findmnt -rn --target "$storage_mount" -o UUID)"
test "$actual_target" = "$storage_mount"
test "$(printf '%s' "$actual_uuid" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$expected_uuid" | tr '[:upper:]' '[:lower:]')"
test ! -e "$test_root" && test ! -L "$test_root"
test ! -e "$daemon_socket" && test ! -L "$daemon_socket"
umask 077
mkdir -m 0700 "$test_root"
operator_group="$(id -gn)"
sudo -n nohup dockerd \
  --host="unix://$daemon_socket" \
  --data-root="$test_root/data" \
  --exec-root="$test_root/exec" \
  --pidfile="$test_root/dockerd.pid" \
  --group="$operator_group" \
  --bridge=none \
  --iptables=false \
  --ip-forward=false \
  --ip-masq=false \
  --userland-proxy=false \
  --log-level=error \
  </dev/null >"$test_root/dockerd.log" 2>&1 &

ready=0
attempt=0
while test "$attempt" -lt 60; do
  attempt=$((attempt + 1))
  if test -S "$daemon_socket" && docker -H "unix://$daemon_socket" info >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
test "$ready" = 1
test -f "$test_root/dockerd.pid" && test ! -L "$test_root/dockerd.pid"
test -z "$(docker -H "unix://$daemon_socket" ps -aq)"
REMOTE_SCRIPT
}

stop_remote_daemon() {
  remote_sh \
    "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" \
    "$NEXTCLOUD_STORAGE_MOUNT" \
    "$NEXTCLOUD_STORAGE_UUID" \
    "$REMOTE_TEST_ROOT" \
    "$REMOTE_SOCKET" <<'REMOTE_SCRIPT'
set -eu
expected_hostname="$1"
storage_mount="$2"
expected_uuid="$3"
test_root="$4"
daemon_socket="$5"

test "$(hostname)" = "$expected_hostname"
actual_target="$(findmnt -rn --target "$storage_mount" -o TARGET)"
actual_uuid="$(findmnt -rn --target "$storage_mount" -o UUID)"
test "$actual_target" = "$storage_mount"
test "$(printf '%s' "$actual_uuid" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$expected_uuid" | tr '[:upper:]' '[:lower:]')"
test "$(dirname -- "$test_root")" = "$storage_mount"
test_root_name="$(basename -- "$test_root")"
[[ "$test_root_name" =~ ^\.nextcloud-image-readiness-[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]
[[ "$daemon_socket" =~ ^/tmp/nextcloud-image-readiness-[0-9]{8}T[0-9]{6}Z-[0-9]+\.sock$ ]]

if test -e "$test_root"; then
  test -d "$test_root" && test ! -L "$test_root"
  pidfile="$test_root/dockerd.pid"
  if test -e "$pidfile"; then
    test -f "$pidfile" && test ! -L "$pidfile"
    pid="$(sudo -n cat "$pidfile")"
    case "$pid" in ''|*[!0-9]*) exit 2 ;; esac
    if sudo -n kill -0 "$pid" 2>/dev/null; then
      process_state="$(sudo -n awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)"
      if test "$process_state" != Z; then
        command_line="$(sudo -n cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' '\n' || true)"
        if test -n "$command_line"; then
          printf '%s\n' "$command_line" | grep -E '/?dockerd$' >/dev/null
          printf '%s\n' "$command_line" | grep -Fx -- "--data-root=$test_root/data" >/dev/null
          printf '%s\n' "$command_line" | grep -Fx -- "--host=unix://$daemon_socket" >/dev/null
          sudo -n kill "$pid"
        elif sudo -n kill -0 "$pid" 2>/dev/null; then
          process_state="$(sudo -n awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)"
          test "$process_state" = Z
        fi
        attempt=0
        while sudo -n kill -0 "$pid" 2>/dev/null && test "$attempt" -lt 30; do
          process_state="$(sudo -n awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)"
          test "$process_state" != Z || break
          attempt=$((attempt + 1))
          sleep 1
        done
      fi
      process_state="$(sudo -n awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)"
      if sudo -n kill -0 "$pid" 2>/dev/null && test "$process_state" != Z; then
        sudo -n kill -KILL "$pid"
        attempt=0
        while sudo -n kill -0 "$pid" 2>/dev/null && test "$attempt" -lt 10; do
          process_state="$(sudo -n awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)"
          test "$process_state" != Z || break
          attempt=$((attempt + 1))
          sleep 1
        done
      fi
      process_state="$(sudo -n awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)"
      ! sudo -n kill -0 "$pid" 2>/dev/null || test "$process_state" = Z
    fi
  elif test -S "$daemon_socket"; then
    exit 1
  fi
  sudo -n rm -rf -- "$test_root"
fi
sudo -n rm -f -- "$daemon_socket"
test ! -e "$test_root" && test ! -L "$test_root"
test ! -e "$daemon_socket" && test ! -L "$daemon_socket"
REMOTE_SCRIPT
}

start_tunnel() {
  [[ ! -e "$LOCAL_SOCKET" && ! -L "$LOCAL_SOCKET" ]] || die "local disposable socket already exists"
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o ExitOnForwardFailure=yes \
    -N \
    -L "$LOCAL_SOCKET:$REMOTE_SOCKET" \
    "$REMOTE" &
  TUNNEL_PID=$!

  local attempt=0
  while (( attempt < 30 )); do
    attempt=$((attempt + 1))
    if [[ -S "$LOCAL_SOCKET" ]] && docker -H "unix://$LOCAL_SOCKET" info >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "$TUNNEL_PID" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

stop_tunnel() {
  if [[ -n "$TUNNEL_PID" ]]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
  fi
  if [[ -n "$LOCAL_SOCKET" && "$LOCAL_SOCKET" == /tmp/nextcloud-image-readiness-*.sock ]]; then
    rm -f -- "$LOCAL_SOCKET"
  fi
}

cleanup() {
  local status=$?
  set +e
  stop_tunnel
  if (( REMOTE_ARMED != 0 )); then
    if ! stop_remote_daemon; then
      warn "disposable daemon cleanup failed; retry with: ./scripts/run-image-restore-readiness.sh --cleanup $READINESS_ID"
    fi
  fi
  return "$status"
}

case "$MODE" in
  --check|--apply)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    ;;
  --cleanup)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

command -v docker >/dev/null 2>&1 || die "Docker CLI is required locally"
command -v ssh >/dev/null 2>&1 || die "OpenSSH is required locally"

if [[ "$MODE" == --cleanup ]]; then
  set_targets "$ARGUMENT"
  stop_tunnel
  stop_remote_daemon || die "disposable daemon targets still require manual cleanup"
  printf 'RECOVERY: isolated image-readiness targets are absent\n'
  exit 0
fi

verify_unattested_recovery "$ARGUMENT"
archive_bytes="$(wc -c <"$ARGUMENT/images.tar" | tr -d '[:space:]')"
[[ "$archive_bytes" =~ ^[1-9][0-9]*$ ]] || die "image archive size is invalid"
set_targets "$(date -u +%Y%m%dT%H%M%SZ)-$$"
check_remote_prerequisites "$archive_bytes"

if [[ "$MODE" == --check ]]; then
  printf 'CHECK: isolated image restore-readiness prerequisites passed; no changes were made\n'
  exit 0
fi

printf 'Image restore-readiness ID: %s\n' "$READINESS_ID"
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
REMOTE_ARMED=1
start_remote_daemon || die "isolated Docker daemon did not become ready"
start_tunnel || die "isolated Docker socket forwarding did not become ready"

readiness_status=0
"$SCRIPT_DIR/test-image-restore-readiness.sh" \
  --docker-host "unix://$LOCAL_SOCKET" \
  "$ARGUMENT" || readiness_status=$?

stop_tunnel
if ! stop_remote_daemon; then
  die "readiness completed but disposable daemon cleanup failed; retry --cleanup $READINESS_ID"
fi
REMOTE_ARMED=0
trap - EXIT HUP INT TERM

(( readiness_status == 0 )) || die "image restore-readiness test failed; disposable targets were removed"
printf 'Image restore-readiness lifecycle passed; all disposable targets were removed.\n'
