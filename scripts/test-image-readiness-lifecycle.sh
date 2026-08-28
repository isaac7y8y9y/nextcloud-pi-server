#!/usr/bin/env bash
set -euo pipefail

# Offline regression guard for the isolated-daemon lifecycle. The live drill
# requires separate approval; CI keeps its target isolation and cleanup contract
# fail-closed.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LIFECYCLE="$SCRIPT_DIR/run-image-restore-readiness.sh"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/image-lock.sh"
image_lock_load "$REPOSITORY_ROOT"

bash -n "$LIFECYCLE"
grep -Fq -- '--data-root="$test_root/data"' "$LIFECYCLE"
grep -Fq -- '--exec-root="$test_root/exec"' "$LIFECYCLE"
grep -Fq -- '--pidfile="$test_root/dockerd.pid"' "$LIFECYCLE"
grep -Fq -- '--bridge=none' "$LIFECYCLE"
grep -Fq -- '--iptables=false' "$LIFECYCLE"
grep -Fq -- '--ip-forward=false' "$LIFECYCLE"
grep -Fq -- '--ip-masq=false' "$LIFECYCLE"
grep -Fq -- '--userland-proxy=false' "$LIFECYCLE"
[[ "$(grep -Fc 'actual_target="$(findmnt -rn --target "$storage_mount" -o TARGET)"' "$LIFECYCLE")" == 3 ]]
[[ "$(grep -Fc 'actual_uuid="$(findmnt -rn --target "$storage_mount" -o UUID)"' "$LIFECYCLE")" == 3 ]]
[[ "$(grep -Fc 'test "$actual_target" = "$storage_mount"' "$LIFECYCLE")" == 3 ]]
[[ "$(grep -Fc "tr '[:upper:]' '[:lower:]'" "$LIFECYCLE")" == 3 ]]
grep -Fq -- '-L "$LOCAL_SOCKET:$REMOTE_SOCKET"' "$LIFECYCLE"
grep -Fq 'test-image-restore-readiness.sh' "$LIFECYCLE"
grep -Fq 'stop_remote_daemon' "$LIFECYCLE"
grep -Fq -- '--cleanup $READINESS_ID' "$LIFECYCLE"
grep -Fq 'grep -Fx -- "--data-root=$test_root/data"' "$LIFECYCLE"
grep -Fq 'grep -Fx -- "--host=unix://$daemon_socket"' "$LIFECYCLE"
if grep -Fq '/var/run/docker.sock' "$LIFECYCLE"; then
  printf 'isolated lifecycle references the live Docker socket\n' >&2
  exit 1
fi

extract_function() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\) \\{" { capture = 1 } capture { print } capture && $0 == "}" { exit }' "$LIFECYCLE"
}

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
extract_function valid_readiness_id >"$TEST_DIR/valid-readiness-id.sh"
source "$TEST_DIR/valid-readiness-id.sh"
valid_readiness_id 20260828T120000Z-1234
for invalid in '' 20260828-1234 20260828T120000Z /tmp/example 20260828T120000Z-abc; do
  if valid_readiness_id "$invalid"; then
    printf 'invalid readiness ID was accepted: %s\n' "$invalid" >&2
    exit 1
  fi
done

printf 'isolated image-readiness lifecycle regression checks passed\n'

# Exercise check, apply, failure, and cleanup behavior through hermetic fake
# SSH and Docker transports. Remote scripts execute locally against disposable
# paths so no daemon or configured Pi is contacted.
FAKE_BIN="$TEST_DIR/fake-bin"
mkdir "$FAKE_BIN" "$TEST_DIR/storage"

