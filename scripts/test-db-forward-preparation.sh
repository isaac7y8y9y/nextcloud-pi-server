#!/usr/bin/env bash
# Exercise the root-owned forward preparation checkpoints without live state.
set -euo pipefail
umask 077
if [[ "$(uname -s)" != Linux ]]; then
  printf 'forward database preparation fixture is Linux-only\n'
  exit 0
fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
stage=20261019T000000Z-12
fingerprint="$(printf 'a%.0s' {1..64})"
source_image="sha256:$(printf '1%.0s' {1..64})"
target_image="sha256:$(printf '2%.0s' {1..64})"
fixture_container_id="$(printf '3%.0s' {1..64})"
mkdir -p "$fixture/state" "$fixture/storage/nextcloud_db" "$fixture/project"
declare -A P=([NEXTCLOUD_PI_STORAGE_MOUNT]="$fixture/storage" [NEXTCLOUD_PI_PROJECT_DIR]="$fixture/project" [NEXTCLOUD_PI_DB_CONTAINER]=nextcloud-docker-db-1 [NEXTCLOUD_PI_APP_CONTAINER]=nextcloud-docker-app-1 [NEXTCLOUD_PI_CADDY_CONTAINER]=nextcloud-docker-caddy-1)
ACTIVE_RECORD="$fixture/active-images.env"
VALIDATOR=/usr/bin/true
printf 'NEXTCLOUD_ACTIVE_IMAGES_DB_TAG=mariadb:11.4.13\nNEXTCLOUD_ACTIVE_IMAGES_APP_TAG=nextcloud:33.0.10-apache\nNEXTCLOUD_ACTIVE_IMAGES_DB_ID=%s\n' "$source_image" >"$ACTIVE_RECORD"
printf 'private-fixture\n' >"$fixture/project/.env"
printf 'MYSQL_DATABASE=nextcloud\n' >"$fixture/state/$stage.env"
env_hash="$(sha256sum "$fixture/project/.env" | awk '{print $1}')"
restricted_hash="$(sha256sum "$fixture/state/$stage.env" | awk '{print $1}')"

for function in db_cutover_file db_cutover_field db_cutover_flush db_cutover_rewrite db_cutover_temp_record db_cutover_forward_step db_cutover_forward db_cutover_path db_cutover_inode db_cutover_digest cmd_db_cutover_begin cmd_db_cutover_temp_start db_cutover_temp_identity db_cutover_upgrade_marker db_cutover_source_data cmd_db_cutover_temp_upgrade cmd_db_cutover_temp_ready cmd_db_cutover_attest cmd_db_cutover_reset_preparing; do
  text="$(sed -n "/^$function() {/,/^}/p" "$root/privileged/nextcloud-pi-ops")"
  # One-line helpers end on their first line.
  first_line="${text%%$'\n'*}"
  if [[ "$first_line" == *'}' ]]; then text="$first_line"; fi
  text="${text//\/usr\/bin\/docker/docker_fake}"
  text="${text//\/usr\/bin\/install/install_fake}"
  eval "$text"
done
die() { printf '%s\n' "$1" >&2; exit 1; }
invalid() { die 'invalid fixture arguments'; }
reject_stdin() { :; }; lock() { :; }; validate_host() { :; }
db_cutover_scan() { [[ ! -e "$fixture/deny-scan" ]] || die 'source inode differs'; }
valid_id() { [[ "$1" == "$stage" ]]; }
valid_hash() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
hash() { sha256sum "$1" | awk '{print $1}'; }
metadata() { awk -F '\t' -v key="$2" '$1==key {n++;v=$2} END {if(n==1)print v;else exit 1}' "$1"; }
db_cutover_root() { printf '%s/state' "$fixture"; }
db_cutover_require() { [[ "$2" == "$fingerprint" ]] || die 'fingerprint differs'; }
freeze_require_current() { :; }
freeze_field() { [[ "$1" == phase ]] && printf active || printf '%s' "$fingerprint"; }
freeze_table_hash() { printf '%s' "$fingerprint"; }
live_hash() { printf '%s' "$fingerprint"; }
upgrade_stage_compose_hash() { printf '%s' "$fingerprint"; }
available() { printf 99999999; }; db_cutover_space_required() { printf 0; }
ensure_parent() { :; }; safe_dir() { [[ -d "$1" && ! -L "$1" ]]; }
protected_file() { [[ -f "$1" && ! -L "$1" && "$(stat -c '%a' "$1")" == "${2#0}" ]] || die 'unsafe fixture file'; }
install_fake() {
  local arguments=()
  while (( $# )); do
    case "$1" in -o|-g) shift 2;; *) arguments+=("$1"); shift;; esac
  done
  /usr/bin/install "${arguments[@]}"
}
no_nested_mounts() { [[ ! -e "$fixture/nested-mount" ]]; }; db_cutover_source_consumers() { :; }
db_cutover_no_consumers() { [[ ! -e "$fixture/temp.present" ]] || die 'consumer remains'; }
out() { :; }

