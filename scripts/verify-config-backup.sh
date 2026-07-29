#!/usr/bin/env bash
set -euo pipefail

# Validate a published configuration backup entirely offline. The verifier
# enforces a closed payload schema, protected permissions, provenance records,
# and exact byte sizes and SHA-256 checksums before declaring it usable.

# These lists define the only directory, file, and container records accepted
# by the current manifest format.
readonly EXPECTED_DIRECTORIES=(compose caddy systemd storage metadata)
readonly REQUIRED_FILES=(
  manifest.tsv
  compose/docker-compose.yml
  caddy/Caddyfile
  systemd/nextcloud.service
  storage/fstab-entry.txt
  metadata/docker-compose.txt
  metadata/docker-containers.txt
  metadata/mount-state.txt
  metadata/nextcloud-status.txt
  metadata/nextcloud-data-directory.txt
  metadata/nextcloud-trusted-domains.txt
)
readonly OPTIONAL_FILES=(compose/.env)
readonly REQUIRED_PAYLOAD_FILES=(
  compose/docker-compose.yml
  caddy/Caddyfile
  systemd/nextcloud.service
  storage/fstab-entry.txt
  metadata/docker-compose.txt
  metadata/docker-containers.txt
  metadata/mount-state.txt
  metadata/nextcloud-status.txt
  metadata/nextcloud-data-directory.txt
  metadata/nextcloud-trusted-domains.txt
)
readonly OPTIONAL_PAYLOAD_FILES=(compose/.env)
readonly EXPECTED_CONTAINERS=(nextcloud-docker-app-1 nextcloud-docker-db-1 nextcloud-docker-caddy-1)

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-config-backup.sh <backup-directory>

Validate a configuration-only backup without contacting the Raspberry Pi.
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

