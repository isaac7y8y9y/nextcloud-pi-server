#!/usr/bin/env bash

# Validate the root-only active image record as literal data. It is shared by
# deploy-time rendering and local tests; remote consumers perform the same
# closed-schema checks before using a tag mapping.

active_images_die() { printf 'Error: %s\n' "$1" >&2; return 1; }

active_images_validate_file() {
  local file="$1" expected_host="$2" expected_project="$3" expected_storage="$4"
  local line key value seen='|' required
  local required_keys=(
    NEXTCLOUD_ACTIVE_IMAGES_FORMAT NEXTCLOUD_ACTIVE_IMAGES_MODE
    NEXTCLOUD_ACTIVE_IMAGES_HOST NEXTCLOUD_ACTIVE_IMAGES_PROJECT
    NEXTCLOUD_ACTIVE_IMAGES_STORAGE NEXTCLOUD_ACTIVE_IMAGES_PLATFORM
    NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256
    NEXTCLOUD_ACTIVE_IMAGES_APP_TAG NEXTCLOUD_ACTIVE_IMAGES_APP_ID
    NEXTCLOUD_ACTIVE_IMAGES_DB_TAG NEXTCLOUD_ACTIVE_IMAGES_DB_ID
    NEXTCLOUD_ACTIVE_IMAGES_CADDY_TAG NEXTCLOUD_ACTIVE_IMAGES_CADDY_ID
  )
  [[ -f "$file" && ! -L "$file" ]] || { active_images_die "active image record is missing"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.+)$ ]] || { active_images_die "active image record has an invalid line"; return 1; }
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    case "$key" in
      NEXTCLOUD_ACTIVE_IMAGES_FORMAT|NEXTCLOUD_ACTIVE_IMAGES_MODE|NEXTCLOUD_ACTIVE_IMAGES_HOST|NEXTCLOUD_ACTIVE_IMAGES_PROJECT|NEXTCLOUD_ACTIVE_IMAGES_STORAGE|NEXTCLOUD_ACTIVE_IMAGES_PLATFORM|NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256|NEXTCLOUD_ACTIVE_IMAGES_APP_TAG|NEXTCLOUD_ACTIVE_IMAGES_APP_ID|NEXTCLOUD_ACTIVE_IMAGES_DB_TAG|NEXTCLOUD_ACTIVE_IMAGES_DB_ID|NEXTCLOUD_ACTIVE_IMAGES_CADDY_TAG|NEXTCLOUD_ACTIVE_IMAGES_CADDY_ID) ;;
      *) active_images_die "active image record has an unknown key"; return 1 ;;
    esac
    [[ "$seen" != *"|$key|"* ]] || { active_images_die "active image record has a duplicate key"; return 1; }
    seen+="$key|"; printf -v "$key" '%s' "$value"
  done <"$file"
  for required in "${required_keys[@]}"; do [[ -n "${!required-}" ]] || { active_images_die "active image record is incomplete"; return 1; }; done
  [[ "$NEXTCLOUD_ACTIVE_IMAGES_FORMAT" == nextcloud-active-images-v1 ]] || { active_images_die "active image record format is invalid"; return 1; }
  [[ "$NEXTCLOUD_ACTIVE_IMAGES_MODE" == source || "$NEXTCLOUD_ACTIVE_IMAGES_MODE" == recovered ]] || { active_images_die "active image record mode is invalid"; return 1; }
  [[ "$NEXTCLOUD_ACTIVE_IMAGES_HOST" == "$expected_host" && "$NEXTCLOUD_ACTIVE_IMAGES_PROJECT" == "$expected_project" && "$NEXTCLOUD_ACTIVE_IMAGES_STORAGE" == "$expected_storage" && "$NEXTCLOUD_ACTIVE_IMAGES_PLATFORM" == linux/arm64/v8 ]] || { active_images_die "active image record target differs"; return 1; }
  [[ "$NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || { active_images_die "active image provenance is invalid"; return 1; }
  for key in NEXTCLOUD_ACTIVE_IMAGES_APP_TAG NEXTCLOUD_ACTIVE_IMAGES_DB_TAG NEXTCLOUD_ACTIVE_IMAGES_CADDY_TAG; do [[ "${!key}" =~ ^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]+$ ]] || { active_images_die "active image tag is invalid"; return 1; }; done
  for key in NEXTCLOUD_ACTIVE_IMAGES_APP_ID NEXTCLOUD_ACTIVE_IMAGES_DB_ID NEXTCLOUD_ACTIVE_IMAGES_CADDY_ID; do [[ "${!key}" =~ ^sha256:[0-9a-f]{64}$ ]] || { active_images_die "active image ID is invalid"; return 1; }; done
}
