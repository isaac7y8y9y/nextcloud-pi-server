#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/privileged/nextcloud-pi-bundle-installer"; MANAGER="$ROOT/scripts/manage-pi-privileged-interface.sh"
bash -n "$INSTALLER" "$MANAGER"
grep -Fq 'visudo -cf' "$INSTALLER"; grep -Fq 'sudo -u "$user" sudo -n /usr/local/libexec/nextcloud-pi-ops check' "$INSTALLER"
grep -Fq 'rollback_install' "$INSTALLER"; grep -Fq 'nextcloud-pi-bundle-installer' "$MANAGER"
grep -Fq 'readonly LOCK_ROOT=/run/nextcloud-pi-locks' "$INSTALLER"
grep -Fq 'exec 9>>"$INSTALL_LOCK"' "$INSTALLER"
grep -Fq 'require_no_lifecycles' "$INSTALLER"
grep -Fq 'image-readiness daemon is still running' "$INSTALLER"
! grep -Fq '/run/lock/nextcloud-pi-' "$INSTALLER"

if [[ "${GITHUB_ACTIONS:-}" == true && "$(uname -s)" == Linux ]]; then
  sudo -n true
  TEST_DIR="$(mktemp -d)"
  PACKAGE_ROOT="$(mktemp -d)"
  readiness_pid=""
  cleanup() { local status=$?; trap - EXIT HUP INT TERM; [[ -z "$readiness_pid" ]] || { kill "$readiness_pid" 2>/dev/null || true; wait "$readiness_pid" 2>/dev/null || true; }; sudo rm -rf -- "$TEST_DIR"; rm -rf -- "$PACKAGE_ROOT"; exit "$status"; }
  trap cleanup EXIT HUP INT TERM
  TEST_USER="$(id -un)"; TEST_GID="$(id -g)"; TEST_HOST=test-host
  TEST_UUID=11111111-1111-1111-1111-111111111111
  TEST_MOUNT="$TEST_DIR/mount"; TEST_PROJECT="$TEST_MOUNT/nextcloud-docker"
  TEST_STATE="$TEST_DIR/state"; TEST_LOCK_ROOT="$TEST_DIR/run/locks"; TEST_SOCKET_ROOT="$TEST_DIR/run/sockets"
  TEST_LIVE="$TEST_DIR/live"; TEST_BIN="$TEST_DIR/bin"; TEST_LOG="$TEST_DIR/mv.log"
  LIVE_HELPER="$TEST_LIVE/libexec/nextcloud-pi-ops"
  LIVE_VALIDATOR="$TEST_LIVE/libexec/nextcloud-pi-validate-active-images"
  LIVE_LAUNCHER="$TEST_LIVE/libexec/nextcloud-pi-compose-start"
  LIVE_POLICY="$TEST_LIVE/etc/nextcloud-pi/privileged-policy.conf"
  LIVE_MANIFEST="$TEST_LIVE/etc/nextcloud-pi/bundle-manifest.tsv"
  LIVE_UNIT="$TEST_LIVE/systemd/nextcloud.service"
  LIVE_DROPIN="$TEST_LIVE/systemd/docker.service.d/nextcloud-storage.conf"
  LIVE_SUDOERS="$TEST_LIVE/sudoers/nextcloud-pi-automation"
  mkdir -p "$TEST_BIN" "$TEST_MOUNT" "$TEST_PROJECT"

  sed \
    -e "s|export PATH=/usr/sbin:/usr/bin:/sbin:/bin|export PATH=$TEST_BIN:/usr/sbin:/usr/bin:/sbin:/bin|" \
    -e "s|/var/lib/nextcloud-pi-ops|$TEST_STATE|g" \
    -e "s|/run/nextcloud-pi-locks|$TEST_LOCK_ROOT|g" \
    -e "s|/run/nextcloud-pi-ops|$TEST_SOCKET_ROOT|g" \
    -e "s|/usr/local/libexec/nextcloud-pi-ops|$LIVE_HELPER|g" \
    -e "s|/usr/local/libexec/nextcloud-pi-validate-active-images|$LIVE_VALIDATOR|g" \
    -e "s|/usr/local/libexec/nextcloud-pi-compose-start|$LIVE_LAUNCHER|g" \
    -e "s|/etc/nextcloud-pi/privileged-policy.conf|$LIVE_POLICY|g" \
    -e "s|/etc/nextcloud-pi/bundle-manifest.tsv|$LIVE_MANIFEST|g" \
    -e "s|/etc/systemd/system/docker.service.d/nextcloud-storage.conf|$LIVE_DROPIN|g" \
    -e "s|/etc/systemd/system/nextcloud.service|$LIVE_UNIT|g" \
    -e "s|/etc/systemd/system|$TEST_LIVE/systemd|g" \
    -e "s|/etc/sudoers.d/nextcloud-pi-automation|$LIVE_SUDOERS|g" \
    "$INSTALLER" >"$TEST_DIR/installer"
  chmod 0700 "$TEST_DIR/installer"

  cat >"$TEST_BIN/hostname" <<EOF
