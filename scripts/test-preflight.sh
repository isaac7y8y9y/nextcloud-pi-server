#!/usr/bin/env bash
set -euo pipefail

# Keep source-mode readiness and hardened-launcher conformance from drifting.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PREFLIGHT="$SCRIPT_DIR/preflight.sh"
source "$SCRIPT_DIR/lib/launcher-prerequisites.sh"
grep -Fq 'Protected source active-image record matches local image tags' "$PREFLIGHT"
grep -Fq 'Protected active-image record is recovered; readiness requires source mode' "$PREFLIGHT"
grep -Fq 'Protected recovered active-image record matches local image tags' "$PREFLIGHT"
grep -Fq 'Root-only startup launcher' "$PREFLIGHT"
grep -Fq 'Root-only active-image validator' "$PREFLIGHT"
grep -Fq 'Approved readiness transition:' "$PREFLIGHT"
grep -Fq 'Unexpected configuration drift:' "$PREFLIGHT"
grep -Fq '(( FAIL_COUNT == 0 )) || exit 1' "$PREFLIGHT"
grep -Fq 'record FAIL "Remote hostname does not match the configured deployment target"' "$PREFLIGHT"
grep -Fq 'record FAIL "Unable to read live $label"' "$PREFLIGHT"
grep -Fq 'allowed_absent_path' "$PREFLIGHT"
grep -Fq '"/usr/local/libexec/nextcloud-pi-compose-start"' "$PREFLIGHT"
grep -Fq 'Docker storage mount drop-in differs from live configuration' "$PREFLIGHT"
grep -Fq 'App published port differs from the reviewed readiness baseline' "$PREFLIGHT"
grep -Fq 'Protected active image record is invalid, unreadable, or differs' "$PREFLIGHT"

extract_function() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\) \\{" { capture = 1 } capture { print } capture && $0 == "}" { exit }' "$PREFLIGHT"
}

# Exercise the actual comparison helper with a mocked remote transport. An
# optional baseline path is warning-only precisely when the transport verifies
# that the path is absent; an unreadable existing file or a failed transport is
# still a hard failure.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
extract_function normalize_active_config >"$TMP_DIR/normalize-active-config.sh"
extract_function compare_normalized_file_to_remote_command >"$TMP_DIR/compare-normalized-config.sh"
source "$TMP_DIR/normalize-active-config.sh"
source "$TMP_DIR/compare-normalized-config.sh"
extract_function check_active_image_identity >"$TMP_DIR/check-active-image-identity.sh"
source "$TMP_DIR/check-active-image-identity.sh"
extract_function record_authorization_boundary >"$TMP_DIR/record-authorization-boundary.sh"
source "$TMP_DIR/record-authorization-boundary.sh"
extract_function print_authorization_boundary >"$TMP_DIR/print-authorization-boundary.sh"
source "$TMP_DIR/print-authorization-boundary.sh"

local_file="$TMP_DIR/local"
printf 'example\n' >"$local_file"

result=""
record() {
  result="$1:$2"
}
drift() {
  record WARNING "Approved readiness transition: $1"
}
remote() {
  local command="$1"
  case "$scenario" in
    absent)
      [[ "$command" == "cat /optional" ]] && return 1
      [[ "$command" == "test ! -e '/optional' && test ! -L '/optional'" ]] && return 0
      return 1
      ;;
    unreadable)
      [[ "$command" == "cat /optional" ]] && return 1
      [[ "$command" == "test ! -e '/optional' && test ! -L '/optional'" ]] && return 1
      return 1
      ;;
    transport_failed)
      return 255
      ;;
  esac
}

scenario=absent
compare_normalized_file_to_remote_command "Optional configuration" "$local_file" "cat /optional" "/optional"
[[ "$result" == "WARNING:Approved readiness transition: Optional configuration active configuration differs from live configuration" ]]

scenario=unreadable
result=""
compare_normalized_file_to_remote_command "Optional configuration" "$local_file" "cat /optional" "/optional"
[[ "$result" == "FAIL:Unable to read live Optional configuration" ]]

scenario=transport_failed
result=""
compare_normalized_file_to_remote_command "Optional configuration" "$local_file" "cat /optional" "/optional"
[[ "$result" == "FAIL:Unable to read live Optional configuration" ]]

PREFLIGHT_MODE=--readiness
scenario=active_absent
remote() {
  case "$scenario:$1" in
    active_absent:sudo\ -n\ /usr/local/libexec/nextcloud-pi-validate-active-images) return 1 ;;
    active_absent:sudo\ -n\ test\ !\ -e\ /etc/nextcloud-pi/active-images.env\ \&\&\ sudo\ -n\ test\ !\ -L\ /etc/nextcloud-pi/active-images.env) return 0 ;;
    active_invalid:sudo\ -n\ /usr/local/libexec/nextcloud-pi-validate-active-images) return 1 ;;
    active_invalid:sudo\ -n\ test\ !\ -e\ /etc/nextcloud-pi/active-images.env\ \&\&\ sudo\ -n\ test\ !\ -L\ /etc/nextcloud-pi/active-images.env) return 1 ;;
    active_recovered:sudo\ -n\ /usr/local/libexec/nextcloud-pi-validate-active-images) return 0 ;;
    active_recovered:sudo\ -n\ awk*) printf 'recovered\n'; return 0 ;;
    *) return 1 ;;
  esac
}
result=""
check_active_image_identity
[[ "$result" == "WARNING:Active image record is absent; this is reviewed safety-baseline drift" ]]
scenario=active_invalid
result=""
check_active_image_identity
[[ "$result" == "FAIL:Protected active image record is invalid, unreadable, or differs" ]]
scenario=active_recovered
result=""
check_active_image_identity
[[ "$result" == "FAIL:Protected active-image record is recovered; readiness requires source mode" ]]

PREFLIGHT_MODE=--conformance
ENV_PREPARED=1
SECRETS_MIGRATED=1
result=""
record_authorization_boundary
[[ -z "$result" ]]
[[ "$(print_authorization_boundary)" == *"Hardened deployment conformance passed."* ]]
[[ "$(print_authorization_boundary)" != *"remain blocked"* ]]

PREFLIGHT_MODE=--readiness
result=""
record_authorization_boundary
[[ "$result" == "WARNING:Phase 1 secret migration is prepared; Phase 2 deployment and any restart still require validation, rollback planning, and explicit approval" ]]
[[ "$(print_authorization_boundary)" == *"remain blocked"* ]]

scenario=launcher_prerequisites
captured_command=""
remote() {
  captured_command="$1"
  [[ "$scenario" == launcher_prerequisites ]]
}
launcher_prerequisites_remote
[[ "$captured_command" == *"command -v python3"* ]]
[[ "$captured_command" == *"docker compose up --help"*"--pull"* ]]
[[ "$captured_command" == *"config --format json"* ]]
scenario=launcher_prerequisites_missing
if launcher_prerequisites_remote; then
  echo 'launcher prerequisite failure was ignored' >&2
  exit 1
fi
echo 'preflight active-image regression tests passed'
