#!/usr/bin/env bash
set -euo pipefail

# Exercise the rendered root launcher with a fake Docker transport. Validation
# must reject a wrong image or extra service before the `up` operation occurs.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fixture="$TEST_DIR/deployment.env"
cp "$REPOSITORY_ROOT/config/deployment.env.example" "$fixture"
chmod 600 "$fixture"
NEXTCLOUD_PI_HOST=pi.test.invalid \
NEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-test \
NEXTCLOUD_PI_USER=test-user \
NEXTCLOUD_REMOTE_PROJECT_DIR="$TEST_DIR/nextcloud-docker" \
NEXTCLOUD_STORAGE_MOUNT=/mnt/test-nextcloud \
NEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111 \
NEXTCLOUD_PUBLIC_HOSTNAME=nextcloud.test.invalid \
NEXTCLOUD_DEPLOYMENT_ENV_FILE="$fixture" "$SCRIPT_DIR/render-deployment-config.sh" --output-dir "$TEST_DIR/rendered"

mkdir -p "$TEST_DIR/nextcloud-docker" "$TEST_DIR/bin" "$TEST_DIR/libexec"
mkdir -m 700 "$TEST_DIR/locks"
: >"$TEST_DIR/locks/startup-selection.lock"
chmod 600 "$TEST_DIR/locks/startup-selection.lock"
cat >"$TEST_DIR/libexec/ops" <<'EOF'
#!/usr/bin/env bash
if [[ "${LAUNCHER_ASSERT_LOCK:-no}" == yes ]]; then
  ! /usr/bin/flock -n "$LAUNCHER_LOCK" true || exit 1
fi
[[ "$1" == upgrade-startup-guard && $# == 1 && "${LAUNCHER_CUTOVER_BLOCK:-no}" == no ]]
EOF
chmod 700 "$TEST_DIR/libexec/ops"
cp "$TEST_DIR/rendered/docker-compose.yml" "$TEST_DIR/nextcloud-docker/docker-compose.yml"
cp "$TEST_DIR/rendered/active-images/active-images.env" "$TEST_DIR/active-images.env"
sed \
  -e "s|RECORD=/etc/nextcloud-pi/active-images.env|RECORD=$TEST_DIR/active-images.env|" \
  -e "s|== 0|== $(id -u)|" \
  "$TEST_DIR/rendered/launcher/nextcloud-pi-validate-active-images" >"$TEST_DIR/libexec/validate"
chmod 700 "$TEST_DIR/libexec/validate"

sed \
  -e "s|RECORD=/etc/nextcloud-pi/active-images.env|RECORD=$TEST_DIR/active-images.env|" \
  -e "s|/usr/local/libexec/nextcloud-pi-validate-active-images|$TEST_DIR/libexec/validate|" \
  -e "s|/usr/local/libexec/nextcloud-pi-ops|$TEST_DIR/libexec/ops|" \
  -e "s|/run/nextcloud-pi-locks|$TEST_DIR/locks|" \
  -e "s|0:0:700|$(id -u):$(id -g):700|" \
  -e "s|0:0:600|$(id -u):$(id -g):600|" \
  -e "s|/run/nextcloud-pi-compose.XXXXXX|$TEST_DIR/snapshot.XXXXXX|" \
  "$TEST_DIR/rendered/launcher/nextcloud-pi-compose-start" >"$TEST_DIR/launcher"
chmod 700 "$TEST_DIR/launcher"

cat >"$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${LAUNCHER_ASSERT_LOCK:-no}" == yes ]]; then
  ! /usr/bin/flock -n "$LAUNCHER_LOCK" true || exit 1
fi
if [[ "$1 $2" == 'image inspect' ]]; then
  if [[ "${LAUNCHER_IMAGE_MODE:-source}" == recovered && " $* " == *' --platform linux/arm64/v8 '* ]]; then
    case "${@: -1}" in
      nextcloud:30) printf 'sha256:%064d\n' 4 ;;
      mariadb:11) printf 'sha256:%064d\n' 5 ;;
      caddy:2) printf 'sha256:%064d\n' 6 ;;
      *) exit 1 ;;
    esac
  else
    case "${@: -1}" in
      nextcloud:30) printf '%s\n' sha256:fb966733647ea03f0446b0c22eac9733c8eb616d37b960caca9d4c3010e14a08 ;;
      mariadb:11) printf '%s\n' sha256:7fcb6109db2ba31b22a5709c1eaf9e84f76c9f1b9b9031ef09f24092f7f207cc ;;
      caddy:2) printf '%s\n' sha256:c3d7ee5d2b11f9dc54f947f68a734c84e9c9666c92c88a7f30b9cba5da182adb ;;
      *) exit 1 ;;
    esac
  fi
  exit 0
fi
if [[ "$*" == *" config --format json" ]]; then
  case "$LAUNCHER_SCENARIO" in
    valid) printf '%s\n' '{"services":{"app":{"image":"nextcloud:30"},"db":{"image":"mariadb:11"},"caddy":{"image":"caddy:2"}}}' ;;
    wrong) printf '%s\n' '{"services":{"app":{"image":"evil:cached"},"db":{"image":"mariadb:11"},"caddy":{"image":"caddy:2"}}}' ;;
    extra) printf '%s\n' '{"services":{"app":{"image":"nextcloud:30"},"db":{"image":"mariadb:11"},"caddy":{"image":"caddy:2"},"extra":{"image":"evil:cached"}}}' ;;
    *) exit 2 ;;
  esac
  exit 0
