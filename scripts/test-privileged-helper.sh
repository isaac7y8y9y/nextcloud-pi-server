#!/usr/bin/env bash
set -euo pipefail
readonly HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/privileged/nextcloud-pi-ops"
bash -n "$HELPER"
for command in cmd_recovery_check cmd_active_prepare cmd_readiness_start cmd_drill_apply; do grep -Fq "$command" "$HELPER"; done
grep -Fq 'valid_id' "$HELPER"; grep -Fq 'reject_stdin' "$HELPER"; grep -Fq 'active-record-current' "$HELPER"; grep -Fq 'no_nested_mounts' "$HELPER"
grep -Fq 'required_unit="nextcloud-pi-drill-required-$id.service"' "$HELPER"; grep -Fq 'Requires=%s' "$HELPER"
grep -Fq '/usr/bin/nohup "${args[@]}" 9>&- </dev/null' "$HELPER"
grep -Fq 'ACTIVE_PREPARE_ABORT_TX="$tx"' "$HELPER"
grep -Fq 'trap '\''active_prepare_abort "$?"'\'' EXIT HUP INT TERM' "$HELPER"
grep -Fq 'else protected_file "$ACTIVE_RECORD" 0600; /usr/bin/cp -p "$ACTIVE_RECORD" "$tx/snapshot"; fi' "$HELPER"
grep -Fq 'readonly LOCK_ROOT=/run/nextcloud-pi-locks' "$HELPER"
grep -Fq 'exec 9>>"$LOCK"' "$HELPER"
grep -Fq 'local path expected; path="$(resource_path "$1")"; expected="$(resource_mode "$1")"' "$HELPER"
grep -Fq 'cmd_runtime_backup_stream() { [[ $# == 1 ]] || invalid; reject_stdin;' "$HELPER"
! grep -Fq '/run/lock/nextcloud-pi-ops.lock' "$HELPER"
! grep -Fq 'rm -rf --one-file-system -- "$tx"; exit "$s"' "$HELPER"
! grep -Fq 'eval ' "$HELPER"
abort_fixture="$(mktemp -d)"
mkdir "$abort_fixture/transaction"
ACTIVE_PREPARE_ABORT_TX="$abort_fixture/transaction"
abort_function="$(awk '$0 ~ /^active_prepare_abort\(\)/ { print; exit }' "$HELPER")"
if [[ ! -x /usr/bin/rm ]]; then
  abort_function="${abort_function//\/usr\/bin\/rm -rf --one-file-system --/\/bin\/rm -rf --}"
fi
eval "$abort_function"
set +e
(active_prepare_abort 23)
abort_status=$?
set -e
[[ "$abort_status" == 23 && ! -e "$ACTIVE_PREPARE_ABORT_TX" ]]
rmdir "$abort_fixture"
python3 - "$HELPER" <<'PY'
import io
import pathlib
import sys
import tarfile
import tempfile

helper = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
readiness = helper.split("readiness_args() {", 1)[1].split("\nverify_readiness()", 1)[0]
for required in (
    '"--containerd-namespace=nextcloud-pi-readiness-$id"',
    '"--containerd-plugins-namespace=nextcloud-pi-readiness-plugins-$id"',
):
    if required not in readiness:
        raise SystemExit(f"readiness daemon is missing ID-bound namespace: {required}")
if "--containerd-namespace=moby" in readiness or "--containerd-plugins-namespace=plugins.moby" in readiness:
    raise SystemExit("readiness daemon reuses a live Docker containerd namespace")