cat >"$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
forward=""
tunnel=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) shift 2 ;;
    -L) forward="$2"; shift 2 ;;
    -N) tunnel=1; shift ;;
    bash)
      shift
      [[ "${1:-}" == -s && "${2:-}" == -- ]]
      shift 2
      remote_arguments=("$@")
      payload="$(mktemp)"
      trap 'rm -f "$payload"' EXIT
      cat >"$payload"
      if grep -Fq 'sudo -n nohup dockerd' "$payload"; then
        test_root="${remote_arguments[3]}"
        mkdir -m 700 "$test_root"
        if [[ "${FAKE_DOCKERD_FAIL:-0}" == 1 ]]; then exit 1; fi
        mkdir "$test_root/data" "$test_root/exec"
        /bin/sleep 300 </dev/null >"$test_root/dockerd.log" 2>&1 &
        printf '%s\n' "$!" >"$test_root/dockerd.pid"
        exit 0
      fi
      if grep -Fq 'pidfile="$test_root/dockerd.pid"' "$payload"; then
        test_root="${remote_arguments[3]}"
        daemon_socket="${remote_arguments[4]}"
        [[ "${FAKE_FINDMNT_SCENARIO:-valid}" == valid ]] || exit 1
        if [[ -f "$test_root/dockerd.pid" ]]; then
          kill "$(cat "$test_root/dockerd.pid")" 2>/dev/null || true
        fi
        rm -rf -- "$test_root"
        rm -f -- "$daemon_socket"
        exit 0
      fi
      exec /bin/bash -s -- "${remote_arguments[@]}" <"$payload"
      ;;
    *) shift ;;
  esac
done
if (( tunnel != 0 )); then
  [[ -n "$forward" ]]
  local_socket="${forward%%:*}"
  exec socket-listener "$local_socket"
fi
exit 2
EOF

cat >"$FAKE_BIN/hostname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$NEXTCLOUD_PI_SYSTEM_HOSTNAME"
EOF

cat >"$FAKE_BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
field=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then field="$2"; shift 2; else shift; fi
done
case "${FAKE_FINDMNT_SCENARIO:-valid}:$field" in
  valid:TARGET) printf '%s\n' "$NEXTCLOUD_STORAGE_MOUNT" ;;
  valid:UUID) printf '%s\n' "$NEXTCLOUD_STORAGE_UUID" ;;
  wrong_target:TARGET) printf '/\n' ;;
  wrong_target:UUID) printf '%s\n' "$NEXTCLOUD_STORAGE_UUID" ;;
  wrong_uuid:TARGET) printf '%s\n' "$NEXTCLOUD_STORAGE_MOUNT" ;;
  wrong_uuid:UUID) printf '00000000-0000-0000-0000-000000000000\n' ;;
  *) exit 1 ;;
esac
EOF

cat >"$FAKE_BIN/df" <<'EOF'
#!/usr/bin/env bash
printf 'Avail\n999999999999\n'
EOF

cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" != -n ]] || shift
if [[ "${1:-}" == cat && "${2:-}" =~ ^/proc/([0-9]+)/cmdline$ ]]; then
  process_command="$(ps -p "${BASH_REMATCH[1]}" -o command=)"
  printf '%s' "$process_command" | tr ' ' '\0'
  exit 0
fi
if [[ "${1:-}" == awk && "${*: -1}" =~ ^/proc/([0-9]+)/stat$ ]]; then
  process_state="$(ps -p "${BASH_REMATCH[1]}" -o state= | tr -d '[:space:]')"
  printf '%s (dockerd) %s\n' "${BASH_REMATCH[1]}" "${process_state:0:1}"
  exit 0
fi
exec "$@"
EOF

cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
/bin/sleep 0.05
EOF

cat >"$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -H ]]; then shift 2; fi
case "${1:-}" in
  info) exit 0 ;;
  ps) exit 0 ;;
  load)
    [[ "${FAKE_DOCKER_LOAD_FAIL:-0}" == 0 ]]
    ;;
  image)
    tag="${*: -1}"
    case "$tag" in
      nextcloud:30) printf '%s\n' "$FAKE_APP_ID" ;;
      mariadb:11) printf '%s\n' "$FAKE_DB_ID" ;;
      caddy:2) printf '%s\n' "$FAKE_CADDY_ID" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF

cat >"$FAKE_BIN/dockerd" <<'PY'
#!/usr/bin/env python3
import os
import signal
import socket
import sys
import time

if os.environ.get("FAKE_DOCKERD_FAIL") == "1":
    raise SystemExit(1)