docker_fake() {
  local action="$1"; shift
  case "$action" in
    image) printf '%s\n' "${@: -1}" ;;
    create)
      [[ "$*" == *'--network none --restart=no'* && "$*" == *"source=$(db_cutover_path "$stage"),target=/var/lib/mysql"* ]] || return 2
      printf '%s' "${@: -1}" >"$fixture/temp.image"
      printf '%s' "$(db_cutover_path "$stage")" >"$fixture/temp.path"
      printf '%s' "$fixture_container_id" >"$fixture/temp.id"
      printf false >"$fixture/temp.running"; printf 0 >"$fixture/temp.exit"; printf false >"$fixture/temp.oom"
      touch "$fixture/temp.present"
      printf '%s\n' "$fixture_container_id" ;;
    start) printf true >"$fixture/temp.running" ;;
    inspect)
      if [[ "$1" != --format ]]; then [[ -e "$fixture/temp.present" ]]; return; fi
      if [[ "$3" == nextcloud-docker-db-1 && "$2" == '{{.Image}}' ]]; then printf '%s' "$source_image"; return; fi
      if [[ "$3" == nextcloud-docker-* ]]; then printf '%s true' "$fixture_container_id"; return; fi
      [[ -e "$fixture/temp.present" ]] || return 1
      printf '%s %s %s no none 0 1 %s %s %s %s' "$(<"$fixture/temp.id")" "$stage" "$(<"$fixture/temp.image")" "$(<"$fixture/temp.path")" "$(<"$fixture/temp.running")" "$(<"$fixture/temp.exit")" "$(<"$fixture/temp.oom")" ;;
    exec)
      if [[ "$*" == *'SELECT VERSION()'* ]]; then printf '%s' "${fixture_version:-11.8.9-MariaDB}"; return; fi
      [[ "$5" == 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb-upgrade --protocol=tcp --host=127.0.0.1 -uroot --force' ]] || return 2
      [[ ! -e "$fixture/fail-upgrade" ]] || return 1
      printf '11.8.9-MariaDB\n' >"$(db_cutover_path "$stage")/mariadb_upgrade_info"
      printf 'upgraded\n' >>"$fixture/upgrade.calls" ;;
    *) return 2 ;;
  esac
}
must_fail() {
  if (set -e; "$@") >"$fixture/rejected.log" 2>&1; then
    printf 'unexpected acceptance: %s\n' "$*" >&2; exit 1
  fi
}
begin() { cmd_db_cutover_begin "$stage" "$fingerprint" "$stage" "$fingerprint" "$fingerprint" "$fingerprint" "$fingerprint" "$fingerprint" "$target_image" "$env_hash" "$restricted_hash" "$fingerprint" "$fingerprint" "$@"; }
must_fail begin unknown "$source_image"
sed -i 's/33.0.10/32.0.15/' "$ACTIVE_RECORD"
must_fail begin forward-114-118 "$source_image"
sed -i 's/32.0.15/33.0.10/' "$ACTIVE_RECORD"
must_fail begin forward-114-118 "$target_image"
touch "$fixture/deny-scan"
must_fail begin forward-114-118 "$source_image"
rm "$fixture/deny-scan"
begin forward-114-118 "$source_image"
[[ "$(db_cutover_field "$stage" forward_step)" == initial ]]
must_fail begin
must_fail cmd_db_cutover_temp_start "$stage" "$fingerprint" target
must_fail cmd_db_cutover_temp_start "$stage" "$fingerprint"
must_fail cmd_db_cutover_attest "$stage" "$fingerprint"
cmd_db_cutover_temp_start "$stage" "$fingerprint" source
must_fail cmd_db_cutover_temp_ready "$stage" "$fingerprint" source
printf false >"$fixture/temp.running"
must_fail cmd_db_cutover_temp_ready "$stage" "$fingerprint" source
mkdir "$(db_cutover_path "$stage")/mysql"
printf 'initialized-source\n' >"$(db_cutover_path "$stage")/ibdata1"
[[ ! -e "$(db_cutover_path "$stage")/mariadb_upgrade_info" ]] # Fresh initialization has no upgrade marker.
touch "$fixture/nested-mount"
must_fail cmd_db_cutover_temp_ready "$stage" "$fingerprint" source
rm "$fixture/nested-mount"
mv "$(db_cutover_path "$stage")/mysql" "$fixture/source-system-tables"
ln -s "$fixture/source-system-tables" "$(db_cutover_path "$stage")/mysql"
must_fail cmd_db_cutover_temp_ready "$stage" "$fingerprint" source
rm "$(db_cutover_path "$stage")/mysql"
mv "$fixture/source-system-tables" "$(db_cutover_path "$stage")/mysql"
for field in id image path exit oom; do
  cp "$fixture/temp.$field" "$fixture/saved"
  printf foreign >"$fixture/temp.$field"
  must_fail cmd_db_cutover_temp_ready "$stage" "$fingerprint" source
  mv "$fixture/saved" "$fixture/temp.$field"
