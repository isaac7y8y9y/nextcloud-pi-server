#!/usr/bin/env bash
# Exercise the non-database recovery detach and boot/startup checkpoints.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux ]]; then
  printf 'runtime recovery startup fixture is Linux-only\n'
  exit 0
fi
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
export RECOVERY_FIXTURE="$fixture" RECOVERY_STAGE=20260929T000000Z-71
fingerprint="$(printf 'a%.0s' {1..64})"
export RECOVERY_FINGERPRINT="$fingerprint"

for name in recovery_non_db_objects_absent recovery_non_db_write cmd_recovery_detach \
            runtime_recovery_startup_guard cmd_upgrade_freeze_boot_guard cmd_recovery_source_ready \
            cmd_recovery_promote; do
  definition="$(sed -n "/^${name}() {/,/^}/p" "$root/privileged/nextcloud-pi-ops")"
  [[ -n "$definition" ]] || exit 1
  definition="${definition//\/usr\/bin\/docker/docker_fake}"
  definition="${definition//\/usr\/bin\/systemctl/systemctl_fake}"
  definition="${definition//\/usr\/bin\/cp/cp_fake}"
  definition="${definition//\/usr\/bin\/install/install_fake}"
  eval "$definition"
done
definition="$(sed -n '/^recovery_promote_pair() {/,/^}/p' "$root/privileged/nextcloud-pi-ops")"
[[ -n "$definition" ]] || exit 1
eval "${definition/recovery_promote_pair()/recovery_promote_pair_original()}"
recovery_promote_pair() {
  local count
  count="$(<"$RECOVERY_FIXTURE/promote-count")"; count=$((count + 1))
  printf '%s\n' "$count" >"$RECOVERY_FIXTURE/promote-count"
  if [[ "$count" == 2 && -f "$RECOVERY_FIXTURE/promote-fail-once" ]]; then
    rm "$RECOVERY_FIXTURE/promote-fail-once"
    return 1
  fi
  recovery_promote_pair_original "$@"
}

