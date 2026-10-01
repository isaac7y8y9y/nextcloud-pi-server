#!/usr/bin/env bash
# Exercise the protected database directory switch on a disposable Linux filesystem.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux ]]; then
  printf 'database directory-switch fixture is Linux-only\n'
  exit 0
fi

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
export DB_SWITCH_TEST_ROOT="$fixture"

move="$fixture/move"
cat >"$move" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count="$(<"$DB_SWITCH_TEST_ROOT/count")"
count=$((count + 1))
printf '%s\n' "$count" >"$DB_SWITCH_TEST_ROOT/count"
if [[ "$(<"$DB_SWITCH_TEST_ROOT/fail")" == "before-$count" ]]; then exit 1; fi
/usr/bin/mv "$@"
if [[ "$(<"$DB_SWITCH_TEST_ROOT/fail")" == "after-$count" ]]; then exit 1; fi
SH
chmod 0700 "$move"

function_text="$(sed -n '/^cmd_db_cutover_switch() {/,/^}/p' "$root/privileged/nextcloud-pi-ops")"
[[ -n "$function_text" ]] || exit 1
function_text="${function_text//\/usr\/bin\/mv/$move}"
eval "$function_text"

declare -A P
P[NEXTCLOUD_PI_STORAGE_MOUNT]="$fixture/storage"
stage_id=20260927T000000Z-12
phase_file="$fixture/phase"
source_inode=''
candidate_inode=''
candidate_digest=''
mkdir -p "$fixture/storage/.db-cutover-$stage_id/data" "$fixture/storage/nextcloud_db"

invalid() { printf 'invalid fixture invocation\n' >&2; exit 2; }
die() { printf '%s\n' "$1" >&2; return 1; }
reject_stdin() { :; }
lock() { :; }
validate_host() { :; }
db_cutover_require() { :; }
db_cutover_stage_bound() { :; }
db_cutover_old_objects_absent() { :; }
upgrade_stage_field() { printf 'runtime-may-have-changed'; }
db_cutover_path() { printf '%s/.db-cutover-%s/data' "${P[NEXTCLOUD_PI_STORAGE_MOUNT]}" "$1"; }
db_cutover_inode() { /usr/bin/stat -c '%d:%i' "$1"; }
db_cutover_digest() {
  (cd -- "$1" && /usr/bin/find . -type f -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 -r /usr/bin/sha256sum | /usr/bin/sha256sum | /usr/bin/awk '{print $1}')
}
db_cutover_field() {
  case "$2" in
    phase) <"$phase_file" /usr/bin/tr -d '\n' ;;
    source_inode) printf '%s' "$EXPECTED_SOURCE_INODE" ;;
    candidate_inode) printf '%s' "$EXPECTED_CANDIDATE_INODE" ;;
    candidate_digest) printf '%s' "$EXPECTED_CANDIDATE_DIGEST" ;;
    *) invalid ;;
  esac
}
db_cutover_rewrite() { printf '%s\n' "$2" >"$phase_file"; }
out() { :; }
export DB_SWITCH_STORAGE_MOUNT="${P[NEXTCLOUD_PI_STORAGE_MOUNT]}" stage_id phase_file
for function_name in cmd_db_cutover_switch invalid die reject_stdin lock validate_host \
                     db_cutover_require db_cutover_stage_bound db_cutover_old_objects_absent \
                     upgrade_stage_field db_cutover_path db_cutover_inode db_cutover_digest \
                     db_cutover_field db_cutover_rewrite out; do
  export -f "$function_name"
done

for failure in before-1 after-1 before-2 after-2; do
  case_root="$fixture/storage"
  /usr/bin/rm -rf -- "$case_root"
  mkdir -p "$case_root/.db-cutover-$stage_id/data" "$case_root/nextcloud_db"
  printf 'original\n' >"$case_root/nextcloud_db/identity"
  printf 'imported\n' >"$case_root/.db-cutover-$stage_id/data/identity"
  source_inode="$(db_cutover_inode "$case_root/nextcloud_db")"
  candidate_inode="$(db_cutover_inode "$case_root/.db-cutover-$stage_id/data")"
  candidate_digest="$(db_cutover_digest "$case_root/.db-cutover-$stage_id/data")"
  export EXPECTED_SOURCE_INODE="$source_inode" EXPECTED_CANDIDATE_INODE="$candidate_inode" EXPECTED_CANDIDATE_DIGEST="$candidate_digest"
  printf 'detached\n' >"$phase_file"
  printf '0\n' >"$fixture/count"
  printf '%s\n' "$failure" >"$fixture/fail"
  if bash -e -c 'declare -A P=([NEXTCLOUD_PI_STORAGE_MOUNT]="$DB_SWITCH_STORAGE_MOUNT"); cmd_db_cutover_switch "$stage_id" fingerprint stage-fingerprint' >/dev/null 2>&1; then
    printf 'switch unexpectedly passed injected %s failure\n' "$failure" >&2
    exit 1
  fi
  [[ "$(<"$phase_file")" == switching ]]
  printf 'none\n' >"$fixture/fail"
  cmd_db_cutover_switch "$stage_id" fingerprint stage-fingerprint
  [[ "$(<"$case_root/nextcloud_db/identity")" == imported ]]
  [[ "$(<"$case_root/.nextcloud-db-before-$stage_id/identity")" == original ]]
  [[ "$(db_cutover_inode "$case_root/nextcloud_db")" == "$candidate_inode" ]]
  [[ "$(db_cutover_inode "$case_root/.nextcloud-db-before-$stage_id")" == "$source_inode" ]]
  [[ ! -e "$case_root/.db-cutover-$stage_id/data" ]]
done

/usr/bin/rm -rf -- "$fixture/storage"
mkdir -p "$fixture/storage/.db-cutover-$stage_id/data" "$fixture/storage/.nextcloud-db-before-$stage_id" "$fixture/storage/nextcloud_db"
printf 'imported\n' >"$fixture/storage/.db-cutover-$stage_id/data/identity"
printf 'original\n' >"$fixture/storage/.nextcloud-db-before-$stage_id/identity"
printf 'unexpected\n' >"$fixture/storage/nextcloud_db/identity"
export EXPECTED_SOURCE_INODE="$(db_cutover_inode "$fixture/storage/.nextcloud-db-before-$stage_id")"
export EXPECTED_CANDIDATE_INODE="$(db_cutover_inode "$fixture/storage/.db-cutover-$stage_id/data")"
export EXPECTED_CANDIDATE_DIGEST="$(db_cutover_digest "$fixture/storage/.db-cutover-$stage_id/data")"
printf 'switching\n' >"$phase_file"
if bash -e -c 'declare -A P=([NEXTCLOUD_PI_STORAGE_MOUNT]="$DB_SWITCH_STORAGE_MOUNT"); cmd_db_cutover_switch "$stage_id" fingerprint stage-fingerprint' >/dev/null 2>&1; then
  printf 'switch accepted an unexpected canonical database directory\n' >&2
  exit 1
fi
[[ "$(<"$fixture/storage/.nextcloud-db-before-$stage_id/identity")" == original ]]
[[ "$(<"$fixture/storage/.db-cutover-$stage_id/data/identity")" == imported ]]
[[ "$(<"$fixture/storage/nextcloud_db/identity")" == unexpected ]]

printf 'database directory-switch interruption fixture passed\n'
