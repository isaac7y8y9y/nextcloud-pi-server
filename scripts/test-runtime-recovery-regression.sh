#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DRILL="$SCRIPT_DIR/test-runtime-recovery.sh"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/image-lock.sh"
image_lock_load "$REPOSITORY_ROOT"

extract_function() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\) \\{" { capture = 1 } capture { print } capture && $0 == "}" { exit }' "$DRILL"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
extract_function validate_runtime_recovery_image_identity >"$TMP_DIR/helper.sh"
source "$TMP_DIR/helper.sh"

error=""
commands=""
die() {
  error="$1"
  return 1
}
remote() {
  local command="$1"
  # Model OpenSSH's ability to drain the producer stream. The helper's image
  # loop must redirect each remote call away from image_lock_tags input.
  cat >/dev/null
  commands+="$command"$'\n'
  case "$scenario" in
    validator_present)
      [[ "$command" == "sudo -n test -x /usr/local/libexec/nextcloud-pi-validate-active-images" || "$command" == "sudo -n /usr/local/libexec/nextcloud-pi-validate-active-images" ]]
      ;;
    validator_rejects)
      [[ "$command" == "sudo -n test -x /usr/local/libexec/nextcloud-pi-validate-active-images" ]] && return 0
      [[ "$command" == "sudo -n /usr/local/libexec/nextcloud-pi-validate-active-images" ]] && return 1
      return 1
      ;;
    source_valid)
      if [[ "$command" == "sudo -n test -x /usr/local/libexec/nextcloud-pi-validate-active-images" ]]; then return 1; fi
      if [[ "$command" == "sudo -n test ! -e /etc/nextcloud-pi/active-images.env && sudo -n test ! -L /etc/nextcloud-pi/active-images.env" ]]; then return 0; fi
      [[ "$command" == *"docker image inspect"* ]]
      ;;
    record_present)
      if [[ "$command" == "sudo -n test -x /usr/local/libexec/nextcloud-pi-validate-active-images" ]]; then return 1; fi
      return 1
      ;;
    source_mismatch)
      if [[ "$command" == "sudo -n test -x /usr/local/libexec/nextcloud-pi-validate-active-images" ]]; then return 1; fi
      if [[ "$command" == "sudo -n test ! -e /etc/nextcloud-pi/active-images.env && sudo -n test ! -L /etc/nextcloud-pi/active-images.env" ]]; then return 0; fi
      [[ "$command" == *"$NEXTCLOUD_IMAGE_APP_TAG"* ]] && return 1
      [[ "$command" == *"docker image inspect"* ]]
      ;;
  esac
}

scenario=validator_present
validate_runtime_recovery_image_identity
scenario=validator_rejects
error=""
commands=""
if validate_runtime_recovery_image_identity; then
  echo 'expected installed validator rejection to fail' >&2
  exit 1
fi
[[ "$error" == "installed active-image validator rejected the Pi image state" ]]
[[ "$commands" != *"/etc/nextcloud-pi/active-images.env"* ]]

scenario=source_valid
commands=""
validate_runtime_recovery_image_identity
[[ "$(grep -c 'docker image inspect' <<<"$commands")" == 3 ]]

scenario=record_present
error=""
if validate_runtime_recovery_image_identity; then
  echo 'expected record-present fallback to fail' >&2
  exit 1
fi
[[ "$error" == "active-image validator is absent but an active-image record exists" ]]

scenario=source_mismatch
error=""
if validate_runtime_recovery_image_identity; then
  echo 'expected mismatched source lock to fail' >&2
  exit 1
fi
[[ "$error" == "source-locked image is missing or differs: $NEXTCLOUD_IMAGE_APP_TAG" ]]

# All post-initialization database operations must use TCP. The official image
# disables networking on its temporary initialization server, so this prevents
# a socket probe from succeeding during the shutdown/startup handoff.
[[ "$(grep -Fc -- '--protocol=tcp --host=127.0.0.1' "$DRILL")" == 4 ]]
grep -Fq -- '-e \"SELECT 1\"' "$DRILL"
grep -Fq -- 'exec mariadb --protocol=tcp --host=127.0.0.1' "$DRILL"
grep -Fq -- 'mariadb-check --protocol=tcp --host=127.0.0.1' "$DRILL"
grep -Fq 'remote "docker image inspect --format '\''{{.Id}}'\'' '\''$tag'\'' | grep -Fx '\''$expected'\'' >/dev/null" </dev/null' "$DRILL"
echo 'runtime recovery drill regression checks passed'