verify_readiness = helper.split("verify_readiness() {", 1)[1].split("\ncmd_readiness_check()", 1)[0]
for required in (
    'mapfile -t expected < <(readiness_args "$id")',
    'mapfile -d \'\' -t actual <"/proc/$pid/cmdline"',
    '[[ "${expected[$i]}" == "${actual[$i]}" ]]',
):
    if required not in verify_readiness:
        raise SystemExit("readiness process identity does not compare the complete expected command")
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
    safe_link = pathlib.Path(directory, "safe-link.tar")
    with tarfile.open(safe_link, "w") as archive:
        payload = b"safe"
        target = tarfile.TarInfo("safe-target")
        target.size = len(payload)
        archive.addfile(target, io.BytesIO(payload))
        link = tarfile.TarInfo("safe-link")
        link.type = tarfile.SYMTYPE
        link.linkname = "safe-target"
        link.mode = 0o777
        archive.addfile(link)
    sys.argv = ["validate_archive", str(safe_link)]
    exec(compile(validator, "validate_archive", "exec"), {"__name__": "__main__"})
    safe_sticky = pathlib.Path(directory, "safe-sticky.tar")
    with tarfile.open(safe_sticky, "w") as archive:
        sticky = tarfile.TarInfo("runtime-tmp")
        sticky.type = tarfile.DIRTYPE
        sticky.uid = 0
        sticky.gid = 0
        sticky.mode = 0o1777
        archive.addfile(sticky)
    sys.argv = ["validate_archive", str(safe_sticky)]
    exec(compile(validator, "validate_archive", "exec"), {"__name__": "__main__"})
    unsafe_sticky = pathlib.Path(directory, "unsafe-sticky.tar")
    with tarfile.open(unsafe_sticky, "w") as archive:
        sticky = tarfile.TarInfo("runtime-tmp")
        sticky.type = tarfile.DIRTYPE
        sticky.uid = 1000
        sticky.gid = 1000
        sticky.mode = 0o1777
        archive.addfile(sticky)
    sys.argv = ["validate_archive", str(unsafe_sticky)]
    try:
        exec(compile(validator, "validate_archive", "exec"), {"__name__": "__main__"})
    except SystemExit:
        pass
    else:
        raise SystemExit("non-root sticky directory was accepted")
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
  sed -e "s|/etc/nextcloud-pi/privileged-policy.conf|$FIXTURE/policy|g" -e "s|/etc/nextcloud-pi/bundle-manifest.tsv|$FIXTURE/manifest|g" -e "s|/usr/local/libexec/nextcloud-pi-ops|$FIXTURE/ops|g" -e "s|/usr/local/libexec/nextcloud-pi-validate-active-images|$FIXTURE/validator|g" -e "s|/etc/nextcloud-pi/active-images.env|$FIXTURE/active-images.env|g" -e "s|/etc/nextcloud-pi/.active-images|$FIXTURE/.active-images|g" -e "s|/run/nextcloud-pi-locks|$FIXTURE/lock-root|g" -e "s|/var/lib/nextcloud-pi-ops|$FIXTURE/state|g" -e "s|/run/nextcloud-pi-ops|$FIXTURE/socket|g" -e "s|/etc/systemd/system|$FIXTURE/systemd|g" -e "s|/usr/bin/hostname|$FIXTURE/bin/hostname|g" -e "s|/usr/bin/findmnt|$FIXTURE/bin/findmnt|g" -e "s|/usr/bin/dockerd|$FIXTURE/bin/dockerd|g" -e "s|/usr/bin/docker|$FIXTURE/bin/docker|g" -e "s|/usr/bin/systemctl|$FIXTURE/bin/systemctl|g" -e "s|/usr/bin/df|$FIXTURE/bin/df|g" "$HELPER" >"$SOURCE_DIR/ops"
  cat >"$SOURCE_DIR/validator" <<EOF
#!/bin/sh
test ! -e '$FIXTURE/validator-fail'
EOF
  printf '#!/bin/sh\nexit 0\n' >"$SOURCE_DIR/launcher"
  printf 'unit\n' >"$SOURCE_DIR/unit"
  printf 'dropin\n' >"$SOURCE_DIR/dropin"
  cat >"$SOURCE_DIR/hostname" <<EOF
#!/bin/sh
printf '%s\n' '$(hostname)'
EOF
  cat >"$SOURCE_DIR/findmnt" <<EOF
#!/bin/bash
if [[ " \$* " != *' --target '* ]]; then printf '/\n'; exit 0; fi
case "\${*: -1}" in
  TARGET) printf '%s\n' '$FIXTURE/mount' ;;
  FSTYPE) printf 'ext4\n' ;;
  UUID) printf '11111111-1111-1111-1111-111111111111\n' ;;
  *) exit 2 ;;
esac
EOF
  cat >"$SOURCE_DIR/docker" <<EOF
#!/bin/bash
if [[ "\${1:-}:\${2:-}" == volume:inspect ]]; then
  case "\${3:-}" in
    nextcloud-docker_caddy_data) printf '%s\n' '$FIXTURE/volumes/caddy-data' ;;
    nextcloud-docker_caddy_config) printf '%s\n' '$FIXTURE/volumes/caddy-config' ;;
    *) exit 2 ;;
  esac
