#!/usr/bin/env bash
set -euo pipefail

# Verify the closed runtime-backup-v1 schema, permissions, archive readability,
# and payload integrity entirely offline without listing private archive paths.

readonly EXPECTED_DIRECTORIES=(nextcloud database caddy)
readonly REQUIRED_FILES=(
  manifest.tsv
  nextcloud/nextcloud.tar
  database/nextcloud.sql
  caddy/data.tar
  caddy/config.tar
)
readonly PAYLOAD_FILES=(
  nextcloud/nextcloud.tar
  database/nextcloud.sql
  caddy/data.tar
  caddy/config.tar
)

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-runtime-backup.sh <runtime-backup-directory>

Validate a private runtime-state backup without contacting the Raspberry Pi.
EOF
}

die() {
  printf 'Verification failed: %s\n' "$1" >&2
  exit 1
}

mode_of() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_size() {
  wc -c <"$1" | tr -d '[:space:]'
}

contains() {
  local needle="$1"
  shift
  local value

  for value in "$@"; do
    [[ "$value" == "$needle" ]] && return 0
  done
  return 1
}

validate_archive_namespace() {
  local archive="$1"
  local expected_prefix="$2"

  # Checksums prove bytes did not change after publication, but they do not
  # make a deliberately rebuilt archive safe for privileged extraction. This
  # closed namespace rejects traversal, device nodes, duplicates, and links
  # that could escape an isolated restore root.
  command -v python3 >/dev/null 2>&1 || die "python3 is required to validate archive namespaces"
  python3 - "$archive" "$expected_prefix" <<'PY' || return 1
import posixpath
import sys
import tarfile

archive_path, expected_prefix = sys.argv[1:]
seen = set()
prefix_seen = not expected_prefix

with tarfile.open(archive_path, "r:*") as archive:
    for member in archive:
        name = member.name
        if not name or "\0" in name or posixpath.isabs(name):
            raise SystemExit(1)
        normalized = posixpath.normpath(name)
        if normalized == ".." or normalized.startswith("../"):
            raise SystemExit(1)
        if normalized in seen:
            raise SystemExit(1)
        seen.add(normalized)

        if expected_prefix:
            if normalized != expected_prefix and not normalized.startswith(expected_prefix + "/"):
                raise SystemExit(1)
            if normalized == expected_prefix:
                prefix_seen = True

        if member.isdev() or member.isfifo():
            raise SystemExit(1)
        if member.issym() or member.islnk():
            link = member.linkname
            if not link or "\0" in link or posixpath.isabs(link):
                raise SystemExit(1)
            base = posixpath.dirname(normalized) if member.issym() else ""
            resolved = posixpath.normpath(posixpath.join(base, link))
            if resolved == ".." or resolved.startswith("../"):
                raise SystemExit(1)
            if expected_prefix and resolved != expected_prefix and not resolved.startswith(expected_prefix + "/"):
                raise SystemExit(1)

if not seen or not prefix_seen:
    raise SystemExit(1)
PY
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
backup_dir="$1"

[[ -d "$backup_dir" && ! -L "$backup_dir" ]] || die "backup directory is missing or symbolic-linked"
backup_dir="$(cd -- "$backup_dir" && pwd -P)"
backup_name="$(basename -- "$backup_dir")"
[[ "$backup_name" =~ ^runtime-backup-[0-9]{8}T[0-9]{6}Z$ ]] || die "backup directory has an unexpected name"

git_root="$(git -C "$backup_dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$git_root" ]] || die "runtime backup is stored inside a Git worktree: $git_root"
[[ "$(mode_of "$backup_dir")" == 700 ]] || die "backup directory permissions must be 0700"

for relative_dir in "${EXPECTED_DIRECTORIES[@]}"; do
  directory="$backup_dir/$relative_dir"
  [[ -d "$directory" && ! -L "$directory" ]] || die "missing or symbolic-link directory: $relative_dir"
  [[ "$(mode_of "$directory")" == 700 ]] || die "directory permissions must be 0700: $relative_dir"
done

for relative_file in "${REQUIRED_FILES[@]}"; do
  payload="$backup_dir/$relative_file"
  [[ -f "$payload" && ! -L "$payload" ]] || die "missing or symbolic-link file: $relative_file"
  [[ "$(mode_of "$payload")" == 600 ]] || die "file permissions must be 0600: $relative_file"
  [[ -s "$payload" ]] || die "file is empty: $relative_file"
done

while IFS= read -r -d '' entry; do
  relative_entry="${entry#$backup_dir/}"
  if [[ -L "$entry" ]]; then
    die "symbolic links are not allowed: $relative_entry"
  elif [[ -d "$entry" ]]; then
    contains "$relative_entry" "${EXPECTED_DIRECTORIES[@]}" || die "unexpected directory: $relative_entry"
  elif [[ -f "$entry" ]]; then
    contains "$relative_entry" "${REQUIRED_FILES[@]}" || die "unexpected file: $relative_entry"
  else
    die "unexpected non-regular payload: $relative_entry"
  fi
done < <(find "$backup_dir" -mindepth 1 -print0)

manifest="$backup_dir/manifest.tsv"
# The manifest is also the publication marker. Requiring its closed schema and
# every payload entry prevents an interrupted directory from becoming usable.
for field in format state timestamp remote_host remote_user source_nextcloud app_container database_container database_image caddy_data_volume caddy_config_volume backup_path; do
  [[ "$(awk -F $'\t' -v key="$field" '$1 == key { count++ } END { print count + 0 }' "$manifest")" == 1 ]] ||
    die "manifest must contain exactly one $field field"
done
grep -Fx $'format\truntime-backup-v1' "$manifest" >/dev/null || die "unsupported manifest format"
grep -Fx $'state\tcomplete' "$manifest" >/dev/null || die "backup is incomplete"

manifest_timestamp="$(awk -F $'\t' '$1 == "timestamp" { print $2 }' "$manifest")"
manifest_backup_path="$(awk -F $'\t' '$1 == "backup_path" { print $2 }' "$manifest")"
manifest_source_nextcloud="$(awk -F $'\t' '$1 == "source_nextcloud" { print $2 }' "$manifest")"
[[ "$backup_name" == "runtime-backup-$manifest_timestamp" ]] || die "directory name does not match manifest timestamp"
[[ -d "$manifest_backup_path" && "$manifest_backup_path" -ef "$backup_dir" ]] || die "backup path does not match its manifest"
[[ "$manifest_source_nextcloud" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "manifest Nextcloud source path is unsafe"
nextcloud_archive_prefix="$(basename -- "$manifest_source_nextcloud")"
[[ -n "$nextcloud_archive_prefix" && "$nextcloud_archive_prefix" != "." && "$nextcloud_archive_prefix" != ".." ]] ||
  die "manifest Nextcloud source path has an unsafe basename"

seen_payloads=""
while IFS=$'\t' read -r record first second third extra; do
  case "$record" in
    format|state|timestamp|remote_host|remote_user|source_nextcloud|app_container|database_container|database_image|caddy_data_volume|caddy_config_volume|backup_path)
      [[ -n "$first" && -z "$second" && -z "$third" && -z "$extra" ]] || die "invalid $record entry"
      ;;
    payload)
      [[ -z "$extra" && -n "$first" && "$second" =~ ^[0-9]+$ && "$third" =~ ^[0-9a-f]{64}$ ]] || die "invalid payload entry"
      contains "$first" "${PAYLOAD_FILES[@]}" || die "unexpected manifest payload: $first"
      [[ ",$seen_payloads," != *",$first,"* ]] || die "duplicate manifest payload: $first"
      seen_payloads+="${seen_payloads:+,}$first"
      payload="$backup_dir/$first"
      [[ "$(file_size "$payload")" == "$second" ]] || die "size mismatch: $first"
      [[ "$(sha256_file "$payload")" == "$third" ]] || die "checksum mismatch: $first"
      ;;
    *) die "unknown manifest entry: ${record:-empty}" ;;
  esac
done <"$manifest"

for relative_file in "${PAYLOAD_FILES[@]}"; do
  [[ ",$seen_payloads," == *",$relative_file,"* ]] || die "missing manifest payload: $relative_file"
done

validate_archive_namespace "$backup_dir/nextcloud/nextcloud.tar" "$nextcloud_archive_prefix" ||
  die "Nextcloud archive has an unsafe namespace"
validate_archive_namespace "$backup_dir/caddy/data.tar" "" ||
  die "Caddy data archive has an unsafe namespace"
validate_archive_namespace "$backup_dir/caddy/config.tar" "" ||
  die "Caddy config archive has an unsafe namespace"

printf 'Runtime backup verified: %s\n' "$backup_dir"
