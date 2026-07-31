#!/usr/bin/env bash
set -euo pipefail

# Prepare the deployment-target .env without exposing database values locally.
# It does not replace docker-compose.yml or restart containers. The flow is:
# validate local sanitized inputs -> verify a rollback backup -> validate the
# live stack -> atomically create a new target .env -> validate it again.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/deployment-config.sh"
load_deployment_config "$REPOSITORY_ROOT"

NEXTCLOUD_DB_CONTAINER="${NEXTCLOUD_DB_CONTAINER:-nextcloud-docker-db-1}"
NEXTCLOUD_BACKUP_MAX_AGE_SECONDS="${NEXTCLOUD_BACKUP_MAX_AGE_SECONDS:-3600}"

readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
readonly REQUIRED_ENV_KEYS=(MYSQL_ROOT_PASSWORD MYSQL_PASSWORD MYSQL_DATABASE MYSQL_USER)

APPLY=0
BACKUP_DIR=""
BACKUP_COMPOSE_SHA256=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/prepare-env-migration.sh --check
  ./scripts/prepare-env-migration.sh --apply <verified-backup-directory>

--check is read-only. It reports whether the target .env is absent or is a
regular 0600 file containing exactly the expected non-empty database keys.

--apply verifies a configuration backup locally and confirms it is recent,
belongs to the configured Pi and project, and contains the current live Compose
file. It then creates a new .env on the Pi from the running MariaDB container's
existing environment. It refuses to overwrite any existing .env, does not
print secret values, does not replace docker-compose.yml, and does not restart
services. Backups may be at most NEXTCLOUD_BACKUP_MAX_AGE_SECONDS old (default:
3600).
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

is_safe_remote_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$1" != *"/../"* ]] && [[ "$1" != */.. ]]
}

