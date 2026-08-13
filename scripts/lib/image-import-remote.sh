#!/usr/bin/env bash
set -euo pipefail

image_import_failure_record() {
  umask 077
  printf 'format\timage-import-failure-v1\nstate\tfailed\ntimestamp\t%s\nactions\tstop,load,verify,retag,record-install,restart,rollback\n' "$(date -u +%Y%m%dT%H%M%SZ)" >"$IMAGE_IMPORT_STAGE/failure.tsv"
  chmod 600 "$IMAGE_IMPORT_STAGE/failure.tsv"
}

image_import_stop_and_remove() {
  local name
  sudo -n systemctl stop nextcloud.service || true
  (cd "$IMAGE_IMPORT_PROJECT" && docker compose down) || true
  for name in nextcloud-docker-app-1 nextcloud-docker-db-1 nextcloud-docker-caddy-1; do
    if docker inspect "$name" >/dev/null 2>&1; then
      docker rm -f "$name" >/dev/null
    fi
    ! docker inspect "$name" >/dev/null 2>&1 || return 1
  done
  local service_state
  if service_state="$(sudo -n systemctl is-active nextcloud.service 2>/dev/null)"; then
    return 1
  fi
  [[ "$service_state" == inactive || "$service_state" == failed ]]
}

image_import_rollback() {
  trap - EXIT HUP INT TERM
  image_import_failure_record
  image_import_stop_and_remove
  while IFS=$'\t' read -r tag id; do docker tag "$id" "$tag"; done <"$IMAGE_IMPORT_STAGE/prior-tags.tsv"
  sudo -n install -m 0600 "$IMAGE_IMPORT_STAGE/prior-active.env" /etc/nextcloud-pi/active-images.env
  sudo -n systemctl start nextcloud.service
}

image_import_apply() {
  sudo -n cp -p /etc/nextcloud-pi/active-images.env "$IMAGE_IMPORT_STAGE/prior-active.env"
  for tag in "$IMAGE_IMPORT_APP_TAG" "$IMAGE_IMPORT_DB_TAG" "$IMAGE_IMPORT_CADDY_TAG"; do
    printf '%s\t%s\n' "$tag" "$(docker image inspect --format '{{.Id}}' "$tag")"
  done >"$IMAGE_IMPORT_STAGE/prior-tags.tsv"
  trap 'trap - EXIT HUP INT TERM; image_import_rollback; exit 1' EXIT HUP INT TERM
  image_import_stop_and_remove
  cd "$IMAGE_IMPORT_PROJECT"
  docker load -i "$IMAGE_IMPORT_STAGE/images.tar"
  awk -F '\t' '$1 == "image" { print $2 "\t" $3 }' "$IMAGE_IMPORT_STAGE/restore-attestation.tsv" >"$IMAGE_IMPORT_STAGE/attested-tags.tsv"
  while IFS=$'\t' read -r tag id; do test "$(docker image inspect --format '{{.Id}}' "$tag")" = "$id"; done <"$IMAGE_IMPORT_STAGE/attested-tags.tsv"
  sudo -n install -m 0600 "$IMAGE_IMPORT_STAGE/recovered.env" /etc/nextcloud-pi/active-images.env
  sudo -n systemctl start nextcloud.service
  trap - EXIT HUP INT TERM
}

if [[ "${IMAGE_IMPORT_LIBRARY_ONLY:-}" == 1 && "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0 2>/dev/null || exit 0
fi

[[ $# -eq 6 && ( "$1" == apply || "$1" == rollback ) ]] || { echo 'image import remote usage error' >&2; exit 2; }
mode="$1"
IMAGE_IMPORT_STAGE="$2"
IMAGE_IMPORT_PROJECT="$3"
IMAGE_IMPORT_APP_TAG="$4"
IMAGE_IMPORT_DB_TAG="$5"
IMAGE_IMPORT_CADDY_TAG="$6"
case "$IMAGE_IMPORT_STAGE:$IMAGE_IMPORT_PROJECT" in /*:/*) ;; *) exit 2 ;; esac
case "$mode" in apply) image_import_apply ;; rollback) image_import_rollback ;; esac