done
cmd_db_cutover_temp_ready "$stage" "$fingerprint" source
must_fail cmd_db_cutover_temp_start "$stage" "$fingerprint" target
rm "$fixture/temp.present"
mv "$(db_cutover_path "$stage")/ibdata1" "$fixture/source-ibdata1"
must_fail cmd_db_cutover_temp_start "$stage" "$fingerprint" target
ln -s "$fixture/source-ibdata1" "$(db_cutover_path "$stage")/ibdata1"
must_fail cmd_db_cutover_temp_start "$stage" "$fingerprint" target
rm "$(db_cutover_path "$stage")/ibdata1"
mv "$fixture/source-ibdata1" "$(db_cutover_path "$stage")/ibdata1"
cmd_db_cutover_temp_start "$stage" "$fingerprint" target
printf false >"$fixture/temp.running"
must_fail cmd_db_cutover_temp_ready "$stage" "$fingerprint" target
printf true >"$fixture/temp.running"
touch "$fixture/fail-upgrade"
must_fail cmd_db_cutover_temp_upgrade "$stage" "$fingerprint"
[[ "$(db_cutover_field "$stage" forward_step)" == target-started ]]
rm "$fixture/fail-upgrade"
fixture_version=11.4.13
must_fail cmd_db_cutover_temp_upgrade "$stage" "$fingerprint"
unset fixture_version
cmd_db_cutover_temp_upgrade "$stage" "$fingerprint"
cmd_db_cutover_temp_upgrade "$stage" "$fingerprint" # Safe full retry after a lost response.
[[ "$(wc -l <"$fixture/upgrade.calls")" == 2 ]]
printf false >"$fixture/temp.running"
mv "$(db_cutover_path "$stage")/mariadb_upgrade_info" "$fixture/target-marker"
must_fail cmd_db_cutover_temp_ready "$stage" "$fingerprint" target
mv "$fixture/target-marker" "$(db_cutover_path "$stage")/mariadb_upgrade_info"
printf '11x8.9-MariaDB\n' >"$(db_cutover_path "$stage")/mariadb_upgrade_info"
must_fail cmd_db_cutover_temp_ready "$stage" "$fingerprint" target
printf '11.8.9-MariaDB\n' >"$(db_cutover_path "$stage")/mariadb_upgrade_info"
cmd_db_cutover_temp_ready "$stage" "$fingerprint" target
must_fail cmd_db_cutover_attest "$stage" "$fingerprint"
rm "$fixture/temp.present"
cmd_db_cutover_reset_preparing "$stage" "$fingerprint"
[[ "$(db_cutover_field "$stage" forward_step)" == initial && -z "$(find "$(db_cutover_path "$stage")" -mindepth 1 -print -quit)" ]]
must_fail cmd_db_cutover_temp_upgrade "$stage" "$fingerprint"
printf '11.8.9-MariaDB\n' >"$(db_cutover_path "$stage")/mariadb_upgrade_info"
db_cutover_forward_step "$stage" complete
cmd_db_cutover_attest "$stage" "$fingerprint"
[[ "$(db_cutover_field "$stage" phase)" == prepared ]]
must_fail cmd_db_cutover_temp_start "$stage" "$fingerprint" source
must_fail cmd_db_cutover_temp_upgrade "$stage" "$fingerprint"
printf 'forward database preparation checkpoints passed\n'

# Exercise the real full-runtime promoter's durable forward restoration proof.
for function in recovery_promote_pair cmd_recovery_promote db_cutover_restored_identity cmd_db_cutover_source_ready; do
  text="$(sed -n "/^$function() {/,/^}/p" "$root/privileged/nextcloud-pi-ops")"
  text="${text//\/usr\/bin\/docker/docker_fake}"
  text="${text//\/usr\/bin\/systemctl/systemctl_fake}"
  text="${text//\/usr\/bin\/install/install_fake}"
  eval "$text"
