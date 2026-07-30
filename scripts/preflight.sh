#!/usr/bin/env bash
set -euo pipefail

# Read-only deployment gate. The checks below deliberately gather only safe
# runtime facts and configuration drift; they never copy configuration, print
# database values, or restart the Pi services.

# These defaults describe the existing deployment, while environment overrides
# let an operator validate a replacement Pi without editing the repository.
NEXTCLOUD_PI_HOST="${NEXTCLOUD_PI_HOST:?set NEXTCLOUD_PI_HOST}"
NEXTCLOUD_PI_USER="${NEXTCLOUD_PI_USER:?set NEXTCLOUD_PI_USER}"
NEXTCLOUD_REMOTE_PROJECT_DIR="${NEXTCLOUD_REMOTE_PROJECT_DIR:?set NEXTCLOUD_REMOTE_PROJECT_DIR}"
NEXTCLOUD_STORAGE_MOUNT="${NEXTCLOUD_STORAGE_MOUNT:?set NEXTCLOUD_STORAGE_MOUNT}"

REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
EXPECTED_REPO_NAME="nextcloud-pi-server"

PASS_COUNT=0
WARNING_COUNT=0
FAIL_COUNT=0
UNKNOWN_COUNT=0
DRIFT_COUNT=0
ENV_PREPARED=0
SECRETS_MIGRATED=0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

section() {
  printf '\n== %s ==\n' "$1"
}

record() {
  local status="$1"
  local message="$2"

  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARNING) WARNING_COUNT=$((WARNING_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    UNKNOWN) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)) ;;
    *) status="UNKNOWN"; UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)) ;;
  esac

  printf '%-7s %s\n' "$status" "$message"
}

# Keep all remote access non-interactive and centralized so a preflight run
# cannot fall back to a password prompt or a different SSH behavior per check.
remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"
}

remote_sh() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "sh -s" "$@"
}

drift() {
  DRIFT_COUNT=$((DRIFT_COUNT + 1))
  record WARNING "$1"
}

require_local_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    record PASS "Found $path"
  else
    record FAIL "Missing $path"
  fi
}

tracked_matches() {
  local pattern="$1"
  git ls-files -z | while IFS= read -r -d '' path; do
    case "$path" in
      $pattern) printf '%s\n' "$path" ;;
    esac
  done
}

compare_file_to_remote_command() {
  local label="$1"
  local local_file="$2"
  local remote_command="$3"
  local remote_file="$TMP_DIR/${label//[^A-Za-z0-9_.-]/_}.remote"

  if remote "$remote_command" >"$remote_file"; then
    if cmp -s "$local_file" "$remote_file"; then
      record PASS "$label matches live configuration"
    else
      drift "$label differs from live configuration"
    fi
  else
    record FAIL "Unable to read live $label"
  fi
}

normalize_active_config() {
  sed -e 's/[[:space:]]*$//' \
    -e '/^[[:space:]]*$/d' \
    -e '/^[[:space:]]*#/d' \
    "$1"
}

compare_normalized_file_to_remote_command() {
  local label="$1"
  local local_file="$2"
  local remote_command="$3"
  local remote_file="$TMP_DIR/${label//[^A-Za-z0-9_.-]/_}.remote"
  local normalized_local="$TMP_DIR/${label//[^A-Za-z0-9_.-]/_}.local.normalized"
  local normalized_remote="$TMP_DIR/${label//[^A-Za-z0-9_.-]/_}.remote.normalized"

  # Configuration comments and blank lines are not operational drift, so
  # compare the active Caddy/systemd directives rather than raw formatting.
  if remote "$remote_command" >"$remote_file"; then
    normalize_active_config "$local_file" >"$normalized_local"
    normalize_active_config "$remote_file" >"$normalized_remote"
    if cmp -s "$normalized_local" "$normalized_remote"; then
      record PASS "$label active configuration matches live configuration"
    else
      drift "$label active configuration differs from live configuration"
    fi
  else
    record FAIL "Unable to read live $label"
  fi
}

remote_compose_config() {
  local subcommand="$1"
  remote "cd '$NEXTCLOUD_REMOTE_PROJECT_DIR' && if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then docker compose config '$subcommand'; elif command -v docker-compose >/dev/null 2>&1; then docker-compose config '$subcommand'; else exit 127; fi"
}

section "Local repository checks"

