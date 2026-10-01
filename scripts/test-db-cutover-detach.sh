#!/usr/bin/env bash
# Fault-inject root-owned source-container detach before database promotion.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux ]]; then
  printf 'database container-detach fixture is Linux-only\n'
  exit 0
fi
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
export DETACH_ROOT="$fixture"
stage_id=20260927T000000Z-12
export stage_id
source_id="$(printf 'a%.0s' {1..64})"
candidate_id="$(printf 'b%.0s' {1..64})"
export APP_ID="$(printf '1%.0s' {1..64})"
export DB_ID="$(printf '2%.0s' {1..64})"
export CADDY_ID="$(printf '3%.0s' {1..64})"

function_text="$(sed -n '/^cmd_db_cutover_detach() {/,/^}/p' "$root/privileged/nextcloud-pi-ops")"
[[ -n "$function_text" ]] || exit 1
function_text="${function_text//\/usr\/bin\/docker/docker_fake}"
function_text="${function_text//\/usr\/bin\/systemctl/systemctl_fake}"
eval "$function_text"

maybe_fail() {
  local side="$1" action="$2"
  if [[ -f "$DETACH_ROOT/fail-once" && "$(<"$DETACH_ROOT/fail-once")" == "$side-$action" ]]; then
    rm -- "$DETACH_ROOT/fail-once"
    return 1
  fi
}
container_key() {
  case "$1" in
    nextcloud-docker-app-1) printf app ;;
    nextcloud-docker-db-1) printf db ;;
    nextcloud-docker-caddy-1) printf caddy ;;
    *) return 1 ;;
  esac
}
container_id() {
  case "$1" in app) printf '%s' "$APP_ID";; db) printf '%s' "$DB_ID";; caddy) printf '%s' "$CADDY_ID";; esac
}
docker_fake() {
  local command="$1" key name format
  shift
  case "$command" in
    inspect)
      [[ "$1" == --format ]] || return 2
      format="$2"; name="$3"; key="$(container_key "$name")" || return 1
      [[ -f "$DETACH_ROOT/$key.present" ]] || return 1
      case "$format" in
        '{{.Id}}') printf '%s\n' "$(container_id "$key")" ;;
        '{{.Id}} {{.State.Running}}') printf '%s %s\n' "$(container_id "$key")" "$(<"$DETACH_ROOT/$key.running")" ;;
        '{{.State.ExitCode}}') printf '0\n' ;;
        *) return 2 ;;
      esac
      ;;
    update)
      [[ "$1" == --restart=no ]] || return 2
      key="$(container_key "$2")" || return 1
      maybe_fail before "update-$key" || return 1
      printf 'no\n' >"$DETACH_ROOT/$key.restart"
      maybe_fail after "update-$key" || return 1
      ;;
    stop)
      [[ "$1" == --time && "$2" == 120 ]] || return 2
      key="$(container_key "$3")" || return 1
      maybe_fail before "stop-$key" || return 1
      printf 'false\n' >"$DETACH_ROOT/$key.running"
      maybe_fail after "stop-$key" || return 1
      ;;
    rm)
      key="$(container_key "$1")" || return 1
      maybe_fail before "rm-$key" || return 1
      rm -- "$DETACH_ROOT/$key.present"
      maybe_fail after "rm-$key" || return 1
      ;;
    *) return 2 ;;
  esac
}
systemctl_fake() {
  [[ "$1" == stop && "$2" == nextcloud.service ]] || return 2
  maybe_fail before systemctl || return 1
  printf 'inactive\n' >"$DETACH_ROOT/service-state"
  maybe_fail after systemctl || return 1
}
invalid() { printf 'invalid detach fixture invocation\n' >&2; exit 2; }
die() { printf '%s\n' "$1" >&2; exit 1; }
reject_stdin() { :; }
lock() { :; }
validate_host() { :; }
db_cutover_require() { :; }
db_cutover_stage_bound() { :; }
upgrade_stage_field() { printf prepared; }
db_cutover_field() {
  case "$2" in
    phase) <"$DETACH_ROOT/phase" tr -d '\n' ;;
    pre_record_sha256) printf '%s' "$SOURCE_HASH" ;;
    pre_compose_sha256) printf '%s' "$COMPOSE_HASH" ;;
    source_inode) printf '%s' "$SOURCE_INODE" ;;
    candidate_inode) printf '%s' "$CANDIDATE_INODE" ;;
    candidate_digest) printf '%s' "$CANDIDATE_DIGEST" ;;
    app_container_id) printf '%s' "$APP_ID" ;;
    db_container_id) printf '%s' "$DB_ID" ;;
    caddy_container_id) printf '%s' "$CADDY_ID" ;;
    *) invalid ;;
  esac
}
db_cutover_rewrite() { printf '%s\n' "$2" >"$DETACH_ROOT/phase"; }
db_cutover_inode() { stat -c '%d:%i' "$1"; }
db_cutover_path() { printf '%s/storage/.db-cutover-%s/data' "$DETACH_ROOT" "$1"; }
db_cutover_digest() { sha256sum "$1/identity" | awk '{print $1}'; }
db_cutover_old_objects_absent() {
  local key
  for key in app db caddy; do [[ ! -f "$DETACH_ROOT/$key.present" ]] || die "old container remains"; done
}
live_hash() { printf '%s' "$SOURCE_HASH"; }
upgrade_stage_compose_hash() { printf '%s' "$COMPOSE_HASH"; }
available() { printf '1000000'; }
db_cutover_space_required() { printf '100'; }
out() { :; }

