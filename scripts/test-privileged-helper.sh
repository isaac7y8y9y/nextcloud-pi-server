#!/usr/bin/env bash
set -euo pipefail
readonly HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/privileged/nextcloud-pi-ops"
bash -n "$HELPER"
for command in cmd_recovery_check cmd_active_prepare cmd_readiness_start cmd_drill_apply; do grep -Fq "$command" "$HELPER"; done
grep -Fq 'valid_id' "$HELPER"; grep -Fq 'reject_stdin' "$HELPER"; grep -Fq 'active-record-current' "$HELPER"; grep -Fq 'no_nested_mounts' "$HELPER"
! grep -Fq 'eval ' "$HELPER"
python3 - "$HELPER" <<'PY'
import io
import pathlib
import sys
import tarfile
import tempfile

helper = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
prefix = "validate_archive() { /usr/bin/python3 - \"$1\" <<'PY'\n"
validator = helper.split(prefix, 1)[1].split("\nPY\n}", 1)[0]
with tempfile.TemporaryDirectory() as directory:
    safe = pathlib.Path(directory, "caddy.tar")
    with tarfile.open(safe, "w") as archive:
        root = tarfile.TarInfo("./")
        root.type = tarfile.DIRTYPE
        archive.addfile(root)
    sys.argv = ["validate_archive", str(safe)]
    exec(compile(validator, "validate_archive", "exec"), {"__name__": "__main__"})
    unsafe = pathlib.Path(directory, "unsafe.tar")
    with tarfile.open(unsafe, "w") as archive:
        payload = b"bad"
        member = tarfile.TarInfo("/escape")
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
    sys.argv = ["validate_archive", str(unsafe)]
    try:
        exec(compile(validator, "validate_archive", "exec"), {"__name__": "__main__"})
    except SystemExit:
        pass
    else:
        raise SystemExit("unsafe archive was accepted")
    unsafe_root = pathlib.Path(directory, "unsafe-root.tar")
    with tarfile.open(unsafe_root, "w") as archive:
        root = tarfile.TarInfo("./")
        root.type = tarfile.DIRTYPE
        root.mode = 0o777
        archive.addfile(root)
    sys.argv = ["validate_archive", str(unsafe_root)]
    try:
        exec(compile(validator, "validate_archive", "exec"), {"__name__": "__main__"})
    except SystemExit:
        pass
    else:
        raise SystemExit("unsafe archive root was accepted")
PY

# Run the installed dispatcher itself in an isolated root-owned fixture on the
# ephemeral Linux runner. The production locations stay untouched; this covers
# the policy/manifest/caller gate and real command/argument/stdin denials.
if [[ "${GITHUB_ACTIONS:-}" == true && "$(uname -s)" == Linux ]]; then
  sudo -n true
  FIXTURE="$(sudo mktemp -d /root/nextcloud-pi-ops-test.XXXXXX)"
  SOURCE_DIR="$(mktemp -d)"
  cleanup_fixture() { local status=$?; trap - EXIT HUP INT TERM; sudo rm -rf -- "$FIXTURE"; rm -rf -- "$SOURCE_DIR"; exit "$status"; }
  trap cleanup_fixture EXIT HUP INT TERM
  sed -e "s|/etc/nextcloud-pi/privileged-policy.conf|$FIXTURE/policy|g" -e "s|/etc/nextcloud-pi/bundle-manifest.tsv|$FIXTURE/manifest|g" -e "s|/usr/local/libexec/nextcloud-pi-ops|$FIXTURE/ops|g" -e "s|/usr/local/libexec/nextcloud-pi-validate-active-images|$FIXTURE/validator|g" -e "s|/etc/nextcloud-pi/active-images.env|$FIXTURE/active-images.env|g" -e "s|/run/lock/nextcloud-pi-ops.lock|$FIXTURE/lock|g" -e "s|/var/lib/nextcloud-pi-ops|$FIXTURE/state|g" -e "s|/run/nextcloud-pi-ops|$FIXTURE/socket|g" "$HELPER" >"$SOURCE_DIR/ops"
  printf '#!/bin/sh\nexit 0\n' >"$SOURCE_DIR/validator"
  printf '#!/bin/sh\nexit 0\n' >"$SOURCE_DIR/launcher"
  printf 'unit\n' >"$SOURCE_DIR/unit"
  printf 'dropin\n' >"$SOURCE_DIR/dropin"
  sudo install -d -m 0700 -o root -g root "$FIXTURE/state" "$FIXTURE/mount/nextcloud-docker"
  sudo install -m 0700 -o root -g root "$SOURCE_DIR/ops" "$FIXTURE/ops"
  sudo install -m 0700 -o root -g root "$SOURCE_DIR/validator" "$FIXTURE/validator"
  sudo install -m 0700 -o root -g root "$SOURCE_DIR/launcher" "$FIXTURE/launcher"
  sudo install -m 0644 -o root -g root "$SOURCE_DIR/unit" "$FIXTURE/unit"
  sudo install -m 0644 -o root -g root "$SOURCE_DIR/dropin" "$FIXTURE/dropin"
  cat >"$SOURCE_DIR/policy" <<EOF
