#!/usr/bin/env bash
set -euo pipefail

# Export the three locked Pi images into one protected, local archive. This is
# intentionally separate from deployment: exporting does not authorize a
# configuration change or a container restart.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
source "$SCRIPT_DIR/lib/image-lock.sh"
load_deployment_config "$REPOSITORY_ROOT"
image_lock_load "$REPOSITORY_ROOT"

readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
OUTPUT_ROOT="${NEXTCLOUD_IMAGE_RECOVERY_ROOT:-$HOME/nextcloud-pi-image-recovery}"
STAGING_DIR=""

usage() { printf 'Usage: %s [--output-root <absolute-directory>]\n' "$0" >&2; }
die() { printf 'Image recovery export failed: %s\n' "$1" >&2; exit 1; }
mode_of() { if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"; }
cleanup() { [[ -z "$STAGING_DIR" || ! -d "$STAGING_DIR" ]] || rm -rf "$STAGING_DIR"; }
reject_git_target() {
  local target="$1" ancestor="$1" git_root
  [[ "$target" = /* ]] || die "output root must be absolute"
  while [[ ! -e "$ancestor" ]]; do ancestor="$(dirname -- "$ancestor")"; done
  git_root="$(git -C "$ancestor" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -z "$git_root" ]] || die "output root must not be inside a Git worktree"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-root) [[ $# -eq 2 ]] || { usage; exit 2; }; OUTPUT_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
reject_git_target "$OUTPUT_ROOT"
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"
[[ "$(mode_of "$OUTPUT_ROOT")" == "700" ]] || die "could not protect output root"

remote "test \"\$(hostname)\" = '$NEXTCLOUD_PI_SYSTEM_HOSTNAME' && test \"\$(id -un)\" = '$NEXTCLOUD_PI_USER'" || die "connected Pi identity does not match"
while IFS= read -r tag; do
  expected="$(image_lock_expected_id "$tag")"
  actual="$(remote "docker image inspect --format '{{.Id}}' '$tag'" </dev/null)"
  [[ "$actual" == "$expected" ]] || die "remote locked image is missing or has a different ID: $tag"
done < <(image_lock_tags)

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final_dir="$OUTPUT_ROOT/image-recovery-$timestamp"
[[ ! -e "$final_dir" ]] || die "recovery destination already exists"
STAGING_DIR="$OUTPUT_ROOT/.incomplete-image-recovery-$timestamp-$$"
trap cleanup EXIT
umask 077
mkdir "$STAGING_DIR"
chmod 700 "$STAGING_DIR"

printf 'Exporting locked images from the configured Pi; no containers will start.\n'
remote "docker image save --platform '$NEXTCLOUD_IMAGE_PLATFORM' $(image_lock_tags | sed "s/^/'/;s/$/'/" | tr '\n' ' ')" >"$STAGING_DIR/images.tar"
chmod 600 "$STAGING_DIR/images.tar"
[[ -s "$STAGING_DIR/images.tar" ]] || die "image archive is empty"

{
  printf 'format\timage-recovery-v1\n'
  printf 'state\tcomplete\n'
  printf 'timestamp\t%s\n' "$timestamp"
  printf 'remote_host\t%s\n' "$NEXTCLOUD_PI_SYSTEM_HOSTNAME"
  printf 'remote_user\t%s\n' "$NEXTCLOUD_PI_USER"
  printf 'source_project\t%s\n' "$NEXTCLOUD_REMOTE_PROJECT_DIR"
  printf 'storage_mount\t%s\n' "$NEXTCLOUD_STORAGE_MOUNT"
  printf 'platform\t%s\n' "$NEXTCLOUD_IMAGE_PLATFORM"
  printf 'archive_sha256\t%s\n' "$(sha256 "$STAGING_DIR/images.tar")"
  printf 'archive_bytes\t%s\n' "$(wc -c <"$STAGING_DIR/images.tar" | tr -d '[:space:]')"
  printf 'image\t%s\t%s\n' "$NEXTCLOUD_IMAGE_APP_TAG" "$NEXTCLOUD_IMAGE_APP_ID"
  printf 'image\t%s\t%s\n' "$NEXTCLOUD_IMAGE_DB_TAG" "$NEXTCLOUD_IMAGE_DB_ID"
  printf 'image\t%s\t%s\n' "$NEXTCLOUD_IMAGE_CADDY_TAG" "$NEXTCLOUD_IMAGE_CADDY_ID"
} >"$STAGING_DIR/manifest.tsv"
chmod 600 "$STAGING_DIR/manifest.tsv"
mv "$STAGING_DIR" "$final_dir"
STAGING_DIR=""
printf 'Image recovery archive completed: %s\n' "$final_dir"
printf 'Verify it offline before deployment: %s %q\n' "$SCRIPT_DIR/verify-image-recovery.sh" "$final_dir"
