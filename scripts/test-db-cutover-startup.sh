#!/usr/bin/env bash
# Exercise database startup journal gates with synthetic Linux directories.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux ]]; then
  printf 'database startup-journal fixture is Linux-only\n'
  exit 0
fi
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
declare -A P
P[NEXTCLOUD_PI_STORAGE_MOUNT]="$fixture/storage"
stage_id=20260927T000000Z-12
expected_id="sha256:$(printf 'a%.0s' {1..64})"
mkdir -p "$fixture/state/db-cutover" "$fixture/storage/nextcloud_db" "$fixture/storage/.db-cutover-$stage_id/data"
printf 'source\n' >"$fixture/storage/nextcloud_db/identity"
printf 'candidate\n' >"$fixture/storage/.db-cutover-$stage_id/data/identity"
source_inode="$(stat -c '%d:%i' "$fixture/storage/nextcloud_db")"
candidate_inode="$(stat -c '%d:%i' "$fixture/storage/.db-cutover-$stage_id/data")"
active_hash=source-record
compose_hash=source-compose
current_db_id="$expected_id"
ACTIVE_RECORD="$fixture/active-images.env"
printf 'NEXTCLOUD_ACTIVE_IMAGES_DB_ID=%s\n' "$expected_id" >"$ACTIVE_RECORD"
chmod 0600 "$ACTIVE_RECORD"

for function_name in db_cutover_scan db_cutover_startup_guard db_cutover_forward_owner db_cutover_restored_identity; do
  function_text="$(sed -n "/^${function_name}() {/,/^}/p" "$root/privileged/nextcloud-pi-ops")"
  [[ -n "$function_text" ]] || exit 1
  eval "$function_text"
done
db_cutover_root() { printf '%s/state/db-cutover' "$fixture"; }
db_cutover_field() { metadata "$(db_cutover_root)/$1.tsv" "$2"; }
db_cutover_forward() { [[ "$(db_cutover_field "$1" preparation_mode 2>/dev/null || true)" == forward-114-118 ]]; }
metadata() { awk -F '\t' -v wanted="$2" '$1 == wanted {print $2; found=1; exit} END {if (!found) exit 1}' "$1"; }
valid_id() { [[ "$1" =~ ^[A-Za-z0-9-]+$ ]]; }
safe_dir() { [[ -d "$1" && ! -L "$1" ]]; }
protected_file() { [[ -f "$1" && ! -L "$1" ]]; }
db_cutover_inode() { stat -c '%d:%i' "$1"; }
live_hash() { printf '%s' "$active_hash"; }
upgrade_stage_compose_hash() { printf '%s' "$compose_hash"; }
die() { printf '%s\n' "$1" >&2; exit 1; }

write_journal() {
  local phase="$1"
  printf 'format\tdb-cutover-v1\nid\t%s\nphase\t%s\nsource_inode\t%s\ncandidate_inode\t%s\nobjects_removed\tyes\npre_record_sha256\tsource-record\npre_compose_sha256\tsource-compose\ncandidate_record_sha256\tcandidate-record\ncandidate_compose_sha256\tcandidate-compose\nexpected_id\t%s\n' \
    "$stage_id" "$phase" "$source_inode" "$candidate_inode" "$expected_id" >"$fixture/state/db-cutover/$stage_id.tsv"
  chmod 0600 "$fixture/state/db-cutover/$stage_id.tsv"
}
permit() { db_cutover_startup_guard >/dev/null; }
deny() { if (db_cutover_startup_guard) >/dev/null 2>&1; then printf 'unsafe startup was permitted\n' >&2; exit 1; fi; }

write_journal preparing
permit
write_journal prepared
permit
write_journal detaching
deny
write_journal detached
deny
write_journal switching
deny

mv -T -- "$fixture/storage/nextcloud_db" "$fixture/storage/.nextcloud-db-before-$stage_id"
mv -T -- "$fixture/storage/.db-cutover-$stage_id/data" "$fixture/storage/nextcloud_db"
active_hash=candidate-record
compose_hash=candidate-compose
write_journal candidate-ready
permit
write_journal accepted
permit

