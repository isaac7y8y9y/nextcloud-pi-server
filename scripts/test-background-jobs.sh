#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly RUNNER="$ROOT/systemd/nextcloud-pi-background-jobs"
readonly SERVICE="$ROOT/systemd/nextcloud-background-jobs.service"
readonly TIMER="$ROOT/systemd/nextcloud-background-jobs.timer"
readonly HELPER="$ROOT/privileged/nextcloud-pi-ops"
readonly BACKUP="$ROOT/scripts/backup-runtime-state.sh"

bash -n "$RUNNER" "$HELPER" "$BACKUP"
grep -Fq 'OnBootSec=10min' "$TIMER"
grep -Fq 'OnUnitActiveSec=5min' "$TIMER"
grep -Fq 'TimeoutStartSec=infinity' "$SERVICE"
grep -Fq 'RequiresMountsFor=@NEXTCLOUD_STORAGE_MOUNT@' "$SERVICE"
grep -Fq 'After=nextcloud.service' "$SERVICE"
! grep -Fq 'Requires=nextcloud.service' "$SERVICE"
grep -Fq 'systemctl is-active --quiet "$NEXTCLOUD_SERVICE" || exit 0' "$RUNNER"
grep -Fq 'install -d -m 0700 -o root -g root "$LOCK_ROOT"' "$RUNNER"
grep -Fq 'php -f /var/www/html/cron.php' "$RUNNER"
grep -Fq 'cmd_background_jobs_pause' "$HELPER"
grep -Fq 'background-jobs) sub=' "$HELPER"
grep -Fq 'pause_background_jobs' "$BACKUP"
grep -Fq 'BACKGROUND_JOBS_RESUME=1' "$BACKUP"
grep -Fq 'resume_background_jobs || cleanup_failed=1' "$BACKUP"
grep -Fq 'quiesce_background_jobs' "$ROOT/privileged/nextcloud-pi-bundle-installer"
! grep -Fq 'systemctl stop "$BACKGROUND_JOBS_SERVICE"' "$ROOT/privileged/nextcloud-pi-bundle-installer"

# A failed remote pause may already have stopped the timer. The runtime backup
# cleanup must therefore know to resume it before the pause command returns.
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
awk '/^pause_background_jobs\(\)/,/^resume_background_jobs\(\)/ { if (!/^resume_background_jobs\(\)/) print }' "$BACKUP" >"$TEST_DIR/pause.sh"
source "$TEST_DIR/pause.sh"
remote() {
  case "$1" in
    *'background-jobs state') printf 'timer_active\tyes\n' ;;
    *'background-jobs pause') return 1 ;;
    *) return 1 ;;
  esac
}
die() { return 1; }
BACKGROUND_JOBS_RESUME=0
if pause_background_jobs; then
  printf 'expected failed background-job pause\n' >&2
  exit 1
fi
[[ "$BACKGROUND_JOBS_RESUME" == 1 ]]

# Installer quiescence stops future ticks and waits for the current oneshot;
# it does not terminate the supervising service while Docker may retain PHP.
awk '/^quiesce_background_jobs\(\)/,/^snapshot\(\)/ { if (!/^snapshot\(\)/) print }' "$ROOT/privileged/nextcloud-pi-bundle-installer" >"$TEST_DIR/quiesce.sh"
source "$TEST_DIR/quiesce.sh"
printf '%s\n' activating >"$TEST_DIR/background-state"
printf '%s\n' 0 >"$TEST_DIR/status-queries"
printf '%s\n' 0 >"$TEST_DIR/waits"
touch "$TEST_DIR/transition-to-inactive"
systemctl() {
  case "$1:$2" in
    stop:nextcloud-background-jobs.timer) return 0 ;;
    is-active:nextcloud-background-jobs.service)
      background_state="$(<"$TEST_DIR/background-state")"
      status_queries="$(<"$TEST_DIR/status-queries")"
      printf '%s\n' "$((status_queries + 1))" >"$TEST_DIR/status-queries"
      printf '%s\n' "$background_state"
      if [[ -e "$TEST_DIR/transition-to-inactive" ]]; then
        rm -f -- "$TEST_DIR/transition-to-inactive"
        printf '%s\n' inactive >"$TEST_DIR/background-state"
      fi
      ;;
    *) return 1 ;;
  esac
}
sleep() {
  waits="$(<"$TEST_DIR/waits")"
  printf '%s\n' "$((waits + 1))" >"$TEST_DIR/waits"
}
BACKGROUND_JOBS_SERVICE=nextcloud-background-jobs.service
BACKGROUND_JOBS_TIMER=nextcloud-background-jobs.timer
quiesce_background_jobs
[[ "$(<"$TEST_DIR/background-state")" == inactive ]]
[[ "$(<"$TEST_DIR/status-queries")" == 2 ]]
[[ "$(<"$TEST_DIR/waits")" == 1 ]]

# A oneshot that never completes must fail after the bounded wait rather than
# being treated as quiescent.
printf '%s\n' active >"$TEST_DIR/background-state"
printf '%s\n' 0 >"$TEST_DIR/status-queries"
printf '%s\n' 0 >"$TEST_DIR/waits"
if quiesce_background_jobs; then
  printf 'expected persistent background job to prevent quiescence\n' >&2
  exit 1
fi
[[ "$(<"$TEST_DIR/status-queries")" == 300 ]]
[[ "$(<"$TEST_DIR/waits")" == 300 ]]
printf 'background-job scheduling contracts passed\n'
