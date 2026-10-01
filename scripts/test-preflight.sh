#!/usr/bin/env bash
# Static guard that preflight reads protected Pi state through the dispatcher.
set -euo pipefail
readonly PREFLIGHT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/preflight.sh"
bash -n "$PREFLIGHT"
grep -Fq 'nextcloud-pi-ops active-images-state' "$PREFLIGHT"
grep -Fq 'nextcloud-pi-ops protected-state active-image-record' "$PREFLIGHT"
grep -Fq 'background_jobs_scheduler_state()' "$PREFLIGHT"
grep -Fq 'background-job scheduler is absent before initial installation' "$PREFLIGHT"
grep -Fq 'Background-job scheduler installation is partial or unsafe' "$PREFLIGHT"
grep -Fq 'verify-image-upgrade.py' "$PREFLIGHT"
grep -Fq 'NEXTCLOUD_IMAGE_LOCK_FILE="$CANDIDATE_DIR/image-lock.env"' "$PREFLIGHT"
grep -Fq 'Protected active-image record matches the private candidate' "$PREFLIGHT"
grep -Fq 'Candidate conformance requires an active freeze and paused timer' "$PREFLIGHT"
grep -Fq 'compare_file_to_remote_command "candidate Compose"' "$PREFLIGHT"
if bash "$PREFLIGHT" --conformance --candidate relative-path >/dev/null 2>&1; then
  printf 'preflight accepted a relative private candidate path\n' >&2
  exit 1
fi
! grep -Eq 'sudo -n (cat|awk|test|sha256sum)' "$PREFLIGHT"

# An actual one-image candidate must pass the local candidate/rendered checks
# and reach the first remote probe. Fake SSH prevents any Pi contact.
readonly REPOSITORY_ROOT="$(cd -- "$(dirname -- "$PREFLIGHT")/.." && pwd)"
readonly TEST_DIR="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TEST_DIR/bin/ssh"
chmod 700 "$TEST_DIR/bin/ssh"
test_id="${BASHPID:-$$}"
printf 'NEXTCLOUD_PI_HOST=pi-%s.example.invalid\nNEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-%s\nNEXTCLOUD_PI_USER=test-user\nNEXTCLOUD_REMOTE_PROJECT_DIR=/opt/nextcloud-docker\nNEXTCLOUD_STORAGE_MOUNT=/mnt/test-%s\nNEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111\nNEXTCLOUD_PUBLIC_HOSTNAME=nextcloud-%s.example.invalid\n' \
  "$test_id" "$test_id" "$test_id" "$test_id" >"$TEST_DIR/deployment.env"
chmod 600 "$TEST_DIR/deployment.env"
NEXTCLOUD_DEPLOYMENT_ENV_FILE="$TEST_DIR/deployment.env" "$REPOSITORY_ROOT/scripts/render-deployment-config.sh" --output-dir "$TEST_DIR/rendered"
printf 'format\tnextcloud-upgrade-image-v1\nimage\tmariadb\ntag\tmariadb:11.4.13\nplatform\tlinux/arm64/v8\nindex_digest\tsha256:%064d\nmanifest_digest\tsha256:%064d\nconfig_digest\tsha256:%064d\n' 0 0 0 >"$TEST_DIR/metadata.tsv"
NEXTCLOUD_DEPLOYMENT_ENV_FILE="$TEST_DIR/deployment.env" python3 "$REPOSITORY_ROOT/scripts/prepare-image-upgrade.py" \
  --target db --metadata "$TEST_DIR/metadata.tsv" --image-lock "$REPOSITORY_ROOT/config/image-lock.env" \
  --rendered "$TEST_DIR/rendered" --output-dir "$TEST_DIR/candidate" >/dev/null
if PATH="$TEST_DIR/bin:$PATH" NEXTCLOUD_DEPLOYMENT_ENV_FILE="$TEST_DIR/deployment.env" \
  bash "$PREFLIGHT" --conformance --candidate "$TEST_DIR/candidate" >"$TEST_DIR/preflight.out" 2>&1; then
  printf 'fake SSH unexpectedly passed candidate preflight\n' >&2
  exit 1
fi
if ! grep -Fq '== Remote connectivity checks ==' "$TEST_DIR/preflight.out"; then
  printf 'valid candidate failed before remote conformance checks\n' >&2
  exit 1
fi
printf 'preflight privileged-state static contract tests passed\n'
