#!/usr/bin/env bash
set -euo pipefail

# Controlled configuration deployment. --plan is Pi-read-only and produces an
# expiring approval artifact; --apply consumes that exact artifact before any
# remote mutation. Runtime recovery and image import remain separate approvals.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
source "$SCRIPT_DIR/lib/image-lock.sh"
source "$SCRIPT_DIR/lib/active-images.sh"
source "$SCRIPT_DIR/lib/launcher-prerequisites.sh"
source "$SCRIPT_DIR/lib/deployment-transaction.sh"
load_deployment_config "$REPOSITORY_ROOT"
image_lock_load "$REPOSITORY_ROOT"
readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
readonly APPROVAL_ROOT="${NEXTCLOUD_DEPLOY_APPROVAL_ROOT:-$HOME/nextcloud-pi-deploy-approvals}"
MODE="${1:-}"
ARTIFACT=""
CONFIG_BACKUP=""
RUNTIME_BACKUP=""
IMAGE_RECOVERY=""
case "$MODE" in
  --plan) CONFIG_BACKUP="${2:-}"; RUNTIME_BACKUP="${3:-}"; IMAGE_RECOVERY="${4:-}" ;;
  --apply) ARTIFACT="${2:-}"; CONFIG_BACKUP="${3:-}"; RUNTIME_BACKUP="${4:-}"; IMAGE_RECOVERY="${5:-}" ;;
