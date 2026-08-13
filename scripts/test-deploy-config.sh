#!/usr/bin/env bash
set -euo pipefail

# Offline regression guard for the transaction invariants. The full transaction
# requires an expressly approved Pi drill; CI verifies that future edits retain
# the critical no-replay, validation, atomic-replace, and rollback controls.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOYER="$SCRIPT_DIR/deploy-config.sh"

grep -Fq 'mkdir -m 700 "$consume_lock"' "$DEPLOYER"
grep -Fq 'chmod 600 "$ARTIFACT.consumed"' "$DEPLOYER"
grep -Fq 'candidate changed after approval' "$DEPLOYER"
grep -Fq 'live pre-state changed after approval' "$DEPLOYER"
grep -Fq 'recovery artifacts or deployment authority changed after approval' "$DEPLOYER"
grep -Fq 'local and Pi clocks differ by more than 60 seconds' "$DEPLOYER"
grep -Fq 'Redacted candidate transition:' "$DEPLOYER"
grep -Fq 'remote_file_hash "$remote_path"' "$DEPLOYER"
grep -Fq 'remote "docker image inspect --format '\''{{.Id}}'\'' '\''$tag'\''" </dev/null' "$DEPLOYER"
grep -Fq '/etc/*|/usr/local/libexec/*)' "$DEPLOYER"
grep -Fq "sudo -n sha256sum '\$path'" "$DEPLOYER"
grep -Fq 'result="$(remote' "$DEPLOYER"
grep -Fq '[[ "$digest" =~ ^[0-9a-f]{64}$ && -n "$remainder" ]]' "$DEPLOYER"
grep -Fq 'prestate_hash()' "$DEPLOYER"
grep -Fq '</dev/null' "$DEPLOYER"
grep -Fq 'actions\tinstall-safety-baseline,replace-compose-caddy,daemon-reload,restart,health-check,configuration-rollback' "$DEPLOYER"
grep -Fq 'exclusions\t.env,runtime-data,volumes,images,pulls,pruning,image-removal,runtime-recovery' "$DEPLOYER"
grep -Fq 'image_attestation_sha256' "$DEPLOYER"
grep -Fq 'remote_env_valid()' "$DEPLOYER"
grep -Fq 'config_compose_sha256' "$DEPLOYER"
grep -Fq 'rollback-compose.yml' "$DEPLOYER"
grep -Fq 'configuration rollback payload changed after approval' "$DEPLOYER"
grep -Fq 'atomic_replace_preserve' "$DEPLOYER"
grep -Fq ". '\$stage/atomic-transaction.sh'" "$DEPLOYER"
grep -Fq 'docker compose -f - config' "$DEPLOYER"
grep -Fq "grep -Fx 'ExecStart=/usr/local/libexec/nextcloud-pi-compose-start'" "$DEPLOYER"
grep -Fq "sed 's|^ExecStart=/usr/local/libexec/nextcloud-pi-compose-start$|ExecStart=\$stage/nextcloud-pi-compose-start|'" "$DEPLOYER"
grep -Fq "systemd-analyze verify '\$stage/systemd-verify/nextcloud.service'" "$DEPLOYER"
grep -Fq 'mv -f' "$SCRIPT_DIR/lib/atomic-transaction.sh"
grep -Fq 'deployment_run_safety_transaction' "$DEPLOYER"
grep -Fq 'deployment_run_application_transaction' "$DEPLOYER"
grep -Fq 'deployment_application_restore' "$SCRIPT_DIR/lib/deployment-transaction.sh"
grep -Fq 'preserve remote recovery stage $stage' "$DEPLOYER"
grep -Fq 'application change rolled back' "$DEPLOYER"
grep -Fq 'bash "$SCRIPT_DIR/health-check.sh"' "$DEPLOYER"
grep -Fq -- '--caddyfile "$CONFIG_BACKUP/caddy/Caddyfile"' "$DEPLOYER"
[[ -x "$SCRIPT_DIR/test-deploy-transaction.sh" || -f "$SCRIPT_DIR/test-deploy-transaction.sh" ]]
grep -Fq 'nextcloud-pi-compose-start' "$DEPLOYER"
grep -Fq 'nextcloud-pi-validate-active-images' "$DEPLOYER"
grep -Fq 'active-images.env' "$DEPLOYER"
grep -Fq 'a recovered active-image record requires a separately approved recovery transition' "$DEPLOYER"
grep -Fq 'sudo -n /usr/local/libexec/nextcloud-pi-validate-active-images' "$DEPLOYER"
grep -Fq 'sudo -n awk -F=' "$DEPLOYER"
grep -Fq 'source "$SCRIPT_DIR/lib/launcher-prerequisites.sh"' "$DEPLOYER"
grep -Fq 'launcher_prerequisites_remote' "$DEPLOYER"
grep -Fq 'command -v python3' "$SCRIPT_DIR/lib/launcher-prerequisites.sh"
grep -Fq 'config --format json' "$SCRIPT_DIR/lib/launcher-prerequisites.sh"
grep -Fq '"$TMP_DIR/rendered/launcher/nextcloud-pi-validate-active-images"' "$DEPLOYER"
grep -Fq "atomic_install_root '\$stage/nextcloud-pi-validate-active-images' /usr/local/libexec/nextcloud-pi-validate-active-images 0700" "$DEPLOYER"
grep -Fq 'nextcloud-pi-validate-active-images:/usr/local/libexec/nextcloud-pi-validate-active-images' "$DEPLOYER"
grep -Fq 'atomic_restore_root \"\$previous\" \"\$target\"' "$DEPLOYER"
grep -Fq 'created-docker-dropin-parent' "$DEPLOYER"
grep -Fq 'consumed disposable approval cannot be replayed' "$SCRIPT_DIR/test-deploy-transaction.sh"
grep -Fq 'missing mount failure' "$SCRIPT_DIR/test-deploy-transaction.sh"
grep -Fq 'privileged atomic replacement preserved ownership and rollback under a root-owned parent' "$SCRIPT_DIR/test-deploy-transaction.sh"
grep -Fq '. "$helper_path"' "$SCRIPT_DIR/test-deploy-transaction.sh"
grep -Fq 'command -v bash >/dev/null' "$SCRIPT_DIR/test-deploy-transaction.sh"
grep -Fq '"$REMOTE" bash -s --' "$SCRIPT_DIR/test-deploy-transaction.sh"