elif [[ "\${1:-}" == --host && "\${3:-}" == info ]]; then
  exit 0
elif [[ "\${1:-}" == --host && "\${3:-}:\${4:-}" == ps:-aq ]]; then
  exit 0
else
  exit 2
fi
EOF
  cat >"$SOURCE_DIR/systemctl" <<EOF
#!/bin/bash
state='$FIXTURE/service-state'
case "\${1:-}" in
  daemon-reload) exit 0 ;;
  start|restart)
    [[ "\${2:-}" != nextcloud-pi-drill-* ]] || exit 1
    [[ ! -e '$FIXTURE/systemctl-fail' ]] || exit 1
    printf 'active\n' >"\$state"
    ;;
  stop) printf 'inactive\n' >"\$state" ;;
  is-active)
    quiet=0
    [[ "\${2:-}" != --quiet ]] || quiet=1
    current="\$(cat "\$state")"
    (( quiet )) || printf '%s\n' "\$current"
    [[ "\$current" == active ]]
    ;;
  *) exit 2 ;;
esac
EOF
  cat >"$SOURCE_DIR/df" <<'EOF'
#!/bin/sh
printf 'Avail\n10737418240\n'
EOF
  cat >"$SOURCE_DIR/dockerd.c" <<'EOF'
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static void stop(int signal_number) { (void)signal_number; running = 0; }

