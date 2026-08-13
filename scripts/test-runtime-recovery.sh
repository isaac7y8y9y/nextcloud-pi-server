#!/usr/bin/env bash
set -euo pipefail

# Restore a verified runtime backup only into disposable Pi paths and a
# disposable MariaDB container and bind directory. The live Nextcloud, database, and Caddy
# paths are read-only throughout this drill.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/deployment-config.sh"
load_deployment_config "$REPOSITORY_ROOT"
source "$SCRIPT_DIR/lib/image-lock.sh"
image_lock_load "$REPOSITORY_ROOT"

NEXTCLOUD_DATA_ROOT="${NEXTCLOUD_DATA_ROOT:-$NEXTCLOUD_STORAGE_MOUNT/nextcloud}"
NEXTCLOUD_DB_CONTAINER="${NEXTCLOUD_DB_CONTAINER:-nextcloud-docker-db-1}"
NEXTCLOUD_CADDY_DATA_VOLUME="${NEXTCLOUD_CADDY_DATA_VOLUME:-nextcloud-docker_caddy_data}"
NEXTCLOUD_CADDY_CONFIG_VOLUME="${NEXTCLOUD_CADDY_CONFIG_VOLUME:-nextcloud-docker_caddy_config}"

readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"

APPLY=0
CLEANUP_ONLY=0
BACKUP_DIR=""
RECOVERY_TEST_ID=""
REMOTE_TEST_ROOT=""
TEST_DB_CONTAINER=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/test-runtime-recovery.sh --check <runtime-backup-directory>
  ./scripts/test-runtime-recovery.sh --apply <runtime-backup-directory>
  ./scripts/test-runtime-recovery.sh --cleanup <recovery-test-id>

--check validates the backup, target identity, tools, and free space without
changing the Pi. --apply restores into disposable locations, verifies the
restored state, and removes those locations. It never targets live paths.

--cleanup retries removal of disposable targets from a failed --apply run. Use
the recovery-test ID printed by that run; live paths are never accepted.
EOF
}

die() {
  printf 'Recovery test failed: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$1" >&2
}

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"
}

validate_runtime_recovery_image_identity() {
  local tag expected

  # Before the safety baseline exists, the source lock is the only available
  # identity authority. Once a validator exists, an absent or malformed record
  # must fail there instead of silently falling back to source mode.
  if remote "sudo -n test -x /usr/local/libexec/nextcloud-pi-validate-active-images"; then
    remote "sudo -n /usr/local/libexec/nextcloud-pi-validate-active-images" ||
      { die "installed active-image validator rejected the Pi image state"; return 1; }
    return 0
  fi

  remote "sudo -n test ! -e /etc/nextcloud-pi/active-images.env && sudo -n test ! -L /etc/nextcloud-pi/active-images.env" ||
    { die "active-image validator is absent but an active-image record exists"; return 1; }
  while IFS= read -r tag; do
    expected="$(image_lock_expected_id "$tag")"
    remote "docker image inspect --format '{{.Id}}' '$tag' | grep -Fx '$expected' >/dev/null" </dev/null ||
      { die "source-locked image is missing or differs: $tag"; return 1; }
  done < <(image_lock_tags)
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
  is_safe_docker_name "$NEXTCLOUD_DB_CONTAINER" || die "NEXTCLOUD_DB_CONTAINER contains unsupported characters"
  is_safe_docker_name "$NEXTCLOUD_CADDY_DATA_VOLUME" || die "NEXTCLOUD_CADDY_DATA_VOLUME contains unsupported characters"
  is_safe_docker_name "$NEXTCLOUD_CADDY_CONFIG_VOLUME" || die "NEXTCLOUD_CADDY_CONFIG_VOLUME contains unsupported characters"
}