NEXTCLOUD_PI_POLICY_FORMAT=nextcloud-pi-privileged-policy-v1
NEXTCLOUD_PI_BUNDLE_VERSION=1
NEXTCLOUD_PI_DEPLOYMENT_USER=$(id -un)
NEXTCLOUD_PI_SYSTEM_HOSTNAME=$(hostname)
NEXTCLOUD_PI_PROJECT_DIR=$FIXTURE/mount/nextcloud-docker
NEXTCLOUD_PI_STORAGE_MOUNT=$FIXTURE/mount
NEXTCLOUD_PI_STORAGE_TYPE=ext4
NEXTCLOUD_PI_STORAGE_UUID=11111111-1111-1111-1111-111111111111
NEXTCLOUD_PI_IMAGE_PLATFORM=linux/arm64
NEXTCLOUD_PI_SERVICE_NAME=nextcloud.service
NEXTCLOUD_PI_APP_CONTAINER=nextcloud-docker-app-1
NEXTCLOUD_PI_DB_CONTAINER=nextcloud-docker-db-1
NEXTCLOUD_PI_CADDY_CONTAINER=nextcloud-docker-caddy-1
NEXTCLOUD_PI_CADDY_DATA_VOLUME=nextcloud-docker_caddy_data
NEXTCLOUD_PI_CADDY_CONFIG_VOLUME=nextcloud-docker_caddy_config
NEXTCLOUD_PI_STATE_ROOT=$FIXTURE/state
NEXTCLOUD_PI_SOCKET_ROOT=$FIXTURE/socket
NEXTCLOUD_PI_RUNTIME_RECOVERY_PREFIX=.recovery-
NEXTCLOUD_PI_IMAGE_READINESS_PREFIX=.readiness-
NEXTCLOUD_PI_MAX_STAGING_BYTES=1048576
EOF
  {
    printf 'format\tnextcloud-pi-bundle-manifest-v1\nversion\t1\n'
    for entry in "privileged-helper:$FIXTURE/ops:0700" "active-image-validator:$FIXTURE/validator:0700" "compose-launcher:$FIXTURE/launcher:0700" "nextcloud-unit:$FIXTURE/unit:0644" "docker-storage-drop-in:$FIXTURE/dropin:0644"; do
      logical="${entry%%:*}"; remainder="${entry#*:}"; path="${remainder%:*}"; mode="${entry##*:}"
      printf 'file\t%s\ttest\t%s\t%s\t%s\n' "$logical" "$path" "$mode" "$(sudo sha256sum "$path" | awk '{print $1}')"
    done
  } >"$SOURCE_DIR/manifest"
  sudo install -m 0600 -o root -g root "$SOURCE_DIR/policy" "$FIXTURE/policy"
  sudo install -m 0600 -o root -g root "$SOURCE_DIR/manifest" "$FIXTURE/manifest"
  sudo "$FIXTURE/ops" version | grep -Fx $'version\t1' >/dev/null
  if sudo "$FIXTURE/ops" version extra >/dev/null 2>&1 || printf x | sudo "$FIXTURE/ops" version >/dev/null 2>&1 || sudo /usr/bin/env SUDO_USER=wrong "$FIXTURE/ops" version >/dev/null 2>&1; then
    printf 'dispatcher accepted invalid caller input\n' >&2
    exit 1
  fi
  sudo chmod 0644 "$FIXTURE/policy"
  if sudo "$FIXTURE/ops" version >/dev/null 2>&1; then
    printf 'dispatcher accepted an unsafe policy mode\n' >&2
    exit 1
  fi
fi
printf 'privileged helper contract tests passed\n'
