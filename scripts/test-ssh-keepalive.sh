#!/usr/bin/env bash
set -euo pipefail

# Large runtime/image streams must keep their SSH transport alive independently
# of a caller's local SSH config.
readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for script in \
  scripts/backup-runtime-state.sh \
  scripts/test-runtime-recovery.sh \
  scripts/export-image-recovery.sh \
  scripts/restore-image-recovery.sh \
  scripts/run-image-restore-readiness.sh \
  scripts/lib/image-import-transfer.sh; do
  grep -Fq 'ServerAliveInterval=30' "$ROOT/$script"
  grep -Fq 'ServerAliveCountMax=12' "$ROOT/$script"
done
grep -Fq 'scp -q -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=12' "$ROOT/scripts/lib/image-import-transfer.sh"
printf 'long-running SSH keepalive policy tests passed\n'
