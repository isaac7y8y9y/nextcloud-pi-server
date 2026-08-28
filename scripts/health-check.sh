#!/usr/bin/env bash
set -euo pipefail

# Read-only post-start check. It never starts a container, pulls an image, or
# prints credential-bearing configuration.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
load_deployment_config "$REPOSITORY_ROOT"
readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
# A responsive SSH transport can still host a hung Docker, OCC, or curl
# process. timeout is intentionally remote-side so stdin-based Caddy checks
# are bounded too; absence of timeout is a failed health check, never a bypass.
remote() {
  local command="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 "$REMOTE" "timeout 15s sh -c $(printf '%q' "$command")"
}
die() { printf 'Health check failed: %s\n' "$1" >&2; exit 1; }
retry_remote() {
  local label="$1" command="$2" deadline remaining
  deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    remote "$command" >/dev/null 2>&1 && return 0
    remaining=$((deadline - SECONDS))
    (( remaining > 0 )) || break
    (( remaining < 5 )) && sleep "$remaining" || sleep 5
  done
  die "$label did not become ready before the 60-second deadline"
}

# By default validate the rendered candidate. A deployment rollback supplies
# its verified pre-state Caddyfile so recovery is checked against the service
# identity that was actually restored, not against the rejected candidate.
HEALTH_CADDYFILE="$TMP_DIR/rendered/caddy/Caddyfile"
HEALTH_HOSTNAME="$NEXTCLOUD_PUBLIC_HOSTNAME"
HEALTH_MODE=candidate
prepare_health_config() {
  HEALTH_CADDYFILE="$TMP_DIR/rendered/caddy/Caddyfile"
  HEALTH_HOSTNAME="$NEXTCLOUD_PUBLIC_HOSTNAME"
  HEALTH_MODE=candidate
  if [[ $# == 0 ]]; then
    "$SCRIPT_DIR/render-deployment-config.sh" --output-dir "$TMP_DIR/rendered"
  elif [[ $# == 2 && "$1" == --caddyfile ]]; then
    [[ -f "$2" && ! -L "$2" ]] || die "rollback Caddyfile is missing or unsafe"
    mkdir -p "$TMP_DIR/rendered/caddy"
    cp "$2" "$HEALTH_CADDYFILE"
    HEALTH_HOSTNAME="$(awk '$0 !~ /^[[:space:]]*(#|$)/ && $2 == "{" { count++; value=$1 } END { if (count == 1) print value; else exit 1 }' "$HEALTH_CADDYFILE")" || die "rollback Caddyfile must contain exactly one site address"
    [[ "$HEALTH_HOSTNAME" =~ ^[A-Za-z0-9.-]+$ ]] || die "rollback Caddyfile site address is unsafe"
    HEALTH_MODE=rollback
  else
    die "usage: health-check.sh [--caddyfile <verified-caddyfile>]"
  fi
}
check_app_port_policy() {
  if [[ "$HEALTH_MODE" == candidate ]]; then
    remote "! docker port nextcloud-docker-app-1 80/tcp >/dev/null 2>&1" || die "application port is published"
  fi
}

# The offline regression test sources the bounded primitives above; normal
# invocation always continues into the full read-only Pi health check below.
if [[ "${HEALTH_CHECK_LIBRARY_ONLY:-}" == 1 && "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0 2>/dev/null || exit 0
fi

prepare_health_config "$@"

retry_remote "target identity and storage mount" "test \"\$(hostname)\" = '$NEXTCLOUD_PI_SYSTEM_HOSTNAME' && findmnt -rn --target '$NEXTCLOUD_STORAGE_MOUNT' >/dev/null"
retry_remote "active image identity" "sudo -n /usr/local/libexec/nextcloud-pi-validate-active-images"
for container in nextcloud-docker-db-1 nextcloud-docker-app-1 nextcloud-docker-caddy-1; do
  retry_remote "container $container" "test \"\$(docker inspect --format '{{.State.Running}}' '$container' 2>/dev/null || true)\" = true"
done
retry_remote "MariaDB" "docker exec nextcloud-docker-db-1 sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mariadb --protocol=tcp --host=127.0.0.1 -uroot --skip-column-names --batch \"\$MYSQL_DATABASE\" -e \"SELECT 1\"' | grep -Fx 1"
retry_remote "Nextcloud status" "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status 2>/dev/null | grep -Eq 'installed: true|installed: yes' && docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status 2>/dev/null | grep -Eq 'maintenance: false|maintenance: no' && docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status 2>/dev/null | grep -Eq 'needsDbUpgrade: false|needsDbUpgrade: no'"
check_app_port_policy
remote "docker exec -i nextcloud-docker-caddy-1 caddy adapt --config /dev/stdin --adapter caddyfile >/dev/null 2>&1" <"$HEALTH_CADDYFILE" || die "Caddy configuration validation failed"
retry_remote "HTTPS proxy" "curl --fail --silent --show-error --max-time 10 --insecure --resolve '$HEALTH_HOSTNAME:443:127.0.0.1' 'https://$HEALTH_HOSTNAME/' >/dev/null"
printf 'Health check passed for %s.\n' "$NEXTCLOUD_PI_SYSTEM_HOSTNAME"
