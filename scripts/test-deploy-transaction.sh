#!/usr/bin/env bash
set -euo pipefail

# Exercise deployment safety without touching Nextcloud configuration, Docker,
# images, volumes, mounts, data, or the Pi-only credential file.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
load_deployment_config "$REPOSITORY_ROOT"
readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
MODE="${1:-}"

usage() { printf 'Usage: %s --check | --apply\n' "$0" >&2; }
die() { printf 'Deployment transaction drill failed: %s\n' "$1" >&2; exit 1; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"; }

case "$MODE" in
  --check|--apply) [[ $# -eq 1 ]] || { usage; exit 2; } ;;
  *) usage; exit 2 ;;
esac

remote "test \"\$(hostname)\" = '$NEXTCLOUD_PI_SYSTEM_HOSTNAME' && test \"\$(id -un)\" = '$NEXTCLOUD_PI_USER' && findmnt -rn --target '$NEXTCLOUD_STORAGE_MOUNT' >/dev/null && sudo -n true && command -v bash >/dev/null && command -v systemctl >/dev/null && command -v systemd-analyze >/dev/null" || die "Pi identity, mount, passwordless sudo, Bash, or systemd prerequisites failed"
if [[ "$MODE" == "--check" ]]; then
  printf 'CHECK: disposable deployment transaction drill prerequisites passed; no changes were made.\n'
  exit 0
fi

drill_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
printf 'Deployment transaction drill ID: %s\n' "$drill_id"
helper_path="/tmp/nextcloud-atomic-transaction-$drill_id.sh"
scp -q "$SCRIPT_DIR/lib/atomic-transaction.sh" "$REMOTE:$helper_path"
cleanup_helper() { remote "rm -f '$helper_path'" >/dev/null 2>&1 || true; }
trap cleanup_helper EXIT HUP INT TERM

if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" bash -s -- "$drill_id" "$NEXTCLOUD_STORAGE_MOUNT" "$helper_path" <<'REMOTE_SCRIPT'
set -eu
drill_id="$1"
storage_mount="$2"
helper_path="$3"
case "$drill_id" in *[!0-9TZ-]*|'') exit 2 ;; esac
case "$storage_mount" in /*) ;; *) exit 2 ;; esac
root="/tmp/nextcloud-deploy-drill-$drill_id"
marker="$root/marker"
privileged_root="$root/root-owned"
privileged_target="$privileged_root/target"
service_unit="nextcloud-deploy-drill-docker-$drill_id.service"
mountpoint="$root/missing-mount"
mount_unit="$(systemd-escape --path --suffix=mount "$mountpoint")"
mount_path="/etc/systemd/system/$mount_unit"
service_path="/etc/systemd/system/$service_unit"
cleanup() {
  sudo -n rm -f "$mount_path" "$service_path" || true
  sudo -n systemctl daemon-reload || true
  sudo -n rm -f "$privileged_target" "$privileged_root"/.nextcloud-pi-target.*.replace || true
  sudo -n rmdir "$privileged_root" || true
  rm -rf "$root" || true
  rm -f "$helper_path" || true
}
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
test ! -e "$root"
umask 077
mkdir -m 700 "$root"
. "$helper_path"
printf 'original\n' >"$root/target"
printf 'candidate\n' >"$root/candidate"
cp "$root/target" "$root/backup"
uid="$(id -u)"
gid="$(id -g)"
sudo -n install -d -m 0755 -o root -g root "$privileged_root"
sudo -n install -m 0600 -o "$uid" -g "$gid" "$root/target" "$privileged_target"
printf 'format\tdeploy-drill-approval-v1\nstate\tunused\nactions\tdisposable-replace,rollback,mount-gate\n' >"$root/approval.tsv"
consume_approval() {
  mkdir "$root/approval.tsv.lock" 2>/dev/null || return 1
  if ! awk -F '\t' '$1 == "state" && $2 == "unused" { count++ } END { exit count == 1 ? 0 : 1 }' "$root/approval.tsv" || ! sed 's/^state\tunused$/state\tconsumed/' "$root/approval.tsv" >"$root/approval.tsv.consumed"; then
    rm -f "$root/approval.tsv.consumed"; rmdir "$root/approval.tsv.lock" || true; return 1
  fi
  mv "$root/approval.tsv.consumed" "$root/approval.tsv"
  rmdir "$root/approval.tsv.lock"
}
consume_approval
grep -Fx 'state	consumed' "$root/approval.tsv"
if consume_approval; then exit 1; fi
rollback_target() { install -m 0600 "$root/backup" "$root/target.new"; mv -f "$root/target.new" "$root/target"; }
install -m 0600 "$root/candidate" "$root/target.new"
mv -f "$root/target.new" "$root/target"
if ! false; then rollback_target; fi
cmp -s "$root/target" "$root/backup"
atomic_replace_preserve "$root/candidate" "$privileged_target" 0600
cmp -s "$privileged_target" "$root/candidate"
test "$(stat -c '%u:%g:%a' "$privileged_target")" = "$uid:$gid:600"
atomic_replace_preserve "$root/backup" "$privileged_target" 0600
cmp -s "$privileged_target" "$root/backup"
mkdir "$mountpoint"
cat >"$root/missing-mount.mount" <<EOF
[Unit]
Description=Disposable failing mount dependency for Nextcloud deployment drill
[Mount]
What=/dev/null
Where=$mountpoint
Type=none
Options=bind
EOF
cat >"$root/docker.service" <<EOF
[Unit]
Description=Disposable Docker-like mount-gate drill service
Requires=$mount_unit
After=$mount_unit
RequiresMountsFor=$mountpoint
[Service]
Type=oneshot
ExecStart=/usr/bin/touch $marker
EOF
sudo -n install -m 0644 "$root/missing-mount.mount" "$mount_path"
sudo -n install -m 0644 "$root/docker.service" "$service_path"
sudo -n systemd-analyze verify "$service_path"
sudo -n systemctl daemon-reload
if sudo -n systemctl start "$service_unit"; then exit 1; fi
test ! -e "$marker"
printf 'CHECK: forced mid-apply rollback restored its disposable target\n'
printf 'CHECK: privileged atomic replacement preserved ownership and rollback under a root-owned parent\n'
printf 'CHECK: consumed disposable approval cannot be replayed\n'
printf 'CHECK: mount-gated Docker-like service did not run its marker after missing mount failure\n'
REMOTE_SCRIPT
then
  die "disposable remote transaction failed; cleanup was attempted"
fi
cleanup_helper
trap - EXIT HUP INT TERM
printf 'Deployment transaction drill passed; all disposable Pi targets were removed.\n'
