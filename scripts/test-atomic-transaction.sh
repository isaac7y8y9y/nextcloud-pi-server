#!/usr/bin/env bash
set -euo pipefail

# Exercise the same atomic primitive staged by production deployment while
# injecting each material post-replacement failure deterministically.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$SCRIPT_DIR/lib/atomic-transaction.sh"
source "$SCRIPT_DIR/lib/deployment-transaction.sh"

stat() {
  if [[ "$(uname -s)" == Darwin && "$1" == -c ]]; then
    case "$2" in
      %u) /usr/bin/stat -f '%u' "$3" ;;
      %g) /usr/bin/stat -f '%g' "$3" ;;
      %a) /usr/bin/stat -f '%Lp' "$3" ;;
      *) return 2 ;;
    esac
  else
    /usr/bin/stat "$@"
  fi
}
mode_of() {
  if [[ "$(uname -s)" == Darwin ]]; then
    /usr/bin/stat -f '%Lp' "$1"
  else
    /usr/bin/stat -c '%a' "$1"
  fi
}
sudo() {
  [[ "$1" == -n ]] && shift
  "$@"
}

printf 'backup\n' >"$TEST_DIR/backup"
printf 'candidate\n' >"$TEST_DIR/candidate"
printf 'backup\n' >"$TEST_DIR/target"
chmod 600 "$TEST_DIR/target"

reset_transaction() {
  printf 'backup\n' >"$TEST_DIR/target"
  : >"$TEST_DIR/operations"
  restart_count=0
  daemon_count=0
}
operation() { printf '%s\n' "$1" >>"$TEST_DIR/operations"; }
deployment_safety_validate() { operation safety-validate; [[ "$FAIL_AT" != native-validation ]]; }
deployment_safety_install() {
  operation safety-install
  atomic_replace_preserve "$TEST_DIR/candidate" "$TEST_DIR/target" 0600
  [[ "$FAIL_AT" != safety-install ]]
}
deployment_safety_restore() { operation safety-restore; atomic_replace_preserve "$TEST_DIR/backup" "$TEST_DIR/target" 0600; }
deployment_daemon_reload() { operation daemon-reload; daemon_count=$((daemon_count + 1)); [[ "$FAIL_AT" != daemon-reload || "$daemon_count" -gt 1 ]]; }
deployment_application_install() { operation application-install; atomic_replace_preserve "$TEST_DIR/candidate" "$TEST_DIR/target" 0600; [[ "$FAIL_AT" != application-install ]]; }
deployment_restart() { operation restart; restart_count=$((restart_count + 1)); [[ "$FAIL_AT" != restart || "$restart_count" -gt 1 ]]; }
deployment_health() { operation health; [[ "$FAIL_AT" != health ]]; }
deployment_application_restore() { operation application-restore; atomic_replace_preserve "$TEST_DIR/backup" "$TEST_DIR/target" 0600; }
deployment_rollback_health() { operation rollback-health; [[ "$FAIL_AT" != rollback-health ]]; }

for FAIL_AT in native-validation safety-install daemon-reload; do
  reset_transaction
  if deployment_run_safety_transaction; then
    echo "expected safety transaction failure: $FAIL_AT" >&2
    exit 1
  fi
  cmp -s "$TEST_DIR/target" "$TEST_DIR/backup"
  if [[ "$FAIL_AT" == native-validation ]]; then
    [[ "$(cat "$TEST_DIR/operations")" == safety-validate ]]
  else
    grep -Fx safety-restore "$TEST_DIR/operations" >/dev/null
    [[ "$(grep -Fxc daemon-reload "$TEST_DIR/operations")" -ge 1 ]]
  fi
done

for FAIL_AT in application-install restart health; do
  reset_transaction
  if deployment_run_application_transaction; then
    echo "expected application transaction failure: $FAIL_AT" >&2
    exit 1
  fi
  cmp -s "$TEST_DIR/target" "$TEST_DIR/backup"
  [[ "$(grep -Fxc application-restore "$TEST_DIR/operations")" == 1 ]]
  [[ "$(grep -Fxc daemon-reload "$TEST_DIR/operations")" == 1 ]]
  grep -Fx rollback-health "$TEST_DIR/operations" >/dev/null
done

FAIL_AT=success; reset_transaction
deployment_run_application_transaction
cmp -s "$TEST_DIR/target" "$TEST_DIR/candidate"
[[ "$(cat "$TEST_DIR/operations")" == $'application-install\nrestart\nhealth' ]]
[[ "$(mode_of "$TEST_DIR/target")" == 600 ]]

# A failed privileged install must remove its exact temporary path and leave
# an existing target unchanged.
printf 'original\n' >"$TEST_DIR/safety-target"
sudo() {
  [[ "$1" == -n ]] && shift
  if [[ "$1" == mv ]]; then return 1; fi
  "$@"
}
if atomic_install_root "$TEST_DIR/candidate" "$TEST_DIR/safety-target" 0600; then
  echo 'expected atomic safety install failure' >&2
  exit 1
fi
[[ "$(cat "$TEST_DIR/safety-target")" == original ]]
[[ -z "$(find "$TEST_DIR" -maxdepth 1 -name '.nextcloud-pi-safety-target.*.new' -print -quit)" ]]
echo 'shared atomic transaction failure tests passed'