require_safe_settings() {
  # These values are interpolated into remote shell commands below. Restrict
  # them to the deployment's expected syntax before opening an SSH session.
  [[ "$NEXTCLOUD_PI_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "NEXTCLOUD_PI_HOST contains unsupported characters"
  [[ "$NEXTCLOUD_PI_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "NEXTCLOUD_PI_USER contains unsupported characters"
  is_safe_remote_path "$NEXTCLOUD_REMOTE_PROJECT_DIR" || die "NEXTCLOUD_REMOTE_PROJECT_DIR must be a simple absolute path"
  [[ "$NEXTCLOUD_DB_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "NEXTCLOUD_DB_CONTAINER contains unsupported characters"
  [[ "$NEXTCLOUD_BACKUP_MAX_AGE_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "NEXTCLOUD_BACKUP_MAX_AGE_SECONDS must be a positive integer"
}

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"
}

validate_local_repository() {
  # Confirm this worktree contains the sanitized Compose contract that the
  # future deployment phase will use; do not accept a local tracked .env.
  git rev-parse --show-toplevel >/dev/null 2>&1 || die "run this script from the repository"
  [[ -f "compose/.env.example" ]] || die "missing compose/.env.example"
  [[ -f "compose/docker-compose.yml" ]] || die "missing compose/docker-compose.yml"

  local key
  for key in "${REQUIRED_ENV_KEYS[@]}"; do
    grep -E "^${key}=" compose/.env.example >/dev/null || die "compose/.env.example is missing $key"
    grep -F "\${${key}}" compose/docker-compose.yml >/dev/null || die "compose/docker-compose.yml is missing the ${key} reference"
  done

  if git ls-files --error-unmatch .env >/dev/null 2>&1; then
    die "a local .env file is tracked"
  fi
}

check_remote_env() {
  local env_file="$NEXTCLOUD_REMOTE_PROJECT_DIR/.env"
  local mode

  # Exit status 2 means "not prepared" rather than malformed. Callers retain
  # that distinction so --check can still validate the current live stack.
  if remote "test ! -e '$env_file' && test ! -L '$env_file'" >/dev/null 2>&1; then
    printf 'CHECK: Pi-only .env is absent\n'
    return 2
  fi

  remote "test -f '$env_file' && test ! -L '$env_file'" >/dev/null 2>&1 || die "Pi-only .env is not a regular file"
  mode="$(remote "if stat -f '%Lp' '$env_file' >/dev/null 2>&1; then stat -f '%Lp' '$env_file'; else stat -c '%a' '$env_file'; fi")"
  [[ "$mode" == "600" ]] || die "Pi-only .env permissions are $mode, expected 0600"

  remote "awk -F= '
    BEGIN {
      expected[\"MYSQL_ROOT_PASSWORD\"] = 1
      expected[\"MYSQL_PASSWORD\"] = 1
      expected[\"MYSQL_DATABASE\"] = 1
      expected[\"MYSQL_USER\"] = 1
      quote = sprintf(\"%c\", 39)
      invalid = 0
    }
    {
      separator = index(\$0, \"=\")
      value = substr(\$0, separator + 1)
      if (separator == 0 || !(\$1 in expected) || seen[\$1]++ || length(value) < 3 || substr(value, 1, 1) != quote || substr(value, length(value), 1) != quote) invalid = 1
    }
    END {
      for (key in expected) if (!seen[key]) invalid = 1
      exit invalid
    }
  ' '$env_file'" >/dev/null 2>&1 || die "Pi-only .env is missing, malformed, or has unexpected keys"

  printf 'CHECK: Pi-only .env is a regular 0600 file with the expected keys\n'
}

verify_backup() {
  [[ -n "$BACKUP_DIR" ]] || die "--apply requires a verified backup directory"
  "$SCRIPT_DIR/verify-config-backup.sh" "$BACKUP_DIR" >/dev/null
  BACKUP_DIR="$(cd -- "$BACKUP_DIR" && pwd -P)"
}

manifest_value() {
  local key="$1"

  awk -F $'\t' -v key="$key" '$1 == key { print $2 }' "$BACKUP_DIR/manifest.tsv"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

verify_backup_binding() {
  local manifest_timestamp
  local manifest_remote_host
  local manifest_remote_user
  local manifest_source_project
  local manifest_backup_path
  local backup_epoch
  local current_epoch
  local backup_age
  local current_remote_host
  local current_remote_user
  local live_compose_sha256

  # Integrity alone is not an authorization to mutate a deployment. Bind the
  # verified recovery point to this exact target and its current Compose file.
  manifest_timestamp="$(manifest_value timestamp)"
  manifest_remote_host="$(manifest_value remote_host)"
  manifest_remote_user="$(manifest_value remote_user)"
  manifest_source_project="$(manifest_value source_project)"
  manifest_backup_path="$(manifest_value backup_path)"

  [[ "$manifest_timestamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "backup timestamp has an unexpected format"
  [[ "$(basename -- "$BACKUP_DIR")" == "config-backup-$manifest_timestamp" ]] || die "backup directory name does not match its timestamp"
  [[ -d "$manifest_backup_path" && "$manifest_backup_path" -ef "$BACKUP_DIR" ]] || die "backup path does not match its manifest"
  [[ "$manifest_remote_user" == "$NEXTCLOUD_PI_USER" ]] || die "backup user does not match the configured Pi user"
  [[ "$manifest_source_project" == "$NEXTCLOUD_REMOTE_PROJECT_DIR" ]] || die "backup project does not match the configured Pi project"

  command -v python3 >/dev/null 2>&1 || die "python3 is required to validate backup freshness"
  backup_epoch="$(python3 - "$manifest_timestamp" <<'PY'
from datetime import datetime, timezone
import sys

try:
    timestamp = datetime.strptime(sys.argv[1], "%Y%m%dT%H%M%SZ")
except ValueError:
    raise SystemExit(1)

print(int(timestamp.replace(tzinfo=timezone.utc).timestamp()))
PY
  )" || die "backup timestamp is not a valid UTC time"
  current_epoch="$(date -u +%s)"
  backup_age=$((current_epoch - backup_epoch))
  (( backup_age >= 0 )) || die "backup timestamp is in the future"
  (( backup_age <= NEXTCLOUD_BACKUP_MAX_AGE_SECONDS )) || die "backup is $backup_age seconds old; maximum age is $NEXTCLOUD_BACKUP_MAX_AGE_SECONDS"

  current_remote_host="$(remote hostname)"
  current_remote_user="$(remote id -un)"
  [[ "$manifest_remote_host" == "$current_remote_host" ]] || die "backup host does not match the connected Pi"
  [[ "$manifest_remote_user" == "$current_remote_user" ]] || die "backup user does not match the connected Pi"

  BACKUP_COMPOSE_SHA256="$(sha256_file "$BACKUP_DIR/compose/docker-compose.yml")"
  if ! live_compose_sha256="$(remote "test -f '$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml' && test ! -L '$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml' && cat '$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml'" | sha256_stream)"; then
    die "could not checksum the live Compose file"
  fi
  [[ "$BACKUP_COMPOSE_SHA256" == "$live_compose_sha256" ]] || die "backup Compose file does not match the live Pi"

  printf 'CHECK: verified backup is fresh and belongs to the current live deployment\n'
}

validate_remote_compose() {
  # config -q resolves the running Compose project without emitting the
  # rendered configuration, which could otherwise reveal secret values.
  remote "cd '$NEXTCLOUD_REMOTE_PROJECT_DIR' && if docker compose version >/dev/null 2>&1; then docker compose config -q; elif docker-compose version >/dev/null 2>&1; then docker-compose config -q; else exit 127; fi" >/dev/null
  printf 'CHECK: resolved live Compose configuration validated without output\n'
}

prepare_remote_env() {
  local env_file="$NEXTCLOUD_REMOTE_PROJECT_DIR/.env"

  # The remote program leaves the live Compose file and containers untouched.
  # It reads only Docker's JSON environment metadata, serializes a narrow
  # allowlist, and publishes the resulting file with no-overwrite semantics.
  remote "
    set -eu
    project_dir='$NEXTCLOUD_REMOTE_PROJECT_DIR'
    env_file='$env_file'
    db_container='$NEXTCLOUD_DB_CONTAINER'
    expected_compose_sha256='$BACKUP_COMPOSE_SHA256'
    test -d \"\$project_dir\"
    test ! -e \"\$env_file\" && test ! -L \"\$env_file\"
    test -f \"\$project_dir/docker-compose.yml\" && test ! -L \"\$project_dir/docker-compose.yml\"
    # Recheck the recovery point's Compose binding immediately before creating
    # .env so validation and mutation cannot silently target different stacks.
    if command -v sha256sum >/dev/null 2>&1; then
      live_compose_sha256=\"\$(sha256sum \"\$project_dir/docker-compose.yml\" | awk '{print \$1}')\"
    elif command -v shasum >/dev/null 2>&1; then
      live_compose_sha256=\"\$(shasum -a 256 \"\$project_dir/docker-compose.yml\" | awk '{print \$1}')\"
    else
      exit 127
    fi
    test \"\$live_compose_sha256\" = \"\$expected_compose_sha256\"
    docker inspect \"\$db_container\" >/dev/null
    command -v python3 >/dev/null
    umask 077
    temporary_file=\"\$(mktemp \"\$project_dir/.env.migration.XXXXXX\")\"
    cleanup() { rm -f \"\$temporary_file\"; }
    trap cleanup EXIT HUP INT TERM
    # JSON keeps embedded line breaks unambiguous. Python rejects values that
    # cannot be losslessly represented as a literal single-quoted Compose .env
    # value before any target file is linked into place.
    docker inspect \"\$db_container\" --format '{{json .Config.Env}}' | python3 -c '
import json
import sys

required = (\"MYSQL_ROOT_PASSWORD\", \"MYSQL_PASSWORD\", \"MYSQL_DATABASE\", \"MYSQL_USER\")
unsafe_characters = (chr(10), chr(13), chr(39), chr(92))
values = {}

for entry in json.load(sys.stdin):
    key, separator, value = entry.partition(\"=\")
    if key not in required:
        continue
    if not separator or not value or key in values or any(character in value for character in unsafe_characters):
        raise SystemExit(\"database environment contains an unsafe value\")
    values[key] = value

if set(values) != set(required):
    raise SystemExit(\"database environment is missing a required value\")

for key in required:
    print(key + \"=\" + chr(39) + values[key] + chr(39))
' >\"\$temporary_file\"
    chmod 600 \"\$temporary_file\"
    test \"\$(wc -l <\"\$temporary_file\" | tr -d '[:space:]')\" = 4
    # A hard link is an atomic no-clobber publish because both files are in the
    # same project directory. If another process creates .env first, ln fails.
    ln \"\$temporary_file\" \"\$env_file\"
    rm -f \"\$temporary_file\"
    trap - EXIT HUP INT TERM
  "
}

case "${1:-}" in
  --check)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    ;;
  --apply)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    APPLY=1
    BACKUP_DIR="$2"
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
validate_local_repository

if (( APPLY == 0 )); then
  # Read-only mode still validates the current Compose project when .env is
  # absent, then returns 2 to make the unmet migration state visible.
  if check_remote_env; then
    validate_remote_compose
    exit 0
  else
    check_exit=$?
    if [[ "$check_exit" == 2 ]]; then
      validate_remote_compose
    fi
    exit "$check_exit"
  fi
fi

verify_backup
verify_backup_binding
# Validate before mutation so a broken running configuration is never paired
# with a newly created secret file.
validate_remote_compose
prepare_remote_env
check_remote_env
validate_remote_compose
printf 'Prepared Pi-only .env. The live Compose file and running services were not changed.\n'