done
P[NEXTCLOUD_PI_SERVICE_NAME]=nextcloud.service
recovery_root() { printf '%s/storage/.recovery-%s' "$fixture" "$1"; }
recovery_state() { printf '%s/recovery-state' "$fixture"; }
safe_recovery_root() { safe_dir "$1"; }
upgrade_stage_require() { :; }
upgrade_stage_field() { case "$2" in phase) printf runtime-may-have-changed;; fingerprint) printf '%s' "$fingerprint";; target) printf db;; esac; }
db_cutover_stage_bound() { :; }
db_cutover_old_objects_absent() { [[ ! -e "$fixture/foreign-consumer" ]] || die 'foreign consumer'; }
systemctl_fake() { printf inactive; }
mkdir -p "$(recovery_state "$stage")" "$(recovery_root "$stage")/nextcloud/nextcloud" \
  "$(recovery_root "$stage")/mariadb-data" "$(recovery_root "$stage")/caddy-data" "$(recovery_root "$stage")/caddy-config" \
  "$fixture/storage/nextcloud" "$fixture/caddy-data" "$fixture/caddy-config"
for path in nextcloud/nextcloud mariadb-data caddy-data caddy-config; do
  printf 'restored\n' >"$(recovery_root "$stage")/$path/identity"
done
mv "$fixture/storage/nextcloud_db" "$fixture/storage/.nextcloud-db-before-$stage"
mkdir "$fixture/storage/nextcloud_db"
for path in "$fixture/storage/nextcloud_db" "$fixture/storage/nextcloud" "$fixture/caddy-data" "$fixture/caddy-config"; do
  printf 'failed\n' >"$path/identity"
done
printf 'format\truntime-recovery-v1\nstate\tprepared\nstage_id\t%s\ncaddy_data_path\t%s\ncaddy_config_path\t%s\n' \
  "$stage" "$fixture/caddy-data" "$fixture/caddy-config" >"$(recovery_state "$stage")/metadata.tsv"
for item in nextcloud caddy-data caddy-config; do printf '%s\n' "$fingerprint" >"$(recovery_state "$stage")/$item.complete"; done
printf 'sql_sha256\t%s\ntables\t1\ncolumns\t1\nfilecache_rows\t1\n' "$fingerprint" >"$(recovery_state "$stage")/database.complete"
db_cutover_rewrite "$stage" recovering yes '1:2' "$fingerprint"
original_flush="$(declare -f db_cutover_flush)"
eval "${original_flush/db_cutover_flush/db_cutover_flush_original}"
db_cutover_flush() {
  db_cutover_flush_original "$@"
  if [[ -e "$fixture/fail-after-proof" ]] && db_cutover_field "$stage" restored_source_inode >/dev/null 2>&1; then
    rm "$fixture/fail-after-proof"
    exit 77
  fi
}
touch "$fixture/fail-after-proof"
must_fail cmd_recovery_promote "$stage" "$fingerprint"
[[ "$(metadata "$(recovery_state "$stage")/metadata.tsv" state)" == promoting ]]
restored_inode="$(db_cutover_field "$stage" restored_source_inode)"
[[ "$restored_inode" == "$(db_cutover_inode "$fixture/storage/nextcloud_db")" ]]
cmd_recovery_promote "$stage" "$fingerprint"
[[ "$(metadata "$(recovery_state "$stage")/metadata.tsv" state)" == promoted ]]
[[ "$(db_cutover_field "$stage" restored_source_inode)" == "$restored_inode" ]]
mv "$fixture/storage/nextcloud_db" "$fixture/storage/.saved-restored"
mkdir "$fixture/storage/nextcloud_db"
must_fail cmd_recovery_promote "$stage" "$fingerprint"
must_fail cmd_db_cutover_source_ready "$stage" "$fingerprint" "$fingerprint"
[[ "$(db_cutover_field "$stage" restored_source_inode)" == "$restored_inode" ]]
rmdir "$fixture/storage/nextcloud_db"
mv "$fixture/storage/.saved-restored" "$fixture/storage/nextcloud_db"
cmd_db_cutover_source_ready "$stage" "$fingerprint" "$fingerprint"
cmd_db_cutover_source_ready "$stage" "$fingerprint" "$fingerprint"
[[ "$(db_cutover_field "$stage" phase)" == source-ready && "$(db_cutover_field "$stage" restored_source_inode)" == "$restored_inode" ]]
printf 'forward full-runtime restoration proof interruption tests passed\n'
