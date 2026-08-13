#!/usr/bin/env bash
set -euo pipefail

# Verify image-recovery material offline. The archive is deliberately not
# unpacked here: Docker load into an isolated daemon is the readiness proof.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/image-lock.sh"
image_lock_load "$REPOSITORY_ROOT"

usage() { printf 'Usage: %s [--require-attestation] <image-recovery-directory>\n' "$0" >&2; }
die() { printf 'Image recovery verification failed: %s\n' "$1" >&2; exit 1; }
mode_of() { if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
value() { awk -F $'\t' -v key="$1" '$1 == key { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$recovery_dir/manifest.tsv"; }

require_attestation=0
if [[ "${1:-}" == "--require-attestation" ]]; then require_attestation=1; shift; fi
[[ $# -eq 1 ]] || { usage; exit 2; }
recovery_dir="$1"
[[ -d "$recovery_dir" && ! -L "$recovery_dir" ]] || die "recovery directory is missing or symbolic-linked"
recovery_dir="$(cd -- "$recovery_dir" && pwd -P)"
[[ "$(basename -- "$recovery_dir")" == image-recovery-* ]] || die "recovery directory name is unexpected"
[[ "$(mode_of "$recovery_dir")" == "700" ]] || die "recovery directory permissions must be 0700"
for file in manifest.tsv images.tar; do
  [[ -f "$recovery_dir/$file" && ! -L "$recovery_dir/$file" ]] || die "missing or symbolic-linked file: $file"
  [[ "$(mode_of "$recovery_dir/$file")" == "600" ]] || die "file permissions must be 0600: $file"
done
expected_entries=2
(( require_attestation != 0 )) && expected_entries=3
[[ "$(find "$recovery_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')" == "$expected_entries" ]] || die "recovery directory contains unexpected entries"
[[ "$(value format)" == "image-recovery-v1" && "$(value state)" == "complete" ]] || die "unsupported or incomplete recovery manifest"
[[ "$(value remote_host)" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && "$(value remote_user)" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die "recovery target identity is invalid"
[[ "$(value source_project)" =~ ^/[A-Za-z0-9._/-]+$ && "$(value storage_mount)" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "recovery target paths are invalid"
[[ "$(value platform)" == "$NEXTCLOUD_IMAGE_PLATFORM" ]] || die "recovery platform does not match lock"
[[ "$(value archive_sha256)" == "$(sha256 "$recovery_dir/images.tar")" ]] || die "archive checksum mismatch"
[[ "$(value archive_bytes)" == "$(wc -c <"$recovery_dir/images.tar" | tr -d '[:space:]')" ]] || die "archive size mismatch"
for tag in $(image_lock_tags); do
  expected="$(image_lock_expected_id "$tag")"
  actual="$(awk -F $'\t' -v tag="$tag" '$1 == "image" && $2 == tag { count++; value=$3 } END { if (count == 1) print value; else exit 1 }' "$recovery_dir/manifest.tsv")"
  [[ "$actual" == "$expected" ]] || die "recovery manifest image does not match lock: $tag"
done
if (( require_attestation != 0 )); then
  attestation="$recovery_dir/restore-attestation.tsv"
  [[ -f "$attestation" && ! -L "$attestation" && "$(mode_of "$attestation")" == "600" ]] || die "restore attestation is missing or unprotected"
  attested_value() { awk -F $'\t' -v key="$1" '$1 == key { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$attestation"; }
  attested_image_value() { awk -F $'\t' -v kind="$1" -v tag="$2" '$1 == kind && $2 == tag { count++; value=$3 } END { if (count == 1) print value; else exit 1 }' "$attestation"; }
  awk -F $'\t' '
    $1 == "format" || $1 == "archive_sha256" || $1 == "platform" || $1 == "remote_host" || $1 == "remote_user" || $1 == "source_project" || $1 == "storage_mount" || $1 == "isolated_docker_host" || $1 == "isolated_result" || $1 == "timestamp" { if (NF != 2) bad = 1; next }
    $1 == "source_image" || $1 == "image" { if (NF != 3) bad = 1; next }
    { bad = 1 }
    END { exit bad }
  ' "$attestation" || die "restore attestation field count is invalid"
  known_tag() { local wanted="$1" tag; while IFS= read -r tag; do [[ "$tag" == "$wanted" ]] && return 0; done < <(image_lock_tags); return 1; }
  while IFS=$'\t' read -r kind second third extra || [[ -n "$kind$second$third$extra" ]]; do
    case "$kind" in
      format|archive_sha256|platform|remote_host|remote_user|source_project|storage_mount|isolated_docker_host|isolated_result|timestamp)
        [[ -n "$second" && -z "$third" && -z "$extra" ]] || die "restore attestation singleton field is malformed"
        ;;
      source_image|image)
        [[ -n "$second" && "$third" =~ ^sha256:[0-9a-f]{64}$ && -z "$extra" ]] || die "restore attestation image mapping is malformed"
        known_tag "$second" || die "restore attestation has an unexpected image tag"
        ;;
      *) die "restore attestation has an unknown field" ;;
    esac
  done <"$attestation"
  [[ "$(attested_value format)" == "image-restore-attestation-v1" ]] || die "restore attestation format is invalid"
  [[ "$(attested_value archive_sha256)" == "$(value archive_sha256)" && "$(attested_value platform)" == "$NEXTCLOUD_IMAGE_PLATFORM" ]] || die "restore attestation does not bind this archive"
  for field in remote_host remote_user source_project storage_mount; do [[ "$(attested_value "$field")" == "$(value "$field")" ]] || die "restore attestation target differs"; done
  [[ "$(attested_value isolated_docker_host)" =~ ^unix:///tmp/[A-Za-z0-9._/-]+\.sock$ && "$(attested_value isolated_result)" == no-containers && "$(attested_value timestamp)" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "restore attestation isolated result is invalid"
  [[ "$(awk -F $'\t' '$1 == "source_image" { count++ } END { print count + 0 }' "$attestation")" == 3 && "$(awk -F $'\t' '$1 == "image" { count++ } END { print count + 0 }' "$attestation")" == 3 ]] || die "restore attestation image mapping count is invalid"
  for tag in $(image_lock_tags); do
    source_id="$(awk -F $'\t' -v tag="$tag" '$1 == "image" && $2 == tag { print $3 }' "$recovery_dir/manifest.tsv")"
    attested_source_id="$(attested_image_value source_image "$tag")"
    post_id="$(attested_image_value image "$tag")"
    [[ "$attested_source_id" == "$source_id" && "$post_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "restore attestation image mapping is invalid"
    [[ "$post_id" != "$source_id" ]] || die "restore attestation substitutes a source ID for a post-load ID"
  done
fi
printf 'Image recovery verified: %s\n' "$recovery_dir"
