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
if bash "$PREFLIGHT" --conformance --candidate relative-path >/dev/null 2>&1; then
  printf 'preflight accepted a relative private candidate path\n' >&2
  exit 1
fi
! grep -Eq 'sudo -n (cat|awk|test|sha256sum)' "$PREFLIGHT"
printf 'preflight privileged-state static contract tests passed\n'