extract_function() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\) \\{" { capture = 1 } capture { print } capture && $0 == "}" { exit }' "$DEPLOYER"
}

# Exercise the actual redacted-plan loop with a remote transport that drains
# its stdin. remote_file_hash must isolate SSH from the heredoc so all six
# closed-schema targets are still emitted.
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
extract_function remote_file_hash >"$TEST_DIR/remote-file-hash.sh"
extract_function redacted_plan_diff >"$TEST_DIR/redacted-plan-diff.sh"
extract_function artifact_age_ok >"$TEST_DIR/artifact-age-ok.sh"
extract_function clock_skew_ok >"$TEST_DIR/clock-skew-ok.sh"
source "$TEST_DIR/remote-file-hash.sh"
source "$TEST_DIR/redacted-plan-diff.sh"
source "$TEST_DIR/artifact-age-ok.sh"
source "$TEST_DIR/clock-skew-ok.sh"
TMP_DIR="$TEST_DIR"
NEXTCLOUD_REMOTE_PROJECT_DIR=/srv/nextcloud-docker
NEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-test
REPOSITORY_ROOT="$TEST_DIR"
mkdir -p "$TEST_DIR/config"
remote() {
  cat >/dev/null
  printf '%064d  %s\n' 0 mock-file
}
sha256() {
  printf '%064d\n' 1
}
image_lock_tags() {
  printf '%s\n' nextcloud:30 mariadb:11 caddy:2
}

# A protected hash must fail closed when sudo/read access fails; it must never
# be normalized to the explicit missing marker or an empty digest.
remote() {
  cat >/dev/null
  return 1
}
if remote_file_hash /etc/nextcloud-pi/active-images.env >/dev/null 2>&1; then
  echo 'protected hash unexpectedly tolerated a remote sudo/read failure' >&2
  exit 1
fi

remote() {
  cat >/dev/null
  printf '%064d  %s\n' 0 /etc/nextcloud-pi/active-images.env
}
[[ "$(remote_file_hash /etc/nextcloud-pi/active-images.env)" == "$(printf '%064d' 0)" ]]

remote() {
  cat >/dev/null
  printf '%064d' 0
}
plan_output="$(redacted_plan_diff)"
for label in Compose Caddyfile launcher active-record Nextcloud-unit Docker-drop-in; do
  [[ "$(grep -c "^    $label:" <<<"$plan_output")" == 1 ]]
done

timestamp_at_offset() {
  python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y%m%dT%H%M%SZ"))' "$1"
}
printf 'timestamp\t%s\n' "$(timestamp_at_offset -10)" >"$TEST_DIR/fresh-manifest.tsv"
printf 'timestamp\t%s\n' "$(timestamp_at_offset -7200)" >"$TEST_DIR/stale-manifest.tsv"
printf 'timestamp\t%s\n' "$(timestamp_at_offset 120)" >"$TEST_DIR/future-manifest.tsv"
artifact_age_ok "$TEST_DIR/fresh-manifest.tsv"
if artifact_age_ok "$TEST_DIR/stale-manifest.tsv" || artifact_age_ok "$TEST_DIR/future-manifest.tsv"; then
  echo 'artifact freshness accepted a stale or future timestamp' >&2
  exit 1
fi
clock_skew_ok 1000 1060
clock_skew_ok 1060 1000
if clock_skew_ok 1000 1061 || clock_skew_ok 1061 1000; then
  echo 'clock-skew limit accepted more than 60 seconds' >&2
  exit 1
fi
echo 'deployment transaction regression checks passed'