#!/bin/bash
printf '%s\n' '$TEST_HOST'
EOF
  cat >"$TEST_BIN/findmnt" <<EOF
#!/bin/bash
case "\${*: -1}" in TARGET) printf '%s\n' '$TEST_MOUNT' ;; FSTYPE) printf 'ext4\n' ;; UUID) printf '%s\n' '$TEST_UUID' ;; *) exit 2 ;; esac
EOF
  cat >"$TEST_BIN/visudo" <<'EOF'
#!/bin/bash
case "${TEST_VISUDO_FAILURE:-}:${1:-}" in
  candidate:-cf) exit 1 ;;
  final:-c)
    if [[ ! -e "$TEST_VISUDO_MARKER" ]]; then
      : >"$TEST_VISUDO_MARKER"
      exit 1
    fi
    ;;
esac
exit 0
EOF
  cat >"$TEST_BIN/systemd-analyze" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat >"$TEST_BIN/systemctl" <<'EOF'
#!/bin/bash
if [[ "${TEST_INTERRUPT_ON_RELOAD:-}" == 1 && ! -e "$TEST_INTERRUPT_MARKER" ]]; then
  : >"$TEST_INTERRUPT_MARKER"
  kill -TERM "$PPID"
fi
exit 0
EOF
  cat >"$TEST_BIN/sudo" <<'EOF'
#!/bin/bash
set -e
if [[ "${1:-}" == -u ]]; then export SUDO_USER="$2"; shift 2; fi
if [[ "${1:-}" == sudo ]]; then shift; fi
[[ "${1:-}" != -n ]] || shift
exec "$@"
EOF
  cat >"$TEST_BIN/mv" <<'EOF'
