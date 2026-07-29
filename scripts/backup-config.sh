#!/usr/bin/env bash
set -euo pipefail

# Create a local, configuration-only recovery point from the live Pi. Remote
# operations are read-only, credential-bearing files are streamed directly into
# protected files, and the completed backup is published atomically.

NEXTCLOUD_PI_HOST="${NEXTCLOUD_PI_HOST:?set NEXTCLOUD_PI_HOST}"
NEXTCLOUD_PI_USER="${NEXTCLOUD_PI_USER:?set NEXTCLOUD_PI_USER}"
NEXTCLOUD_REMOTE_PROJECT_DIR="${NEXTCLOUD_REMOTE_PROJECT_DIR:?set NEXTCLOUD_REMOTE_PROJECT_DIR}"
NEXTCLOUD_STORAGE_MOUNT="${NEXTCLOUD_STORAGE_MOUNT:?set NEXTCLOUD_STORAGE_MOUNT}"
NEXTCLOUD_SYSTEMD_UNIT="${NEXTCLOUD_SYSTEMD_UNIT:-/etc/systemd/system/nextcloud.service}"
NEXTCLOUD_BACKUP_ROOT="${NEXTCLOUD_BACKUP_ROOT:-$HOME/Projects/nextcloud-pi-backups}"

readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CONTAINERS=(nextcloud-docker-app-1 nextcloud-docker-db-1 nextcloud-docker-caddy-1)
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
PAYLOAD_FILES=("${REQUIRED_PAYLOAD_FILES[@]}")

STAGING_DIR=""

usage() {
  cat <<'EOF'
Usage: ./scripts/backup-config.sh

Create a protected, configuration-only backup on this computer. The Pi is read
only. Backups are written below $NEXTCLOUD_BACKUP_ROOT (or the value supplied
in that environment variable), never inside this Git repository.
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf "$STAGING_DIR"
  fi
}

is_safe_remote_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$1" != *"/../"* ]] && [[ "$1" != */.. ]]
}

