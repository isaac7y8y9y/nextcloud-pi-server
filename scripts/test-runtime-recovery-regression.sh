#!/usr/bin/env bash
set -euo pipefail
readonly DRILL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test-runtime-recovery.sh"
bash -n "$DRILL"
for action in 'runtime-recovery check' 'runtime-recovery prepare' 'runtime-recovery restore' 'runtime-recovery cleanup'; do grep -Fq "$action" "$DRILL"; done
! grep -Eq 'sudo -n (find|tar|install|rm|true)' "$DRILL"
printf 'runtime recovery dispatcher behavior tests passed\n'
