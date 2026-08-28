#!/usr/bin/env bash
set -euo pipefail

# Docker load must be proven against a disposable daemon, never the live Pi
# daemon. Start that daemon separately with an isolated data root and pass its
# non-default socket explicitly; this script never starts containers.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/image-lock.sh"
image_lock_load "$REPOSITORY_ROOT"

usage() { printf 'Usage: %s --docker-host <isolated-unix-socket> <image-recovery-directory>\n' "$0" >&2; }
die() { printf 'Image restore-readiness test failed: %s\n' "$1" >&2; exit 1; }

[[ "${1:-}" == "--docker-host" && $# -eq 3 ]] || { usage; exit 2; }
docker_host="$2"
recovery_dir="$3"
attestation="$recovery_dir/restore-attestation.tsv"
staging_attestation="$recovery_dir/.restore-attestation-$$.tsv"
validation_dir=""
ATTESTATION_COMPLETE=0
[[ ! -e "$attestation" && ! -L "$attestation" ]] ||
  die "recovery directory already contains a restore attestation"
cleanup() {
  rm -f -- "$staging_attestation"
  if [[ -n "$validation_dir" && "$validation_dir" == "$(dirname -- "$recovery_dir")"/image-recovery-attestation-check.* ]]; then
    rm -rf -- "$validation_dir"
  fi
  (( ATTESTATION_COMPLETE != 0 )) || rm -f -- "$attestation"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
[[ "$docker_host" =~ ^unix:///tmp/[A-Za-z0-9._/-]+\.sock$ ]] || die "Docker host must be an explicit isolated /tmp socket"
[[ "$docker_host" != "unix:///var/run/docker.sock" ]] || die "the live Docker socket is never allowed"
"$SCRIPT_DIR/verify-image-recovery.sh" "$recovery_dir" >/dev/null

docker -H "$docker_host" info >/dev/null || die "isolated Docker daemon is not reachable"
[[ -z "$(docker -H "$docker_host" ps -aq)" ]] || die "isolated daemon already contains containers"
docker -H "$docker_host" load -i "$recovery_dir/images.tar" >/dev/null
umask 077
{
  printf 'format\timage-restore-attestation-v1\n'
  printf 'archive_sha256\t%s\n' "$(awk -F $'\t' '$1 == "archive_sha256" { print $2 }' "$recovery_dir/manifest.tsv")"
  for field in platform remote_host remote_user source_project storage_mount; do
    printf '%s\t%s\n' "$field" "$(awk -F $'\t' -v key="$field" '$1 == key { print $2 }' "$recovery_dir/manifest.tsv")"
  done
  printf 'isolated_docker_host\t%s\n' "$docker_host"
  printf 'isolated_result\tno-containers\n'
  printf 'timestamp\t%s\n' "$(date -u +%Y%m%dT%H%M%SZ)"
  while IFS= read -r tag; do
    printf 'source_image\t%s\t%s\n' "$tag" "$(image_lock_expected_id "$tag")"
    printf 'image\t%s\t%s\n' "$tag" "$(docker -H "$docker_host" image inspect --format '{{.Id}}' "$tag")"
  done < <(image_lock_tags)
} >"$staging_attestation"
chmod 600 "$staging_attestation"
while IFS= read -r tag; do
  expected="$(awk -F $'\t' -v tag="$tag" '$1 == "image" && $2 == tag { print $3 }' "$staging_attestation")"
  actual="$(docker -H "$docker_host" image inspect --format '{{.Id}}' "$tag")"
  [[ "$actual" == "$expected" ]] || die "loaded tag does not resolve to the attested image ID: $tag"
done < <(image_lock_tags)
[[ -z "$(docker -H "$docker_host" ps -aq)" ]] || die "the restore-readiness test must not create containers"

# Validate the complete candidate before publishing it. Hard links keep the
# potentially large archive on the same filesystem without copying it.
validation_dir="$(mktemp -d "$(dirname -- "$recovery_dir")/image-recovery-attestation-check.XXXXXX")"
chmod 700 "$validation_dir"
ln "$recovery_dir/manifest.tsv" "$validation_dir/manifest.tsv"
ln "$recovery_dir/images.tar" "$validation_dir/images.tar"
cp "$staging_attestation" "$validation_dir/restore-attestation.tsv"
chmod 600 "$validation_dir/restore-attestation.tsv"
"$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$validation_dir" >/dev/null
rm -rf -- "$validation_dir"
validation_dir=""

mv "$staging_attestation" "$attestation"
"$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$recovery_dir" >/dev/null
ATTESTATION_COMPLETE=1
printf 'Image restore-readiness passed; remove the isolated daemon and its data root separately.\n'
