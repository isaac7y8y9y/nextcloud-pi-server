#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEMPLATE="$ROOT/privileged/nextcloud-pi-automation.sudoers.in"

die() { printf 'privileged sudoers test failed: %s\n' "$1" >&2; exit 1; }

# Never alter a developer machine or an installed Pi bundle. GitHub Actions
# supplies an ephemeral Linux administrator context for this policy test.
if [[ "${GITHUB_ACTIONS:-}" != true || "$(uname -s)" != Linux ]]; then
  grep -Fx 'Defaults:@NEXTCLOUD_PI_USER@ env_reset' "$TEMPLATE" >/dev/null
  grep -Fx 'Defaults:@NEXTCLOUD_PI_USER@ !setenv' "$TEMPLATE" >/dev/null
  grep -Fx '@NEXTCLOUD_PI_USER@ ALL=(root) NOPASSWD: /usr/local/libexec/nextcloud-pi-ops' "$TEMPLATE" >/dev/null
  printf 'privileged sudoers template tests passed (Linux integration skipped)\n'
  exit 0
fi

sudo -n true || die 'CI administrator sudo is unavailable'
readonly TEST_USER="nextcloud-pi-sudo-test-$$"
readonly HELPER=/usr/local/libexec/nextcloud-pi-ops
readonly POLICY=/etc/nextcloud-pi/privileged-policy.conf
readonly MANIFEST=/etc/nextcloud-pi/bundle-manifest.tsv
readonly SUDOERS=/etc/sudoers.d/nextcloud-pi-automation
TMP_DIR="$(mktemp -d)"
readonly RUNNER_SUDOERS=/etc/sudoers.d/runner
RUNNER_SUDOERS_MODE=""

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  sudo rm -f -- "$HELPER" "$POLICY" "$MANIFEST" "$SUDOERS"
  [[ -z "$RUNNER_SUDOERS_MODE" ]] || sudo chmod "$RUNNER_SUDOERS_MODE" "$RUNNER_SUDOERS"
  sudo rmdir --ignore-fail-on-non-empty /etc/nextcloud-pi 2>/dev/null || true
  sudo userdel "$TEST_USER" 2>/dev/null || true
  rm -rf -- "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

for path in "$HELPER" "$POLICY" "$MANIFEST" "$SUDOERS"; do
  sudo test ! -e "$path" && sudo test ! -L "$path" || die "refusing to overwrite existing $path"
done

# ubuntu-latest intentionally ships this runner-specific drop-in with a mode
# visudo rejects. Correct it only for this ephemeral composed-policy check and
# restore its original mode in the trap above.
if sudo test -f "$RUNNER_SUDOERS" && sudo test ! -L "$RUNNER_SUDOERS"; then
  RUNNER_SUDOERS_MODE="$(sudo stat -c '%a' "$RUNNER_SUDOERS")"
  sudo chmod 0440 "$RUNNER_SUDOERS"
fi

sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$TEST_USER"
install -d -m 0700 "$TMP_DIR/bundle"
cat >"$TMP_DIR/bundle/helper" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 1 ] && [ "$1" = check ] || exit 2
printf 'status\tok\n'
EOF
printf 'test policy\n' >"$TMP_DIR/bundle/policy"
printf 'test manifest\n' >"$TMP_DIR/bundle/manifest"
sed "s/@NEXTCLOUD_PI_USER@/$TEST_USER/g" "$TEMPLATE" >"$TMP_DIR/bundle/sudoers"
chmod 0700 "$TMP_DIR/bundle/helper"

sudo install -d -m 0755 -o root -g root /usr/local/libexec /etc/nextcloud-pi
sudo install -m 0700 -o root -g root "$TMP_DIR/bundle/helper" "$HELPER"
sudo install -m 0600 -o root -g root "$TMP_DIR/bundle/policy" "$POLICY"
sudo install -m 0600 -o root -g root "$TMP_DIR/bundle/manifest" "$MANIFEST"
sudo install -m 0440 -o root -g root "$TMP_DIR/bundle/sudoers" "$SUDOERS"
sudo visudo -cf "$SUDOERS" >/dev/null
sudo visudo -c >/dev/null

allowed() { sudo -u "$TEST_USER" -- sudo -n "$@" >/dev/null; }
denied() { if sudo -u "$TEST_USER" -- sudo -n "$@" >/dev/null 2>&1; then die "unexpected sudo authorization: $*"; fi; }

allowed "$HELPER" check
denied "$HELPER"
denied "$HELPER" check extra
denied "$HELPER" --check
denied true
denied /bin/sh -c true
denied /usr/bin/env true
denied /usr/bin/python3 -c 'print(1)'
denied /usr/bin/systemctl status nextcloud.service
denied /usr/bin/tar --version
denied /usr/bin/dockerd --version
denied /usr/local/libexec/nextcloud-pi-validate-active-images
denied /tmp/nextcloud-pi-ops check
for path in "$HELPER" "$POLICY" "$MANIFEST" "$SUDOERS"; do
  sudo -u "$TEST_USER" -- test ! -w "$path"
done

printf 'privileged sudoers Linux integration tests passed\n'