# Task worktrees are required by AGENTS.md. Accept the prescribed sibling name
# while still rejecting unrelated repositories that happen to contain scripts.
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  repo_root="$(git rev-parse --show-toplevel)"
  repo_name="$(basename "$repo_root")"
  if [[ "$repo_name" == "$EXPECTED_REPO_NAME" || "$repo_name" == "$EXPECTED_REPO_NAME-"* ]]; then
    record PASS "Running from expected Git repository or task worktree: $repo_root"
  else
    record FAIL "Unexpected Git repository: $repo_root"
  fi
else
  record FAIL "Not running inside a Git repository"
  exit 1
fi

current_branch="$(git branch --show-current 2>/dev/null || true)"
if [[ -n "$current_branch" ]]; then
  record PASS "Current branch: $current_branch"
else
  record UNKNOWN "Unable to determine current branch"
fi

if [[ -z "$(git status --short)" ]]; then
  record PASS "Working tree is clean"
else
  record WARNING "Working tree has local changes"
fi

require_local_file "compose/docker-compose.yml"
require_local_file "compose/.env.example"
require_local_file "caddy/Caddyfile"
require_local_file "systemd/nextcloud.service"
require_local_file "storage/fstab.nextcloud"

if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  record FAIL "A live .env file is tracked"
else
  record PASS "No live .env file is tracked"
fi

forbidden_tracked="$(
  {
    tracked_matches "*.crt"
    tracked_matches "*.key"
    tracked_matches "*.pem"
    tracked_matches "*.p12"
    tracked_matches "*.pfx"
    tracked_matches "*.sql"
    tracked_matches "*.sql.gz"
    tracked_matches "*.dump"
    tracked_matches "*.backup"
    tracked_matches "*.bak"
    tracked_matches "config.php"
    tracked_matches "reports/raw/*"
    tracked_matches "staging/*"
    tracked_matches "nextcloud/*"
    tracked_matches "nextcloud_db/*"
    tracked_matches "mysql/*"
    tracked_matches "mariadb/*"
    tracked_matches "caddy_data/*"
    tracked_matches "caddy_config/*"
  } | sort -u
)"

if [[ -z "$forbidden_tracked" ]]; then
  record PASS "No certificate, key, database, data, raw report, or staging paths are tracked"
else
  record FAIL "Forbidden tracked paths were found"
  printf '%s\n' "$forbidden_tracked"
fi

mysql_scan_file="$TMP_DIR/mysql-scan.txt"
if git grep -nE 'MYSQL_(ROOT_PASSWORD|PASSWORD|DATABASE|USER)=' -- ':!compose/.env.example' >"$mysql_scan_file" 2>/dev/null; then
  if grep -v '\${MYSQL_' "$mysql_scan_file" >/dev/null; then
    record FAIL "A tracked file contains direct MYSQL assignment syntax outside .env.example"
    cut -d: -f1,2 "$mysql_scan_file" | sort -u
  else
    record PASS "Tracked MYSQL assignments use environment-variable references"
  fi
else
  record PASS "No direct MYSQL assignments found outside .env.example"
fi

section "Remote connectivity checks"

if remote "true" >/dev/null 2>&1; then
  record PASS "SSH connection succeeded: $REMOTE"
else
  record FAIL "SSH connection failed: $REMOTE"
  printf '\nDeployment remains blocked until SSH connectivity, a verified configuration backup, a safe .env migration, and Pi-side validation are complete.\n'
  exit 1
fi

remote_user="$(remote "id -un" 2>/dev/null || true)"
if [[ "$remote_user" == "$NEXTCLOUD_PI_USER" ]]; then
  record PASS "Remote username is $remote_user"
else
  record FAIL "Remote username mismatch: ${remote_user:-unknown}"
fi

remote_hostname="$(remote "hostname" 2>/dev/null || true)"
if [[ "$remote_hostname" == "example-pi-system" ]]; then
  record PASS "Remote hostname is example-pi-system"
else
  record WARNING "Remote hostname is ${remote_hostname:-unknown}, expected example-pi-system"
fi

if remote "command -v docker >/dev/null 2>&1" >/dev/null 2>&1; then
  record PASS "Docker command is installed"
else
  record FAIL "Docker command is not installed"
fi

if remote "docker info >/dev/null 2>&1" >/dev/null 2>&1; then
  record PASS "Docker daemon is running"
else
  record FAIL "Docker daemon is not reachable"
fi

if remote "docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1" >/dev/null 2>&1; then
  record PASS "Docker Compose is available"
else
  record FAIL "Docker Compose is not available"
fi