esac
TMP_DIR="$(mktemp -d)"
CONSUME_LOCK=""
cleanup() {
  [[ -z "$CONSUME_LOCK" || ! -d "$CONSUME_LOCK" ]] || rmdir "$CONSUME_LOCK" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
die() { printf 'Deployment failed: %s\n' "$1" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"; }
remote_file_hash() {
  local path="$1" result digest remainder
  case "$path" in
    /etc/*|/usr/local/libexec/*)
      result="$(remote "set -eu; if sudo -n test -L '$path'; then exit 1; elif sudo -n test -f '$path'; then sudo -n sha256sum '$path'; elif sudo -n test ! -e '$path'; then printf 'missing\\n'; else exit 1; fi" </dev/null)" || return 1
      ;;
    *)
      result="$(remote "set -eu; if test -L '$path'; then exit 1; elif test -f '$path'; then sha256sum '$path'; elif test ! -e '$path'; then printf 'missing\\n'; else exit 1; fi" </dev/null)" || return 1
      ;;
  esac
  if [[ "$result" == missing ]]; then
    printf '%s\n' missing
    return
  fi
  [[ "$result" != *$'\n'* ]] || return 1
  read -r digest remainder <<<"$result"
  [[ "$digest" =~ ^[0-9a-f]{64}$ && -n "$remainder" ]] || return 1
  printf '%s\n' "$digest"
}
remote_env_valid() {
  remote "set -eu; env_file='$NEXTCLOUD_REMOTE_PROJECT_DIR/.env'; test -f \"\$env_file\" && test ! -L \"\$env_file\" && test \"\$(stat -c '%a' \"\$env_file\")\" = 600; awk -F= '
    BEGIN { expected[\"MYSQL_ROOT_PASSWORD\"] = 1; expected[\"MYSQL_PASSWORD\"] = 1; expected[\"MYSQL_DATABASE\"] = 1; expected[\"MYSQL_USER\"] = 1; quote = sprintf(\"%c\", 39); invalid = 0 }
    { separator = index(\$0, \"=\"); value = substr(\$0, separator + 1); if (separator == 0 || !(\$1 in expected) || seen[\$1]++ || length(value) < 3 || substr(value, 1, 1) != quote || substr(value, length(value), 1) != quote) invalid = 1 }
    END { for (key in expected) if (!seen[key]) invalid = 1; exit invalid }
  ' \"\$env_file\""
}
require_identity_and_images() {
  local active_mode
  remote "set -eu; test \"\$(hostname)\" = '$NEXTCLOUD_PI_SYSTEM_HOSTNAME'; test \"\$(id -un)\" = '$NEXTCLOUD_PI_USER'" || die "target identity check failed"
  launcher_prerequisites_remote || die "launcher Compose/Python support failed"
  if remote "test -f /etc/nextcloud-pi/active-images.env && test ! -L /etc/nextcloud-pi/active-images.env" >/dev/null 2>&1; then
    remote "sudo -n /usr/local/libexec/nextcloud-pi-validate-active-images" || die "active image identity check failed"
    active_mode="$(remote "sudo -n awk -F= '\$1 == \"NEXTCLOUD_ACTIVE_IMAGES_MODE\" { print \$2 }' /etc/nextcloud-pi/active-images.env")"
    [[ "$active_mode" == source ]] || die "a recovered active-image record requires a separately approved recovery transition before configuration deployment"
  else
    while IFS= read -r tag; do
      [[ "$(remote "docker image inspect --format '{{.Id}}' '$tag'" </dev/null)" == "$(image_lock_expected_id "$tag")" ]] || die "source image lock check failed: $tag"
    done < <(image_lock_tags)
  fi
}
render() { "$SCRIPT_DIR/render-deployment-config.sh" --output-dir "$TMP_DIR/rendered"; }
candidate_hash() {
  cat "$TMP_DIR/rendered/docker-compose.yml" "$TMP_DIR/rendered/caddy/Caddyfile" \
    "$TMP_DIR/rendered/systemd/nextcloud.service" \
    "$TMP_DIR/rendered/systemd/docker.service.d/nextcloud-storage.conf" \
    "$TMP_DIR/rendered/launcher/nextcloud-pi-compose-start" \
    "$TMP_DIR/rendered/launcher/nextcloud-pi-validate-active-images" \
    "$TMP_DIR/rendered/active-images/active-images.env" \
    "$SCRIPT_DIR/lib/atomic-transaction.sh" \
    "$SCRIPT_DIR/lib/deployment-transaction.sh" \
    "$REPOSITORY_ROOT/config/image-lock.env" >"$TMP_DIR/candidate"
  sha256 "$TMP_DIR/candidate"
}
prestate_hash() {
  local path digest prestate_file="$TMP_DIR/prestate"
  : >"$prestate_file"
  while IFS= read -r path; do
    digest="$(remote_file_hash "$path")" || return 1
    printf '%s  %s\n' "$digest" "$path" >>"$prestate_file"
  done <<EOF
$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml
$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile
/etc/systemd/system/nextcloud.service
/etc/systemd/system/docker.service.d/nextcloud-storage.conf
/usr/local/libexec/nextcloud-pi-compose-start
/usr/local/libexec/nextcloud-pi-validate-active-images
/etc/nextcloud-pi/active-images.env
EOF
  sha256 "$prestate_file"
}
artifact_value() {
  local key="$1"
  awk -F $'\t' -v key="$key" '$1 == key { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$ARTIFACT"
}
artifact_age_ok() {
  local manifest="$1" timestamp now then
  timestamp="$(awk -F $'\t' '$1 == "timestamp" { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$manifest")" || return 1
  now="$(date -u +%s)"
  then="$(python3 -c 'import calendar,sys,time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y%m%dT%H%M%SZ")))' "$timestamp" 2>/dev/null)" || return 1
  [[ "$then" =~ ^[0-9]+$ ]] && (( then <= now && now - then <= 3600 ))
}
manifest_value() {
  local manifest="$1" key="$2"
  awk -F $'\t' -v key="$key" '$1 == key { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$manifest"
}
clock_skew_ok() {
  local local_epoch="$1" remote_epoch="$2" delta
  [[ "$local_epoch" =~ ^[0-9]+$ && "$remote_epoch" =~ ^[0-9]+$ ]] || return 1
  delta=$((local_epoch - remote_epoch)); (( delta < 0 )) && delta=$((-delta))
  (( delta <= 60 ))
}
require_recovery_artifacts() {
  [[ -n "$CONFIG_BACKUP" && -n "$RUNTIME_BACKUP" && -n "$IMAGE_RECOVERY" ]] || die "verified configuration, runtime, and image recovery artifacts are required"
  "$SCRIPT_DIR/verify-config-backup.sh" "$CONFIG_BACKUP" >/dev/null
  "$SCRIPT_DIR/verify-runtime-backup.sh" "$RUNTIME_BACKUP" >/dev/null
  "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$IMAGE_RECOVERY" >/dev/null
  artifact_age_ok "$CONFIG_BACKUP/manifest.tsv" || die "configuration backup is not fresh"
  artifact_age_ok "$RUNTIME_BACKUP/manifest.tsv" || die "runtime backup is not fresh"
  artifact_age_ok "$IMAGE_RECOVERY/manifest.tsv" || die "image recovery archive is not fresh"
  artifact_age_ok "$IMAGE_RECOVERY/restore-attestation.tsv" || die "image restore attestation is not fresh"
  [[ "$(manifest_value "$CONFIG_BACKUP/manifest.tsv" remote_host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(manifest_value "$CONFIG_BACKUP/manifest.tsv" remote_user)" == "$NEXTCLOUD_PI_USER" && "$(manifest_value "$CONFIG_BACKUP/manifest.tsv" source_project)" == "$NEXTCLOUD_REMOTE_PROJECT_DIR" ]] || die "configuration backup is not bound to this Pi"
  [[ "$(manifest_value "$RUNTIME_BACKUP/manifest.tsv" remote_host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(manifest_value "$RUNTIME_BACKUP/manifest.tsv" remote_user)" == "$NEXTCLOUD_PI_USER" && "$(manifest_value "$RUNTIME_BACKUP/manifest.tsv" source_nextcloud)" == "$NEXTCLOUD_STORAGE_MOUNT/nextcloud" ]] || die "runtime backup is not bound to this Pi"
  [[ "$(manifest_value "$IMAGE_RECOVERY/manifest.tsv" remote_host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(manifest_value "$IMAGE_RECOVERY/manifest.tsv" remote_user)" == "$NEXTCLOUD_PI_USER" && "$(manifest_value "$IMAGE_RECOVERY/manifest.tsv" source_project)" == "$NEXTCLOUD_REMOTE_PROJECT_DIR" && "$(manifest_value "$IMAGE_RECOVERY/manifest.tsv" storage_mount)" == "$NEXTCLOUD_STORAGE_MOUNT" && "$(manifest_value "$IMAGE_RECOVERY/manifest.tsv" platform)" == "$NEXTCLOUD_IMAGE_PLATFORM" ]] || die "image recovery archive is not bound to this Pi"
}
require_config_rollback_backup() {
  [[ "$(sha256 "$CONFIG_BACKUP/compose/docker-compose.yml")" == "$(remote_file_hash "$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml")" && "$(sha256 "$CONFIG_BACKUP/caddy/Caddyfile")" == "$(remote_file_hash "$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile")" ]] || die "verified configuration backup does not match the current Compose and Caddy pre-state"
}
redacted_plan_diff() {
  local candidate remote_hash
  printf 'Redacted candidate transition:\n'
  printf '  active mode: source\n  target: %s\n  source-lock SHA-256: %s\n' "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$(sha256 "$REPOSITORY_ROOT/config/image-lock.env")"
  while IFS= read -r candidate; do printf '  allowed tag: %s\n' "$candidate"; done < <(image_lock_tags)
  printf '  actions: install-safety-baseline, replace-compose-caddy, daemon-reload, restart, health-check, configuration-rollback\n'
  printf '  exclusions: .env, runtime-data, volumes, images, pulls, pruning, image-removal, runtime-recovery\n'
  printf '  files (live SHA-256 -> candidate SHA-256):\n'
  while IFS=$'\t' read -r label remote_path local_path; do
    remote_hash="$(remote_file_hash "$remote_path")"
    printf '    %s: %s -> %s\n' "$label" "$remote_hash" "$(sha256 "$local_path")"
  done <<EOF
Compose	$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml	$TMP_DIR/rendered/docker-compose.yml
Caddyfile	$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile	$TMP_DIR/rendered/caddy/Caddyfile
launcher	/usr/local/libexec/nextcloud-pi-compose-start	$TMP_DIR/rendered/launcher/nextcloud-pi-compose-start
active-record	/etc/nextcloud-pi/active-images.env	$TMP_DIR/rendered/active-images/active-images.env
Nextcloud-unit	/etc/systemd/system/nextcloud.service	$TMP_DIR/rendered/systemd/nextcloud.service
Docker-drop-in	/etc/systemd/system/docker.service.d/nextcloud-storage.conf	$TMP_DIR/rendered/systemd/docker.service.d/nextcloud-storage.conf
EOF
}
plan() {
  render
  require_identity_and_images
  active_images_validate_file "$TMP_DIR/rendered/active-images/active-images.env" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$NEXTCLOUD_REMOTE_PROJECT_DIR" "$NEXTCLOUD_STORAGE_MOUNT"
  require_recovery_artifacts
  remote_env_valid || die "Pi-only .env protections or key set failed"
  require_config_rollback_backup
  remote "cd '$NEXTCLOUD_REMOTE_PROJECT_DIR' && docker compose -f - config >/dev/null" <"$TMP_DIR/rendered/docker-compose.yml" || die "candidate Compose validation failed"
  remote "docker exec -i nextcloud-docker-caddy-1 caddy adapt --config /dev/stdin --adapter caddyfile >/dev/null 2>&1" <"$TMP_DIR/rendered/caddy/Caddyfile" || die "candidate Caddy validation failed"
  grep -Fq 'RequiresMountsFor=' "$TMP_DIR/rendered/systemd/nextcloud.service" && grep -Fq 'RequiresMountsFor=' "$TMP_DIR/rendered/systemd/docker.service.d/nextcloud-storage.conf" || die "invalid mount-gate candidates"
  bash -n "$TMP_DIR/rendered/launcher/nextcloud-pi-compose-start" || die "launcher syntax is invalid"
  mkdir -p "$APPROVAL_ROOT"; chmod 700 "$APPROVAL_ROOT"
  local now remote_now expiry fingerprint artifact prestate
  now="$(date -u +%s)"; remote_now="$(remote 'date -u +%s')"; clock_skew_ok "$now" "$remote_now" || die "local and Pi clocks differ by more than 60 seconds"
  expiry=$((now + 900)); fingerprint="$(candidate_hash)"; prestate="$(prestate_hash)"
  artifact="$APPROVAL_ROOT/approval-$fingerprint-$now.tsv"
  { printf 'format\tdeploy-approval-v1\nstate\tunused\nfingerprint\t%s\ncandidate_sha256\t%s\nprestate_sha256\t%s\nsource_lock_sha256\t%s\nconfig_manifest_sha256\t%s\nconfig_compose_sha256\t%s\nconfig_caddy_sha256\t%s\nruntime_manifest_sha256\t%s\nimage_manifest_sha256\t%s\nimage_attestation_sha256\t%s\nactions\tinstall-safety-baseline,replace-compose-caddy,daemon-reload,restart,health-check,configuration-rollback\nexclusions\t.env,runtime-data,volumes,images,pulls,pruning,image-removal,runtime-recovery\ncreated\t%s\nremote_created\t%s\nexpires\t%s\nhost\t%s\n' "$fingerprint" "$fingerprint" "$prestate" "$(sha256 "$REPOSITORY_ROOT/config/image-lock.env")" "$(sha256 "$CONFIG_BACKUP/manifest.tsv")" "$(sha256 "$CONFIG_BACKUP/compose/docker-compose.yml")" "$(sha256 "$CONFIG_BACKUP/caddy/Caddyfile")" "$(sha256 "$RUNTIME_BACKUP/manifest.tsv")" "$(sha256 "$IMAGE_RECOVERY/manifest.tsv")" "$(sha256 "$IMAGE_RECOVERY/restore-attestation.tsv")" "$now" "$remote_now" "$expiry" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME"; } >"$artifact"; chmod 600 "$artifact"
  redacted_plan_diff
  printf 'Plan ready. Approval artifact: %s\nFingerprint: %s\nExpires (UTC epoch): %s\n' "$artifact" "$fingerprint" "$expiry"
}
deployment_safety_validate() {
  remote "set -eu
    test -f '$stage/nextcloud.service' && test -f '$stage/nextcloud-storage.conf' && test -f '$stage/nextcloud-pi-compose-start' && test -f '$stage/nextcloud-pi-validate-active-images' && test -f '$stage/active-images.env' && test -f '$stage/atomic-transaction.sh'
    grep -Fx 'RequiresMountsFor=$NEXTCLOUD_STORAGE_MOUNT' '$stage/nextcloud.service'
    grep -Fx 'RequiresMountsFor=$NEXTCLOUD_STORAGE_MOUNT' '$stage/nextcloud-storage.conf'
    grep -Fx 'ExecStart=/usr/local/libexec/nextcloud-pi-compose-start' '$stage/nextcloud.service'
    bash -n '$stage/nextcloud-pi-compose-start'
    bash -n '$stage/nextcloud-pi-validate-active-images'
    grep -Fx 'NEXTCLOUD_ACTIVE_IMAGES_MODE=source' '$stage/active-images.env'
    mkdir -m 0700 '$stage/systemd-verify'
    sed 's|^ExecStart=/usr/local/libexec/nextcloud-pi-compose-start$|ExecStart=$stage/nextcloud-pi-compose-start|' '$stage/nextcloud.service' >'$stage/systemd-verify/nextcloud.service'
    test \"\$(grep -Fxc 'ExecStart=$stage/nextcloud-pi-compose-start' '$stage/systemd-verify/nextcloud.service')\" = 1
    test \"\$(grep -Fxc 'ExecStart=/usr/local/libexec/nextcloud-pi-compose-start' '$stage/systemd-verify/nextcloud.service')\" = 0
    chmod 0700 '$stage/nextcloud-pi-compose-start' '$stage/nextcloud-pi-validate-active-images'
    sudo -n systemd-analyze verify '$stage/systemd-verify/nextcloud.service'
  "
}
deployment_safety_install() {
  remote "set -eu
    if ! test -d /etc/systemd/system/docker.service.d; then printf '%s\n' created >'$stage/created-docker-dropin-parent'; sudo -n mkdir -p /etc/systemd/system/docker.service.d; fi
    if ! test -d /etc/nextcloud-pi; then printf '%s\n' created >'$stage/created-active-parent'; sudo -n mkdir -p /etc/nextcloud-pi; fi
    if ! test -d /usr/local/libexec; then printf '%s\n' created >'$stage/created-launcher-parent'; sudo -n mkdir -p /usr/local/libexec; fi
    . '$stage/atomic-transaction.sh'
    for pair in nextcloud.service:/etc/systemd/system/nextcloud.service nextcloud-storage.conf:/etc/systemd/system/docker.service.d/nextcloud-storage.conf nextcloud-pi-compose-start:/usr/local/libexec/nextcloud-pi-compose-start nextcloud-pi-validate-active-images:/usr/local/libexec/nextcloud-pi-validate-active-images active-images.env:/etc/nextcloud-pi/active-images.env; do name=\${pair%%:*}; target=\${pair#*:}; if test -f \"\$target\" && test ! -L \"\$target\"; then sudo -n cp -p \"\$target\" '$stage/previous-'\"\$name\"; else printf '%s\n' absent >'$stage/previous-'\"\$name\"; fi; done
    atomic_install_root '$stage/nextcloud.service' /etc/systemd/system/nextcloud.service 0644
    atomic_install_root '$stage/nextcloud-storage.conf' /etc/systemd/system/docker.service.d/nextcloud-storage.conf 0644
    atomic_install_root '$stage/nextcloud-pi-compose-start' /usr/local/libexec/nextcloud-pi-compose-start 0700
    atomic_install_root '$stage/nextcloud-pi-validate-active-images' /usr/local/libexec/nextcloud-pi-validate-active-images 0700
    atomic_install_root '$stage/active-images.env' /etc/nextcloud-pi/active-images.env 0600
  "
}
deployment_safety_restore() {
  remote "set -eu; . '$stage/atomic-transaction.sh'; for pair in nextcloud.service:/etc/systemd/system/nextcloud.service nextcloud-storage.conf:/etc/systemd/system/docker.service.d/nextcloud-storage.conf nextcloud-pi-compose-start:/usr/local/libexec/nextcloud-pi-compose-start nextcloud-pi-validate-active-images:/usr/local/libexec/nextcloud-pi-validate-active-images active-images.env:/etc/nextcloud-pi/active-images.env; do name=\${pair%%:*}; target=\${pair#*:}; previous='$stage/previous-'\"\$name\"; if test -f \"\$previous\" && ! sudo -n grep -Fx absent \"\$previous\" >/dev/null 2>&1; then atomic_restore_root \"\$previous\" \"\$target\"; elif test -f \"\$previous\"; then sudo -n rm -f \"\$target\"; fi; done; if test -f '$stage/created-active-parent'; then sudo -n rmdir /etc/nextcloud-pi 2>/dev/null || true; fi; if test -f '$stage/created-launcher-parent'; then sudo -n rmdir /usr/local/libexec 2>/dev/null || true; fi; if test -f '$stage/created-docker-dropin-parent'; then sudo -n rmdir /etc/systemd/system/docker.service.d 2>/dev/null || true; fi"
}
deployment_daemon_reload() { remote "sudo -n systemctl daemon-reload"; }
deployment_application_install() {
  remote "set -eu
    test \"\$(sha256sum '$stage/rollback-compose.yml' | awk '{print \$1}')\" = '$(artifact_value config_compose_sha256)'
    test \"\$(sha256sum '$stage/rollback-Caddyfile' | awk '{print \$1}')\" = '$(artifact_value config_caddy_sha256)'
    . '$stage/atomic-transaction.sh'
    atomic_replace_preserve '$stage/docker-compose.yml' '$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml' 0644
    atomic_replace_preserve '$stage/Caddyfile' '$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile' 0644
  "
}
deployment_restart() { remote "sudo -n systemctl restart nextcloud.service"; }
deployment_health() { bash "$SCRIPT_DIR/health-check.sh"; }
deployment_application_restore() {
  remote "set -eu; . '$stage/atomic-transaction.sh'; test \"\$(sha256sum '$stage/rollback-compose.yml' | awk '{print \$1}')\" = '$(artifact_value config_compose_sha256)' && test \"\$(sha256sum '$stage/rollback-Caddyfile' | awk '{print \$1}')\" = '$(artifact_value config_caddy_sha256)'; atomic_replace_preserve '$stage/rollback-compose.yml' '$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml' 0644; atomic_replace_preserve '$stage/rollback-Caddyfile' '$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile' 0644"
}
deployment_rollback_health() { bash "$SCRIPT_DIR/health-check.sh" --caddyfile "$CONFIG_BACKUP/caddy/Caddyfile"; }
deployment_interrupted() {
  local status="$1" rollback_failed=0
  trap - HUP INT TERM
  if [[ "$TRANSACTION_PHASE" == application ]]; then
    deployment_application_restore || rollback_failed=1
    deployment_daemon_reload || rollback_failed=1
    deployment_restart || rollback_failed=1
  elif [[ "$TRANSACTION_PHASE" == safety ]]; then
    deployment_safety_restore || rollback_failed=1
    deployment_daemon_reload || rollback_failed=1
  fi
  if (( rollback_failed == 0 )); then
    remote "rm -rf '$stage'" || true
  else
    printf 'Deployment interrupted; rollback failed. Preserve remote recovery stage: %s\n' "$stage" >&2
  fi
  cleanup
  exit "$status"
}
apply() {
  [[ -n "$ARTIFACT" && -f "$ARTIFACT" && ! -L "$ARTIFACT" ]] || die "an unused approval artifact is required"
  [[ "$(artifact_value state)" == unused ]] || die "approval artifact was already consumed"
  [[ "$(artifact_value expires)" =~ ^[0-9]+$ ]] || die "approval artifact is invalid"
  (( $(date -u +%s) <= $(artifact_value expires) )) || die "approval artifact expired"
  render; require_identity_and_images; require_recovery_artifacts; remote_env_valid || die "Pi-only .env protections or key set failed"; require_config_rollback_backup
  active_images_validate_file "$TMP_DIR/rendered/active-images/active-images.env" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$NEXTCLOUD_REMOTE_PROJECT_DIR" "$NEXTCLOUD_STORAGE_MOUNT"
  [[ "$(artifact_value host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" ]] || die "approval artifact target differs"
  [[ "$(artifact_value candidate_sha256)" == "$(candidate_hash)" ]] || die "candidate changed after approval"
  [[ "$(artifact_value prestate_sha256)" == "$(prestate_hash)" ]] || die "live pre-state changed after approval"
  [[ "$(artifact_value source_lock_sha256)" == "$(sha256 "$REPOSITORY_ROOT/config/image-lock.env")" && "$(artifact_value config_manifest_sha256)" == "$(sha256 "$CONFIG_BACKUP/manifest.tsv")" && "$(artifact_value config_compose_sha256)" == "$(sha256 "$CONFIG_BACKUP/compose/docker-compose.yml")" && "$(artifact_value config_caddy_sha256)" == "$(sha256 "$CONFIG_BACKUP/caddy/Caddyfile")" && "$(artifact_value runtime_manifest_sha256)" == "$(sha256 "$RUNTIME_BACKUP/manifest.tsv")" && "$(artifact_value image_manifest_sha256)" == "$(sha256 "$IMAGE_RECOVERY/manifest.tsv")" && "$(artifact_value image_attestation_sha256)" == "$(sha256 "$IMAGE_RECOVERY/restore-attestation.tsv")" && "$(artifact_value actions)" == "install-safety-baseline,replace-compose-caddy,daemon-reload,restart,health-check,configuration-rollback" && "$(artifact_value exclusions)" == ".env,runtime-data,volumes,images,pulls,pruning,image-removal,runtime-recovery" ]] || die "recovery artifacts or deployment authority changed after approval"
  clock_skew_ok "$(date -u +%s)" "$(remote 'date -u +%s')" || die "local and Pi clocks differ by more than 60 seconds"
  # mkdir is atomic on the local filesystem. Recheck state while holding that
  # per-artifact lock so concurrent applies cannot both consume the approval.
  local consume_lock="$ARTIFACT.lock"
  CONSUME_LOCK="$consume_lock"
  mkdir -m 700 "$consume_lock" 2>/dev/null || die "approval artifact is being consumed or was already used"
  if [[ "$(artifact_value state)" != unused ]] || ! awk -F $'\t' '$1 == "state" && $2 == "unused" { count++ } END { exit count == 1 ? 0 : 1 }' "$ARTIFACT" || ! sed 's/^state\tunused$/state\tconsumed/' "$ARTIFACT" >"$ARTIFACT.consumed"; then
    rm -f "$ARTIFACT.consumed"; rmdir "$consume_lock" || true; CONSUME_LOCK=""
    die "approval artifact could not be atomically consumed"
  fi
  chmod 600 "$ARTIFACT.consumed"
  # chmod completed before the atomic rename, so the consumed record never has
  # weaker permissions than the protected approval it replaces.
  mv "$ARTIFACT.consumed" "$ARTIFACT"
  rmdir "$consume_lock"
  CONSUME_LOCK=""
  local fingerprint stage
  fingerprint="$(artifact_value fingerprint)"
  cp "$CONFIG_BACKUP/compose/docker-compose.yml" "$TMP_DIR/rollback-compose.yml"
  cp "$CONFIG_BACKUP/caddy/Caddyfile" "$TMP_DIR/rollback-Caddyfile"
  [[ "$(sha256 "$TMP_DIR/rollback-compose.yml")" == "$(artifact_value config_compose_sha256)" && "$(sha256 "$TMP_DIR/rollback-Caddyfile")" == "$(artifact_value config_caddy_sha256)" ]] || die "configuration rollback payload changed after approval"
  stage="$NEXTCLOUD_REMOTE_PROJECT_DIR/.deploy-stage-$fingerprint"
  remote "umask 077; test ! -e '$stage'; mkdir -m 0700 '$stage'" || die "could not create remote deployment staging"
  if ! scp -q "$TMP_DIR/rendered/systemd/nextcloud.service" "$TMP_DIR/rendered/systemd/docker.service.d/nextcloud-storage.conf" "$TMP_DIR/rendered/launcher/nextcloud-pi-compose-start" "$TMP_DIR/rendered/launcher/nextcloud-pi-validate-active-images" "$TMP_DIR/rendered/active-images/active-images.env" "$TMP_DIR/rendered/docker-compose.yml" "$TMP_DIR/rendered/caddy/Caddyfile" "$TMP_DIR/rollback-compose.yml" "$TMP_DIR/rollback-Caddyfile" "$SCRIPT_DIR/lib/atomic-transaction.sh" "$REMOTE:$stage/"; then
    remote "rm -rf '$stage'" || true
    die "remote staging failed after approval consumption"
  fi
  local transaction_status TRANSACTION_PHASE=safety
  trap 'deployment_interrupted 129' HUP
  trap 'deployment_interrupted 130' INT
  trap 'deployment_interrupted 143' TERM
  set +e
  deployment_run_safety_transaction
  transaction_status=$?
  set -e
  if (( transaction_status != 0 )); then
    trap 'cleanup; exit 129' HUP; trap 'cleanup; exit 130' INT; trap 'cleanup; exit 143' TERM
    if (( transaction_status != 1 )); then
      die "safety baseline rollback failed; preserve remote recovery stage $stage and recover manually"
    fi
    remote "rm -rf '$stage'" || true
    die "safety baseline installation failed after approval consumption"
  fi
  TRANSACTION_PHASE=application
  set +e
  deployment_run_application_transaction
  transaction_status=$?
  set -e
  if (( transaction_status != 0 )); then
    trap 'cleanup; exit 129' HUP; trap 'cleanup; exit 130' INT; trap 'cleanup; exit 143' TERM
    if (( transaction_status != 1 )); then
      die "configuration rollback failed; preserve remote recovery stage $stage and recover manually"
    fi
    remote "rm -rf '$stage'" || true
    die "application change rolled back; a new plan and approval are required"
  fi
  TRANSACTION_PHASE=""
  trap 'cleanup; exit 129' HUP; trap 'cleanup; exit 130' INT; trap 'cleanup; exit 143' TERM
  remote "rm -rf '$stage'" || die "deployment succeeded but staging cleanup failed"
  printf 'Deployment applied with consumed approval artifact: %s\n' "$ARTIFACT"
}
case "$MODE" in
  --plan) [[ $# -eq 4 ]] || die 'usage: deploy-config.sh --plan <config-backup> <runtime-backup> <image-recovery>'; plan ;;
  --apply) [[ $# -eq 5 ]] || die 'usage: deploy-config.sh --apply <approval-artifact> <config-backup> <runtime-backup> <image-recovery>'; apply ;;
  *) die 'usage: deploy-config.sh --plan <config-backup> <runtime-backup> <image-recovery> | --apply <approval-artifact> <config-backup> <runtime-backup> <image-recovery>' ;;
esac
