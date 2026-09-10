#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_ROOT/lib/image-import-lifecycle.sh"

readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
SCRIPT_DIR="$TEST_DIR/scripts"
IMAGE_IMPORT_REMOTE_STAGE=/srv/nextcloud-docker/.image-import-20260910T000000Z-123
IMAGE_IMPORT_TRANSACTION_ID=20260910T000000Z-123
NEXTCLOUD_REMOTE_PROJECT_DIR=/srv/nextcloud-docker
NEXTCLOUD_IMAGE_APP_TAG=nextcloud:30
NEXTCLOUD_IMAGE_DB_TAG=mariadb:11
NEXTCLOUD_IMAGE_CADDY_TAG=caddy:2
NEXTCLOUD_IMAGE_PLATFORM=linux/arm64/v8
TEST_SCENARIO=success
TEST_LOG="$TEST_DIR/lifecycle.log"

remote() {
  local command="$1" action
  case "$command" in
    *"image-import-remote.sh' 'rollback'"*) action=rollback ;;
    *"image-import-remote.sh' 'commit'"*) action=commit ;;
    "rm -rf '$IMAGE_IMPORT_REMOTE_STAGE'"*) action=remove-stage ;;
    *) action=unexpected ;;
  esac
  printf '%s\n' "$action" >>"$TEST_LOG"
  case "$TEST_SCENARIO:$action" in
    rollback-failure:rollback|commit-failure:commit|cleanup-failure:remove-stage) return 1 ;;
  esac
}

bash() {
  if [[ "${1:-}" == "$SCRIPT_DIR/health-check.sh" ]]; then
    printf 'health\n' >>"$TEST_LOG"
    [[ "$TEST_SCENARIO" != health-failure ]]
    return
  fi
  command bash "$@"
}

assert_log() {
  local expected="$1"
  [[ "$(paste -sd, "$TEST_LOG")" == "$expected" ]] || {
    printf 'unexpected interruption recovery sequence: %s\n' "$(paste -sd, "$TEST_LOG")" >&2
    return 1
  }
}

for TEST_SCENARIO in success rollback-failure health-failure commit-failure cleanup-failure; do
  : >"$TEST_LOG"
  if [[ "$TEST_SCENARIO" == success ]]; then
    image_import_recover
    assert_log rollback,health,commit,remove-stage
  else
    if image_import_recover; then
      printf 'expected image-import recovery failure: %s\n' "$TEST_SCENARIO" >&2
      exit 1
    fi
    case "$TEST_SCENARIO" in
      rollback-failure|health-failure) assert_log rollback,health ;;
      commit-failure) assert_log rollback,health,commit ;;
      cleanup-failure) assert_log rollback,health,commit,remove-stage ;;
    esac
  fi
done

: >"$TEST_LOG"
if image_import_remote_action invalid; then
  printf 'invalid image-import lifecycle action was accepted\n' >&2
  exit 1
fi
[[ ! -s "$TEST_LOG" ]]
printf 'image-import interruption recovery tests passed\n'
