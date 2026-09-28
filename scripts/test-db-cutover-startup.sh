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

for function_name in db_cutover_scan db_cutover_startup_guard; do
  function_text="$(sed -n "/^${function_name}() {/,/^}/p" "$root/privileged/nextcloud-pi-ops")"
  [[ -n "$function_text" ]] || exit 1
  eval "$function_text"
done
db_cutover_root() { printf '%s/state/db-cutover' "$fixture"; }
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

mv -T -- "$fixture/storage/nextcloud_db" "$fixture/storage/.unexpected-candidate"
mv -T -- "$fixture/storage/.nextcloud-db-before-$stage_id" "$fixture/storage/nextcloud_db"
deny
active_hash=source-record
compose_hash=source-compose
write_journal source-ready
permit
write_journal recovered
permit

printf 'database startup-journal phase fixture passed\n'
