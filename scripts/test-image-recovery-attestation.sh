#!/usr/bin/env bash
set -euo pipefail

# Exercise the offline verifier with a minimal protected archive fixture. The
# archive payload is opaque here; isolated Docker readiness proves its load.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/image-lock.sh"
image_lock_load "$REPOSITORY_ROOT"
readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

recovery="$TEST_DIR/image-recovery-fixture"
mkdir -m 700 "$recovery"
: >"$recovery/images.tar"
chmod 600 "$recovery/images.tar"
archive_sha="$(sha256 "$recovery/images.tar")"
{
  printf 'format\timage-recovery-v1\nstate\tcomplete\ntimestamp\t20260812T000000Z\nremote_host\tpi-test\nremote_user\ttest-user\nsource_project\t/srv/nextcloud-docker\nstorage_mount\t/mnt/test-nextcloud\nplatform\tlinux/arm64/v8\narchive_sha256\t%s\narchive_bytes\t0\n' "$archive_sha"
  while IFS= read -r tag; do printf 'image\t%s\t%s\n' "$tag" "$(image_lock_expected_id "$tag")"; done < <(image_lock_tags)
} >"$recovery/manifest.tsv"
chmod 600 "$recovery/manifest.tsv"

write_attestation() {
  local substitute_source="$1" tag source post
  {
    printf 'format\timage-restore-attestation-v1\narchive_sha256\t%s\nplatform\tlinux/arm64/v8\nremote_host\tpi-test\nremote_user\ttest-user\nsource_project\t/srv/nextcloud-docker\nstorage_mount\t/mnt/test-nextcloud\nisolated_docker_host\tunix:///tmp/nextcloud-attestation-test.sock\nisolated_result\tno-containers\ntimestamp\t20260812T000000Z\n' "$archive_sha"
    while IFS= read -r tag; do
      source="$(image_lock_expected_id "$tag")"
      if [[ "$substitute_source" == yes ]]; then post="$source"; else post="${source%?}0"; [[ "$post" == "$source" ]] && post="${source%?}1"; fi
      printf 'source_image\t%s\t%s\nimage\t%s\t%s\n' "$tag" "$source" "$tag" "$post"
    done < <(image_lock_tags)
  } >"$recovery/restore-attestation.tsv"
  chmod 600 "$recovery/restore-attestation.tsv"
}

write_attestation no
bash "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$recovery" >/dev/null

sed -i.bak 's/^archive_sha256\t.*/archive_sha256\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' "$recovery/restore-attestation.tsv"
rm -f "$recovery/restore-attestation.tsv.bak"
if bash "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$recovery" >/dev/null 2>&1; then
  echo 'expected wrong attestation archive hash to be rejected' >&2
  exit 1
fi

write_attestation no
sed -i.bak 's/^platform\tlinux\/arm64\/v8$/platform\tlinux\/amd64/' "$recovery/restore-attestation.tsv"
rm -f "$recovery/restore-attestation.tsv.bak"
if bash "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$recovery" >/dev/null 2>&1; then
  echo 'expected wrong attestation platform to be rejected' >&2
  exit 1
fi

write_attestation no
sed -i.bak '/^source_image\tcaddy:2\t/d; /^image\tcaddy:2\t/d' "$recovery/restore-attestation.tsv"
rm -f "$recovery/restore-attestation.tsv.bak"
if bash "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$recovery" >/dev/null 2>&1; then
  echo 'expected missing attestation tag to be rejected' >&2
  exit 1
fi

write_attestation yes
if bash "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$recovery" >/dev/null 2>&1; then
  echo 'expected source-ID substitution to be rejected' >&2
  exit 1
fi
write_attestation no
printf 'image\tnextcloud:30\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\textra\n' >>"$recovery/restore-attestation.tsv"
if bash "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$recovery" >/dev/null 2>&1; then
  echo 'expected an extra attestation image field to be rejected' >&2
  exit 1
fi
echo 'image recovery attestation tests passed'
