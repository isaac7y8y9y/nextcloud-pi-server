#!/usr/bin/env bash
set -euo pipefail

sha256_file() { sha256sum "$1" | awk '{print $1}'; }
size_file() { wc -c <"$1" | tr -d '[:space:]'; }
IMAGE_IMPORT_ID="${IMAGE_IMPORT_ID:-20260906T000000Z-1}"
IMAGE_IMPORT_ACTIVE_PREPARED=0

image_import_failure_record() {
  umask 077
  printf 'format\timage-import-failure-v1\nstate\tfailed\ntimestamp\t%s\nactions\tstop,load,verify,retag,record-install,restart,rollback\n' "$(date -u +%Y%m%dT%H%M%SZ)" >"$IMAGE_IMPORT_STAGE/failure.tsv"
  chmod 600 "$IMAGE_IMPORT_STAGE/failure.tsv"
}

image_import_stop_and_remove() {
  local name
  sudo -n /usr/local/libexec/nextcloud-pi-ops service stop || true
  (cd "$IMAGE_IMPORT_PROJECT" && docker compose down) || true
  for name in nextcloud-docker-app-1 nextcloud-docker-db-1 nextcloud-docker-caddy-1; do
    if docker inspect "$name" >/dev/null 2>&1; then
      docker rm -f "$name" >/dev/null
    fi
    ! docker inspect "$name" >/dev/null 2>&1 || return 1
  done
  # The dispatcher verified nextcloud.service reached a stopped state.
  return 0
}

image_import_rollback() {
  trap - EXIT HUP INT TERM
  image_import_failure_record
  image_import_stop_and_remove
  while IFS=$'\t' read -r tag id; do docker tag "$id" "$tag"; done <"$IMAGE_IMPORT_STAGE/prior-tags.tsv"
  if (( IMAGE_IMPORT_ACTIVE_PREPARED )); then
    sudo -n /usr/local/libexec/nextcloud-pi-ops active-record rollback "$IMAGE_IMPORT_ID"
  fi
  sudo -n /usr/local/libexec/nextcloud-pi-ops service start
}

image_import_apply() {
  local record_hash record_size
  for tag in "$IMAGE_IMPORT_APP_TAG" "$IMAGE_IMPORT_DB_TAG" "$IMAGE_IMPORT_CADDY_TAG"; do
    printf '%s\t%s\n' "$tag" "$(docker image inspect --format '{{.Id}}' "$tag")"
  done >"$IMAGE_IMPORT_STAGE/prior-tags.tsv"
  trap 'trap - EXIT HUP INT TERM; image_import_rollback; exit 1' EXIT HUP INT TERM
  cd "$IMAGE_IMPORT_PROJECT"
  docker load -i "$IMAGE_IMPORT_STAGE/images.tar"
  awk -F '\t' '$1 == "image" { print $2 "\t" $3 }' "$IMAGE_IMPORT_STAGE/restore-attestation.tsv" >"$IMAGE_IMPORT_STAGE/attested-tags.tsv"
  # Docker 29 can retain a multi-platform index as a tag's default identity.
  # Recovery attestations bind the selected platform manifest, so verify that
  # mapping explicitly before and after the approval-bound retag.
  while IFS=$'\t' read -r tag id; do
    test "$(docker image inspect --format '{{.Id}}' "$id")" = "$id"
    docker tag "$id" "$tag"
    test "$(docker image inspect --platform "$NEXTCLOUD_IMAGE_PLATFORM" --format '{{.Id}}' "$tag")" = "$id"
  done <"$IMAGE_IMPORT_STAGE/attested-tags.tsv"
  record_hash="$(sha256_file "$IMAGE_IMPORT_STAGE/recovered.env")"
  record_size="$(size_file "$IMAGE_IMPORT_STAGE/recovered.env")"
  sudo -n /usr/local/libexec/nextcloud-pi-ops active-record prepare "$IMAGE_IMPORT_ID" "$record_hash" "$record_size" <"$IMAGE_IMPORT_STAGE/recovered.env"
  IMAGE_IMPORT_ACTIVE_PREPARED=1
  image_import_stop_and_remove
  sudo -n /usr/local/libexec/nextcloud-pi-ops active-record apply "$IMAGE_IMPORT_ID"
  sudo -n /usr/local/libexec/nextcloud-pi-ops service start
  trap - EXIT HUP INT TERM
}

if [[ "${IMAGE_IMPORT_LIBRARY_ONLY:-}" == 1 && "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0 2>/dev/null || exit 0
fi

[[ $# -eq 7 && ( "$1" == apply || "$1" == rollback || "$1" == commit ) ]] || { echo 'image import remote usage error' >&2; exit 2; }
mode="$1"
IMAGE_IMPORT_ID="$2"
IMAGE_IMPORT_STAGE="$3"
IMAGE_IMPORT_PROJECT="$4"
IMAGE_IMPORT_APP_TAG="$5"
IMAGE_IMPORT_DB_TAG="$6"
IMAGE_IMPORT_CADDY_TAG="$7"
[[ "$IMAGE_IMPORT_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || exit 2
case "$IMAGE_IMPORT_STAGE:$IMAGE_IMPORT_PROJECT" in /*:/*) ;; *) exit 2 ;; esac
case "$mode" in
  apply) image_import_apply ;;
  # A health-failure rollback is invoked by the Mac-side owner in a new shell
  # after apply succeeded. That transaction is necessarily prepared, so do not
  # rely on the in-process apply trap's state flag.
  rollback) IMAGE_IMPORT_ACTIVE_PREPARED=1; image_import_rollback ;;
  commit) sudo -n /usr/local/libexec/nextcloud-pi-ops active-record commit "$IMAGE_IMPORT_ID" ;;
esac
