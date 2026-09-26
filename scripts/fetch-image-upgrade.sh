#!/usr/bin/env bash
set -euo pipefail

# Approval-bound, digest-only image retrieval. This never changes Compose,
# source lock, active record, tags, or containers. Activation is a later gate.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
source "$SCRIPT_DIR/lib/image-lock.sh"
[[ -z "${NEXTCLOUD_IMAGE_LOCK_FILE:-}" ]] || { printf 'Image fetch rejected: image-lock override is not allowed\n' >&2; exit 1; }
load_deployment_config "$ROOT"
image_lock_load "$ROOT"
readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
readonly APPROVAL_ROOT="${NEXTCLOUD_UPGRADE_FETCH_APPROVAL_ROOT:-$HOME/nextcloud-pi-upgrade-fetch-approvals}"
MODE="${1:-}"
ARTIFACT=''
if [[ "$MODE" == --apply ]]; then ARTIFACT="${2:-}"; shift 2; else shift || true; fi
readonly CANDIDATE="${1:-}"
readonly RENDERED="${2:-}"
readonly CONFIG_BACKUP="${3:-}"
readonly RUNTIME_BACKUP="${4:-}"
readonly IMAGE_RECOVERY="${5:-}"
readonly FREEZE_ID="${6:-}"
TMP_DIR="$(mktemp -d)"
APPROVAL_LOCK=''
cleanup() {
  local status=$?
  trap - EXIT
  [[ -z "$APPROVAL_LOCK" || ! -d "$APPROVAL_LOCK" ]] || rmdir "$APPROVAL_LOCK" 2>/dev/null || true
  rm -rf -- "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT
die() { printf 'Image fetch rejected: %s\n' "$1" >&2; exit 1; }
usage() { printf 'Usage: %s --plan|--apply [approval-artifact] <candidate> <source-rendered> <config-backup> <held-runtime-backup> <prior-image-recovery> <freeze-id>\n' "$0" >&2; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
mode_of() { if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi; }
field() { awk -F $'\t' -v key="$2" '$1 == key && NF == 2 { n++; v=$2 } END { if (n == 1) print v; else exit 1 }' "$1"; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=12 "$REMOTE" "$*"; }
clock_ok() { local delta=$(( $1 - $2 )); (( delta < 0 )) && delta=$((-delta)); (( delta <= 60 )); }
fresh() {
  local stamp epoch now iso
  stamp="$(field "$1" timestamp)"; [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "recovery timestamp is invalid"
  iso="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z"
  epoch="$(date -u -j -f '%Y%m%dT%H%M%SZ' "$stamp" +%s 2>/dev/null || date -u -d "$iso" +%s 2>/dev/null)" || die "recovery timestamp is invalid"
  now="$(date -u +%s)"; (( epoch <= now && now - epoch <= 86400 )) || die "recovery artifact is older than 24 hours"
}
private_outside_git() {
  local path="$1" ancestor="$1" nearest=''
  [[ "$path" = /* ]] || die "approval path must be absolute"
  while :; do
    [[ ! -L "$ancestor" ]] || die "approval parent is symbolic-linked"
    if [[ -e "$ancestor" ]]; then
      [[ -d "$ancestor" ]] || die "approval parent is not a directory"
      [[ -n "$nearest" ]] || nearest="$ancestor"
    fi
    [[ "$ancestor" == / ]] && break
    ancestor="$(dirname -- "$ancestor")"
  done
  [[ -z "$(git -C "$nearest" rev-parse --show-toplevel 2>/dev/null || true)" ]] || die "approval must stay outside Git"
}
check_artifact_schema() {
  awk -F '\t' '
    BEGIN { split("format state transaction_id fingerprint candidate_sha256 source_lock_sha256 config_manifest_sha256 runtime_manifest_sha256 image_manifest_sha256 image_attestation_sha256 prestate_sha256 freeze_id freeze_table_sha256 tag index_digest manifest_digest config_digest host created remote_created expires actions exclusions", list, " "); for (i in list) expected[list[i]]=1 }
    NF != 2 || !($1 in expected) || seen[$1]++ { bad=1 }
    END { for (key in expected) if (seen[key] != 1) bad=1; exit bad }
  ' "$ARTIFACT" || die "approval artifact schema is invalid"
}
check_inputs() {
  local status timer running name expected actual
  [[ "$FREEZE_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die "freeze ID is invalid"
  python3 "$SCRIPT_DIR/verify-image-upgrade.py" "$CANDIDATE" --source-lock "$ROOT/config/image-lock.env" --source-rendered "$RENDERED" >/dev/null || die "candidate is not the exact one-image transition"
  "$SCRIPT_DIR/verify-config-backup.sh" "$CONFIG_BACKUP" >/dev/null || die "configuration backup failed verification"
  "$SCRIPT_DIR/verify-runtime-backup.sh" "$RUNTIME_BACKUP" >/dev/null || die "runtime backup failed verification"
  "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$IMAGE_RECOVERY" >/dev/null || die "prior image recovery failed verification"
  for name in "$CONFIG_BACKUP/manifest.tsv" "$RUNTIME_BACKUP/manifest.tsv" "$IMAGE_RECOVERY/manifest.tsv" "$IMAGE_RECOVERY/restore-attestation.tsv"; do fresh "$name"; done
  [[ "$(field "$CONFIG_BACKUP/manifest.tsv" remote_host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(field "$CONFIG_BACKUP/manifest.tsv" remote_user)" == "$NEXTCLOUD_PI_USER" && "$(field "$CONFIG_BACKUP/manifest.tsv" source_project)" == "$NEXTCLOUD_REMOTE_PROJECT_DIR" ]] || die "configuration backup target differs"
  [[ "$(field "$RUNTIME_BACKUP/manifest.tsv" format)" == runtime-backup-v2 && "$(field "$RUNTIME_BACKUP/manifest.tsv" remote_host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(field "$RUNTIME_BACKUP/manifest.tsv" remote_user)" == "$NEXTCLOUD_PI_USER" && "$(field "$RUNTIME_BACKUP/manifest.tsv" source_nextcloud)" == "$NEXTCLOUD_STORAGE_MOUNT/nextcloud" && "$(field "$RUNTIME_BACKUP/manifest.tsv" freeze_id)" == "$FREEZE_ID" ]] || die "held runtime backup target or freeze differs"
  [[ "$(field "$IMAGE_RECOVERY/manifest.tsv" remote_host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(field "$IMAGE_RECOVERY/manifest.tsv" remote_user)" == "$NEXTCLOUD_PI_USER" && "$(field "$IMAGE_RECOVERY/manifest.tsv" source_project)" == "$NEXTCLOUD_REMOTE_PROJECT_DIR" && "$(field "$IMAGE_RECOVERY/manifest.tsv" storage_mount)" == "$NEXTCLOUD_STORAGE_MOUNT" ]] || die "prior image recovery target differs"
  metadata="$CANDIDATE/registry-metadata.tsv"
  tag="$(field "$metadata" tag)"; image="$(field "$metadata" image)"; index="$(field "$metadata" index_digest)"
  manifest="$(field "$metadata" manifest_digest)"; loaded="$(field "$metadata" config_digest)"
  python3 "$SCRIPT_DIR/resolve-image-upgrade.py" "$tag" --expected-index "$index" >"$TMP_DIR/registry.tsv" || die "registry identity changed"
  cmp -s "$metadata" "$TMP_DIR/registry.tsv" || die "registry ARM64/config identity changed"
  status="$(remote 'sudo -n /usr/local/libexec/nextcloud-pi-ops upgrade-freeze status')" || die "protected freeze is unavailable"
  [[ "$(awk -F $'\t' '$1 == "state" {print $2}' <<<"$status")" == active && "$(awk -F $'\t' '$1 == "id" {print $2}' <<<"$status")" == "$FREEZE_ID" ]] || die "protected freeze is not active"
  freeze_hash="$(awk -F $'\t' '$1 == "table_sha256" {print $2}' <<<"$status")"
  [[ "$freeze_hash" =~ ^[0-9a-f]{64}$ && "$freeze_hash" == "$(field "$RUNTIME_BACKUP/manifest.tsv" freeze_table_sha256)" ]] || die "protected freeze differs from held backup"
  timer="$(remote 'sudo -n /usr/local/libexec/nextcloud-pi-ops background-jobs state')" || die "background-job state is unavailable"
  [[ "$(awk -F $'\t' '$1 == "timer_active" {print $2}' <<<"$timer")" == no ]] || die "background jobs are not paused"
  remote "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status" | grep -Eq '^[[:space:]]*-[[:space:]]*maintenance:[[:space:]]*true$' || die "maintenance mode is not on"
  [[ "$(remote hostname)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(remote id -un)" == "$NEXTCLOUD_PI_USER" ]] || die "Pi identity differs"
  [[ "$(remote "sha256sum '$NEXTCLOUD_REMOTE_PROJECT_DIR/docker-compose.yml'" | awk '{print $1}')" == "$(sha256 "$RENDERED/docker-compose.yml")" ]] || die "live Compose differs from source candidate"
  [[ "$(remote "sha256sum '$NEXTCLOUD_REMOTE_PROJECT_DIR/caddy/Caddyfile'" | awk '{print $1}')" == "$(sha256 "$RENDERED/caddy/Caddyfile")" ]] || die "live Caddyfile differs from source candidate"
  [[ "$(sha256 "$CONFIG_BACKUP/compose/docker-compose.yml")" == "$(sha256 "$RENDERED/docker-compose.yml")" && "$(sha256 "$CONFIG_BACKUP/caddy/Caddyfile")" == "$(sha256 "$RENDERED/caddy/Caddyfile")" ]] || die "configuration backup differs from live source"
  status="$(remote 'sudo -n /usr/local/libexec/nextcloud-pi-ops active-images-state')" || die "active-image state is invalid"
  [[ "$(awk -F $'\t' '$1 == "mode" {print $2}' <<<"$status")" == source && "$(awk -F $'\t' '$1 == "sha256" {print $2}' <<<"$status")" == "$(sha256 "$RENDERED/active-images/active-images.env")" ]] || die "protected active record differs from source"
  : >"$TMP_DIR/prestate.tsv"
  printf 'active_record\t%s\ncompose\t%s\ncaddy\t%s\n' "$(sha256 "$RENDERED/active-images/active-images.env")" "$(sha256 "$RENDERED/docker-compose.yml")" "$(sha256 "$RENDERED/caddy/Caddyfile")" >>"$TMP_DIR/prestate.tsv"
  for name in APP DB CADDY; do
    case "$name" in APP) expected="$NEXTCLOUD_IMAGE_APP_ID"; actual="$NEXTCLOUD_IMAGE_APP_TAG";; DB) expected="$NEXTCLOUD_IMAGE_DB_ID"; actual="$NEXTCLOUD_IMAGE_DB_TAG";; CADDY) expected="$NEXTCLOUD_IMAGE_CADDY_ID"; actual="$NEXTCLOUD_IMAGE_CADDY_TAG";; esac
    running="$(remote "docker image inspect --format '{{.Id}}' '$actual'")" || die "source image is absent"
    [[ "$running" == "$expected" ]] || die "source image ID differs"
    printf 'source_image\t%s\t%s\n' "$actual" "$running" >>"$TMP_DIR/prestate.tsv"
  done
  for name in nextcloud-docker-app-1 nextcloud-docker-db-1 nextcloud-docker-caddy-1; do
    case "$name" in *-app-1) expected="$NEXTCLOUD_IMAGE_APP_ID";; *-db-1) expected="$NEXTCLOUD_IMAGE_DB_ID";; *-caddy-1) expected="$NEXTCLOUD_IMAGE_CADDY_ID";; esac
    running="$(remote "docker inspect '$name' --format '{{.Id}} {{.Image}} {{.State.Running}}'")" || die "source container is absent"
    [[ "$running" =~ ^[0-9a-f]{64}\ sha256:[0-9a-f]{64}\ true$ && "$running" == *" $expected true" ]] || die "source container image differs from the lock"
    printf 'container\t%s\t%s\n' "$name" "$running" >>"$TMP_DIR/prestate.tsv"
  done
}
authority() {
  printf 'transaction_id\t%s\ncandidate_sha256\t%s\nsource_lock_sha256\t%s\nconfig_manifest_sha256\t%s\nruntime_manifest_sha256\t%s\nimage_manifest_sha256\t%s\nimage_attestation_sha256\t%s\nprestate_sha256\t%s\nfreeze_id\t%s\nfreeze_table_sha256\t%s\ntag\t%s\nindex_digest\t%s\nmanifest_digest\t%s\nconfig_digest\t%s\nhost\t%s\ncreated\t%s\nremote_created\t%s\nexpires\t%s\nactions\tpull-exact-digest,verify-loaded-id\nexclusions\ttag-change,compose,source-lock,active-record,container-start,container-stop,pruning,image-removal,runtime-restore,freeze-release\n' \
    "$transaction_id" "$(sha256 "$CANDIDATE/candidate-manifest.tsv")" "$(sha256 "$ROOT/config/image-lock.env")" "$(sha256 "$CONFIG_BACKUP/manifest.tsv")" "$(sha256 "$RUNTIME_BACKUP/manifest.tsv")" "$(sha256 "$IMAGE_RECOVERY/manifest.tsv")" "$(sha256 "$IMAGE_RECOVERY/restore-attestation.tsv")" "$(sha256 "$TMP_DIR/prestate.tsv")" "$FREEZE_ID" "$freeze_hash" "$tag" "$index" "$manifest" "$loaded" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$created" "$remote_created" "$expires"
}
[[ "$MODE" == --plan || "$MODE" == --apply ]] && [[ $# == 6 ]] || { usage; exit 2; }
[[ -n "$CANDIDATE" && -n "$RENDERED" && -n "$CONFIG_BACKUP" && -n "$RUNTIME_BACKUP" && -n "$IMAGE_RECOVERY" ]] || { usage; exit 2; }
check_inputs
if [[ "$MODE" == --plan ]]; then
  created="$(date -u +%s)"; remote_created="$(remote 'date -u +%s')"; clock_ok "$created" "$remote_created" || die "local and Pi clocks differ by more than 60 seconds"
  expires="$((created + 900))"; transaction_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  authority >"$TMP_DIR/authority.tsv"; fingerprint="$(sha256 "$TMP_DIR/authority.tsv")"
  private_outside_git "$APPROVAL_ROOT"
  [[ ! -L "$APPROVAL_ROOT" ]] || die "approval root is unsafe"
  mkdir -p "$APPROVAL_ROOT"; chmod 700 "$APPROVAL_ROOT"
  [[ "$(mode_of "$APPROVAL_ROOT")" == 700 ]] || die "approval root protection failed"
  artifact="$APPROVAL_ROOT/fetch-$fingerprint-$created.tsv"
  (umask 077; set -C; printf 'format\timage-upgrade-fetch-v1\nstate\tunused\nfingerprint\t%s\n' "$fingerprint" >"$artifact"; cat "$TMP_DIR/authority.tsv" >>"$artifact") || die "approval artifact already exists"
  printf 'Redacted image-fetch plan: host=%s tag=%s index=%s expected-loaded-id=%s\nApproval artifact: %s\n' "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$tag" "$index" "$loaded" "$artifact"
  exit 0
fi
[[ -f "$ARTIFACT" && ! -L "$ARTIFACT" ]] || die "approval artifact is invalid"
private_outside_git "$(dirname -- "$ARTIFACT")"
check_artifact_schema
[[ "$(mode_of "$ARTIFACT")" == 600 && "$(mode_of "$(dirname -- "$ARTIFACT")")" == 700 ]] || die "approval artifact protection is invalid"
[[ "$(field "$ARTIFACT" format)" == image-upgrade-fetch-v1 && "$(field "$ARTIFACT" state)" == unused ]] || die "approval is not unused"
transaction_id="$(field "$ARTIFACT" transaction_id)"; [[ "$transaction_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die "approval transaction ID is invalid"
created="$(field "$ARTIFACT" created)"; remote_created="$(field "$ARTIFACT" remote_created)"; expires="$(field "$ARTIFACT" expires)"
[[ "$created" =~ ^[0-9]+$ && "$remote_created" =~ ^[0-9]+$ && "$expires" =~ ^[0-9]+$ ]] || die "approval clock is invalid"
now="$(date -u +%s)"; remote_now="$(remote 'date -u +%s')"
clock_ok "$now" "$remote_now" && clock_ok "$created" "$remote_created" && (( now >= created && now <= expires && expires - created == 900 )) || die "approval expired or clocks differ"
authority >"$TMP_DIR/authority.tsv"
[[ "$(field "$ARTIFACT" fingerprint)" == "$(sha256 "$TMP_DIR/authority.tsv")" ]] || die "candidate, recovery evidence, or Pi pre-state changed"
cmp -s <(tail -n +4 "$ARTIFACT") "$TMP_DIR/authority.tsv" || die "approval actions or bound fields differ"
APPROVAL_LOCK="$ARTIFACT.lock"; mkdir -m 700 "$APPROVAL_LOCK" 2>/dev/null || die "approval is already in use"
[[ "$(field "$ARTIFACT" state)" == unused ]] || die "approval was consumed"
sed $'s/^state\tunused$/state\tconsumed/' "$ARTIFACT" >"$TMP_DIR/consumed.tsv"
[[ "$(field "$TMP_DIR/consumed.tsv" state)" == consumed ]] || die "approval consumption failed"
chmod 600 "$TMP_DIR/consumed.tsv"; mv "$TMP_DIR/consumed.tsv" "$ARTIFACT"; rmdir "$APPROVAL_LOCK"; APPROVAL_LOCK=''
ref="$image@$index"
remote "sudo -n /usr/local/libexec/nextcloud-pi-ops upgrade-fetch consume '$transaction_id' '$(field "$ARTIFACT" fingerprint)' '$FREEZE_ID' '$freeze_hash' '$ref' '$loaded' '$expires' fetch-only" </dev/null || die "root-owned fetch approval could not be consumed; freeze remains held"
remote "docker pull --platform linux/arm64/v8 '$ref' >/dev/null" </dev/null || die "approved digest pull failed; freeze remains held"
actual="$(remote "docker image inspect --format '{{.Id}}' '$ref'")" || die "fetched image is unavailable; freeze remains held"
[[ "$actual" == "$loaded" ]] || die "fetched image ID differs; freeze remains held"
check_inputs
authority >"$TMP_DIR/authority.tsv"
[[ "$(sha256 "$TMP_DIR/authority.tsv")" == "$(field "$ARTIFACT" fingerprint)" ]] || die "approved evidence changed after fetch; freeze remains held"
remote "sudo -n /usr/local/libexec/nextcloud-pi-ops upgrade-fetch complete '$transaction_id' '$(field "$ARTIFACT" fingerprint)'" </dev/null || die "root-owned fetch completion failed; freeze remains held"
printf 'Approved digest fetched and loaded ID verified: %s %s\nFreeze remains held; no image tag or runtime was changed.\n' "$tag" "$actual"
