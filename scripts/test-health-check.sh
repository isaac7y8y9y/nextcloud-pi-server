#!/usr/bin/env bash
set -euo pipefail

readonly TEST_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_REPOSITORY_ROOT="$(cd -- "$TEST_SCRIPT_DIR/.." && pwd)"
readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
readonly HEALTH_CHECK="$TEST_SCRIPT_DIR/health-check.sh"
fixture="$TEST_DIR/deployment.env"
cp "$TEST_REPOSITORY_ROOT/config/deployment.env.example" "$fixture"
chmod 600 "$fixture"

# Load only retry_remote with harmless deployment values, then prove both a
# bounded retry success and a terminal failure without contacting the Pi.
NEXTCLOUD_PI_HOST=pi.test.invalid NEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-test NEXTCLOUD_PI_USER=test-user NEXTCLOUD_REMOTE_PROJECT_DIR=/srv/nextcloud-docker NEXTCLOUD_STORAGE_MOUNT=/mnt/test-nextcloud NEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111 NEXTCLOUD_PUBLIC_HOSTNAME=nextcloud.test.invalid NEXTCLOUD_DEPLOYMENT_ENV_FILE="$fixture" HEALTH_CHECK_LIBRARY_ONLY=1 source "$HEALTH_CHECK"
NEXTCLOUD_PUBLIC_HOSTNAME=nextcloud.test.invalid
call_count=0
remote() { call_count=$((call_count + 1)); (( call_count >= 3 )); }
sleep() { SECONDS=$((SECONDS + $1)); }
retry_remote 'retry fixture' true
[[ "$call_count" == 3 ]] || { echo 'expected exactly three health attempts' >&2; exit 1; }
if (remote() { return 1; }; sleep() { SECONDS=$((SECONDS + $1)); }; retry_remote 'failure fixture' false) >/dev/null 2>&1; then
  echo 'expected terminal health retry failure' >&2
  exit 1
fi

grep -Fq 'render-deployment-config.sh' "$HEALTH_CHECK"
grep -Fq '"$TMP_DIR/rendered/caddy/Caddyfile"' "$HEALTH_CHECK"
grep -Fq 'needsDbUpgrade: false' "$HEALTH_CHECK"
grep -Fq 'mariadb --protocol=tcp --host=127.0.0.1' "$HEALTH_CHECK"
grep -Fq -- '-e \"SELECT 1\"' "$HEALTH_CHECK"
grep -Fq -- '--caddyfile' "$HEALTH_CHECK"
grep -Fq 'must contain exactly one site address' "$HEALTH_CHECK"
grep -Fq 'HEALTH_HOSTNAME' "$HEALTH_CHECK"
grep -Fq '[[ "$HEALTH_MODE" == candidate ]]' "$HEALTH_CHECK"
grep -Fq 'deadline=$((SECONDS + 60))' "$HEALTH_CHECK"
grep -Fq 'BASH_SOURCE[0]}' "$HEALTH_CHECK"
grep -Fq 'timeout 15s sh -c' "$HEALTH_CHECK"
grep -Fq 'curl --fail --silent --show-error --max-time 10' "$HEALTH_CHECK"
if grep -Fq '"$REPOSITORY_ROOT/caddy/Caddyfile"' "$HEALTH_CHECK"; then
  echo 'health check must not stream the unrendered Caddy template' >&2
  exit 1
fi

valid_caddy="$TEST_DIR/rollback.Caddyfile"
printf '%s\n' 'rollback.test {' '    reverse_proxy app:80' '    tls internal' '}' >"$valid_caddy"
prepare_health_config --caddyfile "$valid_caddy"
[[ "$HEALTH_MODE" == rollback && "$HEALTH_HOSTNAME" == rollback.test ]]
cmp -s "$valid_caddy" "$HEALTH_CADDYFILE"

malformed_caddy="$TEST_DIR/malformed.Caddyfile"
printf '%s\n' 'reverse_proxy app:80' >"$malformed_caddy"
if (prepare_health_config --caddyfile "$malformed_caddy") >/dev/null 2>&1; then
  echo 'malformed rollback Caddyfile unexpectedly passed' >&2
  exit 1
fi

multiple_caddy="$TEST_DIR/multiple.Caddyfile"
printf '%s\n' 'one.test {' '}' 'two.test {' '}' >"$multiple_caddy"
if (prepare_health_config --caddyfile "$multiple_caddy") >/dev/null 2>&1; then
  echo 'multi-site rollback Caddyfile unexpectedly passed' >&2
  exit 1
fi

remote() { return 1; }
HEALTH_MODE=rollback
check_app_port_policy
if (HEALTH_MODE=candidate; check_app_port_policy) >/dev/null 2>&1; then
  echo 'candidate health unexpectedly tolerated a published app port' >&2
  exit 1
fi
echo 'health-check retry and rendering regression tests passed'
