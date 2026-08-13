#!/usr/bin/env bash

# Parse the tracked image lock as data, never as executable shell input. Stable
# tags are used by Compose and offline `docker load`; IDs prove their identity.

image_lock_die() {
  printf 'Error: %s\n' "$1" >&2
  return 1
}

image_lock_load() {
  local repository_root="$1"
  local lock_file="${NEXTCLOUD_IMAGE_LOCK_FILE:-$repository_root/config/image-lock.env}"
  local line key value seen='|'
  local required_key
  local required_keys=(NEXTCLOUD_IMAGE_PLATFORM NEXTCLOUD_IMAGE_APP_TAG NEXTCLOUD_IMAGE_APP_ID NEXTCLOUD_IMAGE_DB_TAG NEXTCLOUD_IMAGE_DB_ID NEXTCLOUD_IMAGE_CADDY_TAG NEXTCLOUD_IMAGE_CADDY_ID)

  [[ -f "$lock_file" && ! -L "$lock_file" ]] || { image_lock_die "missing image lock"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || { image_lock_die "image lock contains an invalid line"; return 1; }
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      NEXTCLOUD_IMAGE_PLATFORM|NEXTCLOUD_IMAGE_APP_TAG|NEXTCLOUD_IMAGE_APP_ID|NEXTCLOUD_IMAGE_DB_TAG|NEXTCLOUD_IMAGE_DB_ID|NEXTCLOUD_IMAGE_CADDY_TAG|NEXTCLOUD_IMAGE_CADDY_ID) ;;
      *) image_lock_die "image lock contains an unknown key"; return 1 ;;
    esac
    [[ "$seen" != *"|$key|"* ]] || { image_lock_die "image lock contains a duplicate key"; return 1; }
    seen+="$key|"
    [[ -n "$value" && "$value" != *[[:space:]]* ]] || { image_lock_die "image lock contains an unsafe value"; return 1; }
    printf -v "$key" '%s' "$value"
  done <"$lock_file"
  for required_key in "${required_keys[@]}"; do
    [[ -n "${!required_key-}" ]] || { image_lock_die "image lock is missing a required key"; return 1; }
  done
  [[ "$NEXTCLOUD_IMAGE_PLATFORM" == "linux/arm64/v8" ]] || { image_lock_die "unsupported image platform"; return 1; }
  for key in NEXTCLOUD_IMAGE_APP_TAG NEXTCLOUD_IMAGE_DB_TAG NEXTCLOUD_IMAGE_CADDY_TAG; do
    [[ "${!key}" =~ ^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]+$ ]] || { image_lock_die "image lock contains an invalid tag"; return 1; }
  done
  for key in NEXTCLOUD_IMAGE_APP_ID NEXTCLOUD_IMAGE_DB_ID NEXTCLOUD_IMAGE_CADDY_ID; do
    [[ "${!key}" =~ ^sha256:[0-9a-f]{64}$ ]] || { image_lock_die "image lock contains an invalid image ID"; return 1; }
  done
  readonly NEXTCLOUD_IMAGE_PLATFORM NEXTCLOUD_IMAGE_APP_TAG NEXTCLOUD_IMAGE_APP_ID
  readonly NEXTCLOUD_IMAGE_DB_TAG NEXTCLOUD_IMAGE_DB_ID NEXTCLOUD_IMAGE_CADDY_TAG NEXTCLOUD_IMAGE_CADDY_ID
}

image_lock_tags() {
  printf '%s\n' "$NEXTCLOUD_IMAGE_APP_TAG" "$NEXTCLOUD_IMAGE_DB_TAG" "$NEXTCLOUD_IMAGE_CADDY_TAG"
}

image_lock_expected_id() {
  case "$1" in
    "$NEXTCLOUD_IMAGE_APP_TAG") printf '%s\n' "$NEXTCLOUD_IMAGE_APP_ID" ;;
    "$NEXTCLOUD_IMAGE_DB_TAG") printf '%s\n' "$NEXTCLOUD_IMAGE_DB_ID" ;;
    "$NEXTCLOUD_IMAGE_CADDY_TAG") printf '%s\n' "$NEXTCLOUD_IMAGE_CADDY_ID" ;;
    *) image_lock_die "image tag is not locked"; return 1 ;;
  esac
}

image_lock_verify_local() {
  local tag actual expected
  while IFS= read -r tag; do
    expected="$(image_lock_expected_id "$tag")"
    actual="$(docker image inspect --format '{{.Id}}' "$tag" 2>/dev/null || true)"
    [[ "$actual" == "$expected" ]] || { image_lock_die "locked image is missing or has a different ID: $tag"; return 1; }
  done < <(image_lock_tags)
}