sha256() {
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

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
backup_dir="$1"

[[ -d "$backup_dir" && ! -L "$backup_dir" ]] || die "backup directory is missing or symbolic-linked"
backup_dir="$(cd -- "$backup_dir" && pwd -P)"
backup_name="$(basename -- "$backup_dir")"
[[ "$backup_name" == config-backup-* ]] || die "backup directory is incomplete or has an unexpected name"

git_root="$(git -C "$backup_dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$git_root" ]] || die "backup is stored inside a Git worktree: $git_root"
[[ "$(mode_of "$backup_dir")" == "700" ]] || die "backup directory permissions must be 0700"

# Verify permissions before reading any payload content.
for relative_dir in "${EXPECTED_DIRECTORIES[@]}"; do
  path="$backup_dir/$relative_dir"
  [[ -d "$path" && ! -L "$path" ]] || die "missing or symbolic-link directory: $relative_dir"
  [[ "$(mode_of "$path")" == "700" ]] || die "directory permissions must be 0700: $relative_dir"
done

for relative_file in "${REQUIRED_FILES[@]}"; do
  path="$backup_dir/$relative_file"
  [[ -f "$path" && ! -L "$path" ]] || die "missing or symbolic-link file: $relative_file"
  [[ "$(mode_of "$path")" == "600" ]] || die "file permissions must be 0600: $relative_file"
done

for relative_file in "${OPTIONAL_FILES[@]}"; do
  path="$backup_dir/$relative_file"
  [[ ! -e "$path" && ! -L "$path" ]] && continue
  [[ -f "$path" && ! -L "$path" ]] || die "optional file is not regular: $relative_file"
  [[ "$(mode_of "$path")" == "600" ]] || die "file permissions must be 0600: $relative_file"
done

# Reject additions and symbolic links so an otherwise valid manifest cannot
# hide or redirect unverified material.
while IFS= read -r -d '' path; do
  relative_path="${path#$backup_dir/}"
  if [[ -L "$path" ]]; then
    die "symbolic links are not allowed: $relative_path"
  elif [[ -d "$path" ]]; then
    contains "$relative_path" "${EXPECTED_DIRECTORIES[@]}" || die "unexpected directory: $relative_path"
  elif [[ -f "$path" ]]; then
    contains "$relative_path" "${REQUIRED_FILES[@]}" "${OPTIONAL_FILES[@]}" || die "unexpected file: $relative_path"
  else
    die "unexpected non-regular payload: $relative_path"
  fi
done < <(find "$backup_dir" -mindepth 1 -print0)

# Validate the complete manifest schema and provenance before trusting its
# checksums.
manifest="$backup_dir/manifest.tsv"
for field in format state timestamp remote_host remote_user deployment_commit source_project backup_path mount_state; do
  [[ "$(awk -F '\t' -v key="$field" '$1 == key { count++ } END { print count + 0 }' "$manifest")" == "1" ]] || die "manifest must contain exactly one $field field"
done
grep -Fx $'format\tconfig-backup-v1' "$manifest" >/dev/null || die "unsupported manifest format"
grep -Fx $'state\tcomplete' "$manifest" >/dev/null || die "backup is incomplete"

seen_payloads=""
seen_containers=""
container_count=0
while IFS=$'\t' read -r record first second third extra; do
  case "$record" in
    format|state|timestamp|remote_host|remote_user|deployment_commit|source_project|backup_path|mount_state)
      [[ -n "$first" && -z "$second" && -z "$third" && -z "$extra" ]] || die "invalid $record entry in manifest"
      ;;
    container)
      [[ -n "$first" && -n "$second" && -z "$third" && -z "$extra" ]] || die "invalid container entry in manifest"
      contains "$first" "${EXPECTED_CONTAINERS[@]}" || die "unexpected container in manifest: $first"
      [[ ",$seen_containers," != *",$first,"* ]] || die "duplicate container in manifest: $first"
      seen_containers+="${seen_containers:+,}$first"
      container_count=$((container_count + 1))
      ;;
    payload)
      relative_path="$first"
      expected_size="$second"
      expected_checksum="$third"
      [[ -z "$extra" && -n "$relative_path" && "$expected_size" =~ ^[0-9]+$ && "$expected_checksum" =~ ^[0-9a-f]{64}$ ]] || die "invalid payload entry in manifest"
      contains "$relative_path" "${REQUIRED_PAYLOAD_FILES[@]}" "${OPTIONAL_PAYLOAD_FILES[@]}" || die "unexpected manifest payload: $relative_path"
      [[ ",$seen_payloads," != *",$relative_path,"* ]] || die "duplicate manifest payload: $relative_path"
      seen_payloads+="${seen_payloads:+,}$relative_path"
      path="$backup_dir/$relative_path"
      [[ "$(file_size "$path")" == "$expected_size" ]] || die "size mismatch: $relative_path"
      [[ "$(sha256 "$path")" == "$expected_checksum" ]] || die "checksum mismatch: $relative_path"
      ;;
    *) die "unknown manifest entry: ${record:-empty}" ;;
  esac
done <"$manifest"

for relative_path in "${REQUIRED_PAYLOAD_FILES[@]}"; do
  [[ ",$seen_payloads," == *",$relative_path,"* ]] || die "missing manifest payload: $relative_path"
done
for relative_path in "${OPTIONAL_PAYLOAD_FILES[@]}"; do
  path="$backup_dir/$relative_path"
  if [[ -f "$path" ]]; then
    [[ ",$seen_payloads," == *",$relative_path,"* ]] || die "missing manifest payload: $relative_path"
  else
    [[ ",$seen_payloads," != *",$relative_path,"* ]] || die "manifest payload has no file: $relative_path"
  fi
done
[[ "$container_count" -eq "${#EXPECTED_CONTAINERS[@]}" ]] || die "manifest container count is incomplete"
for container_name in "${EXPECTED_CONTAINERS[@]}"; do
  [[ ",$seen_containers," == *",$container_name,"* ]] || die "missing manifest container: $container_name"
done

printf 'Backup verified: %s\n' "$backup_dir"