#!/bin/bash
printf '%s\n' "${@: -1}" >>"$TEST_MV_LOG"
exec /bin/mv "$@"
EOF
  chmod 0755 "$TEST_BIN"/*

  package() {
    local directory="$1" helper_result="$2" version="${3:-1}" logical source installed mode
    mkdir -p "$directory/files"
    cat >"$directory/files/privileged-helper" <<EOF
#!/bin/bash
[[ "\${SUDO_USER:-}" == '$TEST_USER' ]] || exit 1
[[ "\${1:-}" == check ]] || exit 2
exit $helper_result
EOF
    printf '#!/bin/bash\nexit 0\n' >"$directory/files/active-image-validator"
    printf '#!/bin/bash\nexit 0\n' >"$directory/files/compose-launcher"
    printf '[Unit]\n[Service]\nType=oneshot\nExecStart=%s\n' "$LIVE_LAUNCHER" >"$directory/files/nextcloud-unit"
    printf '[Service]\nRequiresMountsFor=%s\n' "$TEST_MOUNT" >"$directory/files/docker-storage-drop-in"
    chmod 0700 "$directory/files/privileged-helper" "$directory/files/active-image-validator" "$directory/files/compose-launcher"
    chmod 0644 "$directory/files/nextcloud-unit" "$directory/files/docker-storage-drop-in"
    cat >"$directory/privileged-policy.conf" <<EOF
NEXTCLOUD_PI_POLICY_FORMAT=nextcloud-pi-privileged-policy-v1
NEXTCLOUD_PI_BUNDLE_VERSION=1
NEXTCLOUD_PI_DEPLOYMENT_USER=$TEST_USER
NEXTCLOUD_PI_SYSTEM_HOSTNAME=$TEST_HOST
NEXTCLOUD_PI_PROJECT_DIR=$TEST_PROJECT
NEXTCLOUD_PI_STORAGE_MOUNT=$TEST_MOUNT
NEXTCLOUD_PI_STORAGE_TYPE=ext4
NEXTCLOUD_PI_STORAGE_UUID=$TEST_UUID
NEXTCLOUD_PI_IMAGE_PLATFORM=linux/arm64/v8
NEXTCLOUD_PI_SERVICE_NAME=nextcloud.service
NEXTCLOUD_PI_APP_CONTAINER=nextcloud-docker-app-1
NEXTCLOUD_PI_DB_CONTAINER=nextcloud-docker-db-1
NEXTCLOUD_PI_CADDY_CONTAINER=nextcloud-docker-caddy-1
NEXTCLOUD_PI_CADDY_DATA_VOLUME=nextcloud-docker_caddy_data
NEXTCLOUD_PI_CADDY_CONFIG_VOLUME=nextcloud-docker_caddy_config
NEXTCLOUD_PI_STATE_ROOT=$TEST_STATE
NEXTCLOUD_PI_SOCKET_ROOT=$TEST_SOCKET_ROOT
NEXTCLOUD_PI_RUNTIME_RECOVERY_PREFIX=.runtime-
NEXTCLOUD_PI_IMAGE_READINESS_PREFIX=.readiness-
NEXTCLOUD_PI_MAX_STAGING_BYTES=1048576
EOF
    printf '%s ALL=(root) NOPASSWD: %s\n' "$TEST_USER" "$LIVE_HELPER" >"$directory/nextcloud-pi-automation.sudoers"
    cp "$TEST_DIR/installer" "$directory/nextcloud-pi-bundle-installer"
    {
      printf 'format\tnextcloud-pi-bundle-manifest-v1\nversion\t%s\n' "$version"
      for logical in privileged-helper active-image-validator compose-launcher nextcloud-unit docker-storage-drop-in; do
        case "$logical" in
          privileged-helper) installed="$LIVE_HELPER"; mode=0700 ;;
          active-image-validator) installed="$LIVE_VALIDATOR"; mode=0700 ;;
          compose-launcher) installed="$LIVE_LAUNCHER"; mode=0700 ;;
          nextcloud-unit) installed="$LIVE_UNIT"; mode=0644 ;;
          docker-storage-drop-in) installed="$LIVE_DROPIN"; mode=0644 ;;
        esac
        printf 'file\t%s\ttest\t%s\t%s\t%s\n' "$logical" "$installed" "$mode" "$(sha256sum "$directory/files/$logical" | awk '{print $1}')"
      done
    } >"$directory/bundle-manifest.tsv"
    {
      printf 'format\tnextcloud-pi-package-manifest-v1\n'
      for source in bundle-manifest.tsv privileged-policy.conf nextcloud-pi-automation.sudoers nextcloud-pi-bundle-installer; do
        printf 'file\t%s\t%s\n' "$source" "$(sha256sum "$directory/$source" | awk '{print $1}')"
      done
    } >"$directory/package-manifest.tsv"
    chmod 0600 "$directory"/*.tsv "$directory/privileged-policy.conf" "$directory/nextcloud-pi-automation.sudoers"
  }
  run_install() {
    local directory="$1" id="$2" expected
    expected="$(sha256sum "$directory/package-manifest.tsv" | awk '{print $1}')"
    sudo env TEST_MV_LOG="$TEST_LOG" PATH="$TEST_BIN:/usr/sbin:/usr/bin:/sbin:/bin" bash "$TEST_DIR/installer" install "$directory" "$id" "$expected" "$TEST_USER" "$TEST_HOST" "$TEST_MOUNT" "$TEST_UUID" linux/arm64/v8 "$TEST_PROJECT"
  }
  expect_install_failure() {
    local directory="$1" id="$2" failure_name="$3" failure_value="$4" expected before
    expected="$(sha256sum "$directory/package-manifest.tsv" | awk '{print $1}')"; before="$(sudo sha256sum "$LIVE_HELPER")"
    if sudo env TEST_MV_LOG="$TEST_LOG" "$failure_name=$failure_value" TEST_INTERRUPT_MARKER="$TEST_DIR/interrupted" TEST_VISUDO_MARKER="$TEST_DIR/visudo-failed" PATH="$TEST_BIN:/usr/sbin:/usr/bin:/sbin:/bin" bash "$TEST_DIR/installer" install "$directory" "$id" "$expected" "$TEST_USER" "$TEST_HOST" "$TEST_MOUNT" "$TEST_UUID" linux/arm64/v8 "$TEST_PROJECT" >/dev/null 2>&1; then
      printf 'installer fault injection unexpectedly succeeded: %s\n' "$failure_name" >&2
      exit 1
    fi
    [[ "$(sudo sha256sum "$LIVE_HELPER")" == "$before" ]]
  }

  package "$PACKAGE_ROOT/v1" 0
  : >"$TEST_LOG"
  run_install "$PACKAGE_ROOT/v1" 20260910T000000Z-1 >/dev/null
  sudo test -x "$LIVE_HELPER"; sudo test -f "$LIVE_SUDOERS"
  grep -Fxq "$LIVE_SUDOERS" "$TEST_LOG"

  package "$PACKAGE_ROOT/v2" 0
  printf '# v2\n' >>"$PACKAGE_ROOT/v2/files/privileged-helper"
  helper_hash="$(sha256sum "$PACKAGE_ROOT/v2/files/privileged-helper" | awk '{print $1}')"
  sed -i "s|\(file[[:space:]]privileged-helper[[:space:]].*[[:space:]]\)[0-9a-f]\{64\}$|\1$helper_hash|" "$PACKAGE_ROOT/v2/bundle-manifest.tsv"
  for source in bundle-manifest.tsv; do
    source_hash="$(sha256sum "$PACKAGE_ROOT/v2/$source" | awk '{print $1}')"
    sed -i "s|\(file[[:space:]]$source[[:space:]]\)[0-9a-f]\{64\}$|\1$source_hash|" "$PACKAGE_ROOT/v2/package-manifest.tsv"
  done
  run_install "$PACKAGE_ROOT/v2" 20260910T000000Z-2 >/dev/null
  sudo grep -Fxq '# v2' "$LIVE_HELPER"
  sudo env TEST_MV_LOG="$TEST_LOG" PATH="$TEST_BIN:/usr/sbin:/usr/bin:/sbin:/bin" bash "$TEST_DIR/installer" rollback 20260910T000000Z-2 >/dev/null
  ! sudo grep -Fq '# v2' "$LIVE_HELPER"

  package "$PACKAGE_ROOT/candidate-failure" 0
  expect_install_failure "$PACKAGE_ROOT/candidate-failure" 20260910T000000Z-3 TEST_VISUDO_FAILURE candidate
  package "$PACKAGE_ROOT/final-failure" 0
  rm -f "$TEST_DIR/visudo-failed"
  expect_install_failure "$PACKAGE_ROOT/final-failure" 20260910T000000Z-4 TEST_VISUDO_FAILURE final
  package "$PACKAGE_ROOT/helper-failure" 1
  expect_install_failure "$PACKAGE_ROOT/helper-failure" 20260910T000000Z-5 TEST_UNUSED 1
  package "$PACKAGE_ROOT/interruption" 0
  rm -f "$TEST_DIR/interrupted"
  expect_install_failure "$PACKAGE_ROOT/interruption" 20260910T000000Z-6 TEST_INTERRUPT_ON_RELOAD 1
  package "$PACKAGE_ROOT/version-mismatch" 0 2
  expect_install_failure "$PACKAGE_ROOT/version-mismatch" 20260910T000000Z-7 TEST_UNUSED 1

  sudo env TEST_MV_LOG="$TEST_LOG" PATH="$TEST_BIN:/usr/sbin:/usr/bin:/sbin:/bin" bash "$TEST_DIR/installer" revoke >/dev/null
  sudo test ! -e "$LIVE_SUDOERS"
  if sudo env TEST_MV_LOG="$TEST_LOG" PATH="$TEST_BIN:/usr/sbin:/usr/bin:/sbin:/bin" bash "$TEST_DIR/installer" remove >/dev/null 2>&1; then
    printf 'installer removed a service-referenced bundle\n' >&2; exit 1
  fi
  printf '[Unit]\n[Service]\nType=oneshot\nExecStart=/usr/bin/true\n' >"$TEST_DIR/migrated.service"
  sudo install -m 0644 -o root -g root "$TEST_DIR/migrated.service" "$LIVE_UNIT"

  expect_remove_failure() {
    local label="$1"
    if sudo env TEST_MV_LOG="$TEST_LOG" PATH="$TEST_BIN:/usr/sbin:/usr/bin:/sbin:/bin" bash "$TEST_DIR/installer" remove >/dev/null 2>&1; then
      printf 'installer removed a bundle with %s\n' "$label" >&2
      exit 1
    fi
  }

  sudo install -m 0600 -o root -g root /dev/null "$TEST_STATE/active-record-current"
  expect_remove_failure 'an unresolved active-record transaction'
  sudo rm -- "$TEST_STATE/active-record-current"

  sudo install -d -m 0700 -o root -g root "$TEST_STATE/active-record"
  sudo install -d -m 0700 -o root -g root "$TEST_STATE/active-record/20260910T000000Z-8"
  expect_remove_failure 'active-record state'
  sudo rm -rf -- "$TEST_STATE/active-record/20260910T000000Z-8"

  sudo install -d -m 0700 -o root -g root "$TEST_STATE/runtime-recovery"
  sudo install -d -m 0700 -o root -g root "$TEST_STATE/runtime-recovery/20260910T000000Z-8"
  expect_remove_failure 'runtime-recovery state'
  sudo rm -rf -- "$TEST_STATE/runtime-recovery/20260910T000000Z-8"

  sudo install -d -m 0700 -o root -g root "$TEST_STATE/image-readiness"
  sudo install -d -m 0700 -o root -g root "$TEST_STATE/image-readiness/20260910T000000Z-8"
  expect_remove_failure 'image-readiness state'
  sudo rm -rf -- "$TEST_STATE/image-readiness/20260910T000000Z-8"

  sudo install -d -m 0710 -o root -g "$TEST_GID" "$TEST_SOCKET_ROOT"
  sudo install -m 0600 -o root -g root /dev/null "$TEST_SOCKET_ROOT/image-readiness-20260910T000000Z-8.sock"
  expect_remove_failure 'an image-readiness socket'
  sudo rm -- "$TEST_SOCKET_ROOT/image-readiness-20260910T000000Z-8.sock"

  sudo install -d -m 0700 -o root -g root "$TEST_MOUNT/.runtime-20260910T000000Z-8"
  expect_remove_failure 'runtime-recovery storage'
  sudo rm -rf -- "$TEST_MOUNT/.runtime-20260910T000000Z-8"

  sudo install -d -m 0700 -o root -g root "$TEST_MOUNT/.readiness-20260910T000000Z-8"
  expect_remove_failure 'image-readiness storage'
  sudo rm -rf -- "$TEST_MOUNT/.readiness-20260910T000000Z-8"

  sudo install -m 0600 -o root -g root /dev/null "$TEST_LIVE/systemd/nextcloud-pi-drill-20260910T000000Z-8.service"
  expect_remove_failure 'deployment-drill state'
  sudo rm -- "$TEST_LIVE/systemd/nextcloud-pi-drill-20260910T000000Z-8.service"

  cat >"$TEST_BIN/hold-image-readiness" <<'EOF'
#!/bin/bash
while :; do /bin/sleep 1; done
EOF
  chmod 0755 "$TEST_BIN/hold-image-readiness"
  "$TEST_BIN/hold-image-readiness" "--host=unix://$TEST_SOCKET_ROOT/image-readiness-20260910T000000Z-8.sock" &
  readiness_pid=$!
  expect_remove_failure 'a running image-readiness daemon'
  kill "$readiness_pid"
  wait "$readiness_pid" 2>/dev/null || true
  readiness_pid=""

  sudo env TEST_MV_LOG="$TEST_LOG" PATH="$TEST_BIN:/usr/sbin:/usr/bin:/sbin:/bin" bash "$TEST_DIR/installer" remove >/dev/null
  for installed in "$LIVE_HELPER" "$LIVE_VALIDATOR" "$LIVE_LAUNCHER" "$LIVE_POLICY" "$LIVE_MANIFEST" "$LIVE_UNIT" "$LIVE_DROPIN" "$LIVE_SUDOERS"; do sudo test ! -e "$installed"; done
fi
printf 'privileged installer lifecycle tests passed\n'
