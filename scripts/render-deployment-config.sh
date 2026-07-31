#!/usr/bin/env bash
set -euo pipefail

# Resolve templates relative to this script, so invocation directory is irrelevant.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/deployment-config.sh"

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
mkdir "$output_dir/caddy" "$output_dir/systemd" "$output_dir/storage"
chmod 700 "$output_dir/caddy" "$output_dir/systemd" "$output_dir/storage"

render_file() {
  # Substitute only the four template tokens used by deployment artifacts, then
  # make each resulting file private regardless of the caller's umask.
  local source_file="$1"
  local output_file="$2"

  sed \
    -e "s|@NEXTCLOUD_PUBLIC_HOSTNAME@|$NEXTCLOUD_PUBLIC_HOSTNAME|g" \
    -e "s|@NEXTCLOUD_REMOTE_PROJECT_DIR@|$NEXTCLOUD_REMOTE_PROJECT_DIR|g" \
    -e "s|@NEXTCLOUD_STORAGE_MOUNT@|$NEXTCLOUD_STORAGE_MOUNT|g" \
    -e "s|@NEXTCLOUD_STORAGE_UUID@|$NEXTCLOUD_STORAGE_UUID|g" \
    "$source_file" >"$output_file"
  chmod 600 "$output_file"
}

# These are the only templates with deployment-specific identity or paths.
render_file "$REPOSITORY_ROOT/caddy/Caddyfile" "$output_dir/caddy/Caddyfile"
render_file "$REPOSITORY_ROOT/compose/docker-compose.yml" "$output_dir/docker-compose.yml"
render_file "$REPOSITORY_ROOT/systemd/nextcloud.service" "$output_dir/systemd/nextcloud.service"
render_file "$REPOSITORY_ROOT/storage/fstab.nextcloud" "$output_dir/storage/fstab.nextcloud"