verify_configured_remote_identity() {
  local connected_hostname
  local connected_user

  connected_hostname="$(remote hostname)"
  connected_user="$(remote id -un)"
  [[ "$connected_hostname" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" ]] ||
    die "connected host does not match the configured deployment target"
  [[ "$connected_user" == "$NEXTCLOUD_PI_USER" ]] ||
    die "connected user does not match the configured deployment target"
}

manifest_value() {
  local key="$1"

  awk -F $'\t' -v key="$key" '$1 == key { print $2 }' "$BACKUP_DIR/manifest.tsv"
}

cleanup_targets() {
  local cleanup_failed=0

  # Cleanup is part of the acceptance test. Do not report success until Docker
  # and the filesystem independently confirm that every disposable target is
  # absent; retained identifiers become exact manual recovery instructions.
  if [[ -n "$TEST_DB_CONTAINER" ]]; then
    if ! remote "set -e
      if docker inspect '$TEST_DB_CONTAINER' >/dev/null 2>&1; then
        docker rm -f '$TEST_DB_CONTAINER' >/dev/null
      fi
      ! docker inspect '$TEST_DB_CONTAINER' >/dev/null 2>&1
    " >/dev/null 2>&1; then
      warn "could not verify removal of disposable container: $TEST_DB_CONTAINER"
      warn "retry with: ./scripts/test-runtime-recovery.sh --cleanup $RECOVERY_TEST_ID"
      cleanup_failed=1
    fi
  fi
  if [[ -n "$REMOTE_TEST_ROOT" && "$REMOTE_TEST_ROOT" == "$NEXTCLOUD_STORAGE_MOUNT"/.nextcloud-recovery-test-* ]]; then
    if ! remote "set -e
      if test -d '$REMOTE_TEST_ROOT'; then
        sudo -n find '$REMOTE_TEST_ROOT' -depth -delete
      fi
      test ! -e '$REMOTE_TEST_ROOT'
    " >/dev/null 2>&1; then
      warn "could not verify removal of the disposable recovery directory"
      warn "retry with: ./scripts/test-runtime-recovery.sh --cleanup $RECOVERY_TEST_ID"
      cleanup_failed=1
    fi
  fi
  (( cleanup_failed == 0 ))
}

cleanup() {
  local status=$?

  trap - EXIT
  if ! cleanup_targets; then
    exit 1
  fi
  exit "$status"
}

verify_target_binding() {
  local current_host
  local current_user
  local current_database_image
  local available_bytes
  local required_bytes
  local nextcloud_archive_bytes
  local database_dump_bytes
  local caddy_data_archive_bytes
  local caddy_config_archive_bytes

  current_host="$(remote hostname)"
  current_user="$(remote id -un)"
  current_database_image="$(remote "docker inspect '$NEXTCLOUD_DB_CONTAINER' --format '{{.Config.Image}}'")"

  [[ "$(manifest_value remote_host)" == "$current_host" ]] || die "backup host does not match the connected Pi"
  [[ "$(manifest_value remote_user)" == "$current_user" ]] || die "backup user does not match the connected Pi"
  [[ "$(manifest_value source_nextcloud)" == "$NEXTCLOUD_DATA_ROOT" ]] || die "backup Nextcloud path does not match the configured live path"
  [[ "$(manifest_value database_container)" == "$NEXTCLOUD_DB_CONTAINER" ]] || die "backup database container does not match"
  [[ "$(manifest_value database_image)" == "$current_database_image" ]] || die "backup database image does not match"
  [[ "$current_database_image" == "$NEXTCLOUD_IMAGE_DB_TAG" ]] || die "live database tag is not locked"
  [[ "$(remote "docker image inspect --format '{{.Id}}' '$NEXTCLOUD_IMAGE_DB_TAG'")" == "$NEXTCLOUD_IMAGE_DB_ID" ]] || die "live database image ID is not locked"
  [[ "$(manifest_value caddy_data_volume)" == "$NEXTCLOUD_CADDY_DATA_VOLUME" ]] || die "backup Caddy data volume does not match"
  [[ "$(manifest_value caddy_config_volume)" == "$NEXTCLOUD_CADDY_CONFIG_VOLUME" ]] || die "backup Caddy config volume does not match"

  remote "set -e
    command -v tar >/dev/null
    command -v openssl >/dev/null
    sudo -n true
    docker exec '$NEXTCLOUD_DB_CONTAINER' sh -c 'command -v mariadb >/dev/null'
    docker exec '$NEXTCLOUD_DB_CONTAINER' sh -c 'command -v mariadb-check >/dev/null'
  " >/dev/null

  nextcloud_archive_bytes="$(wc -c <"$BACKUP_DIR/nextcloud/nextcloud.tar" | tr -d '[:space:]')"
  database_dump_bytes="$(wc -c <"$BACKUP_DIR/database/nextcloud.sql" | tr -d '[:space:]')"
  caddy_data_archive_bytes="$(wc -c <"$BACKUP_DIR/caddy/data.tar" | tr -d '[:space:]')"
  caddy_config_archive_bytes="$(wc -c <"$BACKUP_DIR/caddy/config.tar" | tr -d '[:space:]')"
  # Every restore target, including MariaDB's bind directory, lives below the
  # configured storage mount. Budget archive-sized extraction space, three times the SQL dump
  # for database expansion, and one GiB of operational margin.
  required_bytes=$((nextcloud_archive_bytes + database_dump_bytes * 3 + caddy_data_archive_bytes + caddy_config_archive_bytes + 1073741824))
  available_bytes="$(remote "df -B1 --output=avail '$NEXTCLOUD_STORAGE_MOUNT' | tail -1 | tr -d '[:space:]'")"
  [[ "$available_bytes" =~ ^[0-9]+$ ]] || die "could not determine Pi free space"
  (( available_bytes > required_bytes )) || die "insufficient Pi space for isolated recovery test"

  printf 'CHECK: verified backup belongs to this Pi and isolated recovery space is available\n'
}

case "${1:-}" in
  --check)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    BACKUP_DIR="$2"
    ;;
  --apply)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    APPLY=1
    BACKUP_DIR="$2"
    ;;
  --cleanup)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    CLEANUP_ONLY=1
    RECOVERY_TEST_ID="$2"
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
if (( CLEANUP_ONLY != 0 )); then
  [[ "$RECOVERY_TEST_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die "recovery-test ID has an unexpected format"
  REMOTE_TEST_ROOT="$NEXTCLOUD_STORAGE_MOUNT/.nextcloud-recovery-test-$RECOVERY_TEST_ID"
  TEST_DB_CONTAINER="nextcloud-recovery-test-db-$RECOVERY_TEST_ID"
  verify_configured_remote_identity
  cleanup_targets || die "disposable recovery targets still require manual cleanup"
  printf 'RECOVERY: disposable recovery-test targets are absent\n'
  exit 0
fi
"$SCRIPT_DIR/verify-runtime-backup.sh" "$BACKUP_DIR" >/dev/null
BACKUP_DIR="$(cd -- "$BACKUP_DIR" && pwd -P)"
verify_target_binding

if (( APPLY == 0 )); then
  printf 'CHECK: recovery drill prerequisites passed; no changes were made\n'
  exit 0
fi

RECOVERY_TEST_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
REMOTE_TEST_ROOT="$NEXTCLOUD_STORAGE_MOUNT/.nextcloud-recovery-test-$RECOVERY_TEST_ID"
TEST_DB_CONTAINER="nextcloud-recovery-test-db-$RECOVERY_TEST_ID"
printf 'Recovery-test ID: %s\n' "$RECOVERY_TEST_ID"
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

remote "set -e
  test ! -e '$REMOTE_TEST_ROOT'
  sudo -n install -d -m 0700 -o '$NEXTCLOUD_PI_USER' -g '$NEXTCLOUD_PI_USER' '$REMOTE_TEST_ROOT'
  # Separate roots add defense in depth to the verifier's archive namespaces:
  # one archive cannot replace another archive's extraction directory.
  install -d -m 0700 \
    '$REMOTE_TEST_ROOT/nextcloud-restore' \
    '$REMOTE_TEST_ROOT/caddy-data-restore' \
    '$REMOTE_TEST_ROOT/caddy-config-restore' \
    '$REMOTE_TEST_ROOT/mariadb-data'
" >/dev/null

printf 'Restoring Nextcloud archive into an isolated Pi directory...\n'
remote "test -d '$REMOTE_TEST_ROOT/nextcloud-restore' && test ! -L '$REMOTE_TEST_ROOT/nextcloud-restore' &&
  sudo -n tar --numeric-owner --acls --xattrs -xpf - -C '$REMOTE_TEST_ROOT/nextcloud-restore'" <"$BACKUP_DIR/nextcloud/nextcloud.tar"
remote "test -d '$REMOTE_TEST_ROOT/nextcloud-restore' && test ! -L '$REMOTE_TEST_ROOT/nextcloud-restore' &&
  sudo -n tar --compare -f - -C '$REMOTE_TEST_ROOT/nextcloud-restore' >/dev/null 2>&1" <"$BACKUP_DIR/nextcloud/nextcloud.tar" ||
  die "restored Nextcloud tree differs from its archive"
printf 'CHECK: isolated Nextcloud restore matches its protected archive\n'

printf 'Restoring and comparing Caddy TLS state in isolated directories...\n'
remote "test -d '$REMOTE_TEST_ROOT/caddy-data-restore' && test ! -L '$REMOTE_TEST_ROOT/caddy-data-restore' &&
  sudo -n tar --numeric-owner --acls --xattrs -xpf - -C '$REMOTE_TEST_ROOT/caddy-data-restore'" <"$BACKUP_DIR/caddy/data.tar"
remote "test -d '$REMOTE_TEST_ROOT/caddy-config-restore' && test ! -L '$REMOTE_TEST_ROOT/caddy-config-restore' &&
  sudo -n tar --numeric-owner --acls --xattrs -xpf - -C '$REMOTE_TEST_ROOT/caddy-config-restore'" <"$BACKUP_DIR/caddy/config.tar"
remote "test -d '$REMOTE_TEST_ROOT/caddy-data-restore' && test ! -L '$REMOTE_TEST_ROOT/caddy-data-restore' &&
  sudo -n tar --compare -f - -C '$REMOTE_TEST_ROOT/caddy-data-restore' >/dev/null 2>&1" <"$BACKUP_DIR/caddy/data.tar" ||
  die "restored Caddy data differs from its archive"
remote "test -d '$REMOTE_TEST_ROOT/caddy-config-restore' && test ! -L '$REMOTE_TEST_ROOT/caddy-config-restore' &&
  sudo -n tar --compare -f - -C '$REMOTE_TEST_ROOT/caddy-config-restore' >/dev/null 2>&1" <"$BACKUP_DIR/caddy/config.tar" ||
  die "restored Caddy config differs from its archive"
printf 'CHECK: isolated Caddy TLS restore matches its protected archives\n'

printf 'Restoring MariaDB into a disposable container and configured storage bind directory...\n'
database_image="$(manifest_value database_image)"
[[ "$database_image" =~ ^[A-Za-z0-9][A-Za-z0-9_./:@-]*$ ]] || die "manifest database image contains unsupported characters"
validate_runtime_recovery_image_identity
remote "set -eu
  # The random test credential exists only in a 0600 remote temp file and the
  # disposable container environment; it is never returned to local output.
  test_environment=\"\$(mktemp /tmp/nextcloud-recovery-db.XXXXXX.env)\"
  cleanup_environment() { rm -f \"\$test_environment\"; }
  trap cleanup_environment EXIT HUP INT TERM
  umask 077
  recovery_password=\"\$(openssl rand -hex 32)\"
  printf 'MARIADB_ROOT_PASSWORD=%s\\nMARIADB_DATABASE=nextcloud_recovery\\n' \"\$recovery_password\" >\"\$test_environment\"
  test -d '$REMOTE_TEST_ROOT/mariadb-data' && test ! -L '$REMOTE_TEST_ROOT/mariadb-data'
  docker image inspect '$database_image' >/dev/null
  docker run --pull=never -d --name '$TEST_DB_CONTAINER' --env-file \"\$test_environment\" -v '$REMOTE_TEST_ROOT/mariadb-data:/var/lib/mysql' '$database_image' >/dev/null
  rm -f \"\$test_environment\"
  trap - EXIT HUP INT TERM
  ready=0
  attempt=0
  while test \"\$attempt\" -lt 60; do
    attempt=\$((attempt + 1))
    # The image's temporary initialization server accepts socket connections
    # with networking disabled. Require a real TCP query so readiness proves
    # the final server has completed the entrypoint handoff.
    if docker exec '$TEST_DB_CONTAINER' sh -c 'MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb --protocol=tcp --host=127.0.0.1 -uroot --skip-column-names --batch \"\$MARIADB_DATABASE\" -e \"SELECT 1\"' |
      grep -Fx 1 >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done
  test \"\$ready\" = 1
" >/dev/null

remote "docker exec -i '$TEST_DB_CONTAINER' sh -eu -c 'export MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\"; exec mariadb --protocol=tcp --host=127.0.0.1 -uroot \"\$MARIADB_DATABASE\"'" <"$BACKUP_DIR/database/nextcloud.sql"
table_count="$(remote "docker exec '$TEST_DB_CONTAINER' sh -eu -c 'export MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\"; mariadb --protocol=tcp --host=127.0.0.1 -N -uroot \"\$MARIADB_DATABASE\" -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE();\"'")"
[[ "$table_count" =~ ^[1-9][0-9]*$ ]] || die "restored MariaDB database contains no tables"
remote "docker exec '$TEST_DB_CONTAINER' sh -eu -c 'export MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\"; exec mariadb-check --protocol=tcp --host=127.0.0.1 -uroot --all-databases --silent'" >/dev/null
printf 'CHECK: isolated MariaDB restore contains %s tables and passes mariadb-check\n' "$table_count"

cleanup_targets || die "disposable recovery targets require manual cleanup"
trap - EXIT HUP INT TERM
REMOTE_TEST_ROOT=""
TEST_DB_CONTAINER=""
RECOVERY_TEST_ID=""
printf 'Controlled runtime recovery drill passed; live runtime paths were not modified.\n'