if remote "findmnt -rn --target '$NEXTCLOUD_STORAGE_MOUNT' >/dev/null 2>&1" >/dev/null 2>&1; then
  record PASS "$NEXTCLOUD_STORAGE_MOUNT is mounted"
else
  record FAIL "$NEXTCLOUD_STORAGE_MOUNT is not mounted"
fi

mount_type="$(remote "findmnt -rn --target '$NEXTCLOUD_STORAGE_MOUNT' -o FSTYPE" 2>/dev/null || true)"
if [[ "$mount_type" == "ext4" ]]; then
  record PASS "$NEXTCLOUD_STORAGE_MOUNT filesystem is ext4"
elif [[ -n "$mount_type" ]]; then
  record FAIL "$NEXTCLOUD_STORAGE_MOUNT filesystem is $mount_type, expected ext4"
else
  record UNKNOWN "Unable to determine filesystem type for $NEXTCLOUD_STORAGE_MOUNT"
fi

for dir in \
  "$NEXTCLOUD_STORAGE_MOUNT/nextcloud" \
  "$NEXTCLOUD_STORAGE_MOUNT/nextcloud/data" \
  "$NEXTCLOUD_STORAGE_MOUNT/nextcloud_db" \
  "$NEXTCLOUD_REMOTE_PROJECT_DIR"; do
  if remote "test -d '$dir'" >/dev/null 2>&1; then
    record PASS "Remote directory exists: $dir"
  else
    record FAIL "Remote directory missing: $dir"
  fi
done

remote_env_file="$NEXTCLOUD_REMOTE_PROJECT_DIR/.env"
# Preflight validates the target's shape and permissions only. It never reads
# or prints values from the credential-bearing file.
if remote "test ! -e '$remote_env_file' && test ! -L '$remote_env_file'" >/dev/null 2>&1; then
  record UNKNOWN "Pi-only .env file has not been prepared: $remote_env_file"
elif remote "test -f '$remote_env_file' && test ! -L '$remote_env_file'" >/dev/null 2>&1; then
  remote_env_mode="$(remote "if stat -f '%Lp' '$remote_env_file' >/dev/null 2>&1; then stat -f '%Lp' '$remote_env_file'; else stat -c '%a' '$remote_env_file'; fi" 2>/dev/null || true)"
  if [[ "$remote_env_mode" == "600" ]]; then
    ENV_PREPARED=1
    record PASS "Pi-only .env file permissions are 0600"
  else
    record FAIL "Pi-only .env file permissions are ${remote_env_mode:-unknown}, expected 0600"
  fi
else
  record FAIL "Pi-only .env path is not a regular file: $remote_env_file"
fi

