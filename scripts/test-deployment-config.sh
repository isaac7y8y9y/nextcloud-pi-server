#!/usr/bin/env bash
set -euo pipefail

# TEST_DIR contains only generated fixtures and is removed even when a check fails.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mode_of() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

# Start from the public example; caller overrides below provide harmless test values.
fixture="$TEST_DIR/deployment.env"
cp "$REPOSITORY_ROOT/config/deployment.env.example" "$fixture"
chmod 600 "$fixture"

# A copied example must never be renderable without replacing its placeholders.
if NEXTCLOUD_DEPLOYMENT_ENV_FILE="$fixture" "$SCRIPT_DIR/render-deployment-config.sh" --output-dir "$TEST_DIR/placeholders" >/dev/null 2>&1; then
  echo 'expected placeholder deployment configuration to be rejected' >&2
  exit 1
fi

# Exercise the successful path using environment precedence over the fixture.
NEXTCLOUD_PI_HOST=pi.test.invalid \
NEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-test \
NEXTCLOUD_PI_USER=test-user \
NEXTCLOUD_REMOTE_PROJECT_DIR=/srv/nextcloud-docker \
NEXTCLOUD_STORAGE_MOUNT=/mnt/test-nextcloud \
NEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111 \
NEXTCLOUD_PUBLIC_HOSTNAME=nextcloud.test.invalid \
NEXTCLOUD_DEPLOYMENT_ENV_FILE="$fixture" "$SCRIPT_DIR/render-deployment-config.sh" --output-dir "$TEST_DIR/rendered"
# Verify confidentiality permissions, substituted values, and no token leakage.
[[ "$(mode_of "$TEST_DIR/rendered")" == "700" ]]
[[ "$(mode_of "$TEST_DIR/rendered/caddy/Caddyfile")" == "600" ]]
[[ "$(mode_of "$TEST_DIR/rendered/systemd/docker.service.d/nextcloud-storage.conf")" == "600" ]]
[[ "$(mode_of "$TEST_DIR/rendered/launcher/nextcloud-pi-compose-start")" == "700" ]]
[[ "$(mode_of "$TEST_DIR/rendered/launcher/nextcloud-pi-validate-active-images")" == "700" ]]
[[ "$(mode_of "$TEST_DIR/rendered/active-images/active-images.env")" == "600" ]]
grep -Eq 'nextcloud\.test\.invalid' "$TEST_DIR/rendered/caddy/Caddyfile"
grep -Fq '/mnt/test-nextcloud/nextcloud_db' "$TEST_DIR/rendered/docker-compose.yml"
grep -Fq -- '- ./caddy/Caddyfile:/etc/caddy/Caddyfile' "$TEST_DIR/rendered/docker-compose.yml"
[[ -f "$TEST_DIR/rendered/caddy/Caddyfile" ]]
grep -Fq '/srv/nextcloud-docker' "$TEST_DIR/rendered/systemd/nextcloud.service"
grep -Fq 'RequiresMountsFor=/mnt/test-nextcloud' "$TEST_DIR/rendered/systemd/nextcloud.service"
grep -Fq 'RequiresMountsFor=/mnt/test-nextcloud' "$TEST_DIR/rendered/systemd/docker.service.d/nextcloud-storage.conf"
grep -Fq 'nextcloud-pi-compose-start' "$TEST_DIR/rendered/systemd/nextcloud.service"
grep -Fq 'ExecStop=/usr/bin/docker compose stop' "$TEST_DIR/rendered/systemd/nextcloud.service"
if grep -Fq 'ExecStop=/usr/bin/docker compose down' "$TEST_DIR/rendered/systemd/nextcloud.service"; then
  echo 'shutdown must retain container IDs for mount-gated automatic restart' >&2
  exit 1
fi
grep -Fq 'NEXTCLOUD_ACTIVE_IMAGES_MODE=source' "$TEST_DIR/rendered/active-images/active-images.env"
grep -Fq 'NEXTCLOUD_ACTIVE_IMAGES_HOST=pi-test' "$TEST_DIR/rendered/active-images/active-images.env"
grep -Fq 'NEXTCLOUD_ACTIVE_IMAGES_APP_TAG=nextcloud:30' "$TEST_DIR/rendered/active-images/active-images.env"
bash -n "$TEST_DIR/rendered/launcher/nextcloud-pi-compose-start"
grep -Fq 'nextcloud-pi-validate-active-images' "$TEST_DIR/rendered/launcher/nextcloud-pi-compose-start"
grep -Fq -- 'up -d --pull never' "$TEST_DIR/rendered/launcher/nextcloud-pi-compose-start"
grep -Fq -- '--project-directory "$PROJECT" -f "$COMPOSE_FILE" config --format json' "$TEST_DIR/rendered/launcher/nextcloud-pi-compose-start"
grep -Fq -- '-f "$SNAPSHOT" up -d --pull never' "$TEST_DIR/rendered/launcher/nextcloud-pi-compose-start"
grep -Fq '11111111-1111-1111-1111-111111111111' "$TEST_DIR/rendered/storage/fstab.nextcloud"
! grep -q '@NEXTCLOUD_' "$TEST_DIR/rendered/caddy/Caddyfile" "$TEST_DIR/rendered/docker-compose.yml" "$TEST_DIR/rendered/systemd/nextcloud.service" "$TEST_DIR/rendered/systemd/docker.service.d/nextcloud-storage.conf" "$TEST_DIR/rendered/launcher/nextcloud-pi-compose-start" "$TEST_DIR/rendered/active-images/active-images.env" "$TEST_DIR/rendered/storage/fstab.nextcloud"

# Rendering must not overwrite an existing output tree from an earlier run.
mkdir "$TEST_DIR/non-empty-output"
touch "$TEST_DIR/non-empty-output/marker"
if NEXTCLOUD_PI_HOST=pi.test.invalid \
  NEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-test \
  NEXTCLOUD_PI_USER=test-user \
  NEXTCLOUD_REMOTE_PROJECT_DIR=/srv/nextcloud-docker \
  NEXTCLOUD_STORAGE_MOUNT=/mnt/test-nextcloud \
  NEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111 \
  NEXTCLOUD_PUBLIC_HOSTNAME=nextcloud.test.invalid \
  NEXTCLOUD_DEPLOYMENT_ENV_FILE="$fixture" "$SCRIPT_DIR/render-deployment-config.sh" --output-dir "$TEST_DIR/non-empty-output" >/dev/null 2>&1; then
  echo 'expected a non-empty renderer output directory to be rejected' >&2
  exit 1
fi

echo 'deployment configuration rendering tests passed'