int main(int argc, char **argv) {
  const char *prefix = "--host=unix://";
  const char *path = NULL;
  int descriptor;
  struct sockaddr_un address = {0};
  for (int index = 1; index < argc; ++index) {
    if (strncmp(argv[index], prefix, strlen(prefix)) == 0) path = argv[index] + strlen(prefix);
  }
  if (path == NULL || strlen(path) >= sizeof(address.sun_path)) return 2;
  descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
  if (descriptor < 0) return 3;
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path, path, strlen(path) + 1);
  unlink(path);
  if (bind(descriptor, (struct sockaddr *)&address, offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1) != 0) return 4;
  if (listen(descriptor, 1) != 0) return 5;
  signal(SIGTERM, stop);
  signal(SIGINT, stop);
  while (running) pause();
  close(descriptor);
  unlink(path);
  return 0;
}
EOF
  cc -Wall -Wextra -Werror "$SOURCE_DIR/dockerd.c" -o "$SOURCE_DIR/dockerd"
  sudo install -d -m 0700 -o root -g root "$FIXTURE/state" "$FIXTURE/mount/nextcloud-docker" "$FIXTURE/mount/nextcloud" "$FIXTURE/volumes/caddy-data" "$FIXTURE/volumes/caddy-config" "$FIXTURE/bin" "$FIXTURE/systemd"
  sudo install -m 0700 -o root -g root "$SOURCE_DIR/ops" "$FIXTURE/ops"
  sudo install -m 0700 -o root -g root "$SOURCE_DIR/validator" "$FIXTURE/validator"
  sudo install -m 0700 -o root -g root "$SOURCE_DIR/launcher" "$FIXTURE/launcher"
  for fake in hostname findmnt docker systemctl df dockerd; do sudo install -m 0700 -o root -g root "$SOURCE_DIR/$fake" "$FIXTURE/bin/$fake"; done
  sudo install -m 0644 -o root -g root "$SOURCE_DIR/unit" "$FIXTURE/unit"
  sudo install -m 0644 -o root -g root "$SOURCE_DIR/dropin" "$FIXTURE/dropin"
  printf 'active\n' | sudo tee "$FIXTURE/service-state" >/dev/null
  printf 'nextcloud-data\n' | sudo tee "$FIXTURE/mount/nextcloud/data.txt" >/dev/null
  printf 'caddy-data\n' | sudo tee "$FIXTURE/volumes/caddy-data/data.txt" >/dev/null
  printf 'caddy-config\n' | sudo tee "$FIXTURE/volumes/caddy-config/config.txt" >/dev/null
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
  sudo "$FIXTURE/ops" protected-state privileged-helper | grep -Fx $'state\tpresent' >/dev/null
  printf 'NEXTCLOUD_ACTIVE_IMAGES_MODE=source\n' >"$SOURCE_DIR/active-images.env"
  sudo install -m 0600 -o root -g root "$SOURCE_DIR/active-images.env" "$FIXTURE/active-images.env"
  sudo "$FIXTURE/ops" active-images-state | grep -Fx $'mode\tsource' >/dev/null

  sudo "$FIXTURE/ops" check | grep -Fx $'status\tok' >/dev/null
  for action in stop start restart; do
    sudo "$FIXTURE/ops" service "$action" | grep -Fx "$(printf 'state\t%s' "$action")" >/dev/null
  done
  sudo touch "$FIXTURE/systemctl-fail"
  if sudo "$FIXTURE/ops" service restart >/dev/null 2>&1; then
    printf 'dispatcher ignored a service-control failure\n' >&2
    exit 1
  fi
  sudo rm "$FIXTURE/systemctl-fail"

  active_candidate="$SOURCE_DIR/active-candidate.env"
  printf 'NEXTCLOUD_ACTIVE_IMAGES_MODE=recovered\n' >"$active_candidate"
  active_hash="$(sha256sum "$active_candidate" | awk '{print $1}')"
  active_size="$(wc -c <"$active_candidate" | tr -d '[:space:]')"
  active_rollback_id=20260910T000000Z-101
  cat "$active_candidate" | sudo "$FIXTURE/ops" active-record prepare "$active_rollback_id" "$active_hash" "$active_size" | grep -Fx $'state\tprepared' >/dev/null
  sudo "$FIXTURE/ops" active-record apply "$active_rollback_id" | grep -Fx $'state\tapplied' >/dev/null
  sudo "$FIXTURE/ops" active-record rollback "$active_rollback_id" | grep -Fx $'state\trolledback' >/dev/null
  sudo "$FIXTURE/ops" active-record commit "$active_rollback_id" | grep -Fx $'state\tcommitted' >/dev/null
  sudo grep -Fxq NEXTCLOUD_ACTIVE_IMAGES_MODE=source "$FIXTURE/active-images.env"
  active_commit_id=20260910T000000Z-102
  cat "$active_candidate" | sudo "$FIXTURE/ops" active-record prepare "$active_commit_id" "$active_hash" "$active_size" >/dev/null
  sudo "$FIXTURE/ops" active-record apply "$active_commit_id" >/dev/null
  sudo "$FIXTURE/ops" active-record commit "$active_commit_id" >/dev/null
  sudo grep -Fxq NEXTCLOUD_ACTIVE_IMAGES_MODE=recovered "$FIXTURE/active-images.env"
  if { cat "$active_candidate"; printf x; } | sudo "$FIXTURE/ops" active-record prepare 20260910T000000Z-103 "$active_hash" "$active_size" >/dev/null 2>&1; then
    printf 'active-record prepare accepted trailing input\n' >&2
    exit 1
  fi
  sudo touch "$FIXTURE/validator-fail"
  if sudo "$FIXTURE/ops" active-images-state >/dev/null 2>&1; then
    printf 'active-images-state ignored validator failure\n' >&2
    exit 1
  fi
  sudo rm "$FIXTURE/validator-fail"

  sudo "$FIXTURE/ops" runtime-backup size | grep -Fx $'nextcloud_bytes\t15' >/dev/null
  for dataset in nextcloud caddy-data caddy-config; do
    sudo "$FIXTURE/ops" runtime-backup stream "$dataset" >"$SOURCE_DIR/$dataset.tar"
    tar -tf "$SOURCE_DIR/$dataset.tar" >/dev/null
  done
  if printf x | sudo "$FIXTURE/ops" runtime-backup stream nextcloud >/dev/null 2>&1; then
    printf 'runtime-backup stream accepted trailing input\n' >&2
    exit 1
  fi

  recovery_id=20260910T000000Z-104
  sudo "$FIXTURE/ops" runtime-recovery check "$recovery_id" 1 | grep -Fx $'state\tavailable' >/dev/null
  sudo "$FIXTURE/ops" runtime-recovery prepare "$recovery_id" | grep -Fx $'state\tprepared' >/dev/null
  mkdir "$SOURCE_DIR/recovery-source"
  printf 'recovered\n' >"$SOURCE_DIR/recovery-source/data.txt"
  tar --numeric-owner --acls --xattrs -cpf "$SOURCE_DIR/recovery.tar" -C "$SOURCE_DIR/recovery-source" .
  recovery_hash="$(sha256sum "$SOURCE_DIR/recovery.tar" | awk '{print $1}')"
  recovery_size="$(wc -c <"$SOURCE_DIR/recovery.tar" | tr -d '[:space:]')"
  cat "$SOURCE_DIR/recovery.tar" | sudo "$FIXTURE/ops" runtime-recovery restore "$recovery_id" nextcloud "$recovery_hash" "$recovery_size" | grep -Fx $'state\trestored' >/dev/null
  if cat "$SOURCE_DIR/recovery.tar" | sudo "$FIXTURE/ops" runtime-recovery restore "$recovery_id" nextcloud "$recovery_hash" "$recovery_size" >/dev/null 2>&1; then
    printf 'runtime-recovery restored a dataset twice\n' >&2
    exit 1
  fi
  sudo "$FIXTURE/ops" runtime-recovery cleanup "$recovery_id" | grep -Fx $'state\tabsent' >/dev/null
  sudo "$FIXTURE/ops" runtime-recovery cleanup "$recovery_id" >/dev/null

  readiness_id=20260910T000000Z-105
  sudo "$FIXTURE/ops" image-readiness check "$readiness_id" 1 | grep -Fx $'state\tavailable' >/dev/null
  sudo "$FIXTURE/ops" image-readiness start "$readiness_id" | grep -Fx $'state\tready' >/dev/null
  sudo "$FIXTURE/ops" image-readiness status "$readiness_id" | grep -Fx $'state\tready' >/dev/null
  readiness_start="$FIXTURE/state/image-readiness/$readiness_id/start"
  original_start="$(sudo cat "$readiness_start")"
  printf '0\n' | sudo tee "$readiness_start" >/dev/null
  if sudo "$FIXTURE/ops" image-readiness status "$readiness_id" >/dev/null 2>&1; then
    printf 'image-readiness accepted a changed process identity\n' >&2
    exit 1
  fi
  printf '%s\n' "$original_start" | sudo tee "$readiness_start" >/dev/null
  sudo "$FIXTURE/ops" image-readiness stop "$readiness_id" | grep -Fx $'state\tstopped' >/dev/null
  sudo "$FIXTURE/ops" image-readiness cleanup "$readiness_id" | grep -Fx $'state\tabsent' >/dev/null
  sudo "$FIXTURE/ops" image-readiness cleanup "$readiness_id" >/dev/null

  drill_id=20260910T000000Z-106
  sudo "$FIXTURE/ops" deployment-drill check "$drill_id" | grep -Fx $'state\tavailable' >/dev/null
  sudo "$FIXTURE/ops" deployment-drill apply "$drill_id" | grep -Fx $'state\trolledback' >/dev/null
  sudo "$FIXTURE/ops" deployment-drill cleanup "$drill_id" | grep -Fx $'state\tabsent' >/dev/null
  sudo install -m 0600 -o root -g root /dev/null "$FIXTURE/systemd/nextcloud-pi-drill-$drill_id.service"
  if sudo "$FIXTURE/ops" deployment-drill check "$drill_id" >/dev/null 2>&1; then
    printf 'deployment-drill check ignored an existing unit\n' >&2
    exit 1
  fi
  sudo "$FIXTURE/ops" deployment-drill cleanup "$drill_id" >/dev/null

  denied_dispatch() {
    if sudo "$FIXTURE/ops" "$@" >/dev/null 2>&1; then
      printf 'dispatcher accepted invalid invocation: %s\n' "$*" >&2
      exit 1
    fi
  }
  denied_dispatch unknown
  denied_dispatch version extra
  denied_dispatch check extra
  denied_dispatch protected-state /etc/passwd
  denied_dispatch protected-state unknown
  denied_dispatch active-images-state extra
  denied_dispatch service nextcloud.service
  denied_dispatch active-record prepare ../../escape bad 0
  denied_dispatch active-record apply --bad
  denied_dispatch active-record rollback /absolute/path
  denied_dispatch active-record commit bad
  denied_dispatch runtime-backup stream /etc
  denied_dispatch runtime-recovery prepare ../../escape
  denied_dispatch runtime-recovery restore bad wrong bad 0
  denied_dispatch image-readiness start --bad
  denied_dispatch image-readiness cleanup /absolute/path
  denied_dispatch deployment-drill apply ../../escape
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