# Historical accepted 11.4 authority must coexist with a later forward stage.
forward_id=20261019T000000Z-12
forward_file="$fixture/state/db-cutover/$forward_id.tsv"
mkdir -p "$fixture/storage/.db-cutover-$forward_id/data"
printf 'forward-target\n' >"$fixture/storage/.db-cutover-$forward_id/data/identity"
forward_inode="$(stat -c '%d:%i' "$fixture/storage/.db-cutover-$forward_id/data")"
write_forward() {
  printf 'format\tdb-cutover-v1\nid\t%s\nphase\t%s\npreparation_mode\tforward-114-118\nsource_image_id\t%s\nsource_inode\t%s\ncandidate_inode\t%s\nobjects_removed\tyes\npre_record_sha256\tcandidate-record\npre_compose_sha256\tcandidate-compose\ncandidate_record_sha256\tforward-record\ncandidate_compose_sha256\tforward-compose\nexpected_id\tsha256:%064d\n' \
    "$forward_id" "$1" "$expected_id" "$candidate_inode" "$forward_inode" 1 >"$forward_file"
  chmod 0600 "$forward_file"
}
boot_permit() { db_cutover_scan >/dev/null; }
boot_deny() { if (db_cutover_scan) >/dev/null 2>&1; then printf 'unsafe Docker boot was permitted\n' >&2; exit 1; fi; }
write_forward switching
mv -T -- "$fixture/storage/nextcloud_db" "$fixture/storage/.nextcloud-db-before-$forward_id"
boot_permit # First rename completed, source active record still selects 11.4.
deny
mv -T -- "$fixture/storage/.db-cutover-$forward_id/data" "$fixture/storage/nextcloud_db"
boot_permit # Candidate directory, before target active-record installation.
deny
write_forward recovering
mv -T -- "$fixture/storage/nextcloud_db" "$fixture/storage/.forward-failed"
mkdir "$fixture/storage/nextcloud_db"
printf 'restored-source\n' >"$fixture/storage/nextcloud_db/identity"
restored_inode="$(stat -c '%d:%i' "$fixture/storage/nextcloud_db")"
printf 'restored_source_inode\t%s\n' "$restored_inode" >>"$forward_file"
boot_permit # Full promotion and source record restored, before source-ready.
deny
write_forward source-ready
printf 'restored_source_inode\t%s\n' "$restored_inode" >>"$forward_file"
permit
write_forward recovered
printf 'restored_source_inode\t%s\n' "$restored_inode" >>"$forward_file"
permit
cp "$forward_file" "$fixture/forward-good"
for replacement in missing-proof wrong-proof wrong-source no-checkpoint; do
  cp "$fixture/forward-good" "$forward_file"
  case "$replacement" in
    missing-proof) sed -i '/^restored_source_inode/d' "$forward_file" ;;
    wrong-proof) sed -i 's/^restored_source_inode.*/restored_source_inode\t0:0/' "$forward_file" ;;
    wrong-source) sed -i 's/^source_image_id.*/source_image_id\tforeign/' "$forward_file" ;;
    no-checkpoint) sed -i 's/^phase.*/phase\tinitial/' "$forward_file" ;;
  esac
  boot_deny
done
cp "$fixture/forward-good" "$forward_file"
mv "$fixture/storage/.nextcloud-db-before-$forward_id" "$fixture/storage/.missing-forward-source"
boot_deny
mv "$fixture/storage/.missing-forward-source" "$fixture/storage/.nextcloud-db-before-$forward_id"
mv "$fixture/storage/.nextcloud-db-before-$stage_id" "$fixture/storage/.missing-original-source"
boot_deny
mv "$fixture/storage/.missing-original-source" "$fixture/storage/.nextcloud-db-before-$stage_id"
mv "$fixture/storage/nextcloud_db" "$fixture/storage/.restored-held"
mkdir "$fixture/storage/nextcloud_db"
boot_deny
rmdir "$fixture/storage/nextcloud_db"
mv "$fixture/storage/.nextcloud-db-before-$forward_id" "$fixture/storage/nextcloud_db"
rm "$forward_file"
permit

mv -T -- "$fixture/storage/nextcloud_db" "$fixture/storage/.unexpected-candidate"
mv -T -- "$fixture/storage/.nextcloud-db-before-$stage_id" "$fixture/storage/nextcloud_db"
deny
active_hash=source-record
compose_hash=source-compose
write_journal source-ready
permit
write_journal recovered
permit

function_text="$(sed -n '/^cmd_db_cutover_begin() {/,/^}/p' "$root/privileged/nextcloud-pi-ops")"
[[ -n "$function_text" ]] || exit 1
eval "$function_text"
P[NEXTCLOUD_PI_PROJECT_DIR]="$fixture/project"
mkdir -p "$fixture/project"
printf 'synthetic\n' >"$fixture/project/.env"
low_id=20260927T000000Z-13
a_hash="$(printf 'a%.0s' {1..64})"
b_hash="$(printf 'b%.0s' {1..64})"
c_hash="$(printf 'c%.0s' {1..64})"
d_hash="$(printf 'd%.0s' {1..64})"
e_hash="$(printf 'e%.0s' {1..64})"
f_hash="$(printf 'f%.0s' {1..64})"
active_hash="$a_hash"
compose_hash="$b_hash"
valid_hash() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
reject_stdin() { :; }
lock() { :; }
validate_host() { :; }
freeze_require_current() { :; }
freeze_field() { [[ "$1" == phase ]] && printf active || printf '%s' "$c_hash"; }
freeze_table_hash() { printf '%s' "$c_hash"; }
hash() { printf '%s' "$d_hash"; }
no_nested_mounts() { :; }
available() { printf '1'; }
db_cutover_space_required() { printf '1024'; }
if (cmd_db_cutover_begin "$low_id" "$e_hash" "$stage_id" "$c_hash" "$a_hash" "$b_hash" "$f_hash" "$a_hash" "sha256:$b_hash" "$d_hash" "$c_hash" "$e_hash" "$f_hash") >/dev/null 2>&1; then
  printf 'database preparation accepted insufficient recovery space\n' >&2
  exit 1
fi
[[ ! -e "$fixture/state/db-cutover/$low_id.tsv" ]]
[[ "$(<"$fixture/storage/nextcloud_db/identity")" == source ]]

printf 'database startup-journal phase fixture passed\n'
