#!/usr/bin/env bash
set -euo pipefail

# Capture a private, recovery-oriented snapshot of the live Nextcloud files,
# MariaDB database, and Caddy TLS volumes. --check is read-only. --apply enters
# Nextcloud maintenance mode only while the consistent snapshot is streamed to
# this computer, and its trap makes a best effort to leave maintenance mode on
# every exit path.

NEXTCLOUD_PI_HOST="${NEXTCLOUD_PI_HOST:?set NEXTCLOUD_PI_HOST}"
NEXTCLOUD_PI_USER="${NEXTCLOUD_PI_USER:?set NEXTCLOUD_PI_USER}"
NEXTCLOUD_DATA_ROOT="${NEXTCLOUD_DATA_ROOT:-/mnt/example-storage/nextcloud}"
NEXTCLOUD_APP_CONTAINER="${NEXTCLOUD_APP_CONTAINER:-nextcloud-docker-app-1}"
NEXTCLOUD_DB_CONTAINER="${NEXTCLOUD_DB_CONTAINER:-nextcloud-docker-db-1}"
NEXTCLOUD_CADDY_DATA_VOLUME="${NEXTCLOUD_CADDY_DATA_VOLUME:-nextcloud-docker_caddy_data}"
NEXTCLOUD_CADDY_CONFIG_VOLUME="${NEXTCLOUD_CADDY_CONFIG_VOLUME:-nextcloud-docker_caddy_config}"
NEXTCLOUD_RUNTIME_BACKUP_ROOT="${NEXTCLOUD_RUNTIME_BACKUP_ROOT:-$HOME/Projects/nextcloud-pi-backups}"

readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

APPLY=0
# These variables are cleanup capabilities, not just status. They are populated
# only after this process successfully creates or reserves the matching target.
STAGING_DIR=""
PUBLISH_DIR=""
MAINTENANCE_ENABLED=0
REMOTE_LOCK_ARMED=0
REMOTE_LOCK_TOKEN=""
LOCAL_LOCK_DIR=""

readonly REMOTE_LOCK_DIR="/tmp/nextcloud-runtime-backup.lock"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/backup-runtime-state.sh --check
  ./scripts/backup-runtime-state.sh --apply

--check validates prerequisites and reports aggregate source sizes without
changing the Pi. --apply briefly enables Nextcloud maintenance mode and writes
a protected runtime-backup-* directory below NEXTCLOUD_RUNTIME_BACKUP_ROOT.

The backup contains private user data, a database dump, configuration secrets,
and Caddy private keys. Never store it in Git or publish it.
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$1" >&2
}

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"
}

is_safe_remote_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$1" != *"/../"* ]] && [[ "$1" != */.. ]]
}

is_safe_docker_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

