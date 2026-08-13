#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR="$(mktemp -d)"
TEST_PHASE=setup
cleanup() {
  local status=$?
  rm -rf "$TEST_DIR"
  (( status == 0 )) || printf 'image-import transaction test failed in phase: %s\n' "$TEST_PHASE" >&2
  exit "$status"
}
trap cleanup EXIT
IMAGE_IMPORT_LIBRARY_ONLY=1 source "$SCRIPT_DIR/lib/image-import-remote.sh"
source "$SCRIPT_DIR/lib/image-import-approval.sh"
source "$SCRIPT_DIR/lib/image-import-transfer.sh"

IMAGE_IMPORT_STAGE="$TEST_DIR/stage"
IMAGE_IMPORT_PROJECT="$TEST_DIR/nextcloud-docker"
IMAGE_IMPORT_APP_TAG=nextcloud:30
IMAGE_IMPORT_DB_TAG=mariadb:11
IMAGE_IMPORT_CADDY_TAG=caddy:2
mkdir -p "$IMAGE_IMPORT_STAGE" "$IMAGE_IMPORT_PROJECT" "$TEST_DIR/tags"
prior_app=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
prior_db=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
prior_caddy=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
recovered_app=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
recovered_db=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
recovered_caddy=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

tag_file() { printf '%s/%s' "$TEST_DIR/tags" "$(printf '%s' "$1" | tr '/:' '__')"; }
write_tag() { printf '%s\n' "$2" >"$(tag_file "$1")"; }
read_tag() { cat "$(tag_file "$1")"; }
reset_fixture() {
  write_tag "$IMAGE_IMPORT_APP_TAG" "$prior_app"; write_tag "$IMAGE_IMPORT_DB_TAG" "$prior_db"; write_tag "$IMAGE_IMPORT_CADDY_TAG" "$prior_caddy"
  printf 'mode=source\n' >"$TEST_DIR/active.env"; printf 'running\n' >"$TEST_DIR/containers"; : >"$TEST_DIR/systemctl.log"; printf '0\n' >"$TEST_DIR/start-count"
  : >"$IMAGE_IMPORT_STAGE/images.tar"; printf 'mode=recovered\n' >"$IMAGE_IMPORT_STAGE/recovered.env"
  printf 'image\t%s\t%s\nimage\t%s\t%s\nimage\t%s\t%s\n' "$IMAGE_IMPORT_APP_TAG" "$recovered_app" "$IMAGE_IMPORT_DB_TAG" "$recovered_db" "$IMAGE_IMPORT_CADDY_TAG" "$recovered_caddy" >"$IMAGE_IMPORT_STAGE/restore-attestation.tsv"
  rm -f "$IMAGE_IMPORT_STAGE/failure.tsv" "$IMAGE_IMPORT_STAGE/prior-active.env" "$IMAGE_IMPORT_STAGE/prior-tags.tsv"
}

sudo() {
  [[ "$1" == -n ]] && shift
  if [[ "$1 $2" == 'systemctl stop' ]]; then printf 'stop\n' >>"$TEST_DIR/systemctl.log"; return 0; fi
  if [[ "$1 $2" == 'systemctl start' ]]; then
    count="$(cat "$TEST_DIR/start-count")"; count=$((count + 1)); printf '%s\n' "$count" >"$TEST_DIR/start-count"; printf 'start\n' >>"$TEST_DIR/systemctl.log"
    if [[ "$SCENARIO" == restart_failure && "$count" == 1 ]]; then return 1; fi
    printf 'running\n' >"$TEST_DIR/containers"; return 0
  fi
  if [[ "$1 $2" == 'systemctl is-active' ]]; then printf 'inactive\n'; return 3; fi
  if [[ "$1" == cp ]]; then cp "$TEST_DIR/active.env" "$IMAGE_IMPORT_STAGE/prior-active.env"; return 0; fi
  if [[ "$1" == install ]]; then
    source_file="${@: -2:1}"
    if [[ "$SCENARIO" == active_record_failure && "$source_file" == *recovered.env ]]; then return 1; fi
    cp "$source_file" "$TEST_DIR/active.env"; return 0
  fi
  "$@"
}
docker() {
  if [[ "$1 $2" == 'compose down' ]]; then
    if [[ "$SCENARIO" == rollback_down_failure ]]; then return 1; fi
    : >"$TEST_DIR/containers"; return 0
  fi
  if [[ "$1 $2" == 'rm -f' ]]; then : >"$TEST_DIR/containers"; return 0; fi
  if [[ "$1" == inspect ]]; then [[ -s "$TEST_DIR/containers" ]]; return $?; fi
  if [[ "$1 $2" == 'image inspect' ]]; then read_tag "${@: -1}"; return 0; fi
  if [[ "$1" == load ]]; then
    write_tag "$IMAGE_IMPORT_APP_TAG" "$recovered_app"
    if [[ "$SCENARIO" == partial_load ]]; then return 1; fi
    if [[ "$SCENARIO" == interrupted ]]; then kill -TERM "$BASHPID"; return 1; fi
    write_tag "$IMAGE_IMPORT_DB_TAG" "$recovered_db"; write_tag "$IMAGE_IMPORT_CADDY_TAG" "$recovered_caddy"
    if [[ "$SCENARIO" == mapping_mismatch ]]; then write_tag "$IMAGE_IMPORT_CADDY_TAG" "$prior_caddy"; fi
    return 0
  fi
  if [[ "$1" == tag ]]; then write_tag "$3" "$2"; return 0; fi
  return 2
}
assert_prior_restored() {
  [[ "$(read_tag "$IMAGE_IMPORT_APP_TAG")" == "$prior_app" ]] || { echo 'app tag was not restored' >&2; return 1; }
  [[ "$(read_tag "$IMAGE_IMPORT_DB_TAG")" == "$prior_db" ]] || { echo 'db tag was not restored' >&2; return 1; }
  [[ "$(read_tag "$IMAGE_IMPORT_CADDY_TAG")" == "$prior_caddy" ]] || { echo 'caddy tag was not restored' >&2; return 1; }
  [[ "$(cat "$TEST_DIR/active.env")" == mode=source ]] || { echo 'active record was not restored' >&2; return 1; }
  if [[ ! -s "$TEST_DIR/containers" ]]; then
    printf 'containers were not restarted; systemctl-log=%s start-count=%s\n' "$(tr '\n' ',' <"$TEST_DIR/systemctl.log")" "$(cat "$TEST_DIR/start-count")" >&2
    return 1
  fi
  grep -F $'state\tfailed' "$IMAGE_IMPORT_STAGE/failure.tsv" >/dev/null || { echo 'failure record was not preserved' >&2; return 1; }
}

