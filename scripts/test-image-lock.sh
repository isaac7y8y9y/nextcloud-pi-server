#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/image-lock.sh"
image_lock_load "$REPOSITORY_ROOT"
[[ "$(image_lock_expected_id "$NEXTCLOUD_IMAGE_APP_TAG")" == "$NEXTCLOUD_IMAGE_APP_ID" ]]
[[ "$(image_lock_expected_id "$NEXTCLOUD_IMAGE_DB_TAG")" == "$NEXTCLOUD_IMAGE_DB_ID" ]]
[[ "$(image_lock_expected_id "$NEXTCLOUD_IMAGE_CADDY_TAG")" == "$NEXTCLOUD_IMAGE_CADDY_ID" ]]
[[ "$(image_lock_tags)" == $'nextcloud:30\nmariadb:11\ncaddy:2' ]]
if image_lock_expected_id missing:tag >/dev/null 2>&1; then
  echo 'expected unknown image tag to fail' >&2
  exit 1
fi
echo 'image-lock parsing tests passed'