container_key() {
  case "$1" in nextcloud-docker-app-1) printf app;; nextcloud-docker-db-1) printf db;; nextcloud-docker-caddy-1) printf caddy;; *) return 1;; esac
}
container_id() { case "$1" in app) printf '%.0s1' {1..64};; db) printf '%.0s2' {1..64};; caddy) printf '%.0s3' {1..64};; esac; }
image_id() { case "$1" in app) printf 'sha256:%.0s4' {1..64};; db) printf 'sha256:%.0s5' {1..64};; caddy) printf 'sha256:%.0s6' {1..64};; esac; }
docker_fake() {
  local operation="$1" key name format
  shift
  case "$operation" in
    info) return 0 ;;
    inspect)
      if [[ "${1:-}" == --format ]]; then format="$2"; name="$3"; else format=''; name="$1"; fi
      key="$(container_key "$name")" || return 1
      [[ -f "$RECOVERY_FIXTURE/$key.present" ]] || return 1
      if [[ "$format" == *'.Image'* ]]; then
        printf '%s %s %s nextcloud-docker\n' "$(container_id "$key")" "$(image_id "$key")" "$(<"$RECOVERY_FIXTURE/$key.running")"
      elif [[ "$format" == *'RestartPolicy.Name'* ]]; then
        printf '%s %s %s\n' "$(container_id "$key")" "$(<"$RECOVERY_FIXTURE/$key.running")" "$(<"$RECOVERY_FIXTURE/$key.restart")"
      fi
      ;;
    update)
      [[ "$1" == --restart=no ]] || return 2
      key="$(container_key "$2")"; printf 'no\n' >"$RECOVERY_FIXTURE/$key.restart"
      ;;
    rm)
      key="$(container_key "$1")"
      if [[ "$key" == db && -f "$RECOVERY_FIXTURE/fail-once" ]]; then rm "$RECOVERY_FIXTURE/fail-once"; return 1; fi
      rm "$RECOVERY_FIXTURE/$key.present"
      ;;
    *) return 2 ;;
  esac
}
systemctl_fake() {
  case "$1" in
    stop) printf 'inactive\n' >"$RECOVERY_FIXTURE/service" ;;
    is-active) printf 'inactive\n' ;;
    *) return 2 ;;
  esac
}
cp_fake() {
  /usr/bin/cp "$@"
  if [[ -f "$RECOVERY_FIXTURE/copy-fail-once" ]]; then
    rm "$RECOVERY_FIXTURE/copy-fail-once"
    return 1
  fi
}
install_fake() {
  local arguments=()
  while (( $# )); do
    case "$1" in
      -o|-g) shift 2 ;;
      *) arguments+=("$1"); shift ;;
    esac
  done
  /usr/bin/install "${arguments[@]}"
}
metadata() { awk -F $'\t' -v wanted="$2" '$1 == wanted {print $2; found=1; exit} END {if (!found) exit 1}' "$1"; }
upgrade_stage_file() { printf '%s/stage.tsv' "$RECOVERY_FIXTURE"; }
upgrade_stage_field() { metadata "$(upgrade_stage_file)" "$2"; }
upgrade_stage_require() { protected_file "$(upgrade_stage_file)" 0600; }
recovery_state() { printf '%s/runtime-recovery/%s' "$RECOVERY_FIXTURE" "$1"; }
recovery_root() { printf '%s/storage/.recovery-%s' "$RECOVERY_FIXTURE" "$1"; }
safe_recovery_root() { safe_dir "$1"; }
no_nested_mounts() { :; }
freeze_root() { printf '%s/freeze-absent' "$RECOVERY_FIXTURE"; }
freeze_current() { printf '%s/current-absent' "$RECOVERY_FIXTURE"; }
db_cutover_boot_guard() { :; }
valid_id() { [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; }
valid_hash() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
protected_file() { [[ -f "$1" && ! -L "$1" ]]; }
safe_dir() { [[ -d "$1" && ! -L "$1" ]]; }
lock() { :; }
validate_host() { :; }
reject_stdin() { :; }
live_hash() { printf '%s' "$(printf 'b%.0s' {1..64})"; }
upgrade_stage_compose_hash() { printf '%s' "$(printf 'c%.0s' {1..64})"; }
out() { :; }
invalid() { return 2; }
die() { printf '%s\n' "$1" >&2; return 1; }

mkdir -p "$fixture/runtime-recovery/$RECOVERY_STAGE" "$fixture/storage/nextcloud" \
  "$fixture/storage/nextcloud_db" "$fixture/caddy-data" "$fixture/caddy-config"
printf 'format\tupgrade-stage-v1\nid\t%s\nphase\truntime-may-have-changed\ntarget\tapp\nfingerprint\t%s\npre_record_sha256\t%s\npre_compose_sha256\t%s\n' \
  "$RECOVERY_STAGE" "$fingerprint" "$(printf 'b%.0s' {1..64})" "$(printf 'c%.0s' {1..64})" >"$fixture/stage.tsv"
printf 'format\truntime-recovery-v1\nstate\tprepared\nstage_id\t%s\ncaddy_data_path\t%s\ncaddy_config_path\t%s\n' \
  "$RECOVERY_STAGE" "$fixture/caddy-data" "$fixture/caddy-config" >"$fixture/runtime-recovery/$RECOVERY_STAGE/metadata.tsv"
for item in nextcloud caddy-data caddy-config database; do printf 'complete\n' >"$fixture/runtime-recovery/$RECOVERY_STAGE/$item.complete"; done
for key in app db caddy; do
  printf 'yes\n' >"$fixture/$key.present"
  printf 'false\n' >"$fixture/$key.running"
  printf 'always\n' >"$fixture/$key.restart"
done
printf 'NEXTCLOUD_ACTIVE_IMAGES_APP_ID=%s\nNEXTCLOUD_ACTIVE_IMAGES_DB_ID=%s\nNEXTCLOUD_ACTIVE_IMAGES_CADDY_ID=%s\n' \
  "$(image_id app)" "$(image_id db)" "$(image_id caddy)" >"$fixture/active-images.env"
chmod 600 "$fixture/stage.tsv" "$fixture/runtime-recovery/$RECOVERY_STAGE/metadata.tsv" "$fixture/runtime-recovery/$RECOVERY_STAGE/"*.complete
export ACTIVE_RECORD="$fixture/active-images.env"
freeze_table=nextcloud_pi_upgrade

for function_name in recovery_non_db_objects_absent recovery_non_db_write cmd_recovery_detach \
  runtime_recovery_startup_guard cmd_upgrade_freeze_boot_guard cmd_recovery_source_ready \
  cmd_recovery_promote recovery_promote_pair recovery_promote_pair_original \
  container_key container_id image_id docker_fake systemctl_fake cp_fake install_fake metadata upgrade_stage_file \
  upgrade_stage_field upgrade_stage_require recovery_state recovery_root safe_recovery_root no_nested_mounts freeze_root freeze_current \
  db_cutover_boot_guard valid_id valid_hash protected_file safe_dir lock validate_host \
  reject_stdin live_hash upgrade_stage_compose_hash out invalid die; do export -f "$function_name"; done

run_detach() {
  bash -e -c 'declare -A P=([NEXTCLOUD_PI_STATE_ROOT]="$RECOVERY_FIXTURE" [NEXTCLOUD_PI_STORAGE_MOUNT]="$RECOVERY_FIXTURE/storage" [NEXTCLOUD_PI_PROJECT_DIR]="$RECOVERY_FIXTURE/nextcloud-docker" [NEXTCLOUD_PI_APP_CONTAINER]=nextcloud-docker-app-1 [NEXTCLOUD_PI_DB_CONTAINER]=nextcloud-docker-db-1 [NEXTCLOUD_PI_CADDY_CONTAINER]=nextcloud-docker-caddy-1 [NEXTCLOUD_PI_SERVICE_NAME]=nextcloud.service); cmd_recovery_detach "$RECOVERY_STAGE" "$RECOVERY_FINGERPRINT"' >/dev/null
}
run_boot_guard() {
  bash -e -c 'declare -A P=([NEXTCLOUD_PI_STATE_ROOT]="$RECOVERY_FIXTURE" [NEXTCLOUD_PI_STORAGE_MOUNT]="$RECOVERY_FIXTURE/storage" [NEXTCLOUD_PI_PROJECT_DIR]="$RECOVERY_FIXTURE/nextcloud-docker" [NEXTCLOUD_PI_APP_CONTAINER]=nextcloud-docker-app-1 [NEXTCLOUD_PI_DB_CONTAINER]=nextcloud-docker-db-1 [NEXTCLOUD_PI_CADDY_CONTAINER]=nextcloud-docker-caddy-1); cmd_upgrade_freeze_boot_guard' >/dev/null
}
run_startup_guard() {
  bash -e -c 'declare -A P=([NEXTCLOUD_PI_STATE_ROOT]="$RECOVERY_FIXTURE" [NEXTCLOUD_PI_STORAGE_MOUNT]="$RECOVERY_FIXTURE/storage" [NEXTCLOUD_PI_PROJECT_DIR]="$RECOVERY_FIXTURE/nextcloud-docker" [NEXTCLOUD_PI_APP_CONTAINER]=nextcloud-docker-app-1 [NEXTCLOUD_PI_DB_CONTAINER]=nextcloud-docker-db-1 [NEXTCLOUD_PI_CADDY_CONTAINER]=nextcloud-docker-caddy-1); runtime_recovery_startup_guard' >/dev/null
}

printf 'yes\n' >"$fixture/fail-once"
if run_detach 2>/dev/null; then printf 'injected detach interruption passed unexpectedly\n' >&2; exit 1; fi
[[ "$(metadata "$fixture/runtime-recovery/$RECOVERY_STAGE/metadata.tsv" state)" == detaching ]]
[[ ! -f "$fixture/app.present" && -f "$fixture/db.present" ]]
for key in db caddy; do [[ "$(<"$fixture/$key.restart")" == no ]]; done
run_boot_guard
if run_startup_guard 2>/dev/null; then printf 'unsafe Compose startup was permitted\n' >&2; exit 1; fi
run_detach
[[ "$(metadata "$fixture/runtime-recovery/$RECOVERY_STAGE/metadata.tsv" state)" == detached ]]
for key in app db caddy; do [[ ! -f "$fixture/$key.present" ]]; done
run_boot_guard
if run_startup_guard 2>/dev/null; then printf 'detached recovery permitted Compose startup\n' >&2; exit 1; fi

mkdir -p "$fixture/storage/.recovery-$RECOVERY_STAGE/nextcloud/nextcloud" \
  "$fixture/storage/.recovery-$RECOVERY_STAGE/mariadb-data" \
  "$fixture/storage/.recovery-$RECOVERY_STAGE/caddy-data" \
  "$fixture/storage/.recovery-$RECOVERY_STAGE/caddy-config"
for path in nextcloud/nextcloud mariadb-data caddy-data caddy-config; do
  printf 'restored\n' >"$fixture/storage/.recovery-$RECOVERY_STAGE/$path/identity"
done
for path in "$fixture/storage/nextcloud" "$fixture/storage/nextcloud_db" "$fixture/caddy-data" "$fixture/caddy-config"; do
  printf 'failed\n' >"$path/identity"
done
for item in nextcloud caddy-data caddy-config; do printf '%s\n' "$fingerprint" >"$fixture/runtime-recovery/$RECOVERY_STAGE/$item.complete"; done
printf 'sql_sha256\t%s\ntables\t1\ncolumns\t1\nfilecache_rows\t1\n' "$fingerprint" >"$fixture/runtime-recovery/$RECOVERY_STAGE/database.complete"
printf '0\n' >"$fixture/promote-count"
run_promote() {
  bash -e -c 'declare -A P=([NEXTCLOUD_PI_STATE_ROOT]="$RECOVERY_FIXTURE" [NEXTCLOUD_PI_STORAGE_MOUNT]="$RECOVERY_FIXTURE/storage" [NEXTCLOUD_PI_RUNTIME_RECOVERY_PREFIX]=.recovery- [NEXTCLOUD_PI_PROJECT_DIR]="$RECOVERY_FIXTURE/nextcloud-docker" [NEXTCLOUD_PI_APP_CONTAINER]=nextcloud-docker-app-1 [NEXTCLOUD_PI_DB_CONTAINER]=nextcloud-docker-db-1 [NEXTCLOUD_PI_CADDY_CONTAINER]=nextcloud-docker-caddy-1 [NEXTCLOUD_PI_SERVICE_NAME]=nextcloud.service); cmd_recovery_promote "$RECOVERY_STAGE" "$RECOVERY_FINGERPRINT"' >/dev/null
}
printf 'yes\n' >"$fixture/copy-fail-once"
if run_promote 2>/dev/null; then printf 'injected Caddy staging interruption passed unexpectedly\n' >&2; exit 1; fi
[[ "$(metadata "$fixture/runtime-recovery/$RECOVERY_STAGE/metadata.tsv" state)" == copying ]]
[[ -d "$fixture/caddy-data.restore-$RECOVERY_STAGE" ]]
run_boot_guard
if run_startup_guard 2>/dev/null; then printf 'partial Caddy staging permitted Compose startup\n' >&2; exit 1; fi
printf 'yes\n' >"$fixture/promote-fail-once"
if run_promote 2>/dev/null; then printf 'injected promotion interruption passed unexpectedly\n' >&2; exit 1; fi
[[ "$(metadata "$fixture/runtime-recovery/$RECOVERY_STAGE/metadata.tsv" state)" == promoting ]]
run_boot_guard
if run_startup_guard 2>/dev/null; then printf 'partial promotion permitted Compose startup\n' >&2; exit 1; fi
run_promote
[[ "$(metadata "$fixture/runtime-recovery/$RECOVERY_STAGE/metadata.tsv" state)" == promoted ]]
for path in "$fixture/storage/nextcloud" "$fixture/storage/nextcloud_db" "$fixture/caddy-data" "$fixture/caddy-config"; do
  [[ "$(<"$path/identity")" == restored ]]
done
run_boot_guard
if run_startup_guard 2>/dev/null; then printf 'unverified promotion permitted Compose startup\n' >&2; exit 1; fi
bash -e -c 'declare -A P=([NEXTCLOUD_PI_STATE_ROOT]="$RECOVERY_FIXTURE" [NEXTCLOUD_PI_STORAGE_MOUNT]="$RECOVERY_FIXTURE/storage" [NEXTCLOUD_PI_PROJECT_DIR]="$RECOVERY_FIXTURE/nextcloud-docker" [NEXTCLOUD_PI_APP_CONTAINER]=nextcloud-docker-app-1 [NEXTCLOUD_PI_DB_CONTAINER]=nextcloud-docker-db-1 [NEXTCLOUD_PI_CADDY_CONTAINER]=nextcloud-docker-caddy-1); cmd_recovery_source_ready "$RECOVERY_STAGE" "$RECOVERY_FINGERPRINT"' >/dev/null
run_boot_guard
run_startup_guard
printf 'runtime recovery startup interruption fixture passed\n'
