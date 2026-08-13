#!/usr/bin/env bash
set -euo pipefail

# Resolve templates relative to this script, so invocation directory is irrelevant.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/deployment-config.sh"
source "$SCRIPT_DIR/lib/image-lock.sh"

usage() {
  printf 'Usage: %s --output-dir <directory>\n' "$0" >&2
}

[[ $# -eq 2 && "$1" == "--output-dir" ]] || { usage; exit 2; }
# Rendered files may contain deployment identity, so require an explicit absolute
# destination instead of accidentally writing beside tracked templates.
output_dir="$2"
[[ "$output_dir" = /* ]] || { printf 'Error: output directory must be absolute\n' >&2; exit 2; }

# Load and validate the ignored source values before creating private output.
load_deployment_config "$REPOSITORY_ROOT" || exit 1
image_lock_load "$REPOSITORY_ROOT" || exit 1
image_lock_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$REPOSITORY_ROOT/config/image-lock.env" | awk '{print $1}'
  else
    shasum -a 256 "$REPOSITORY_ROOT/config/image-lock.env" | awk '{print $1}'
  fi
}
readonly NEXTCLOUD_IMAGE_LOCK_SHA256="$(image_lock_sha256)"
if [[ -e "$output_dir" ]]; then
  # Refuse to merge with an existing directory; stale rendered files are unsafe.
  [[ -d "$output_dir" && ! -L "$output_dir" ]] || { printf 'Error: output directory is not a regular directory\n' >&2; exit 2; }
  [[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || { printf 'Error: output directory must be empty\n' >&2; exit 2; }
else
  mkdir -p "$output_dir"
fi
chmod 700 "$output_dir"
# docker-compose.yml and caddy/ form one directly resolvable Compose project.
# systemd/ and storage/ remain review/install inputs outside that project.
mkdir "$output_dir/caddy" "$output_dir/systemd" "$output_dir/systemd/docker.service.d" "$output_dir/storage" "$output_dir/launcher" "$output_dir/active-images"
chmod 700 "$output_dir/caddy" "$output_dir/systemd" "$output_dir/systemd/docker.service.d" "$output_dir/storage" "$output_dir/launcher" "$output_dir/active-images"

render_file() {
  # Substitute only the four template tokens used by deployment artifacts, then
  # make each resulting file private regardless of the caller's umask.
  local source_file="$1"
  local output_file="$2"

  sed \
    -e "s|@NEXTCLOUD_PUBLIC_HOSTNAME@|$NEXTCLOUD_PUBLIC_HOSTNAME|g" \
    -e "s|@NEXTCLOUD_PI_SYSTEM_HOSTNAME@|$NEXTCLOUD_PI_SYSTEM_HOSTNAME|g" \
    -e "s|@NEXTCLOUD_REMOTE_PROJECT_DIR@|$NEXTCLOUD_REMOTE_PROJECT_DIR|g" \
    -e "s|@NEXTCLOUD_STORAGE_MOUNT@|$NEXTCLOUD_STORAGE_MOUNT|g" \
    -e "s|@NEXTCLOUD_STORAGE_UUID@|$NEXTCLOUD_STORAGE_UUID|g" \
    -e "s|@NEXTCLOUD_IMAGE_PLATFORM@|$NEXTCLOUD_IMAGE_PLATFORM|g" \
    -e "s|@NEXTCLOUD_IMAGE_LOCK_SHA256@|$NEXTCLOUD_IMAGE_LOCK_SHA256|g" \
    -e "s|@NEXTCLOUD_IMAGE_APP_TAG@|$NEXTCLOUD_IMAGE_APP_TAG|g" \
    -e "s|@NEXTCLOUD_IMAGE_APP_ID@|$NEXTCLOUD_IMAGE_APP_ID|g" \
    -e "s|@NEXTCLOUD_IMAGE_DB_TAG@|$NEXTCLOUD_IMAGE_DB_TAG|g" \
    -e "s|@NEXTCLOUD_IMAGE_DB_ID@|$NEXTCLOUD_IMAGE_DB_ID|g" \
    -e "s|@NEXTCLOUD_IMAGE_CADDY_TAG@|$NEXTCLOUD_IMAGE_CADDY_TAG|g" \
    -e "s|@NEXTCLOUD_IMAGE_CADDY_ID@|$NEXTCLOUD_IMAGE_CADDY_ID|g" \
    "$source_file" >"$output_file"
  chmod 600 "$output_file"
}

# These are the only templates with deployment-specific identity or paths.
render_file "$REPOSITORY_ROOT/caddy/Caddyfile" "$output_dir/caddy/Caddyfile"
render_file "$REPOSITORY_ROOT/compose/docker-compose.yml" "$output_dir/docker-compose.yml"
render_file "$REPOSITORY_ROOT/systemd/nextcloud.service" "$output_dir/systemd/nextcloud.service"
render_file "$REPOSITORY_ROOT/systemd/docker.service.d/nextcloud-storage.conf" "$output_dir/systemd/docker.service.d/nextcloud-storage.conf"
render_file "$REPOSITORY_ROOT/systemd/nextcloud-pi-compose-start" "$output_dir/launcher/nextcloud-pi-compose-start"
render_file "$REPOSITORY_ROOT/systemd/nextcloud-pi-validate-active-images" "$output_dir/launcher/nextcloud-pi-validate-active-images"
render_file "$REPOSITORY_ROOT/systemd/active-images.env" "$output_dir/active-images/active-images.env"
chmod 700 "$output_dir/launcher/nextcloud-pi-compose-start"
chmod 700 "$output_dir/launcher/nextcloud-pi-validate-active-images"
render_file "$REPOSITORY_ROOT/storage/fstab.nextcloud" "$output_dir/storage/fstab.nextcloud"
