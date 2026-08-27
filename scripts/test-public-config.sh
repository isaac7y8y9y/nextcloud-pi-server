#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly TEST_DIR="$(mktemp -d)"
readonly CADDY_VALIDATION_IMAGE="${CADDY_VALIDATION_IMAGE:-caddy:2}"
trap 'rm -rf "$TEST_DIR"' EXIT

command -v docker >/dev/null 2>&1 || {
  printf 'Error: Docker is required for public configuration validation\n' >&2
  exit 1
}
docker compose version >/dev/null
docker info >/dev/null

deployment_fixture="$TEST_DIR/deployment.env"
cp "$REPOSITORY_ROOT/config/deployment.env.example" "$deployment_fixture"
chmod 600 "$deployment_fixture"

NEXTCLOUD_PI_HOST=pi.test.invalid \
NEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-test \
NEXTCLOUD_PI_USER=test-user \
NEXTCLOUD_REMOTE_PROJECT_DIR=/srv/nextcloud-docker \
NEXTCLOUD_STORAGE_MOUNT=/mnt/test-nextcloud \
NEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111 \
NEXTCLOUD_PUBLIC_HOSTNAME=nextcloud.test.invalid \
NEXTCLOUD_DEPLOYMENT_ENV_FILE="$deployment_fixture" \
  "$SCRIPT_DIR/render-deployment-config.sh" --output-dir "$TEST_DIR/rendered"

compose_fixture="$TEST_DIR/compose.env"
{
  printf '%s\n' \
    'MYSQL_ROOT_PASSWORD=synthetic-root-password' \
    'MYSQL_PASSWORD=synthetic-user-password' \
    'MYSQL_DATABASE=nextcloud_test' \
    'MYSQL_USER=nextcloud_test'
} >"$compose_fixture"
chmod 600 "$compose_fixture"

docker compose \
  --project-directory "$TEST_DIR/rendered" \
  --env-file "$compose_fixture" \
  --file "$TEST_DIR/rendered/docker-compose.yml" \
  config --quiet
printf 'Compose configuration validation passed\n'

docker run --rm \
  --network none \
  --read-only \
  --tmpfs /config \
  --tmpfs /data \
  --volume "$TEST_DIR/rendered/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
  --entrypoint caddy \
  "$CADDY_VALIDATION_IMAGE" \
  validate --config /etc/caddy/Caddyfile --adapter caddyfile
printf 'Caddy configuration validation passed\n'
