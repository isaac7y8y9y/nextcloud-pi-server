#!/usr/bin/env bash

# Shared root-owned dispatcher fixture for GitHub Actions-only regression tests.

privileged_fixture_cleanup() {
  local status=${1:-0}
  [[ -z "${PRIVILEGED_FIXTURE:-}" ]] || sudo rm -rf -- "$PRIVILEGED_FIXTURE"
  [[ -z "${PRIVILEGED_FIXTURE_SOURCE:-}" ]] || rm -rf -- "$PRIVILEGED_FIXTURE_SOURCE"
  return "$status"
}

privileged_fixture_setup() {
  local helper="$1"
  [[ "${GITHUB_ACTIONS:-}" == true && "$(uname -s)" == Linux ]] || return 1
  sudo -n true
  PRIVILEGED_FIXTURE="$(sudo mktemp -d /root/nextcloud-pi-ops-test.XXXXXX)"
  PRIVILEGED_FIXTURE_SOURCE="$(mktemp -d)"
  export PRIVILEGED_FIXTURE PRIVILEGED_FIXTURE_SOURCE

  sed -e "s|/etc/nextcloud-pi/privileged-policy.conf|$PRIVILEGED_FIXTURE/policy|g" -e "s|/etc/nextcloud-pi/bundle-manifest.tsv|$PRIVILEGED_FIXTURE/manifest|g" -e "s|/usr/local/libexec/nextcloud-pi-ops|$PRIVILEGED_FIXTURE/ops|g" -e "s|/usr/local/libexec/nextcloud-pi-validate-active-images|$PRIVILEGED_FIXTURE/validator|g" -e "s|/etc/nextcloud-pi/active-images.env|$PRIVILEGED_FIXTURE/active-images.env|g" -e "s|/etc/nextcloud-pi/.active-images|$PRIVILEGED_FIXTURE/.active-images|g" -e "s|/run/nextcloud-pi-locks|$PRIVILEGED_FIXTURE/lock-root|g" -e "s|/var/lib/nextcloud-pi-ops|$PRIVILEGED_FIXTURE/state|g" -e "s|/run/nextcloud-pi-ops|$PRIVILEGED_FIXTURE/socket|g" -e "s|/etc/systemd/system|$PRIVILEGED_FIXTURE/systemd|g" -e "s|/usr/bin/hostname|$PRIVILEGED_FIXTURE/bin/hostname|g" -e "s|/usr/bin/findmnt|$PRIVILEGED_FIXTURE/bin/findmnt|g" -e "s|/usr/bin/dockerd|$PRIVILEGED_FIXTURE/bin/dockerd|g" -e "s|/usr/bin/docker|$PRIVILEGED_FIXTURE/bin/docker|g" -e "s|/usr/bin/systemctl|$PRIVILEGED_FIXTURE/bin/systemctl|g" -e "s|/usr/bin/df|$PRIVILEGED_FIXTURE/bin/df|g" "$helper" >"$PRIVILEGED_FIXTURE_SOURCE/ops"

  cat >"$PRIVILEGED_FIXTURE_SOURCE/validator" <<EOF
#!/bin/sh
test ! -e '$PRIVILEGED_FIXTURE/validator-fail'
EOF
  printf '#!/bin/sh\nexit 0\n' >"$PRIVILEGED_FIXTURE_SOURCE/launcher"
  printf 'unit\n' >"$PRIVILEGED_FIXTURE_SOURCE/unit"
  printf 'dropin\n' >"$PRIVILEGED_FIXTURE_SOURCE/dropin"
  cat >"$PRIVILEGED_FIXTURE_SOURCE/hostname" <<EOF
#!/bin/sh
printf '%s\n' '$(hostname)'
EOF
  cat >"$PRIVILEGED_FIXTURE_SOURCE/findmnt" <<EOF
#!/bin/bash
if [[ " \$* " != *' --target '* ]]; then printf '/\n'; exit 0; fi
case "\${*: -1}" in
  TARGET) printf '%s\n' '$PRIVILEGED_FIXTURE/mount' ;;
  FSTYPE) printf 'ext4\n' ;;
  UUID) printf '11111111-1111-1111-1111-111111111111\n' ;;
  *) exit 2 ;;
