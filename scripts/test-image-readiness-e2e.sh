#!/usr/bin/env bash
# Hermetic wrapper-to-dispatcher restore-readiness coverage. The privileged
# branch is deliberately limited to the disposable GitHub Actions fixture.
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly FIXTURE_LIBRARY="$SCRIPT_DIR/lib/test-privileged-fixture.sh"
readonly WRAPPER="$SCRIPT_DIR/run-image-restore-readiness.sh"
source "$SCRIPT_DIR/lib/image-lock.sh"

bash -n "$WRAPPER" "$SCRIPT_DIR/test-image-restore-readiness.sh" "$FIXTURE_LIBRARY"
if [[ "${GITHUB_ACTIONS:-}" != true || "$(uname -s)" != Linux ]]; then
  printf 'image-readiness end-to-end fixture is GitHub-Actions Linux-only; portable checks passed\n'
  exit 0
fi

source "$FIXTURE_LIBRARY"
image_lock_load "$ROOT"
readonly TEST_DIR="$(mktemp -d)"
readonly TEST_BIN="$TEST_DIR/bin"
readonly CONFIG_FILE="$TEST_DIR/deployment.env"
mkdir -m 700 "$TEST_BIN"
cleanup_fixture_readiness() {
  local id failed=0
  [[ -z "${PRIVILEGED_FIXTURE:-}" ]] && return 0
  if sudo test -d "$PRIVILEGED_FIXTURE/state/image-readiness"; then
    while IFS= read -r id; do
      if [[ ! "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; then
        failed=1
        continue
      fi
      sudo "$PRIVILEGED_FIXTURE/ops" image-readiness stop "$id" >/dev/null 2>&1 || failed=1
      sudo "$PRIVILEGED_FIXTURE/ops" image-readiness cleanup "$id" >/dev/null 2>&1 || failed=1
      sudo test ! -e "$PRIVILEGED_FIXTURE/state/image-readiness/$id" || failed=1
      sudo test ! -e "$PRIVILEGED_FIXTURE/mount/.readiness-$id" || failed=1
      sudo test ! -e "$PRIVILEGED_FIXTURE/socket/image-readiness-$id.sock" || failed=1
    done < <(sudo find "$PRIVILEGED_FIXTURE/state/image-readiness" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
  fi
  return "$failed"
}
cleanup() {
  local status=$?
  local attempt
  trap - EXIT HUP INT TERM
  if [[ -n "${WRAPPER_PID:-}" ]]; then
    kill -TERM -- "-$WRAPPER_PID" 2>/dev/null || true
    for attempt in {1..15}; do kill -0 "$WRAPPER_PID" 2>/dev/null || break; sleep 1; done
    kill -0 "$WRAPPER_PID" 2>/dev/null && kill -KILL -- "-$WRAPPER_PID" 2>/dev/null || true
    wait "$WRAPPER_PID" 2>/dev/null || true
  fi
  if ! cleanup_fixture_readiness; then
    printf 'image-readiness end-to-end fixture cleanup failed; retained: %s\n' "$PRIVILEGED_FIXTURE" >&2
    status=1
  elif [[ -n "${PRIVILEGED_FIXTURE:-}" ]] && ! privileged_fixture_cleanup; then
    printf 'image-readiness end-to-end fixture removal failed; retained: %s\n' "$PRIVILEGED_FIXTURE" >&2
    status=1
  fi
  rm -rf -- "$TEST_DIR"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
privileged_fixture_setup "$ROOT/privileged/nextcloud-pi-ops"
export TEST_IMAGE_E2E_DIR="$TEST_DIR" TEST_PRIVILEGED_FIXTURE="$PRIVILEGED_FIXTURE"

cat >"$CONFIG_FILE" <<'EOF'
NEXTCLOUD_PI_HOST=pi.test.invalid
NEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-test
NEXTCLOUD_PI_USER=test-user
NEXTCLOUD_REMOTE_PROJECT_DIR=/srv/nextcloud-docker
NEXTCLOUD_STORAGE_MOUNT=/mnt/test-nextcloud
NEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111
NEXTCLOUD_PUBLIC_HOSTNAME=nextcloud.test.invalid
EOF
chmod 600 "$CONFIG_FILE"

cat >"$TEST_BIN/socket-listener.c" <<'EOF'
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
static volatile sig_atomic_t running = 1;
static void stop(int signal_number) { (void)signal_number; running = 0; }
int main(int argc, char **argv) {
  int descriptor; struct sockaddr_un address = {0}; const char *path;
  if (argc != 2 || strlen(argv[1]) >= sizeof(address.sun_path)) return 2;
  path = argv[1]; descriptor = socket(AF_UNIX, SOCK_STREAM, 0); if (descriptor < 0) return 3;
  address.sun_family = AF_UNIX; memcpy(address.sun_path, path, strlen(path) + 1);
  unlink(path);
  if (bind(descriptor, (struct sockaddr *)&address, offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1) != 0 || listen(descriptor, 1) != 0) return 4;
  signal(SIGHUP, stop); signal(SIGINT, stop); signal(SIGTERM, stop);
  while (running) pause();
  close(descriptor);
  unlink(path);
  return 0;
}
EOF
cc -Wall -Wextra -Werror "$TEST_BIN/socket-listener.c" -o "$TEST_BIN/socket-listener"
rm -f -- "$TEST_BIN/socket-listener.c"
cat >"$TEST_BIN/setsid-launcher.py" <<'PY'
#!/usr/bin/env python3
import os
import signal
import sys

os.setsid()
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvpe(sys.argv[1], sys.argv[1:], os.environ)
PY
chmod 700 "$TEST_BIN/setsid-launcher.py"

cat >"$TEST_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
readonly fixture="${TEST_PRIVILEGED_FIXTURE:?}"
readonly test_dir="${TEST_IMAGE_E2E_DIR:?}"
log() { printf '%s\n' "$*" >>"$test_dir/ssh.log"; }
log "$@"
if [[ "${11:-}" == -N ]]; then
  [[ $# -eq 14 && "$1" == -o && "$2" == BatchMode=yes && "$3" == -o && "$4" == ConnectTimeout=10 && "$5" == -o && "$6" == ServerAliveInterval=30 && "$7" == -o && "$8" == ServerAliveCountMax=12 && "$9" == -o && "${10}" == ExitOnForwardFailure=yes && "${12}" == -L && "${14}" == test-user@pi.test.invalid ]] || exit 2
  forward="${13}"
  [[ "$forward" =~ ^(/tmp/nextcloud-image-readiness-([0-9]{8}T[0-9]{6}Z-[0-9]+)\.sock):(/run/nextcloud-pi-ops/image-readiness-([0-9]{8}T[0-9]{6}Z-[0-9]+)\.sock)$ ]] || exit 2
  [[ "${BASH_REMATCH[2]}" == "${BASH_REMATCH[4]}" ]] || exit 2
  sudo test -S "$fixture/socket/image-readiness-${BASH_REMATCH[2]}.sock"
  sudo test -d "$fixture/state/image-readiness/${BASH_REMATCH[2]}"
  sudo test -d "$fixture/mount/.readiness-${BASH_REMATCH[2]}"
  [[ ! -e "$test_dir/fail-tunnel" ]] || exit 1
  printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >"$test_dir/tunnel-map"
  exec "$test_dir/bin/socket-listener" "${BASH_REMATCH[1]}"
fi
[[ $# -eq 10 && "$1" == -o && "$2" == BatchMode=yes && "$3" == -o && "$4" == ConnectTimeout=10 && "$5" == -o && "$6" == ServerAliveInterval=30 && "$7" == -o && "$8" == ServerAliveCountMax=12 && "${9}" == test-user@pi.test.invalid ]] || exit 2
command_text="${10}"
read -r -a command_parts <<<"${command_text//\'/}"
[[ "${command_parts[0]:-}" == sudo && "${command_parts[1]:-}" == -n && "${command_parts[2]:-}" == /usr/local/libexec/nextcloud-pi-ops && "${command_parts[3]:-}" == image-readiness ]] || exit 2
action="${command_parts[4]:-}"; id="${command_parts[5]:-}"
[[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || exit 2
case "$action" in
  check)
    [[ ${#command_parts[@]} == 7 && "${command_parts[6]}" =~ ^[0-9]+$ ]] || exit 2
    [[ ! -e "$test_dir/fail-check" ]] || exit 1
    sudo "$fixture/ops" image-readiness check "$id" "${command_parts[6]}"
    ;;
  start|status|stop|cleanup)
    [[ ${#command_parts[@]} == 6 ]] || exit 2
    [[ "$action" != cleanup || ! -e "$test_dir/fail-cleanup" ]] || exit 1
    sudo "$fixture/ops" image-readiness "$action" "$id"
    ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$TEST_BIN/ssh"

cat >"$TEST_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
readonly test_dir="${TEST_IMAGE_E2E_DIR:?}"
host=""
case "${1:-}" in
  -H|--host) host="$2"; shift 2 ;;
esac
[[ -n "$host" && -f "$test_dir/tunnel-map" ]] || exit 2
local_socket="$(awk -F $'\t' 'NR == 1 { print $1 }' "$test_dir/tunnel-map")"
[[ "$host" == "unix://$local_socket" ]] || exit 2
printf '%s\t%s\n' "$host" "$*" >>"$test_dir/docker.log"
case "${1:-}:${2:-}" in
  info:) [[ $# == 1 ]] || exit 2; exit 0 ;;
  ps:-aq) [[ $# == 2 ]] || exit 2; exit 0 ;;
  load:-i)
    [[ $# == 3 && -f "${3:-}" && -f "$test_dir/docker-load.expect" ]] || exit 2
    IFS=$'\t' read -r expected_path expected_hash <"$test_dir/docker-load.expect"
    [[ "${3:-}" == "$expected_path" && "$(sha256sum "$3" | awk '{print $1}')" == "$expected_hash" ]] || exit 2
    [[ ! -e "$test_dir/fail-load" ]] || exit 1
    if [[ -e "$test_dir/block-load" ]]; then
      trap 'exit 130' HUP INT TERM
      : >"$test_dir/load-blocked"
      while :; do sleep 1; done
    fi
    cp "$test_dir/docker-images.expected" "$test_dir/docker-images.loaded"
    ;;
  image:inspect)
    [[ $# == 5 && "${2:-}" == inspect && "${3:-}" == --format && -f "$test_dir/docker-images.loaded" ]] || exit 2
    count=0
    [[ ! -f "$test_dir/inspect-count" ]] || count="$(<"$test_dir/inspect-count")"
    count=$((count + 1)); printf '%s\n' "$count" >"$test_dir/inspect-count"
    if [[ -e "$test_dir/fail-attestation" && "$count" -gt 3 ]]; then
      printf 'sha256:%064d\n' 0
      exit 0
    fi
    awk -F $'\t' -v tag="${5:-}" '$1 == tag { print $2; found=1 } END { exit !found }' "$test_dir/docker-images.loaded"
    ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$TEST_BIN/docker"

sha256() { sha256sum "$1" | awk '{print $1}'; }
write_recovery() {
  local name="$1" archive_sha tag
  RECOVERY="$TEST_DIR/image-recovery-$name"
  mkdir -m 700 "$RECOVERY"
  printf 'synthetic-image-recovery-v1\n' >"$RECOVERY/images.tar"
  chmod 600 "$RECOVERY/images.tar"
  archive_sha="$(sha256 "$RECOVERY/images.tar")"
  {
    printf 'format\timage-recovery-v1\nstate\tcomplete\ntimestamp\t20260915T000000Z\nremote_host\tpi-test\nremote_user\ttest-user\nsource_project\t/srv/nextcloud-docker\nstorage_mount\t/mnt/test-nextcloud\nplatform\t%s\narchive_sha256\t%s\narchive_bytes\t%s\n' "$NEXTCLOUD_IMAGE_PLATFORM" "$archive_sha" "$(wc -c <"$RECOVERY/images.tar" | tr -d '[:space:]')"
    while IFS= read -r tag; do printf 'image\t%s\t%s\n' "$tag" "$(image_lock_expected_id "$tag")"; done < <(image_lock_tags)
  } >"$RECOVERY/manifest.tsv"
  chmod 600 "$RECOVERY/manifest.tsv"
  while IFS= read -r tag; do printf '%s\t%s\n' "$tag" "$(image_lock_expected_id "$tag")"; done < <(image_lock_tags) >"$TEST_DIR/docker-images.expected"
  printf '%s\t%s\n' "$RECOVERY/images.tar" "$archive_sha" >"$TEST_DIR/docker-load.expect"
  bash "$SCRIPT_DIR/verify-image-recovery.sh" "$RECOVERY" >/dev/null
}
reset_scenario() {
  rm -f -- "$TEST_DIR"/{ssh.log,docker.log,tunnel-map,load-blocked,docker-images.loaded,inspect-count,fail-check,fail-tunnel,fail-load,fail-attestation,fail-cleanup,block-load}
  sudo rm -f -- "$PRIVILEGED_FIXTURE"/{fail-start,docker.log} || true
}
wrapper() {
  PATH="$TEST_BIN:$PATH" DOCKER_HOST=unix:///tmp/e2e-inherited-live.sock NEXTCLOUD_REMOTE_PROJECT_DIR=/srv/nextcloud-docker NEXTCLOUD_DEPLOYMENT_ENV_FILE="$CONFIG_FILE" "$WRAPPER" "$@"
}
extract_id() { { cat "$1"; [[ ! -f "$TEST_DIR/ssh.log" ]] || cat "$TEST_DIR/ssh.log"; } | sed -nE 's/.*([0-9]{8}T[0-9]{6}Z-[0-9]+).*/\1/p' | tail -1; }
assert_lifecycle_absent() {
  local id="$1"
  [[ ! -e "/tmp/nextcloud-image-readiness-$id.sock" ]]
  sudo test ! -e "$PRIVILEGED_FIXTURE/mount/.readiness-$id"
  sudo test ! -e "$PRIVILEGED_FIXTURE/state/image-readiness/$id"
  sudo test ! -e "$PRIVILEGED_FIXTURE/socket/image-readiness-$id.sock"
}
assert_failure_absent() { assert_lifecycle_absent "$1"; [[ ! -e "$RECOVERY/restore-attestation.tsv" ]]; }
assert_actions() {
  local expected="$1" actual
  actual="$(sed -nE 's/.*image-readiness (check|start|status|stop|cleanup).*/\1/p' "$TEST_DIR/ssh.log" | paste -sd ' ' -)"
  [[ "$actual" == "$expected" ]]
}
expect_failure() {
  set +e
  wrapper "$@" >"$TEST_DIR/output.log" 2>&1
  status=$?
  set -e
  (( status != 0 ))
}

reset_scenario
write_recovery check-success
wrapper --check "$RECOVERY" >"$TEST_DIR/output.log"
CHECK_ID="$(extract_id "$TEST_DIR/output.log")"
[[ -n "$CHECK_ID" ]]
grep -Fq 'image-readiness check' "$TEST_DIR/ssh.log"
assert_actions check
[[ ! -e "$TEST_DIR/tunnel-map" && ! -e "$TEST_DIR/docker.log" ]]
assert_failure_absent "$CHECK_ID"

reset_scenario
write_recovery check-failure
touch "$TEST_DIR/fail-check"
expect_failure --check "$RECOVERY"
CHECK_ID="$(extract_id "$TEST_DIR/output.log")"
[[ -n "$CHECK_ID" ]]
grep -Fq 'image-readiness check' "$TEST_DIR/ssh.log"
assert_actions check
[[ ! -e "$TEST_DIR/tunnel-map" && ! -e "$TEST_DIR/docker.log" ]]
assert_failure_absent "$CHECK_ID"

reset_scenario
write_recovery apply-success
wrapper --apply "$RECOVERY" >"$TEST_DIR/output.log"
APPLY_ID="$(extract_id "$TEST_DIR/output.log")"
[[ -n "$APPLY_ID" ]]
bash "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$RECOVERY" >/dev/null
[[ "$(stat -c '%a' "$RECOVERY/restore-attestation.tsv")" == 600 ]]
grep -Fq $'unix:///tmp/nextcloud-image-readiness-' "$TEST_DIR/docker.log"
! grep -Fq '/var/run/docker.sock' "$TEST_DIR/docker.log"
assert_actions 'check start status stop cleanup'
sudo cat "$PRIVILEGED_FIXTURE/docker.log" | grep -Fq -- '--host '
assert_lifecycle_absent "$APPLY_ID"

for scenario in start tunnel load attestation; do
  reset_scenario
  write_recovery "$scenario-failure"
  case "$scenario" in
    start) sudo touch "$PRIVILEGED_FIXTURE/fail-start" ;;
    tunnel) touch "$TEST_DIR/fail-tunnel" ;;
    load) touch "$TEST_DIR/fail-load" ;;
    attestation) touch "$TEST_DIR/fail-attestation" ;;
  esac
  expect_failure --apply "$RECOVERY"
  APPLY_ID="$(extract_id "$TEST_DIR/output.log")"
  [[ -n "$APPLY_ID" ]]
  if [[ "$scenario" == load || "$scenario" == attestation ]]; then [[ ! -e "$RECOVERY/restore-attestation.tsv" ]]; fi
  case "$scenario" in
    start) assert_actions 'check start stop cleanup' ;;
    tunnel|load|attestation) assert_actions 'check start status stop cleanup' ;;
  esac
  assert_failure_absent "$APPLY_ID"
done

reset_scenario
write_recovery interruption
touch "$TEST_DIR/block-load" "$TEST_DIR/fail-cleanup"
WRAPPER_PID=""
PATH="$TEST_BIN:$PATH" DOCKER_HOST=unix:///tmp/e2e-inherited-live.sock NEXTCLOUD_REMOTE_PROJECT_DIR=/srv/nextcloud-docker NEXTCLOUD_DEPLOYMENT_ENV_FILE="$CONFIG_FILE" python3 "$TEST_BIN/setsid-launcher.py" "$WRAPPER" --apply "$RECOVERY" >"$TEST_DIR/output.log" 2>&1 &
WRAPPER_PID=$!
for _ in {1..15}; do [[ -e "$TEST_DIR/load-blocked" ]] && break; sleep 1; done
[[ -e "$TEST_DIR/load-blocked" ]]
kill -INT -- "-$WRAPPER_PID"
for _ in {1..15}; do kill -0 "$WRAPPER_PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$WRAPPER_PID" 2>/dev/null; then kill -TERM -- "-$WRAPPER_PID" || true; exit 1; fi
set +e
wait "$WRAPPER_PID"
status=$?
set -e
WRAPPER_PID=""
(( status != 0 ))
APPLY_ID="$(extract_id "$TEST_DIR/output.log")"
[[ -n "$APPLY_ID" ]]
grep -Fq "Retry cleanup with readiness ID: $APPLY_ID" "$TEST_DIR/output.log"
grep -Fq 'image-readiness stop' "$TEST_DIR/ssh.log"
grep -Fq 'image-readiness cleanup' "$TEST_DIR/ssh.log"
assert_actions 'check start status stop cleanup'
sudo test -d "$PRIVILEGED_FIXTURE/state/image-readiness/$APPLY_ID"
rm -f -- "$TEST_DIR/fail-cleanup" "$TEST_DIR/block-load"
wrapper --cleanup "$APPLY_ID" >"$TEST_DIR/cleanup.log"
grep -Fq 'Image restore-readiness cleanup removed isolated state' "$TEST_DIR/cleanup.log"
assert_failure_absent "$APPLY_ID"

printf 'image restore-readiness end-to-end fixture tests passed\n'