require_safe_settings() {
  [[ "$NEXTCLOUD_PI_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "NEXTCLOUD_PI_HOST contains unsupported characters"
  [[ "$NEXTCLOUD_PI_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "NEXTCLOUD_PI_USER contains unsupported characters"
  is_safe_remote_path "$NEXTCLOUD_REMOTE_PROJECT_DIR" || die "NEXTCLOUD_REMOTE_PROJECT_DIR must be a simple absolute path"
  is_safe_remote_path "$NEXTCLOUD_STORAGE_MOUNT" || die "NEXTCLOUD_STORAGE_MOUNT must be a simple absolute path"
  is_safe_remote_path "$NEXTCLOUD_SYSTEMD_UNIT" || die "NEXTCLOUD_SYSTEMD_UNIT must be a simple absolute path"
  [[ "$NEXTCLOUD_BACKUP_ROOT" = /* ]] || die "NEXTCLOUD_BACKUP_ROOT must be an absolute path"
}

mode_of() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

ensure_protected_directory() {
  local directory="$1"

  mkdir -p "$directory"
  chmod 700 "$directory"
  [[ "$(mode_of "$directory")" == "700" ]] || die "could not protect directory: $directory"
}

reject_git_path() {
  local path="$1"
  local git_root

  git_root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -z "$git_root" ]] || die "backup path must not be inside a Git worktree: $git_root"
}

reject_git_target() {
  local target="$1"
  local ancestor="$target"

  while [[ ! -e "$ancestor" ]]; do
    ancestor="$(dirname -- "$ancestor")"
  done
  reject_git_path "$ancestor"
}

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"
}

copy_remote_file() {
  local remote_path="$1"
  local relative_path="$2"
  local destination="$STAGING_DIR/$relative_path"

  mkdir -p "$(dirname -- "$destination")"
  chmod 700 "$(dirname -- "$destination")"
  remote "test -f '$remote_path' && test ! -L '$remote_path' && cat '$remote_path'" >"$destination"
  chmod 600 "$destination"
}

copy_optional_remote_file() {
  local remote_path="$1"
  local relative_path="$2"

  # Pre-migration deployments have inline credentials and no .env yet. A
  # present .env is protected configuration and must be a regular file.
  if remote "test ! -e '$remote_path' && test ! -L '$remote_path'" >/dev/null; then
    return
  fi
  remote "test -f '$remote_path' && test ! -L '$remote_path'" >/dev/null || die "optional configuration file is not a regular file: $remote_path"
  copy_remote_file "$remote_path" "$relative_path"
  PAYLOAD_FILES+=("$relative_path")
}

capture_remote_command() {
  local relative_path="$1"
  local command="$2"
  local destination="$STAGING_DIR/$relative_path"

  mkdir -p "$(dirname -- "$destination")"
  chmod 700 "$(dirname -- "$destination")"
  remote "$command" >"$destination"
  chmod 600 "$destination"
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

append_manifest_value() {
  local key="$1"
  local value="$2"

  [[ "$value" != *$'\t'* && "$value" != *$'\n'* ]] || die "unsafe manifest value for $key"
  printf '%s\t%s\n' "$key" "$value" >>"$STAGING_DIR/manifest.tsv"
}

append_manifest_container() {
  local name="$1"
  local image="$2"

  [[ "$name" != *$'\t'* && "$name" != *$'\n'* ]] || die "unsafe container name"
  [[ "$image" != *$'\t'* && "$image" != *$'\n'* ]] || die "unsafe container image"
  printf 'container\t%s\t%s\n' "${name#/}" "$image" >>"$STAGING_DIR/manifest.tsv"
}

append_manifest_payload() {
  local relative_path="$1"
  local size="$2"
  local checksum="$3"

  printf 'payload\t%s\t%s\t%s\n' "$relative_path" "$size" "$checksum" >>"$STAGING_DIR/manifest.tsv"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

require_safe_settings
# Refuse Git-owned locations before creating anything, then recheck the
# canonical directory in case the configured path crosses a symbolic link.
reject_git_target "$NEXTCLOUD_BACKUP_ROOT"
ensure_protected_directory "$NEXTCLOUD_BACKUP_ROOT"
reject_git_path "$NEXTCLOUD_BACKUP_ROOT"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final_dir="$NEXTCLOUD_BACKUP_ROOT/config-backup-$timestamp"
[[ ! -e "$final_dir" ]] || die "backup destination already exists: $final_dir"
STAGING_DIR="$NEXTCLOUD_BACKUP_ROOT/.incomplete-config-backup-$timestamp-$$"
trap cleanup EXIT
umask 077
mkdir "$STAGING_DIR"
chmod 700 "$STAGING_DIR"

printf 'Collecting configuration-only backup from %s...\n' "$REMOTE"

# Copy sensitive configuration without sending its contents to the terminal.
copy_remote_file "$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml" "compose/docker-compose.yml"
copy_optional_remote_file "$NEXTCLOUD_REMOTE_PROJECT_DIR/.env" "compose/.env"
copy_remote_file "$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile" "caddy/Caddyfile"
copy_remote_file "$NEXTCLOUD_SYSTEMD_UNIT" "systemd/nextcloud.service"
capture_remote_command "storage/fstab-entry.txt" "awk -v mount='$NEXTCLOUD_STORAGE_MOUNT' '\$2 == mount { print }' /etc/fstab"

# Collect only the operational fields needed to identify and validate this
# recovery point; unrestricted Docker inspection and container environments are
# intentionally excluded.
capture_remote_command "metadata/docker-compose.txt" "set -e; cd '$NEXTCLOUD_REMOTE_PROJECT_DIR'; if docker compose version >/dev/null 2>&1; then compose='docker compose'; else compose='docker-compose'; fi; \$compose config --services; \$compose config --images; \$compose ps --format '{{.Name}} {{.Image}} {{.State}}'"

container_command="set -e;"
for container in "${CONTAINERS[@]}"; do
  container_command+=" docker inspect '$container' --format '{{.Name}} {{.Config.Image}}';"
done
capture_remote_command "metadata/docker-containers.txt" "$container_command"
capture_remote_command "metadata/mount-state.txt" "findmnt -rn --target '$NEXTCLOUD_STORAGE_MOUNT' -o TARGET,SOURCE,FSTYPE,OPTIONS"
capture_remote_command "metadata/nextcloud-status.txt" "set -e; status=\$(docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status); printf '%s\\n' \"\$status\" | grep -E '^[[:space:]]*-[[:space:]]*(installed|version|versionstring|maintenance|needsDbUpgrade):'"
capture_remote_command "metadata/nextcloud-data-directory.txt" "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ config:system:get datadirectory"
capture_remote_command "metadata/nextcloud-trusted-domains.txt" "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ config:system:get trusted_domains"

[[ -s "$STAGING_DIR/storage/fstab-entry.txt" ]] || die "no /etc/fstab entry was found for $NEXTCLOUD_STORAGE_MOUNT"
[[ -s "$STAGING_DIR/metadata/docker-containers.txt" ]] || die "container metadata was empty"
[[ -s "$STAGING_DIR/metadata/mount-state.txt" ]] || die "mount metadata was empty"

remote_hostname="$(remote hostname)"
remote_username="$(remote id -un)"
# The live deployment is not required to be a Git checkout. Preserve its
# revision when available, but keep a usable recovery point when it is not.
remote_commit="$(remote "if git -C '$NEXTCLOUD_REMOTE_PROJECT_DIR' rev-parse --verify HEAD >/dev/null 2>&1; then git -C '$NEXTCLOUD_REMOTE_PROJECT_DIR' rev-parse HEAD; else printf '%s\\n' unavailable; fi")"
[[ -n "$remote_hostname" ]] || die "remote hostname was empty"
[[ "$remote_username" == "$NEXTCLOUD_PI_USER" ]] || die "remote username did not match $NEXTCLOUD_PI_USER"
[[ "$remote_commit" == "unavailable" || "$remote_commit" =~ ^[0-9a-f]{40}$ ]] || die "remote deployment commit had an unexpected value"

# The manifest records non-secret provenance plus the size and digest of every
# payload so verification never needs to contact the Pi.
manifest="$STAGING_DIR/manifest.tsv"
: >"$manifest"
chmod 600 "$manifest"
append_manifest_value format "config-backup-v1"
append_manifest_value state "complete"
append_manifest_value timestamp "$timestamp"
append_manifest_value remote_host "$remote_hostname"
append_manifest_value remote_user "$remote_username"
append_manifest_value deployment_commit "$remote_commit"
append_manifest_value source_project "$NEXTCLOUD_REMOTE_PROJECT_DIR"
append_manifest_value backup_path "$final_dir"
append_manifest_value mount_state "$(tr '\n\t' '  ' <"$STAGING_DIR/metadata/mount-state.txt")"

while IFS=' ' read -r container_name container_image; do
  [[ -n "$container_name" && -n "$container_image" ]] || die "invalid Docker container metadata"
  append_manifest_container "$container_name" "$container_image"
done <"$STAGING_DIR/metadata/docker-containers.txt"

for relative_path in "${PAYLOAD_FILES[@]}"; do
  file="$STAGING_DIR/$relative_path"
  [[ -f "$file" && ! -L "$file" ]] || die "missing or symbolic-link payload: $relative_path"
  append_manifest_payload "$relative_path" "$(file_size "$file")" "$(sha256 "$file")"
done

# A same-filesystem rename prevents partially collected staging data from being
# mistaken for a published backup.
mv "$STAGING_DIR" "$final_dir"
STAGING_DIR=""

printf 'Backup completed: %s\n' "$final_dir"
printf 'Verify it before any recovery use: %s %q\n' "$SCRIPT_DIR/verify-config-backup.sh" "$final_dir"