esac
EOF
  cat >"$PRIVILEGED_FIXTURE_SOURCE/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
readonly fixture_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
if [[ "${1:-}:${2:-}" == volume:inspect ]]; then
  case "${3:-}" in
    nextcloud-docker_caddy_data) printf '%s\n' "$fixture_root/volumes/caddy-data" ;;
    nextcloud-docker_caddy_config) printf '%s\n' "$fixture_root/volumes/caddy-config" ;;
    *) exit 2 ;;
  esac
  exit 0
fi
[[ "${1:-}" == --host && "$2" == "unix://$fixture_root/socket/image-readiness-"*.sock ]] || exit 2
case "${3:-}:${4:-}" in
  info:) [[ $# == 3 ]] || exit 2 ;;
  ps:-aq) [[ $# == 4 ]] || exit 2 ;;
  *) exit 2 ;;
esac
printf '%s\n' "$*" >>"$fixture_root/docker.log"
exit 0
EOF
  cat >"$PRIVILEGED_FIXTURE_SOURCE/systemctl" <<EOF
#!/bin/bash
state='$PRIVILEGED_FIXTURE/service-state'
case "\${1:-}" in
  daemon-reload) exit 0 ;;
  start|restart)
    [[ "\${2:-}" != nextcloud-pi-drill-* ]] || exit 1
    [[ ! -e '$PRIVILEGED_FIXTURE/systemctl-fail' ]] || exit 1
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
  printf '#!/bin/sh\nprintf "Avail\\n10737418240\\n"\n' >"$PRIVILEGED_FIXTURE_SOURCE/df"
  cat >"$PRIVILEGED_FIXTURE_SOURCE/dockerd.c" <<EOF
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
  if (access("$PRIVILEGED_FIXTURE/fail-start", F_OK) == 0) return 5;
  for (int index = 1; index < argc; ++index) if (strncmp(argv[index], prefix, strlen(prefix)) == 0) path = argv[index] + strlen(prefix);
  if (path == NULL || strlen(path) >= sizeof(address.sun_path)) return 2;
  descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
  if (descriptor < 0) return 3;
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path, path, strlen(path) + 1);
  unlink(path);
  if (bind(descriptor, (struct sockaddr *)&address, offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1) != 0) return 4;
  if (listen(descriptor, 1) != 0) return 5;
  signal(SIGTERM, stop); signal(SIGINT, stop);
  while (running) pause();
  close(descriptor); unlink(path); return 0;
}
EOF
  cc -Wall -Wextra -Werror "$PRIVILEGED_FIXTURE_SOURCE/dockerd.c" -o "$PRIVILEGED_FIXTURE_SOURCE/dockerd"
  sudo install -d -m 0700 -o root -g root "$PRIVILEGED_FIXTURE/state" "$PRIVILEGED_FIXTURE/mount/nextcloud-docker" "$PRIVILEGED_FIXTURE/mount/nextcloud" "$PRIVILEGED_FIXTURE/volumes/caddy-data" "$PRIVILEGED_FIXTURE/volumes/caddy-config" "$PRIVILEGED_FIXTURE/bin" "$PRIVILEGED_FIXTURE/systemd"
  sudo install -m 0700 -o root -g root "$PRIVILEGED_FIXTURE_SOURCE/ops" "$PRIVILEGED_FIXTURE/ops"
  sudo install -m 0700 -o root -g root "$PRIVILEGED_FIXTURE_SOURCE/validator" "$PRIVILEGED_FIXTURE/validator"
  sudo install -m 0700 -o root -g root "$PRIVILEGED_FIXTURE_SOURCE/launcher" "$PRIVILEGED_FIXTURE/launcher"
  for fake in hostname findmnt docker systemctl df dockerd; do sudo install -m 0700 -o root -g root "$PRIVILEGED_FIXTURE_SOURCE/$fake" "$PRIVILEGED_FIXTURE/bin/$fake"; done
  sudo install -m 0644 -o root -g root "$PRIVILEGED_FIXTURE_SOURCE/unit" "$PRIVILEGED_FIXTURE/unit"
  sudo install -m 0644 -o root -g root "$PRIVILEGED_FIXTURE_SOURCE/dropin" "$PRIVILEGED_FIXTURE/dropin"
  printf 'active\n' | sudo tee "$PRIVILEGED_FIXTURE/service-state" >/dev/null
  printf 'nextcloud-data\n' | sudo tee "$PRIVILEGED_FIXTURE/mount/nextcloud/data.txt" >/dev/null
  printf 'caddy-data\n' | sudo tee "$PRIVILEGED_FIXTURE/volumes/caddy-data/data.txt" >/dev/null
  printf 'caddy-config\n' | sudo tee "$PRIVILEGED_FIXTURE/volumes/caddy-config/config.txt" >/dev/null
  cat >"$PRIVILEGED_FIXTURE_SOURCE/policy" <<EOF
