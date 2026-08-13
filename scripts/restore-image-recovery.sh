#!/usr/bin/env bash
set -euo pipefail

# A separately approved image-import transaction. It never pulls, prunes, or
# removes images; rollback retags the captured prior image IDs.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
source "$SCRIPT_DIR/lib/image-lock.sh"
source "$SCRIPT_DIR/lib/image-import-approval.sh"
source "$SCRIPT_DIR/lib/image-import-transfer.sh"
load_deployment_config "$REPOSITORY_ROOT"
image_lock_load "$REPOSITORY_ROOT"
readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
readonly APPROVAL_ROOT="${NEXTCLOUD_IMAGE_IMPORT_APPROVAL_ROOT:-$HOME/nextcloud-pi-image-import-approvals}"
readonly IMAGE_IMPORT_ACTIONS=stop,load,verify,retag,record-install,restart,rollback
MODE="${1:-}"; ARGUMENT="${2:-}"; ARCHIVE="${3:-}"
TMP_DIR="$(mktemp -d)"; IMAGE_IMPORT_APPROVAL_LOCK=""
cleanup() { [[ -z "$IMAGE_IMPORT_APPROVAL_LOCK" || ! -d "$IMAGE_IMPORT_APPROVAL_LOCK" ]] || rmdir "$IMAGE_IMPORT_APPROVAL_LOCK" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
die() { printf 'Image import failed: %s\n' "$1" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"; }
clock_skew_ok() {
  local local_epoch="$1" remote_epoch="$2" delta
  [[ "$local_epoch" =~ ^[0-9]+$ && "$remote_epoch" =~ ^[0-9]+$ ]] || return 1
  delta=$((local_epoch - remote_epoch)); (( delta < 0 )) && delta=$((-delta))
  (( delta <= 60 ))
}
manifest_value() { awk -F $'\t' -v key="$2" '$1 == key { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$1"; }
record_value() { awk -F $'\t' -v key="$1" '$1 == key { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$ARGUMENT"; }
prestate_value() {
  local file="$1" kind="$2" name="${3:-}"
  case "$kind" in
    active_record) awk -F $'\t' '$1 == "active_record" { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$file" ;;
    tag) awk -F $'\t' -v name="$name" '$1 == "tag" && $2 == name { count++; value=$3 } END { if (count == 1) print value; else exit 1 }' "$file" ;;
    container_id) awk -F $'\t' -v name="$name" '$1 == "container" && $2 == name { count++; value=$3 } END { if (count == 1) print value; else exit 1 }' "$file" ;;
    container_image) awk -F $'\t' -v name="$name" '$1 == "container" && $2 == name { count++; value=$4 } END { if (count == 1) print value; else exit 1 }' "$file" ;;
    container_running) awk -F $'\t' -v name="$name" '$1 == "container" && $2 == name { count++; value=$5 } END { if (count == 1) print value; else exit 1 }' "$file" ;;
    *) return 1 ;;
  esac
}
validate_prestate() {
  awk -F '\t' -v app_tag="$NEXTCLOUD_IMAGE_APP_TAG" -v db_tag="$NEXTCLOUD_IMAGE_DB_TAG" -v caddy_tag="$NEXTCLOUD_IMAGE_CADDY_TAG" '
    $1 == "active_record" && NF == 2 && $2 ~ /^[0-9a-f]{64}$/ { active++ ; next }
    $1 == "tag" && NF == 3 && ($2 == app_tag || $2 == db_tag || $2 == caddy_tag) && $3 ~ /^sha256:[0-9a-f]{64}$/ { tags[$2]++ ; next }
    $1 == "container" && NF == 5 && ($2 == "nextcloud-docker-app-1" || $2 == "nextcloud-docker-db-1" || $2 == "nextcloud-docker-caddy-1") && $3 ~ /^[0-9a-f]{64}$/ && $4 ~ /^sha256:[0-9a-f]{64}$/ && $5 == "true" { containers[$2]++ ; next }
    { invalid = 1 }
    END { exit !( !invalid && active == 1 && tags[app_tag] == 1 && tags[db_tag] == 1 && tags[caddy_tag] == 1 && containers["nextcloud-docker-app-1"] == 1 && containers["nextcloud-docker-db-1"] == 1 && containers["nextcloud-docker-caddy-1"] == 1 ) }
  ' "$1"
}
capture_remote_prestate() {
  local out="$1"
  remote "set -eu; test \"\$(hostname)\" = '$NEXTCLOUD_PI_SYSTEM_HOSTNAME'; sudo -n /usr/local/libexec/nextcloud-pi-validate-active-images; active=\$(sudo -n sha256sum /etc/nextcloud-pi/active-images.env); printf 'active_record\\t%s\\n' \"\${active%% *}\"; for tag in '$NEXTCLOUD_IMAGE_APP_TAG' '$NEXTCLOUD_IMAGE_DB_TAG' '$NEXTCLOUD_IMAGE_CADDY_TAG'; do printf 'tag\\t%s\\t%s\\n' \"\$tag\" \"\$(docker image inspect --format '{{.Id}}' \"\$tag\")\"; done; for name in nextcloud-docker-app-1 nextcloud-docker-db-1 nextcloud-docker-caddy-1; do container_id=\$(docker inspect \"\$name\" --format '{{.Id}}'); container_image=\$(docker inspect \"\$name\" --format '{{.Image}}'); container_running=\$(docker inspect \"\$name\" --format '{{.State.Running}}'); printf 'container\\t%s\\t%s\\t%s\\t%s\\n' \"\$name\" \"\$container_id\" \"\$container_image\" \"\$container_running\"; done" >"$out"
  validate_prestate "$out" || die "remote image-import pre-state is invalid"
}
active_record_value() { awk -F= -v key="$2" '$1 == key { count++; value=$2 } END { if (count == 1) print value; else exit 1 }' "$1"; }
validate_approval_artifact() {
  awk -F '\t' '
    BEGIN { split("format state fingerprint archive_sha256 attestation_sha256 recovered_record_sha256 prestate_sha256 current_active_record_sha256 current_app_tag_id current_db_tag_id current_caddy_tag_id current_app_container_id current_app_container_image current_app_container_running current_db_container_id current_db_container_image current_db_container_running current_caddy_container_id current_caddy_container_image current_caddy_container_running recovered_app_id recovered_db_id recovered_caddy_id host created remote_created expires actions", list, " "); for (i in list) expected[list[i]] = 1 }
    NF != 2 || !($1 in expected) || seen[$1]++ { invalid = 1 }
    END { for (key in expected) if (seen[key] != 1) invalid = 1; exit invalid }
  ' "$ARGUMENT" || die "import approval artifact schema is invalid"
}
build_recovered_record() {
  local recovery="$1" attestation="$recovery/restore-attestation.tsv" out="$2" tag id
  {
    printf 'NEXTCLOUD_ACTIVE_IMAGES_FORMAT=nextcloud-active-images-v1\nNEXTCLOUD_ACTIVE_IMAGES_MODE=recovered\n'
    printf 'NEXTCLOUD_ACTIVE_IMAGES_HOST=%s\nNEXTCLOUD_ACTIVE_IMAGES_PROJECT=%s\nNEXTCLOUD_ACTIVE_IMAGES_STORAGE=%s\nNEXTCLOUD_ACTIVE_IMAGES_PLATFORM=%s\n' "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$NEXTCLOUD_REMOTE_PROJECT_DIR" "$NEXTCLOUD_STORAGE_MOUNT" "$NEXTCLOUD_IMAGE_PLATFORM"
    printf 'NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256=%s\n' "$(sha256 "$attestation")"
    for service in APP DB CADDY; do
      eval "tag=\$NEXTCLOUD_IMAGE_${service}_TAG"
      id="$(awk -F $'\t' -v tag="$tag" '$1 == "image" && $2 == tag { count++; value=$3 } END { if (count == 1) print value; else exit 1 }' "$attestation")"
      printf 'NEXTCLOUD_ACTIVE_IMAGES_%s_TAG=%s\nNEXTCLOUD_ACTIVE_IMAGES_%s_ID=%s\n' "$service" "$tag" "$service" "$id"
    done
  } >"$out"
  chmod 600 "$out"
}
plan() {
  local recovery="$ARGUMENT" now remote_now artifact recovered_hash prestate fingerprint expiry
  "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$recovery" >/dev/null
  build_recovered_record "$recovery" "$TMP_DIR/recovered.env"
  capture_remote_prestate "$TMP_DIR/prestate.tsv"
  recovered_hash="$(sha256 "$TMP_DIR/recovered.env")"; prestate="$(sha256 "$TMP_DIR/prestate.tsv")"
  now="$(date -u +%s)"; remote_now="$(remote 'date -u +%s')"; clock_skew_ok "$now" "$remote_now" || die "local and Pi clocks differ by more than 60 seconds"
  expiry=$((now + 900))
  {
    printf 'archive_sha256\t%s\nattestation_sha256\t%s\nrecovered_record_sha256\t%s\nprestate_sha256\t%s\nhost\t%s\ncreated\t%s\nremote_created\t%s\nexpires\t%s\nactions\t%s\n' "$(manifest_value "$recovery/manifest.tsv" archive_sha256)" "$(sha256 "$recovery/restore-attestation.tsv")" "$recovered_hash" "$prestate" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$now" "$remote_now" "$expiry" "$IMAGE_IMPORT_ACTIONS"
  } >"$TMP_DIR/authority.tsv"
  fingerprint="$(sha256 "$TMP_DIR/authority.tsv")"
  mkdir -p "$APPROVAL_ROOT"; chmod 700 "$APPROVAL_ROOT"
  artifact="$APPROVAL_ROOT/import-$fingerprint-$now.tsv"
  { printf 'format\timage-import-approval-v1\nstate\tunused\nfingerprint\t%s\narchive_sha256\t%s\nattestation_sha256\t%s\nrecovered_record_sha256\t%s\nprestate_sha256\t%s\ncurrent_active_record_sha256\t%s\ncurrent_app_tag_id\t%s\ncurrent_db_tag_id\t%s\ncurrent_caddy_tag_id\t%s\ncurrent_app_container_id\t%s\ncurrent_app_container_image\t%s\ncurrent_app_container_running\t%s\ncurrent_db_container_id\t%s\ncurrent_db_container_image\t%s\ncurrent_db_container_running\t%s\ncurrent_caddy_container_id\t%s\ncurrent_caddy_container_image\t%s\ncurrent_caddy_container_running\t%s\nrecovered_app_id\t%s\nrecovered_db_id\t%s\nrecovered_caddy_id\t%s\nhost\t%s\ncreated\t%s\nremote_created\t%s\nexpires\t%s\nactions\t%s\n' \
    "$fingerprint" "$(manifest_value "$recovery/manifest.tsv" archive_sha256)" "$(sha256 "$recovery/restore-attestation.tsv")" "$recovered_hash" "$prestate" \
    "$(prestate_value "$TMP_DIR/prestate.tsv" active_record)" "$(prestate_value "$TMP_DIR/prestate.tsv" tag "$NEXTCLOUD_IMAGE_APP_TAG")" "$(prestate_value "$TMP_DIR/prestate.tsv" tag "$NEXTCLOUD_IMAGE_DB_TAG")" "$(prestate_value "$TMP_DIR/prestate.tsv" tag "$NEXTCLOUD_IMAGE_CADDY_TAG")" \
    "$(prestate_value "$TMP_DIR/prestate.tsv" container_id nextcloud-docker-app-1)" "$(prestate_value "$TMP_DIR/prestate.tsv" container_image nextcloud-docker-app-1)" "$(prestate_value "$TMP_DIR/prestate.tsv" container_running nextcloud-docker-app-1)" "$(prestate_value "$TMP_DIR/prestate.tsv" container_id nextcloud-docker-db-1)" "$(prestate_value "$TMP_DIR/prestate.tsv" container_image nextcloud-docker-db-1)" "$(prestate_value "$TMP_DIR/prestate.tsv" container_running nextcloud-docker-db-1)" "$(prestate_value "$TMP_DIR/prestate.tsv" container_id nextcloud-docker-caddy-1)" "$(prestate_value "$TMP_DIR/prestate.tsv" container_image nextcloud-docker-caddy-1)" "$(prestate_value "$TMP_DIR/prestate.tsv" container_running nextcloud-docker-caddy-1)" \
    "$(active_record_value "$TMP_DIR/recovered.env" NEXTCLOUD_ACTIVE_IMAGES_APP_ID)" "$(active_record_value "$TMP_DIR/recovered.env" NEXTCLOUD_ACTIVE_IMAGES_DB_ID)" "$(active_record_value "$TMP_DIR/recovered.env" NEXTCLOUD_ACTIVE_IMAGES_CADDY_ID)" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$now" "$remote_now" "$expiry" "$IMAGE_IMPORT_ACTIONS"; } >"$artifact"
  chmod 600 "$artifact"
  printf 'Redacted image-import transition:\n  target: %s\n  active-record SHA-256: %s\n  archive SHA-256: %s\n  attestation SHA-256: %s\n' "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$(prestate_value "$TMP_DIR/prestate.tsv" active_record)" "$(manifest_value "$recovery/manifest.tsv" archive_sha256)" "$(sha256 "$recovery/restore-attestation.tsv")"
  for service in app db caddy; do
    case "$service" in app) tag="$NEXTCLOUD_IMAGE_APP_TAG"; name=nextcloud-docker-app-1; record_key=NEXTCLOUD_ACTIVE_IMAGES_APP_ID ;; db) tag="$NEXTCLOUD_IMAGE_DB_TAG"; name=nextcloud-docker-db-1; record_key=NEXTCLOUD_ACTIVE_IMAGES_DB_ID ;; caddy) tag="$NEXTCLOUD_IMAGE_CADDY_TAG"; name=nextcloud-docker-caddy-1; record_key=NEXTCLOUD_ACTIVE_IMAGES_CADDY_ID ;; esac
    printf '  %s: tag=%s current=%s recovered=%s container=%s image=%s running=%s\n' "$service" "$tag" "$(prestate_value "$TMP_DIR/prestate.tsv" tag "$tag")" "$(active_record_value "$TMP_DIR/recovered.env" "$record_key")" "$(prestate_value "$TMP_DIR/prestate.tsv" container_id "$name")" "$(prestate_value "$TMP_DIR/prestate.tsv" container_image "$name")" "$(prestate_value "$TMP_DIR/prestate.tsv" container_running "$name")"
  done
  printf '  actions: %s\nImage import plan ready: %s\nFingerprint: %s\nExpires (UTC epoch): %s\n' "$IMAGE_IMPORT_ACTIONS" "$artifact" "$fingerprint" "$expiry"
}
apply() {
  local recovery="$ARCHIVE" now stage transfer_status
  [[ -f "$ARGUMENT" && ! -L "$ARGUMENT" ]] || die "import approval artifact is required"
  validate_approval_artifact
  [[ "$(record_value format)" == image-import-approval-v1 && "$(record_value state)" == unused && "$(record_value fingerprint)" =~ ^[0-9a-f]{64}$ && "$(record_value created)" =~ ^[0-9]+$ && "$(record_value expires)" =~ ^[0-9]+$ && $(record_value expires) -eq $(($(record_value created) + 900)) && $(date -u +%s) -le $(record_value expires) && "$(record_value actions)" == "$IMAGE_IMPORT_ACTIONS" ]] || die "import approval is invalid or expired"
  [[ "$(record_value host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && "$(record_value remote_created)" =~ ^[0-9]+$ ]] && clock_skew_ok "$(record_value created)" "$(record_value remote_created)" || die "import approval target or timestamp binding differs"
  clock_skew_ok "$(date -u +%s)" "$(remote 'date -u +%s')" || die "local and Pi clocks differ by more than 60 seconds"
  "$SCRIPT_DIR/verify-image-recovery.sh" --require-attestation "$recovery" >/dev/null
  build_recovered_record "$recovery" "$TMP_DIR/recovered.env"
  capture_remote_prestate "$TMP_DIR/prestate.tsv"
  { printf 'archive_sha256\t%s\nattestation_sha256\t%s\nrecovered_record_sha256\t%s\nprestate_sha256\t%s\nhost\t%s\ncreated\t%s\nremote_created\t%s\nexpires\t%s\nactions\t%s\n' "$(manifest_value "$recovery/manifest.tsv" archive_sha256)" "$(sha256 "$recovery/restore-attestation.tsv")" "$(sha256 "$TMP_DIR/recovered.env")" "$(sha256 "$TMP_DIR/prestate.tsv")" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$(record_value created)" "$(record_value remote_created)" "$(record_value expires)" "$IMAGE_IMPORT_ACTIONS"; } >"$TMP_DIR/authority.tsv"
  [[ "$(record_value fingerprint)" == "$(sha256 "$TMP_DIR/authority.tsv")" ]] || die "import approval fingerprint differs"
  [[ "$(record_value archive_sha256)" == "$(manifest_value "$recovery/manifest.tsv" archive_sha256)" && "$(record_value attestation_sha256)" == "$(sha256 "$recovery/restore-attestation.tsv")" && "$(record_value recovered_record_sha256)" == "$(sha256 "$TMP_DIR/recovered.env")" && "$(record_value prestate_sha256)" == "$(sha256 "$TMP_DIR/prestate.tsv")" \
    && "$(record_value current_active_record_sha256)" == "$(prestate_value "$TMP_DIR/prestate.tsv" active_record)" \
    && "$(record_value current_app_tag_id)" == "$(prestate_value "$TMP_DIR/prestate.tsv" tag "$NEXTCLOUD_IMAGE_APP_TAG")" && "$(record_value current_db_tag_id)" == "$(prestate_value "$TMP_DIR/prestate.tsv" tag "$NEXTCLOUD_IMAGE_DB_TAG")" && "$(record_value current_caddy_tag_id)" == "$(prestate_value "$TMP_DIR/prestate.tsv" tag "$NEXTCLOUD_IMAGE_CADDY_TAG")" \
    && "$(record_value current_app_container_id)" == "$(prestate_value "$TMP_DIR/prestate.tsv" container_id nextcloud-docker-app-1)" && "$(record_value current_app_container_image)" == "$(prestate_value "$TMP_DIR/prestate.tsv" container_image nextcloud-docker-app-1)" && "$(record_value current_app_container_running)" == true \
    && "$(record_value current_db_container_id)" == "$(prestate_value "$TMP_DIR/prestate.tsv" container_id nextcloud-docker-db-1)" && "$(record_value current_db_container_image)" == "$(prestate_value "$TMP_DIR/prestate.tsv" container_image nextcloud-docker-db-1)" && "$(record_value current_db_container_running)" == true \
    && "$(record_value current_caddy_container_id)" == "$(prestate_value "$TMP_DIR/prestate.tsv" container_id nextcloud-docker-caddy-1)" && "$(record_value current_caddy_container_image)" == "$(prestate_value "$TMP_DIR/prestate.tsv" container_image nextcloud-docker-caddy-1)" && "$(record_value current_caddy_container_running)" == true \
    && "$(record_value recovered_app_id)" == "$(active_record_value "$TMP_DIR/recovered.env" NEXTCLOUD_ACTIVE_IMAGES_APP_ID)" && "$(record_value recovered_db_id)" == "$(active_record_value "$TMP_DIR/recovered.env" NEXTCLOUD_ACTIVE_IMAGES_DB_ID)" && "$(record_value recovered_caddy_id)" == "$(active_record_value "$TMP_DIR/recovered.env" NEXTCLOUD_ACTIVE_IMAGES_CADDY_ID)" ]] || die "import inputs changed after approval"
  if [[ "$(record_value state)" != unused ]] || ! image_import_consume_approval "$ARGUMENT"; then
    die "import approval could not be atomically consumed"
  fi
  stage="$NEXTCLOUD_REMOTE_PROJECT_DIR/.image-import-$(sha256 "$TMP_DIR/recovered.env")"
  set +e
  image_import_stage_payload "$stage" "$recovery" "$TMP_DIR/recovered.env" "$SCRIPT_DIR/lib/image-import-remote.sh" "$REMOTE"
  transfer_status=$?
  set -e
  if (( transfer_status != 0 )); then
    (( transfer_status == 1 )) || die "image recovery transfer cleanup failed; preserve remote stage $stage"
    die "could not stage image recovery payload; incomplete stage was removed"
  fi
  remote "bash '$stage/image-import-remote.sh' apply '$stage' '$NEXTCLOUD_REMOTE_PROJECT_DIR' '$NEXTCLOUD_IMAGE_APP_TAG' '$NEXTCLOUD_IMAGE_DB_TAG' '$NEXTCLOUD_IMAGE_CADDY_TAG'" || die "image import failed; rollback was attempted"
  if ! bash "$SCRIPT_DIR/health-check.sh"; then
    remote "bash '$stage/image-import-remote.sh' rollback '$stage' '$NEXTCLOUD_REMOTE_PROJECT_DIR' '$NEXTCLOUD_IMAGE_APP_TAG' '$NEXTCLOUD_IMAGE_DB_TAG' '$NEXTCLOUD_IMAGE_CADDY_TAG'" || die "image import health rollback failed"
    bash "$SCRIPT_DIR/health-check.sh" || die "image import rollback health check failed"
    die "image import health check failed and was rolled back"
  fi
  remote "rm -rf '$stage'" || die "image import succeeded but staging cleanup failed"
  printf 'Image import applied with consumed approval: %s\n' "$ARGUMENT"
}
case "$MODE" in
  --plan) [[ $# -eq 2 ]] || die 'usage: restore-image-recovery.sh --plan <recovery-directory>'; plan ;;
  --apply) [[ $# -eq 3 ]] || die 'usage: restore-image-recovery.sh --apply <approval-artifact> <recovery-directory>'; apply ;;
  *) die 'usage: restore-image-recovery.sh --plan <recovery-directory> | --apply <approval-artifact> <recovery-directory>' ;;
esac