values = {}
for argument in sys.argv[1:]:
    if argument.startswith("--") and "=" in argument:
        key, value = argument.split("=", 1)
        values[key] = value

daemon_socket = values["--host"].removeprefix("unix://")
data_root = values["--data-root"]
exec_root = values["--exec-root"]
pidfile = values["--pidfile"]
os.makedirs(data_root, exist_ok=True)
os.makedirs(exec_root, exist_ok=True)
with open(pidfile, "w", encoding="ascii") as handle:
    handle.write(str(os.getpid()))
listener = socket.socket(socket.AF_UNIX)
listener.bind(daemon_socket)
listener.listen(1)

def stop(_signum, _frame):
    listener.close()
    try:
        os.unlink(daemon_socket)
    except FileNotFoundError:
        pass
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
while True:
    time.sleep(1)
PY

cat >"$FAKE_BIN/socket-listener" <<'PY'
#!/usr/bin/env python3
import os
import signal
import socket
import sys
import time

socket_path = sys.argv[1]
listener = socket.socket(socket.AF_UNIX)
listener.bind(socket_path)
listener.listen(1)

def stop(_signum, _frame):
    listener.close()
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
while True:
    time.sleep(1)
PY

chmod 755 "$FAKE_BIN"/*

DEPLOYMENT_FIXTURE="$TEST_DIR/deployment.env"
cp "$REPOSITORY_ROOT/config/deployment.env.example" "$DEPLOYMENT_FIXTURE"
chmod 600 "$DEPLOYMENT_FIXTURE"
export NEXTCLOUD_DEPLOYMENT_ENV_FILE="$DEPLOYMENT_FIXTURE"
export NEXTCLOUD_PI_HOST=pi.test.invalid
export NEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-test
export NEXTCLOUD_PI_USER=test-user
export NEXTCLOUD_REMOTE_PROJECT_DIR=/srv/nextcloud-docker
export NEXTCLOUD_STORAGE_MOUNT="$TEST_DIR/storage"
export NEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111
export NEXTCLOUD_PUBLIC_HOSTNAME=nextcloud.test.invalid
export PATH="$FAKE_BIN:$PATH"
export FAKE_APP_ID="$NEXTCLOUD_IMAGE_APP_ID"
export FAKE_DB_ID="$NEXTCLOUD_IMAGE_DB_ID"
export FAKE_CADDY_ID="$NEXTCLOUD_IMAGE_CADDY_ID"

make_recovery() {
  local recovery="$1" archive_sha
  mkdir -m 700 "$recovery"
  printf 'archive-fixture\n' >"$recovery/images.tar"
  chmod 600 "$recovery/images.tar"
  archive_sha="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$recovery/images.tar" | awk '{print $1}'; else shasum -a 256 "$recovery/images.tar" | awk '{print $1}'; fi)"
  {
    printf 'format\timage-recovery-v1\nstate\tcomplete\ntimestamp\t20260828T120000Z\nremote_host\tpi-test\nremote_user\ttest-user\nsource_project\t/srv/nextcloud-docker\nstorage_mount\t%s\nplatform\t%s\narchive_sha256\t%s\narchive_bytes\t%s\n' \
      "$NEXTCLOUD_STORAGE_MOUNT" "$NEXTCLOUD_IMAGE_PLATFORM" "$archive_sha" "$(wc -c <"$recovery/images.tar" | tr -d '[:space:]')"
    while IFS= read -r tag; do
      printf 'image\t%s\t%s\n' "$tag" "$(image_lock_expected_id "$tag")"
    done < <(image_lock_tags)
  } >"$recovery/manifest.tsv"
  chmod 600 "$recovery/manifest.tsv"
}

CHECK_RECOVERY="$TEST_DIR/image-recovery-check"
make_recovery "$CHECK_RECOVERY"
FAKE_FINDMNT_SCENARIO=valid bash "$LIFECYCLE" --check "$CHECK_RECOVERY" >/dev/null
[[ -z "$(find "$NEXTCLOUD_STORAGE_MOUNT" -mindepth 1 -maxdepth 1 -print -quit)" ]]
if FAKE_FINDMNT_SCENARIO=wrong_target bash "$LIFECYCLE" --check "$CHECK_RECOVERY" >/dev/null 2>&1; then
  printf 'wrong storage mount target passed readiness check\n' >&2
  exit 1
fi
if FAKE_FINDMNT_SCENARIO=wrong_uuid bash "$LIFECYCLE" --check "$CHECK_RECOVERY" >/dev/null 2>&1; then
  printf 'wrong storage UUID passed readiness check\n' >&2
  exit 1
fi

CLEANUP_ID=20260828T120000Z-9876
CLEANUP_ROOT="$NEXTCLOUD_STORAGE_MOUNT/.nextcloud-image-readiness-$CLEANUP_ID"
mkdir -m 700 "$CLEANUP_ROOT"
printf 'preserve\n' >"$CLEANUP_ROOT/sentinel"
if FAKE_FINDMNT_SCENARIO=wrong_target bash "$LIFECYCLE" --cleanup "$CLEANUP_ID" >/dev/null 2>&1; then
  printf 'cleanup accepted an unbound storage target\n' >&2
  exit 1
fi
[[ -f "$CLEANUP_ROOT/sentinel" ]]
FAKE_FINDMNT_SCENARIO=valid bash "$LIFECYCLE" --cleanup "$CLEANUP_ID" >/dev/null
[[ ! -e "$CLEANUP_ROOT" ]]

APPLY_RECOVERY="$TEST_DIR/image-recovery-apply"
make_recovery "$APPLY_RECOVERY"
FAKE_FINDMNT_SCENARIO=valid bash "$LIFECYCLE" --apply "$APPLY_RECOVERY" >/dev/null
bash "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$APPLY_RECOVERY" >/dev/null
[[ -z "$(find "$NEXTCLOUD_STORAGE_MOUNT" -mindepth 1 -maxdepth 1 -print -quit)" ]]
cp "$APPLY_RECOVERY/restore-attestation.tsv" "$TEST_DIR/preserved-attestation.tsv"
if bash "$SCRIPT_DIR/test-image-restore-readiness.sh" \
  --docker-host unix:///tmp/nextcloud-existing-attestation-test.sock \
  "$APPLY_RECOVERY" >/dev/null 2>&1; then
  printf 'low-level readiness test accepted an existing attestation\n' >&2
  exit 1
fi
cmp "$TEST_DIR/preserved-attestation.tsv" "$APPLY_RECOVERY/restore-attestation.tsv"

FAIL_RECOVERY="$TEST_DIR/image-recovery-fail"
make_recovery "$FAIL_RECOVERY"
if FAKE_FINDMNT_SCENARIO=valid FAKE_DOCKER_LOAD_FAIL=1 bash "$LIFECYCLE" --apply "$FAIL_RECOVERY" >/dev/null 2>&1; then
  printf 'readiness apply unexpectedly accepted a failed Docker load\n' >&2
  exit 1
fi
[[ ! -e "$FAIL_RECOVERY/restore-attestation.tsv" ]]
[[ -z "$(find "$FAIL_RECOVERY" -name '.restore-attestation-*.tsv' -print -quit)" ]]
[[ -z "$(find "$NEXTCLOUD_STORAGE_MOUNT" -mindepth 1 -maxdepth 1 -print -quit)" ]]

PARTIAL_RECOVERY="$TEST_DIR/image-recovery-partial"
make_recovery "$PARTIAL_RECOVERY"
if FAKE_FINDMNT_SCENARIO=valid FAKE_DOCKERD_FAIL=1 bash "$LIFECYCLE" --apply "$PARTIAL_RECOVERY" >/dev/null 2>&1; then
  printf 'readiness apply unexpectedly accepted partial daemon startup\n' >&2
  exit 1
fi
[[ -z "$(find "$NEXTCLOUD_STORAGE_MOUNT" -mindepth 1 -maxdepth 1 -print -quit)" ]]

printf 'isolated image-readiness lifecycle behavior tests passed\n'
