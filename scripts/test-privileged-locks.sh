#!/usr/bin/env bash
# Guarded GitHub-Actions-only test for root lock-file ownership and symlink
# protections; portable environments skip the privileged fixture.
set -euo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HELPER="$ROOT/privileged/nextcloud-pi-ops"
readonly INSTALLER="$ROOT/privileged/nextcloud-pi-bundle-installer"

grep -Fq 'readonly LOCK_ROOT=/run/nextcloud-pi-locks' "$HELPER"
grep -Fq 'readonly LOCK_ROOT=/run/nextcloud-pi-locks' "$INSTALLER"
! grep -Fq 'exec 9>"$LOCK"' "$HELPER"
! grep -Fq 'exec 9>"$INSTALL_LOCK"' "$INSTALLER"

if [[ "${GITHUB_ACTIONS:-}" != true || "$(uname -s)" != Linux ]]; then
  printf 'privileged lock behavior tests passed (Linux integration skipped)\n'
  exit 0
fi

sudo -n true
TEST_DIR="$(mktemp -d)"
cleanup() { local status=$?; trap - EXIT HUP INT TERM; sudo rm -rf -- "$TEST_DIR"; exit "$status"; }
trap cleanup EXIT HUP INT TERM
LOCK_ROOT="$TEST_DIR/run/nextcloud-pi-locks"
VICTIM="$TEST_DIR/victim"
mkdir -m 0777 "$TEST_DIR/run"
printf 'must-not-change\n' >"$VICTIM"

awk '/^state_dir\(\)/ { exit } { print }' "$HELPER" | sed "s|/run/nextcloud-pi-locks|$LOCK_ROOT|g" >"$TEST_DIR/helper-lock"
printf '\nlock\n' >>"$TEST_DIR/helper-lock"
sed "s|/run/nextcloud-pi-locks|$LOCK_ROOT|g" "$INSTALLER" >"$TEST_DIR/installer-lock"
chmod 0700 "$TEST_DIR/helper-lock" "$TEST_DIR/installer-lock"

ln -s "$VICTIM" "$LOCK_ROOT"
if sudo bash "$TEST_DIR/helper-lock" >/dev/null 2>"$TEST_DIR/helper-root-link.err"; then
  printf 'helper accepted a symlink lock root\n' >&2
  exit 1
fi
grep -Fq 'lock root is unsafe' "$TEST_DIR/helper-root-link.err"
grep -Fxq 'must-not-change' "$VICTIM"

if sudo bash "$TEST_DIR/installer-lock" invalid >/dev/null 2>"$TEST_DIR/installer-root-link.err"; then
  printf 'installer accepted a symlink lock root\n' >&2
  exit 1
fi
grep -Fq 'lock root is unsafe' "$TEST_DIR/installer-root-link.err"
grep -Fxq 'must-not-change' "$VICTIM"

rm "$LOCK_ROOT"
sudo install -d -m 0700 -o root -g root "$LOCK_ROOT"
sudo ln -s "$VICTIM" "$LOCK_ROOT/operations.lock"
if sudo bash "$TEST_DIR/helper-lock" >/dev/null 2>"$TEST_DIR/helper-file-link.err"; then
  printf 'helper accepted a symlink lock file\n' >&2
  exit 1
fi
grep -Fq 'protected file is unsafe' "$TEST_DIR/helper-file-link.err"
grep -Fxq 'must-not-change' "$VICTIM"

if sudo bash "$TEST_DIR/installer-lock" invalid >/dev/null 2>"$TEST_DIR/installer-file-link.err"; then
  printf 'installer accepted a symlink lock file\n' >&2
  exit 1
fi
grep -Fq 'lock is unsafe' "$TEST_DIR/installer-file-link.err"
grep -Fxq 'must-not-change' "$VICTIM"

sudo rm "$LOCK_ROOT/operations.lock"
sudo bash "$TEST_DIR/helper-lock"
[[ "$(sudo stat -c '%U:%G:%a' "$LOCK_ROOT")" == root:root:700 ]]
[[ "$(sudo stat -c '%U:%G:%a' "$LOCK_ROOT/operations.lock")" == root:root:600 ]]
grep -Fxq 'must-not-change' "$VICTIM"
printf 'privileged lock behavior tests passed\n'
