#!/usr/bin/env bash
set -euo pipefail

# Routine deployment changes only deployment-user-owned config and the sealed
# active-image record. Root code is installed solely by the administrator flow.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
source "$SCRIPT_DIR/lib/image-lock.sh"
source "$SCRIPT_DIR/lib/active-images.sh"
source "$SCRIPT_DIR/lib/launcher-prerequisites.sh"
source "$SCRIPT_DIR/lib/deployment-transaction.sh"
load_deployment_config "$ROOT"; image_lock_load "$ROOT"
readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
readonly APPROVAL_ROOT="${NEXTCLOUD_DEPLOY_APPROVAL_ROOT:-$HOME/nextcloud-pi-deploy-approvals}"
MODE="${1:-}"; ARTIFACT="${2:-}"; CONFIG_BACKUP="${3:-}"; RUNTIME_BACKUP="${4:-}"; IMAGE_RECOVERY="${5:-}"
TMP_DIR="$(mktemp -d)"; TRANSACTION_ID=""; stage=""; PHASE=""; trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
die() { printf 'Deployment failed: %s\n' "$1" >&2; exit 1; }
usage() {
  printf 'Usage: %s --plan <config-backup> <runtime-backup> <image-recovery>\n       %s --apply <approval-artifact> <config-backup> <runtime-backup> <image-recovery>\n' "$0" "$0" >&2
}
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
size() { wc -c <"$1" | tr -d '[:space:]'; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"; }
value() { awk -F $'\t' -v key="$2" '$1 == key { n++; v=$2 } END { if (n == 1) print v; else exit 1 }' "$1"; }
artifact_value() { value "$ARTIFACT" "$1"; }
manifest_value() { awk -F $'\t' -v key="$2" '$1 == key { n++; v=$2 } END { if (n == 1) print v; else exit 1 }' "$1"; }
utc_epoch() {
  local timestamp="$1"
  date -u -j -f '%Y%m%dT%H%M%SZ' "$timestamp" +%s 2>/dev/null || date -u -d "$timestamp" +%s 2>/dev/null
}
require_fresh_manifest() {
  local manifest="$1" timestamp epoch now
  timestamp="$(manifest_value "$manifest" timestamp)"; [[ "$timestamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "backup timestamp is invalid"
  epoch="$(utc_epoch "$timestamp")" || die "backup timestamp cannot be parsed"; now="$(date -u +%s)"
  (( epoch <= now && now - epoch <= 3600 )) || die "backup is older than one hour"
}
remote_env_valid() {
  remote "set -eu; env_file='$NEXTCLOUD_REMOTE_PROJECT_DIR/.env'; test -f \"\$env_file\" && test ! -L \"\$env_file\" && test \"\$(stat -c '%a' \"\$env_file\")\" = 600; awk -F= '
    BEGIN { expected[\"MYSQL_ROOT_PASSWORD\"] = 1; expected[\"MYSQL_PASSWORD\"] = 1; expected[\"MYSQL_DATABASE\"] = 1; expected[\"MYSQL_USER\"] = 1; quote = sprintf(\"%c\", 39) }
    { separator = index(\$0, \"=\"); value = substr(\$0, separator + 1); if (separator == 0 || !(\$1 in expected) || seen[\$1]++ || length(value) < 3 || substr(value, 1, 1) != quote || substr(value, length(value), 1) != quote) invalid = 1 }
    END { for (key in expected) if (!seen[key]) invalid = 1; exit invalid }
  ' \"\$env_file\""
}
validate_candidate() {
  remote "cd '$NEXTCLOUD_REMOTE_PROJECT_DIR' && docker compose -f - config >/dev/null" <"$TMP_DIR/rendered/docker-compose.yml" || die "candidate Compose validation failed"
  remote "docker exec -i nextcloud-docker-caddy-1 caddy adapt --config /dev/stdin --adapter caddyfile >/dev/null 2>&1" <"$TMP_DIR/rendered/caddy/Caddyfile" || die "candidate Caddy validation failed"
  bash -n "$TMP_DIR/rendered/launcher/nextcloud-pi-compose-start" "$TMP_DIR/rendered/launcher/nextcloud-pi-validate-active-images" || die "candidate launcher syntax is invalid"
}
validate_recovery_inputs() {
  "$SCRIPT_DIR/verify-config-backup.sh" "$CONFIG_BACKUP" >/dev/null
  "$SCRIPT_DIR/verify-runtime-backup.sh" "$RUNTIME_BACKUP" >/dev/null
  "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$IMAGE_RECOVERY" >/dev/null
  require_fresh_manifest "$CONFIG_BACKUP/manifest.tsv"
  require_fresh_manifest "$RUNTIME_BACKUP/manifest.tsv"
  require_fresh_manifest "$IMAGE_RECOVERY/manifest.tsv"
  require_fresh_manifest "$IMAGE_RECOVERY/restore-attestation.tsv"
  [[ "$(manifest_value "$CONFIG_BACKUP/manifest.tsv" remote_host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(manifest_value "$CONFIG_BACKUP/manifest.tsv" remote_user)" == "$NEXTCLOUD_PI_USER" && "$(manifest_value "$CONFIG_BACKUP/manifest.tsv" source_project)" == "$NEXTCLOUD_REMOTE_PROJECT_DIR" ]] || die "configuration backup is not bound to this Pi"
  [[ "$(manifest_value "$RUNTIME_BACKUP/manifest.tsv" remote_host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(manifest_value "$RUNTIME_BACKUP/manifest.tsv" remote_user)" == "$NEXTCLOUD_PI_USER" && "$(manifest_value "$RUNTIME_BACKUP/manifest.tsv" source_nextcloud)" == "$NEXTCLOUD_STORAGE_MOUNT/nextcloud" ]] || die "runtime backup is not bound to this Pi"
  [[ "$(manifest_value "$IMAGE_RECOVERY/manifest.tsv" remote_host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(manifest_value "$IMAGE_RECOVERY/manifest.tsv" remote_user)" == "$NEXTCLOUD_PI_USER" && "$(manifest_value "$IMAGE_RECOVERY/manifest.tsv" source_project)" == "$NEXTCLOUD_REMOTE_PROJECT_DIR" && "$(manifest_value "$IMAGE_RECOVERY/manifest.tsv" storage_mount)" == "$NEXTCLOUD_STORAGE_MOUNT" && "$(manifest_value "$IMAGE_RECOVERY/manifest.tsv" platform)" == "$NEXTCLOUD_IMAGE_PLATFORM" ]] || die "image recovery archive is not bound to this Pi"
  CONFIG_MANIFEST_SHA256="$(sha256 "$CONFIG_BACKUP/manifest.tsv")"
  RUNTIME_MANIFEST_SHA256="$(sha256 "$RUNTIME_BACKUP/manifest.tsv")"
  IMAGE_MANIFEST_SHA256="$(sha256 "$IMAGE_RECOVERY/manifest.tsv")"
  IMAGE_ATTESTATION_SHA256="$(sha256 "$IMAGE_RECOVERY/restore-attestation.tsv")"
}
verify_config_prestate() {
  [[ "$(sha256 "$CONFIG_BACKUP/compose/docker-compose.yml")" == "$(remote "sha256sum '$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml'" | awk '{print $1}')" ]] || die "configuration backup Compose file is not the live pre-state"
  [[ "$(sha256 "$CONFIG_BACKUP/caddy/Caddyfile")" == "$(remote "sha256sum '$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile'" | awk '{print $1}')" ]] || die "configuration backup Caddyfile is not the live pre-state"
}
approval_fingerprint() {
  local candidate="$1" prestate="$2" created="$3" remote_created="$4" expires="$5"
  printf 'transaction_id\t%s\ncandidate_sha256\t%s\nprestate_sha256\t%s\nbundle_manifest_sha256\t%s\nconfig_manifest_sha256\t%s\nruntime_manifest_sha256\t%s\nimage_manifest_sha256\t%s\nimage_attestation_sha256\t%s\nhost\t%s\ncreated\t%s\nremote_created\t%s\nexpires\t%s\n' "$TRANSACTION_ID" "$candidate" "$prestate" "$(sha256 "$(bundle_manifest)")" "$CONFIG_MANIFEST_SHA256" "$RUNTIME_MANIFEST_SHA256" "$IMAGE_MANIFEST_SHA256" "$IMAGE_ATTESTATION_SHA256" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$created" "$remote_created" "$expires" >"$TMP_DIR/approval-authority.tsv"
  sha256 "$TMP_DIR/approval-authority.tsv"
}
validate_approval_artifact() {
  awk -F '\t' '
    BEGIN { split("format state transaction_id fingerprint candidate_sha256 prestate_sha256 bundle_manifest_sha256 config_manifest_sha256 runtime_manifest_sha256 image_manifest_sha256 image_attestation_sha256 created remote_created expires host actions exclusions", keys, " "); for (i in keys) expected[keys[i]] = 1 }
    NF != 2 || !($1 in expected) || seen[$1]++ { bad = 1 }
    END { for (key in expected) if (seen[key] != 1) bad = 1; exit bad }
  ' "$ARTIFACT" || die "approval schema is invalid"
}
render() { "$SCRIPT_DIR/render-deployment-config.sh" --output-dir "$TMP_DIR/rendered"; }
bundle_manifest() {
  local out="$TMP_DIR/bundle.tsv" kind logical source installed mode digest file
  printf 'format\tnextcloud-pi-bundle-manifest-v1\nversion\t1\n' >"$out"
  while IFS=$'\t' read -r kind logical source installed mode digest; do
    [[ "$kind" == file ]] || continue
    case "$logical" in privileged-helper) file="$ROOT/privileged/nextcloud-pi-ops";; active-image-validator) file="$TMP_DIR/rendered/launcher/nextcloud-pi-validate-active-images";; compose-launcher) file="$TMP_DIR/rendered/launcher/nextcloud-pi-compose-start";; nextcloud-unit) file="$TMP_DIR/rendered/systemd/nextcloud.service";; docker-storage-drop-in) file="$TMP_DIR/rendered/systemd/docker.service.d/nextcloud-storage.conf";; *) die "unknown bundle entry";; esac
    printf 'file\t%s\t%s\t%s\t%s\t%s\n' "$logical" "$source" "$installed" "$mode" "$(sha256 "$file")" >>"$out"
  done <"$ROOT/privileged/bundle-manifest.tsv"
  printf '%s' "$out"
}
require_interface() {
  local output expected mode
  remote "test \"\$(hostname)\" = '$NEXTCLOUD_PI_SYSTEM_HOSTNAME' && test \"\$(id -un)\" = '$NEXTCLOUD_PI_USER'" || die "target identity differs"
  output="$(remote "sudo -n /usr/local/libexec/nextcloud-pi-ops version")" || die "privileged interface is absent; run administrator install"
  expected="$(sha256 "$(bundle_manifest)")"
  [[ "$(awk -F $'\t' '$1 == "version" {print $2}' <<<"$output")" == 1 && "$(awk -F $'\t' '$1 == "manifest_sha256" {print $2}' <<<"$output")" == "$expected" ]] || die "installed privileged bundle differs; run administrator upgrade"
  remote "sudo -n /usr/local/libexec/nextcloud-pi-ops check" >/dev/null || die "privileged interface check failed"
  output="$(remote "sudo -n /usr/local/libexec/nextcloud-pi-ops active-images-state")" || die "active image record is invalid"
  mode="$(awk -F $'\t' '$1 == "mode" {print $2}' <<<"$output")"; [[ "$mode" == source ]] || die "recovered active image record requires recovery approval"
  launcher_prerequisites_remote || die "launcher prerequisites failed"
}
candidate_hash() { cat "$TMP_DIR/rendered/docker-compose.yml" "$TMP_DIR/rendered/caddy/Caddyfile" "$TMP_DIR/rendered/active-images/active-images.env" "$(bundle_manifest)" "$ROOT/config/image-lock.env" >"$TMP_DIR/candidate"; printf '%s\n' "$TRANSACTION_ID" >>"$TMP_DIR/candidate"; sha256 "$TMP_DIR/candidate"; }
prestate_hash() { local out="$TMP_DIR/prestate" logical output; : >"$out"; for logical in nextcloud-unit docker-storage-drop-in compose-launcher active-image-validator active-image-record privileged-helper privileged-policy sudoers-policy; do output="$(remote "sudo -n /usr/local/libexec/nextcloud-pi-ops protected-state '$logical'")" || return 1; printf '%s\t%s\n' "$(awk -F $'\t' '$1 == "sha256" {print $2}' <<<"$output")" "$logical" >>"$out"; done; for file in docker-compose.yml caddy/Caddyfile; do remote "sha256sum '$NEXTCLOUD_REMOTE_PROJECT_DIR/$file'" >>"$out"; done; sha256 "$out"; }
consume() { local lock="$ARTIFACT.lock" temp="$ARTIFACT.consumed"; mkdir -m 700 "$lock" 2>/dev/null || die "approval is already consumed"; [[ "$(artifact_value state)" == unused ]] || die "approval is already consumed"; sed 's/^state\tunused$/state\tconsumed/' "$ARTIFACT" >"$temp"; chmod 600 "$temp"; mv "$temp" "$ARTIFACT"; rmdir "$lock"; }
deployment_active_prepare() { remote "sudo -n /usr/local/libexec/nextcloud-pi-ops active-record prepare '$TRANSACTION_ID' '$(sha256 "$TMP_DIR/rendered/active-images/active-images.env")' '$(size "$TMP_DIR/rendered/active-images/active-images.env")'" <"$TMP_DIR/rendered/active-images/active-images.env"; }
deployment_active_apply() { remote "sudo -n /usr/local/libexec/nextcloud-pi-ops active-record apply '$TRANSACTION_ID'"; }
deployment_active_rollback() { remote "sudo -n /usr/local/libexec/nextcloud-pi-ops active-record rollback '$TRANSACTION_ID'"; }
deployment_active_commit() { remote "sudo -n /usr/local/libexec/nextcloud-pi-ops active-record commit '$TRANSACTION_ID'"; }
deployment_application_install() { remote "set -eu; . '$stage/atomic-transaction.sh'; atomic_replace_preserve '$stage/docker-compose.yml' '$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml' 0644; atomic_replace_preserve '$stage/Caddyfile' '$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile' 0644"; }
deployment_application_restore() { remote "set -eu; . '$stage/atomic-transaction.sh'; atomic_replace_preserve '$stage/rollback-compose.yml' '$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml' 0644; atomic_replace_preserve '$stage/rollback-Caddyfile' '$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile' 0644"; }
deployment_restart() { remote "sudo -n /usr/local/libexec/nextcloud-pi-ops service restart"; }
deployment_health() { bash "$SCRIPT_DIR/health-check.sh"; }
deployment_rollback_health() { bash "$SCRIPT_DIR/health-check.sh" --caddyfile "$CONFIG_BACKUP/caddy/Caddyfile"; }
plan() {
  local now remote_now fingerprint artifact prestate candidate expires
  TRANSACTION_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"; render; require_interface; remote_env_valid || die "Pi-only .env protections or key set failed"; validate_candidate
  active_images_validate_file "$TMP_DIR/rendered/active-images/active-images.env" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$NEXTCLOUD_REMOTE_PROJECT_DIR" "$NEXTCLOUD_STORAGE_MOUNT"
  validate_recovery_inputs; verify_config_prestate
  now="$(date -u +%s)"; remote_now="$(remote 'date -u +%s')"; (( ${now#-} - ${remote_now#-} <= 60 && ${remote_now#-} - ${now#-} <= 60 )) || die "local and Pi clocks differ by more than 60 seconds"
  prestate="$(prestate_hash)"; candidate="$(candidate_hash)"; expires="$((now + 900))"; fingerprint="$(approval_fingerprint "$candidate" "$prestate" "$now" "$remote_now" "$expires")"; mkdir -p "$APPROVAL_ROOT"; chmod 700 "$APPROVAL_ROOT"; artifact="$APPROVAL_ROOT/approval-$fingerprint-$now.tsv"
  printf 'format\tdeploy-approval-v2\nstate\tunused\ntransaction_id\t%s\nfingerprint\t%s\ncandidate_sha256\t%s\nprestate_sha256\t%s\nbundle_manifest_sha256\t%s\nconfig_manifest_sha256\t%s\nruntime_manifest_sha256\t%s\nimage_manifest_sha256\t%s\nimage_attestation_sha256\t%s\ncreated\t%s\nremote_created\t%s\nexpires\t%s\nhost\t%s\nactions\tseal-active-record,replace-compose-caddy,restart,health-check,rollback\nexclusions\t.env,runtime-data,volumes,images,pulls,pruning,image-removal,runtime-recovery,root-code,systemd\n' "$TRANSACTION_ID" "$fingerprint" "$candidate" "$prestate" "$(sha256 "$(bundle_manifest)")" "$CONFIG_MANIFEST_SHA256" "$RUNTIME_MANIFEST_SHA256" "$IMAGE_MANIFEST_SHA256" "$IMAGE_ATTESTATION_SHA256" "$now" "$remote_now" "$expires" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" >"$artifact"; chmod 600 "$artifact"
  printf 'Redacted deployment plan: target=%s transaction=%s bundle=%s\nApproval artifact: %s\n' "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$TRANSACTION_ID" "$(sha256 "$(bundle_manifest)")" "$artifact"
}
apply() {
  local status=0 now remote_now candidate prestate
  [[ -f "$ARTIFACT" && ! -L "$ARTIFACT" ]] || die "approval is invalid"
  validate_approval_artifact
  [[ "$(artifact_value format)" == deploy-approval-v2 && "$(artifact_value state)" == unused && "$(artifact_value host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(artifact_value fingerprint)" =~ ^[0-9a-f]{64}$ ]] || die "approval is invalid"
  now="$(date -u +%s)"; (( now <= $(artifact_value expires) )) || die "approval expired"; TRANSACTION_ID="$(artifact_value transaction_id)"; [[ "$TRANSACTION_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die "approval transaction ID is invalid"
  remote_now="$(remote 'date -u +%s')"; (( ${now#-} - ${remote_now#-} <= 60 && ${remote_now#-} - ${now#-} <= 60 )) || die "local and Pi clocks differ by more than 60 seconds"
  render; require_interface; remote_env_valid || die "Pi-only .env protections or key set failed"; validate_candidate; validate_recovery_inputs; verify_config_prestate; candidate="$(candidate_hash)"; prestate="$(prestate_hash)"; [[ "$(artifact_value candidate_sha256)" == "$candidate" && "$(artifact_value prestate_sha256)" == "$prestate" && "$(artifact_value bundle_manifest_sha256)" == "$(sha256 "$(bundle_manifest)")" && "$(artifact_value config_manifest_sha256)" == "$CONFIG_MANIFEST_SHA256" && "$(artifact_value runtime_manifest_sha256)" == "$RUNTIME_MANIFEST_SHA256" && "$(artifact_value image_manifest_sha256)" == "$IMAGE_MANIFEST_SHA256" && "$(artifact_value image_attestation_sha256)" == "$IMAGE_ATTESTATION_SHA256" && "$(artifact_value fingerprint)" == "$(approval_fingerprint "$candidate" "$prestate" "$(artifact_value created)" "$(artifact_value remote_created)" "$(artifact_value expires)")" ]] || die "candidate, recovery artifact, bundle, or pre-state changed"
  consume; cp "$CONFIG_BACKUP/compose/docker-compose.yml" "$TMP_DIR/rollback-compose.yml"; cp "$CONFIG_BACKUP/caddy/Caddyfile" "$TMP_DIR/rollback-Caddyfile"; stage="$NEXTCLOUD_REMOTE_PROJECT_DIR/.deploy-stage-$TRANSACTION_ID"; remote "umask 077; mkdir -m 0700 '$stage'" || die "could not create remote stage"
  scp -q "$TMP_DIR/rendered/docker-compose.yml" "$TMP_DIR/rendered/caddy/Caddyfile" "$TMP_DIR/rollback-compose.yml" "$TMP_DIR/rollback-Caddyfile" "$SCRIPT_DIR/lib/atomic-transaction.sh" "$REMOTE:$stage/" || die "staging failed"
  deployment_run_application_transaction || status=$?
  (( status == 0 )) || die "deployment failed; transaction ID: $TRANSACTION_ID"
  remote "rm -rf '$stage'"; printf 'Deployment applied with consumed approval artifact: %s\n' "$ARTIFACT"
}
case "$MODE" in
  --plan)
    [[ $# == 4 ]] || { usage; exit 2; }
    CONFIG_BACKUP="$2"; RUNTIME_BACKUP="$3"; IMAGE_RECOVERY="$4"; plan
    ;;
  --apply)
    [[ $# == 5 ]] || { usage; exit 2; }
    ARTIFACT="$2"; CONFIG_BACKUP="$3"; RUNTIME_BACKUP="$4"; IMAGE_RECOVERY="$5"; apply
    ;;
  *) usage; exit 2 ;;
esac