for function_name in cmd_db_cutover_detach maybe_fail container_key container_id docker_fake \
                     systemctl_fake invalid die reject_stdin lock validate_host db_cutover_require \
                     db_cutover_stage_bound upgrade_stage_field db_cutover_field db_cutover_rewrite \
                     db_cutover_inode db_cutover_path db_cutover_digest db_cutover_old_objects_absent \
                     live_hash upgrade_stage_compose_hash available db_cutover_space_required out; do
  export -f "$function_name"
done
export SOURCE_HASH="$source_id" COMPOSE_HASH="$candidate_id"

for failure in before-update-app after-update-app before-systemctl after-systemctl \
               before-stop-app after-stop-app before-rm-app after-rm-app \
               before-stop-db after-stop-db before-rm-db after-rm-db \
               before-stop-caddy after-stop-caddy before-rm-caddy after-rm-caddy; do
  for key in app db caddy; do
    printf 'yes\n' >"$fixture/$key.present"
    printf 'true\n' >"$fixture/$key.running"
    printf 'always\n' >"$fixture/$key.restart"
  done
  rm -rf -- "$fixture/storage"
  mkdir -p "$fixture/storage/nextcloud_db" "$fixture/storage/.db-cutover-$stage_id/data"
  printf 'original\n' >"$fixture/storage/nextcloud_db/identity"
  printf 'imported\n' >"$fixture/storage/.db-cutover-$stage_id/data/identity"
  export SOURCE_INODE="$(db_cutover_inode "$fixture/storage/nextcloud_db")"
  export CANDIDATE_INODE="$(db_cutover_inode "$fixture/storage/.db-cutover-$stage_id/data")"
  export CANDIDATE_DIGEST="$(db_cutover_digest "$fixture/storage/.db-cutover-$stage_id/data")"
  printf 'prepared\n' >"$fixture/phase"
  printf 'active\n' >"$fixture/service-state"
  printf '%s\n' "$failure" >"$fixture/fail-once"
  if bash -e -c 'declare -A P=([NEXTCLOUD_PI_STORAGE_MOUNT]="$DETACH_ROOT/storage" [NEXTCLOUD_PI_APP_CONTAINER]=nextcloud-docker-app-1 [NEXTCLOUD_PI_DB_CONTAINER]=nextcloud-docker-db-1 [NEXTCLOUD_PI_CADDY_CONTAINER]=nextcloud-docker-caddy-1 [NEXTCLOUD_PI_SERVICE_NAME]=nextcloud.service); cmd_db_cutover_detach "$stage_id" fingerprint stage-fingerprint' >/dev/null 2>&1; then
    printf 'detach unexpectedly passed injected %s failure\n' "$failure" >&2
    exit 1
  fi
  [[ "$(<"$fixture/phase")" == detaching ]]
  [[ "$(<"$fixture/storage/nextcloud_db/identity")" == original ]]
  [[ "$(<"$fixture/storage/.db-cutover-$stage_id/data/identity")" == imported ]]
  bash -e -c 'declare -A P=([NEXTCLOUD_PI_STORAGE_MOUNT]="$DETACH_ROOT/storage" [NEXTCLOUD_PI_APP_CONTAINER]=nextcloud-docker-app-1 [NEXTCLOUD_PI_DB_CONTAINER]=nextcloud-docker-db-1 [NEXTCLOUD_PI_CADDY_CONTAINER]=nextcloud-docker-caddy-1 [NEXTCLOUD_PI_SERVICE_NAME]=nextcloud.service); cmd_db_cutover_detach "$stage_id" fingerprint stage-fingerprint' >/dev/null
  [[ "$(<"$fixture/phase")" == detached ]]
  for key in app db caddy; do [[ ! -f "$fixture/$key.present" ]]; done
  [[ "$(<"$fixture/storage/nextcloud_db/identity")" == original ]]
done

printf 'database container-detach interruption fixture passed\n'