NEXTCLOUD_PI_POLICY_FORMAT=nextcloud-pi-privileged-policy-v1
NEXTCLOUD_PI_BUNDLE_VERSION=1
NEXTCLOUD_PI_DEPLOYMENT_USER=$(id -un)
NEXTCLOUD_PI_SYSTEM_HOSTNAME=$(hostname)
NEXTCLOUD_PI_PROJECT_DIR=$PRIVILEGED_FIXTURE/mount/nextcloud-docker
NEXTCLOUD_PI_STORAGE_MOUNT=$PRIVILEGED_FIXTURE/mount
NEXTCLOUD_PI_STORAGE_TYPE=ext4
NEXTCLOUD_PI_STORAGE_UUID=11111111-1111-1111-1111-111111111111
NEXTCLOUD_PI_IMAGE_PLATFORM=linux/arm64
NEXTCLOUD_PI_SERVICE_NAME=nextcloud.service
NEXTCLOUD_PI_APP_CONTAINER=nextcloud-docker-app-1
NEXTCLOUD_PI_DB_CONTAINER=nextcloud-docker-db-1
NEXTCLOUD_PI_CADDY_CONTAINER=nextcloud-docker-caddy-1
NEXTCLOUD_PI_CADDY_DATA_VOLUME=nextcloud-docker_caddy_data
NEXTCLOUD_PI_CADDY_CONFIG_VOLUME=nextcloud-docker_caddy_config
NEXTCLOUD_PI_STATE_ROOT=$PRIVILEGED_FIXTURE/state
NEXTCLOUD_PI_SOCKET_ROOT=$PRIVILEGED_FIXTURE/socket
NEXTCLOUD_PI_RUNTIME_RECOVERY_PREFIX=.recovery-
NEXTCLOUD_PI_IMAGE_READINESS_PREFIX=.readiness-
NEXTCLOUD_PI_MAX_STAGING_BYTES=1048576
EOF
  {
    printf 'format\tnextcloud-pi-bundle-manifest-v1\nversion\t1\n'
    for entry in "privileged-helper:$PRIVILEGED_FIXTURE/ops:0700" "active-image-validator:$PRIVILEGED_FIXTURE/validator:0700" "compose-launcher:$PRIVILEGED_FIXTURE/launcher:0700" "nextcloud-unit:$PRIVILEGED_FIXTURE/unit:0644" "docker-storage-drop-in:$PRIVILEGED_FIXTURE/dropin:0644"; do
      local logical remainder path mode
      logical="${entry%%:*}"
      remainder="${entry#*:}"
      path="${remainder%:*}"
      mode="${entry##*:}"
      printf 'file\t%s\ttest\t%s\t%s\t%s\n' "$logical" "$path" "$mode" "$(sudo sha256sum "$path" | awk '{print $1}')"
    done
  } >"$PRIVILEGED_FIXTURE_SOURCE/manifest"
  sudo install -m 0600 -o root -g root "$PRIVILEGED_FIXTURE_SOURCE/policy" "$PRIVILEGED_FIXTURE/policy"
  sudo install -m 0600 -o root -g root "$PRIVILEGED_FIXTURE_SOURCE/manifest" "$PRIVILEGED_FIXTURE/manifest"
}