require_safe_settings() {
  [[ "$NEXTCLOUD_PI_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "NEXTCLOUD_PI_HOST contains unsupported characters"
  [[ "$NEXTCLOUD_PI_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "NEXTCLOUD_PI_USER contains unsupported characters"
  is_safe_remote_path "$NEXTCLOUD_DATA_ROOT" || die "NEXTCLOUD_DATA_ROOT must be a simple absolute path"
  [[ "$(basename -- "$NEXTCLOUD_DATA_ROOT")" == "nextcloud" ]] ||
    die "NEXTCLOUD_DATA_ROOT must identify the dedicated nextcloud directory"
  is_safe_docker_name "$NEXTCLOUD_APP_CONTAINER" || die "NEXTCLOUD_APP_CONTAINER contains unsupported characters"
  is_safe_docker_name "$NEXTCLOUD_DB_CONTAINER" || die "NEXTCLOUD_DB_CONTAINER contains unsupported characters"
  is_safe_docker_name "$NEXTCLOUD_CADDY_DATA_VOLUME" || die "NEXTCLOUD_CADDY_DATA_VOLUME contains unsupported characters"
  is_safe_docker_name "$NEXTCLOUD_CADDY_CONFIG_VOLUME" || die "NEXTCLOUD_CADDY_CONFIG_VOLUME contains unsupported characters"
  [[ "$NEXTCLOUD_RUNTIME_BACKUP_ROOT" = /* ]] || die "NEXTCLOUD_RUNTIME_BACKUP_ROOT must be an absolute path"
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

reject_git_path() {
  local directory="$1"
  local git_root

  git_root="$(git -C "$directory" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -z "$git_root" ]] || die "runtime backup path must not be inside a Git worktree: $git_root"
}

reject_git_target() {
  local target="$1"
  local ancestor="$target"

  while [[ ! -e "$ancestor" ]]; do
    ancestor="$(dirname -- "$ancestor")"
  done
  reject_git_path "$ancestor"
}

prepare_backup_root() {
  local configured_root="$NEXTCLOUD_RUNTIME_BACKUP_ROOT"
  local parent
  local parent_canonical
  local leaf

  [[ "$configured_root" != "/" ]] || die "runtime backup root must not be the filesystem root"
  [[ ! -L "$configured_root" ]] || die "runtime backup root must not be a symbolic link"
  parent="$(dirname -- "$configured_root")"
  leaf="$(basename -- "$configured_root")"
  [[ "$leaf" != "." && "$leaf" != ".." && -n "$leaf" ]] || die "runtime backup root has an unsafe leaf name"
  [[ -d "$parent" ]] || die "runtime backup root parent must already exist"
  parent_canonical="$(cd -- "$parent" && pwd -P)"
  NEXTCLOUD_RUNTIME_BACKUP_ROOT="$parent_canonical/$leaf"

  # Existing directories are policy boundaries: validate ownership and mode,
  # but never chmod a caller-supplied shared or system directory into place.
  reject_git_target "$NEXTCLOUD_RUNTIME_BACKUP_ROOT"
  if [[ -e "$NEXTCLOUD_RUNTIME_BACKUP_ROOT" ]]; then
    [[ -d "$NEXTCLOUD_RUNTIME_BACKUP_ROOT" && ! -L "$NEXTCLOUD_RUNTIME_BACKUP_ROOT" ]] ||
      die "runtime backup root must be a regular directory"
  else
    (( APPLY != 0 )) || return 0
    umask 077
    mkdir "$NEXTCLOUD_RUNTIME_BACKUP_ROOT"
  fi

  [[ -O "$NEXTCLOUD_RUNTIME_BACKUP_ROOT" ]] || die "runtime backup root must be owned by the current user"
  [[ "$(mode_of "$NEXTCLOUD_RUNTIME_BACKUP_ROOT")" == 700 ]] ||
    die "runtime backup root must already have 0700 permissions"
  reject_git_path "$NEXTCLOUD_RUNTIME_BACKUP_ROOT"
}

maintenance_is_off() {
  remote "docker exec --user www-data '$NEXTCLOUD_APP_CONTAINER' php /var/www/html/occ status" |
    grep -Eq '^[[:space:]]*-[[:space:]]*maintenance:[[:space:]]*false$'
}

disable_maintenance() {
  if (( MAINTENANCE_ENABLED == 0 )); then
    return
  fi

  if remote "docker exec --user www-data '$NEXTCLOUD_APP_CONTAINER' php /var/www/html/occ maintenance:mode --off" >/dev/null 2>&1 &&
    maintenance_is_off; then
    MAINTENANCE_ENABLED=0
    return 0
  else
    warn "automatic maintenance-mode cleanup failed"
    warn "run: ssh $REMOTE docker exec --user www-data $NEXTCLOUD_APP_CONTAINER php /var/www/html/occ maintenance:mode --off"
    return 1
  fi
}

acquire_locks() {
  local local_lock_candidate

  # The owner token makes cleanup safe even when SSH disconnects after mkdir:
  # this process may probe the lock, but cannot remove another client's lock.
  REMOTE_LOCK_TOKEN="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  [[ "$REMOTE_LOCK_TOKEN" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die "could not create a safe lock token"
  REMOTE_LOCK_ARMED=1
  remote "set -e
    if mkdir '$REMOTE_LOCK_DIR'; then
      trap 'rmdir \"$REMOTE_LOCK_DIR\"' EXIT HUP INT TERM
      printf '%s\\n' '$REMOTE_LOCK_TOKEN' >'$REMOTE_LOCK_DIR/owner'
      trap - EXIT HUP INT TERM
    else
      exit 73
    fi
  " >/dev/null || die "another runtime backup may be active; inspect $REMOTE_LOCK_DIR on the Pi"

  local_lock_candidate="$NEXTCLOUD_RUNTIME_BACKUP_ROOT/.runtime-backup.lock"
  if ! mkdir "$local_lock_candidate"; then
    die "another runtime backup may be publishing into $NEXTCLOUD_RUNTIME_BACKUP_ROOT"
  fi
  LOCAL_LOCK_DIR="$local_lock_candidate"
}

release_remote_lock() {
  if (( REMOTE_LOCK_ARMED == 0 )); then
    return 0
  fi

  if remote "set -e
    test -f '$REMOTE_LOCK_DIR/owner'
    test \"\$(cat '$REMOTE_LOCK_DIR/owner')\" = '$REMOTE_LOCK_TOKEN'
    rm '$REMOTE_LOCK_DIR/owner'
    rmdir '$REMOTE_LOCK_DIR'
    test ! -e '$REMOTE_LOCK_DIR'
  " >/dev/null 2>&1; then
    REMOTE_LOCK_ARMED=0
    return 0
  fi

  warn "could not remove this operation's Pi lock: $REMOTE_LOCK_DIR"
  return 1
}

release_local_lock() {
  if [[ -z "$LOCAL_LOCK_DIR" ]]; then
    return 0
  fi

  if rmdir "$LOCAL_LOCK_DIR"; then
    LOCAL_LOCK_DIR=""
    return 0
  fi

  warn "could not remove local runtime-backup lock: $LOCAL_LOCK_DIR"
  return 1
}

cleanup() {
  local status=$?
  local cleanup_failed=0

  # Service availability comes first, followed by operation locks and private
  # partial payloads. Any service/lock cleanup failure changes success to error.
  trap - EXIT
  disable_maintenance || cleanup_failed=1
  release_remote_lock || cleanup_failed=1
  release_local_lock || cleanup_failed=1
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
  if [[ -n "$PUBLISH_DIR" && "$PUBLISH_DIR" == "$NEXTCLOUD_RUNTIME_BACKUP_ROOT"/runtime-backup-* && -d "$PUBLISH_DIR" ]]; then
    rm -rf -- "$PUBLISH_DIR"
  fi
  if (( cleanup_failed != 0 )); then
    exit 1
  fi
  exit "$status"
}

append_manifest_value() {
  local key="$1"
  local value="$2"

  [[ -n "$value" && "$value" != *$'\t'* && "$value" != *$'\n'* ]] || die "unsafe manifest value for $key"
  printf '%s\t%s\n' "$key" "$value" >>"$STAGING_DIR/manifest.tsv"
}

append_manifest_payload() {
  local relative_path="$1"
  local payload="$STAGING_DIR/$relative_path"

  printf 'payload\t%s\t%s\t%s\n' \
    "$relative_path" \
    "$(file_size "$payload")" \
    "$(sha256_file "$payload")" >>"$STAGING_DIR/manifest.tsv"
}

check_prerequisites() {
  local app_mounts
  local caddy_data_path
  local caddy_config_path

  remote "set -e
    test -d '$NEXTCLOUD_DATA_ROOT' && test ! -L '$NEXTCLOUD_DATA_ROOT'
    command -v tar >/dev/null
    command -v sudo >/dev/null
    sudo -n true
    docker inspect '$NEXTCLOUD_APP_CONTAINER' >/dev/null
    docker inspect '$NEXTCLOUD_DB_CONTAINER' >/dev/null
    docker exec '$NEXTCLOUD_DB_CONTAINER' sh -c 'command -v mariadb-dump >/dev/null'
    docker exec '$NEXTCLOUD_DB_CONTAINER' sh -c 'command -v mariadb >/dev/null'
  " >/dev/null
  maintenance_is_off || die "Nextcloud is already in maintenance mode"

  app_mounts="$(remote "docker inspect '$NEXTCLOUD_APP_CONTAINER' --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'")"
  [[ "$(grep -Fxc "$NEXTCLOUD_DATA_ROOT -> /var/www/html" <<<"$app_mounts")" == 1 ]] ||
    die "NEXTCLOUD_DATA_ROOT does not match the app container's /var/www/html mount"

  caddy_data_path="$(remote "docker volume inspect '$NEXTCLOUD_CADDY_DATA_VOLUME' --format '{{.Mountpoint}}'")"
  caddy_config_path="$(remote "docker volume inspect '$NEXTCLOUD_CADDY_CONFIG_VOLUME' --format '{{.Mountpoint}}'")"
  is_safe_remote_path "$caddy_data_path" || die "Caddy data volume has an unsafe mount path"
  is_safe_remote_path "$caddy_config_path" || die "Caddy config volume has an unsafe mount path"

  remote "set -e
    test -d '$caddy_data_path' && test ! -L '$caddy_data_path'
    test -d '$caddy_config_path' && test ! -L '$caddy_config_path'
    sudo -n du -sh '$NEXTCLOUD_DATA_ROOT' '$caddy_data_path' '$caddy_config_path'
    docker exec '$NEXTCLOUD_DB_CONTAINER' sh -c 'du -sh /var/lib/mysql'
  "
}

case "${1:-}" in
  --check)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    ;;
  --apply)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    APPLY=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

require_safe_settings
prepare_backup_root
check_prerequisites

if (( APPLY == 0 )); then
  printf 'CHECK: runtime backup prerequisites passed; no changes were made\n'
  exit 0
fi

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
acquire_locks
maintenance_is_off || die "Nextcloud entered maintenance mode before this backup acquired its lock"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final_dir="$NEXTCLOUD_RUNTIME_BACKUP_ROOT/runtime-backup-$timestamp"
[[ ! -e "$final_dir" ]] || die "runtime backup destination already exists: $final_dir"
staging_candidate="$NEXTCLOUD_RUNTIME_BACKUP_ROOT/.incomplete-runtime-backup-$timestamp-$$"
umask 077
mkdir "$staging_candidate"
STAGING_DIR="$staging_candidate"
mkdir "$STAGING_DIR/nextcloud" "$STAGING_DIR/database" "$STAGING_DIR/caddy"
chmod 700 "$STAGING_DIR" "$STAGING_DIR/nextcloud" "$STAGING_DIR/database" "$STAGING_DIR/caddy"

remote_host="$(remote hostname)"
remote_user="$(remote id -un)"
database_image="$(remote "docker inspect '$NEXTCLOUD_DB_CONTAINER' --format '{{.Config.Image}}'")"
caddy_data_path="$(remote "docker volume inspect '$NEXTCLOUD_CADDY_DATA_VOLUME' --format '{{.Mountpoint}}'")"
caddy_config_path="$(remote "docker volume inspect '$NEXTCLOUD_CADDY_CONFIG_VOLUME' --format '{{.Mountpoint}}'")"
data_parent="$(dirname -- "$NEXTCLOUD_DATA_ROOT")"
data_name="$(basename -- "$NEXTCLOUD_DATA_ROOT")"

printf 'Entering Nextcloud maintenance mode for consistent runtime capture...\n'
# Arm cleanup before the remote command because a lost SSH response cannot tell
# us whether Nextcloud accepted the maintenance-mode change.
MAINTENANCE_ENABLED=1
remote "docker exec --user www-data '$NEXTCLOUD_APP_CONTAINER' php /var/www/html/occ maintenance:mode --on" >/dev/null
maintenance_is_off && die "Nextcloud did not enter maintenance mode"

printf 'Capturing Nextcloud files without listing private paths...\n'
remote "sudo -n tar --numeric-owner --acls --xattrs -cpf - -C '$data_parent' '$data_name'" >"$STAGING_DIR/nextcloud/nextcloud.tar"
chmod 600 "$STAGING_DIR/nextcloud/nextcloud.tar"
[[ -s "$STAGING_DIR/nextcloud/nextcloud.tar" ]] || die "Nextcloud archive is empty"

printf 'Capturing a transaction-consistent MariaDB dump without printing it...\n'
remote "docker exec '$NEXTCLOUD_DB_CONTAINER' sh -eu -c '
  test -n \"\${MYSQL_ROOT_PASSWORD:-}\"
  test -n \"\${MYSQL_DATABASE:-}\"
  export MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\"
  exec mariadb-dump -uroot --single-transaction --quick --routines --triggers --events --hex-blob --default-character-set=utf8mb4 \"\$MYSQL_DATABASE\"
'" >"$STAGING_DIR/database/nextcloud.sql"
chmod 600 "$STAGING_DIR/database/nextcloud.sql"
[[ -s "$STAGING_DIR/database/nextcloud.sql" ]] || die "MariaDB dump is empty"

printf 'Capturing Caddy TLS state without listing private paths...\n'
remote "sudo -n tar --numeric-owner --acls --xattrs -cpf - -C '$caddy_data_path' ." >"$STAGING_DIR/caddy/data.tar"
remote "sudo -n tar --numeric-owner --acls --xattrs -cpf - -C '$caddy_config_path' ." >"$STAGING_DIR/caddy/config.tar"
chmod 600 "$STAGING_DIR/caddy/data.tar" "$STAGING_DIR/caddy/config.tar"
[[ -s "$STAGING_DIR/caddy/data.tar" && -s "$STAGING_DIR/caddy/config.tar" ]] || die "Caddy archive is empty"

disable_maintenance
maintenance_is_off || die "Nextcloud did not leave maintenance mode"

manifest="$STAGING_DIR/manifest.tsv"
: >"$manifest"
chmod 600 "$manifest"
append_manifest_value format "runtime-backup-v1"
append_manifest_value state "complete"
append_manifest_value timestamp "$timestamp"
append_manifest_value remote_host "$remote_host"
append_manifest_value remote_user "$remote_user"
append_manifest_value source_nextcloud "$NEXTCLOUD_DATA_ROOT"
append_manifest_value app_container "$NEXTCLOUD_APP_CONTAINER"
append_manifest_value database_container "$NEXTCLOUD_DB_CONTAINER"
append_manifest_value database_image "$database_image"
append_manifest_value caddy_data_volume "$NEXTCLOUD_CADDY_DATA_VOLUME"
append_manifest_value caddy_config_volume "$NEXTCLOUD_CADDY_CONFIG_VOLUME"
append_manifest_value backup_path "$final_dir"
append_manifest_payload "nextcloud/nextcloud.tar"
append_manifest_payload "database/nextcloud.sql"
append_manifest_payload "caddy/data.tar"
append_manifest_payload "caddy/config.tar"

mkdir "$final_dir" || die "runtime backup destination was claimed by another process"
chmod 700 "$final_dir"
PUBLISH_DIR="$final_dir"
mv "$STAGING_DIR/nextcloud" "$final_dir/nextcloud"
mv "$STAGING_DIR/database" "$final_dir/database"
mv "$STAGING_DIR/caddy" "$final_dir/caddy"
# manifest.tsv is the publication marker. Moving it last ensures a concurrent
# verifier cannot accept a directory whose payload publication was interrupted.
mv "$STAGING_DIR/manifest.tsv" "$final_dir/manifest.tsv"
rmdir "$STAGING_DIR"
STAGING_DIR=""

"$SCRIPT_DIR/verify-runtime-backup.sh" "$final_dir" >/dev/null
PUBLISH_DIR=""
release_remote_lock || die "runtime backup completed but the Pi operation lock could not be removed"
release_local_lock || die "runtime backup completed but the local operation lock could not be removed"
trap - EXIT HUP INT TERM
printf 'Runtime backup completed and verified: %s\n' "$final_dir"