for SCENARIO in partial_load interrupted mapping_mismatch active_record_failure restart_failure; do
  TEST_PHASE="failure-$SCENARIO"
  export SCENARIO; reset_fixture
  set +e
  (set -e; image_import_apply) >"$TEST_DIR/$SCENARIO.log" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "expected image import failure: $SCENARIO" >&2; exit 1; }
  if ! assert_prior_restored; then
    sed 's/^/transaction: /' "$TEST_DIR/$SCENARIO.log" >&2
    exit 1
  fi
done
TEST_PHASE=success
SCENARIO=success; export SCENARIO; reset_fixture; image_import_apply
[[ "$(read_tag "$IMAGE_IMPORT_APP_TAG")" == "$recovered_app" && "$(read_tag "$IMAGE_IMPORT_DB_TAG")" == "$recovered_db" && "$(read_tag "$IMAGE_IMPORT_CADDY_TAG")" == "$recovered_caddy" ]]
[[ "$(cat "$TEST_DIR/active.env")" == mode=recovered && ! -e "$IMAGE_IMPORT_STAGE/failure.tsv" ]]
image_import_rollback
assert_prior_restored

TEST_PHASE=rollback-down-failure
SCENARIO=success; reset_fixture; image_import_apply
SCENARIO=rollback_down_failure; export SCENARIO
image_import_rollback
assert_prior_restored

approval="$TEST_DIR/approval.tsv"
TEST_PHASE=approval-replay
printf 'format\timage-import-approval-v1\nstate\tunused\n' >"$approval"
IMAGE_IMPORT_APPROVAL_LOCK=""
image_import_consume_approval "$approval"
grep -Fx $'state\tconsumed' "$approval" >/dev/null
if image_import_consume_approval "$approval"; then
  echo 'consumed image-import approval was replayable' >&2
  exit 1
fi
[[ -z "$IMAGE_IMPORT_APPROVAL_LOCK" && ! -e "$approval.lock" && ! -e "$approval.consumed" ]]

for consume_failure in chmod mv; do
  TEST_PHASE="approval-$consume_failure-failure"
  printf 'format\timage-import-approval-v1\nstate\tunused\n' >"$approval"
  CONSUME_FAILURE="$consume_failure"
  chmod() { [[ "$CONSUME_FAILURE" != chmod ]] || return 1; command chmod "$@"; }
  mv() { [[ "$CONSUME_FAILURE" != mv ]] || return 1; command mv "$@"; }
  if image_import_consume_approval "$approval"; then
    echo "approval consumption ignored $consume_failure failure" >&2
    exit 1
  fi
  grep -Fx $'state\tunused' "$approval" >/dev/null
  [[ -z "$IMAGE_IMPORT_APPROVAL_LOCK" && ! -e "$approval.lock" && ! -e "$approval.consumed" ]]
  unset -f chmod mv
done

transfer_stage=/srv/nextcloud-docker/.image-import-test
TEST_PHASE=transfer-cleanup
transfer_log="$TEST_DIR/transfer.log"
remote() {
  printf 'remote:%s\n' "$1" >>"$transfer_log"
  return 0
}
scp() { printf 'scp\n' >>"$transfer_log"; return 1; }
: >"$transfer_log"
if image_import_stage_payload "$transfer_stage" "$TEST_DIR/recovery" "$TEST_DIR/recovered.env" "$TEST_DIR/helper.sh" test@pi; then
  echo 'expected image-import transfer failure' >&2
  exit 1
fi
grep -Fx "remote:rm -rf '$transfer_stage' && test ! -e '$transfer_stage'" "$transfer_log" >/dev/null
[[ "$(grep -Fxc scp "$transfer_log")" == 1 ]]
TEST_PHASE=complete
echo 'image import failure and rollback tests passed'
