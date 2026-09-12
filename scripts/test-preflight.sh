#!/usr/bin/env bash
# Static guard that preflight reads protected Pi state through the dispatcher.
set -euo pipefail
readonly PREFLIGHT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/preflight.sh"
bash -n "$PREFLIGHT"
grep -Fq 'nextcloud-pi-ops active-images-state' "$PREFLIGHT"
grep -Fq 'nextcloud-pi-ops protected-state active-image-record' "$PREFLIGHT"
! grep -Eq 'sudo -n (cat|awk|test|sha256sum)' "$PREFLIGHT"
printf 'preflight privileged-state static contract tests passed\n'