fi
printf 'up\n' >>"$LAUNCHER_CALLS"
EOF
chmod 700 "$TEST_DIR/bin/docker"
cat >"$TEST_DIR/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" == Darwin && "$1" == -c ]]; then
  case "$2" in
    %a) /usr/bin/stat -f '%Lp' "$3" ;;
    %u) /usr/bin/stat -f '%u' "$3" ;;
    %u:%g:%a) /usr/bin/stat -f '%u:%g:%Lp' "$3" ;;
    *) exit 2 ;;
  esac
else
  /usr/bin/stat "$@"
fi
EOF
chmod 700 "$TEST_DIR/bin/stat"
cat >"$TEST_DIR/bin/flock" <<'EOF'
#!/usr/bin/env bash
if [[ -x /usr/bin/flock ]]; then exec /usr/bin/flock "$@"; fi
exit 0
EOF
chmod 700 "$TEST_DIR/bin/flock"

export PATH="$TEST_DIR/bin:$PATH"
export LAUNCHER_CALLS="$TEST_DIR/calls"
export LAUNCHER_LOCK="$TEST_DIR/locks/startup-selection.lock"
if [[ "$(uname -s)" == Linux ]]; then export LAUNCHER_ASSERT_LOCK=yes; fi
for scenario in wrong extra; do
  : >"$LAUNCHER_CALLS"
  export LAUNCHER_SCENARIO="$scenario"
  if bash "$TEST_DIR/launcher" >/dev/null 2>&1; then
    echo "launcher unexpectedly accepted $scenario Compose identity" >&2
    exit 1
  fi
  [[ ! -s "$LAUNCHER_CALLS" ]]
done

: >"$LAUNCHER_CALLS"
export LAUNCHER_SCENARIO=valid
bash "$TEST_DIR/launcher" >/dev/null
[[ "$(cat "$LAUNCHER_CALLS")" == up ]]
[[ -z "$(find "$TEST_DIR" -maxdepth 1 -name 'snapshot.*' -print -quit)" ]]

: >"$LAUNCHER_CALLS"
export LAUNCHER_CUTOVER_BLOCK=yes
if bash "$TEST_DIR/launcher" >/dev/null 2>&1; then
  echo "launcher ignored the database cutover startup guard" >&2
  exit 1
fi
[[ ! -s "$LAUNCHER_CALLS" ]]
unset LAUNCHER_CUTOVER_BLOCK

if [[ "${GITHUB_ACTIONS:-}" == true && "$(uname -s)" == Linux ]]; then
  sudo -n true
  for blocked in yes no; do
    : >"$LAUNCHER_CALLS"
    unit="nextcloud-db-startup-fixture-$$-$blocked"
    sudo systemd-run --quiet --wait --collect --unit="$unit" --service-type=oneshot \
      -p "User=$(id -un)" -p "Environment=PATH=$PATH" \
      -p "Environment=LAUNCHER_CALLS=$LAUNCHER_CALLS" \
      -p "Environment=LAUNCHER_SCENARIO=valid" \
      -p "Environment=LAUNCHER_CUTOVER_BLOCK=$blocked" \
      /bin/bash "$TEST_DIR/launcher" >/dev/null 2>&1 || [[ "$blocked" == yes ]]
    if [[ "$blocked" == yes ]]; then
      [[ ! -s "$LAUNCHER_CALLS" ]] || { echo "systemd started Compose during cutover" >&2; exit 1; }
    else
      [[ "$(<"$LAUNCHER_CALLS")" == up ]] || { echo "systemd did not run the validated launcher" >&2; exit 1; }
    fi
  done
fi

# Model both a service restart and the next boot while recovered mappings are
# authoritative. Each lifecycle invocation resolves and validates afresh.
sed -i.bak 's/NEXTCLOUD_ACTIVE_IMAGES_MODE=source/NEXTCLOUD_ACTIVE_IMAGES_MODE=recovered/' "$TEST_DIR/active-images.env"
sed -i.bak \
  -e 's/^NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256=.*/NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/' \
  -e 's/^NEXTCLOUD_ACTIVE_IMAGES_APP_ID=.*/NEXTCLOUD_ACTIVE_IMAGES_APP_ID=sha256:0000000000000000000000000000000000000000000000000000000000000004/' \
  -e 's/^NEXTCLOUD_ACTIVE_IMAGES_DB_ID=.*/NEXTCLOUD_ACTIVE_IMAGES_DB_ID=sha256:0000000000000000000000000000000000000000000000000000000000000005/' \
  -e 's/^NEXTCLOUD_ACTIVE_IMAGES_CADDY_ID=.*/NEXTCLOUD_ACTIVE_IMAGES_CADDY_ID=sha256:0000000000000000000000000000000000000000000000000000000000000006/' \
  "$TEST_DIR/active-images.env"
: >"$LAUNCHER_CALLS"
export LAUNCHER_IMAGE_MODE=recovered
bash "$TEST_DIR/launcher" >/dev/null
bash "$TEST_DIR/launcher" >/dev/null
[[ "$(cat "$LAUNCHER_CALLS")" == $'up\nup' ]]
[[ -z "$(find "$TEST_DIR" -maxdepth 1 -name 'snapshot.*' -print -quit)" ]]
echo 'Compose launcher identity tests passed'