# Count only active Compose list assignments, and accept a value only when the
# entire right-hand side is exactly ${KEY}. The remote scan returns no file
# content, rejecting inline values without printing or returning secrets.
if (( ENV_PREPARED != 0 )) && remote "awk '
  BEGIN {
    expected[\"MYSQL_ROOT_PASSWORD\"] = 1
    expected[\"MYSQL_PASSWORD\"] = 2
    expected[\"MYSQL_DATABASE\"] = 2
    expected[\"MYSQL_USER\"] = 2
  }
  {
    line = \$0
    sub(/^[[:space:]]*-[[:space:]]*/, \"\", line)
    for (key in expected) {
      prefix = key \"=\"
      if (index(line, prefix) == 1) {
        total[key]++
        reference = sprintf(\"%c{%s}\", 36, key)
        value = substr(line, length(prefix) + 1)
        sub(/[[:space:]]*$/, \"\", value)
        if (value == reference) references[key]++
        else inline[key]++
      }
    }
  }
  END {
    failed = 0
    for (key in expected) {
      if (total[key] != expected[key] || references[key] != total[key] || inline[key] != 0) failed = 1
    }
    exit failed
  }
' '$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml'" >/dev/null 2>&1; then
  SECRETS_MIGRATED=1
  record PASS "Live Compose database assignments use Pi-only .env references"
elif (( ENV_PREPARED != 0 )); then
  record WARNING "Live Compose database assignments are not fully migrated to .env references"
fi

section "Container checks"

for container in nextcloud-docker-app-1 nextcloud-docker-db-1 nextcloud-docker-caddy-1; do
  if remote "docker inspect '$container' >/dev/null 2>&1" >/dev/null 2>&1; then
    record PASS "Container exists: $container"
    remote "docker inspect '$container' --format 'name={{.Name}} image={{.Config.Image}} running={{.State.Running}} restart={{.HostConfig.RestartPolicy.Name}} ports={{json .NetworkSettings.Ports}}'"
    remote "docker inspect '$container' --format '{{range .Mounts}}mount={{.Source}} -> {{.Destination}}{{println}}{{end}}'"
  else
    record FAIL "Container missing: $container"
  fi
done

section "Nextcloud checks"

if remote "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status" >/dev/null 2>&1; then
  record PASS "Nextcloud occ status command succeeded"
  remote "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status | sed -n '/installed:/p;/version:/p;/versionstring:/p;/maintenance:/p;/needsDbUpgrade:/p'"
else
  record FAIL "Nextcloud occ status command failed"
fi

if remote "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ config:system:get datadirectory" >/dev/null 2>&1; then
  record PASS "Nextcloud data directory was read"
  remote "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ config:system:get datadirectory"
else
  record FAIL "Unable to read Nextcloud data directory"
fi

if remote "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ config:system:get trusted_domains" >/dev/null 2>&1; then
  record PASS "Nextcloud trusted domains were read"
  remote "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ config:system:get trusted_domains"
else
  record UNKNOWN "Unable to read Nextcloud trusted domains"
fi

section "Safe configuration comparison"

compare_normalized_file_to_remote_command "Caddyfile" "caddy/Caddyfile" "cat '$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile'"
compare_normalized_file_to_remote_command "systemd service" "systemd/nextcloud.service" "cat /etc/systemd/system/nextcloud.service"

local_fstab_entry="$TMP_DIR/nextcloud.example.invalid"
remote_fstab_entry="$TMP_DIR/fstab.remote"
grep -v '^[[:space:]]*#' storage/fstab.nextcloud | sed '/^[[:space:]]*$/d' >"$local_fstab_entry"
if remote "grep -F ' $NEXTCLOUD_STORAGE_MOUNT ' /etc/fstab" >"$remote_fstab_entry"; then
  if cmp -s "$local_fstab_entry" "$remote_fstab_entry"; then
    record PASS "fstab entry matches live /etc/fstab"
  else
    drift "fstab entry differs from live /etc/fstab"
  fi
else
  record FAIL "Unable to read live fstab entry for $NEXTCLOUD_STORAGE_MOUNT"
fi

services="$(remote_compose_config "--services" 2>/dev/null || true)"
if [[ "$services" == $'db\napp\ncaddy' ]]; then
  record PASS "Compose services match expected baseline"
else
  drift "Compose services differ from expected baseline"
  printf '%s\n' "$services"
fi

expected_volumes="$(printf '%s\n' caddy_data caddy_config | sort)"
volumes="$(remote_compose_config "--volumes" 2>/dev/null | sort || true)"
if [[ "$volumes" == "$expected_volumes" ]]; then
  record PASS "Compose named volumes match expected baseline"
else
  drift "Compose named volumes differ from expected baseline"
  printf '%s\n' "$volumes"
fi

networks="$(remote_compose_config "--networks" 2>/dev/null || true)"
if [[ "$networks" == "default" ]]; then
  record PASS "Compose networks match expected baseline"
else
  drift "Compose networks differ from expected baseline"
  printf '%s\n' "$networks"
fi

app_image="$(remote "docker inspect nextcloud-docker-app-1 --format '{{.Config.Image}}'" 2>/dev/null || true)"
db_image="$(remote "docker inspect nextcloud-docker-db-1 --format '{{.Config.Image}}'" 2>/dev/null || true)"
caddy_image="$(remote "docker inspect nextcloud-docker-caddy-1 --format '{{.Config.Image}}'" 2>/dev/null || true)"

[[ "$app_image" == "nextcloud:30" ]] && record PASS "App image matches nextcloud:30" || drift "App image differs from nextcloud:30"
[[ "$db_image" == "mariadb:11" ]] && record PASS "Database image matches mariadb:11" || drift "Database image differs from mariadb:11"
[[ "$caddy_image" == "caddy:2" ]] && record PASS "Caddy image matches caddy:2" || drift "Caddy image differs from caddy:2"

app_restart="$(remote "docker inspect nextcloud-docker-app-1 --format '{{.HostConfig.RestartPolicy.Name}}'" 2>/dev/null || true)"
db_restart="$(remote "docker inspect nextcloud-docker-db-1 --format '{{.HostConfig.RestartPolicy.Name}}'" 2>/dev/null || true)"
caddy_restart="$(remote "docker inspect nextcloud-docker-caddy-1 --format '{{.HostConfig.RestartPolicy.Name}}'" 2>/dev/null || true)"

[[ "$app_restart" == "unless-stopped" ]] && record PASS "App restart policy matches" || drift "App restart policy differs"
[[ "$db_restart" == "always" ]] && record PASS "Database restart policy matches" || drift "Database restart policy differs"
[[ "$caddy_restart" == "unless-stopped" ]] && record PASS "Caddy restart policy matches" || drift "Caddy restart policy differs"

app_mounts="$(remote "docker inspect nextcloud-docker-app-1 --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'" 2>/dev/null || true)"
db_mounts="$(remote "docker inspect nextcloud-docker-db-1 --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'" 2>/dev/null || true)"
caddy_mounts="$(remote "docker inspect nextcloud-docker-caddy-1 --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} {{.Name}}{{println}}{{end}}'" 2>/dev/null || true)"

grep -F "$NEXTCLOUD_STORAGE_MOUNT/nextcloud -> /var/www/html" <<<"$app_mounts" >/dev/null && record PASS "App mount matches expected baseline" || drift "App mount differs from expected baseline"
grep -F "$NEXTCLOUD_STORAGE_MOUNT/nextcloud_db -> /var/lib/mysql" <<<"$db_mounts" >/dev/null && record PASS "Database mount matches expected baseline" || drift "Database mount differs from expected baseline"
grep -F "$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile -> /etc/caddy/Caddyfile" <<<"$caddy_mounts" >/dev/null && record PASS "Caddyfile mount matches expected baseline" || drift "Caddyfile mount differs from expected baseline"
grep -F "nextcloud-docker_caddy_data" <<<"$caddy_mounts" >/dev/null && record PASS "Caddy data named volume is present" || drift "Caddy data named volume differs or is missing"
grep -F "nextcloud-docker_caddy_config" <<<"$caddy_mounts" >/dev/null && record PASS "Caddy config named volume is present" || drift "Caddy config named volume differs or is missing"

app_ports="$(remote "docker inspect nextcloud-docker-app-1 --format '{{json .NetworkSettings.Ports}}'" 2>/dev/null || true)"
caddy_ports="$(remote "docker inspect nextcloud-docker-caddy-1 --format '{{json .NetworkSettings.Ports}}'" 2>/dev/null || true)"
grep -F '"8080"' <<<"$app_ports" >/dev/null && record PASS "App published port includes 8080" || drift "App published port differs from expected 8080"
grep -F '"80"' <<<"$caddy_ports" >/dev/null && grep -F '"443"' <<<"$caddy_ports" >/dev/null && record PASS "Caddy published ports include 80 and 443" || drift "Caddy published ports differ from expected 80/443"

section "Summary"

if (( FAIL_COUNT == 0 )); then
  record PASS "Pi preflight checks completed without hard failures"
else
  record FAIL "Pi preflight found hard failures"
fi

if remote "findmnt -rn --target '$NEXTCLOUD_STORAGE_MOUNT' >/dev/null 2>&1" >/dev/null 2>&1; then
  record PASS "Storage mount is present"
else
  record FAIL "Storage mount is not present"
fi

if (( DRIFT_COUNT == 0 )); then
  record PASS "Repository matches the checked working architecture"
  record PASS "No checked configuration drift detected"
else
  record WARNING "Configuration drift was detected in checked items"
fi

record WARNING "Deployment should remain blocked"
if (( ENV_PREPARED != 0 && SECRETS_MIGRATED != 0 )); then
  record WARNING "Phase 1 secret migration is prepared; Phase 2 deployment and any restart still require validation, rollback planning, and explicit approval"
else
  record WARNING "Create and verify a configuration backup, then complete .env migration, Pi-side validation, rollback planning, and explicit restart approval before deployment"
fi

printf '\nTotals: PASS=%d WARNING=%d FAIL=%d UNKNOWN=%d DRIFT=%d\n' \
  "$PASS_COUNT" "$WARNING_COUNT" "$FAIL_COUNT" "$UNKNOWN_COUNT" "$DRIFT_COUNT"

if (( ENV_PREPARED != 0 && SECRETS_MIGRATED != 0 )); then
  printf '\nPhase 1 secret migration checks passed. Phase 2 deployment and any restart remain blocked pending validation, rollback planning, and explicit approval.\n'
else
  printf '\nDeployment remains blocked until a verified configuration backup, safe .env migration, Pi-side validation, rollback planning, and explicit restart approval are complete.\n'
fi
