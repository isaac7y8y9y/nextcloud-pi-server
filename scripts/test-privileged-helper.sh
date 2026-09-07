#!/usr/bin/env bash
set -euo pipefail
readonly HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/privileged/nextcloud-pi-ops"
bash -n "$HELPER"
for command in cmd_recovery_check cmd_active_prepare cmd_readiness_start cmd_drill_apply; do grep -Fq "$command" "$HELPER"; done
grep -Fq 'valid_id' "$HELPER"; grep -Fq 'reject_stdin' "$HELPER"; grep -Fq 'active-record-current' "$HELPER"; grep -Fq 'no_nested_mounts' "$HELPER"
! grep -Fq 'eval ' "$HELPER"
printf 'privileged helper contract tests passed\n'
