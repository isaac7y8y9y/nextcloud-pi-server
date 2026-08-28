#!/usr/bin/env bash
set -euo pipefail

# Offline guard for the separately approved import transaction. The disposable
# Pi drill covers systemd mechanics; these assertions keep the distinct image
# import path fail-closed and archive/attestation-bound.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly IMPORTER="$SCRIPT_DIR/restore-image-recovery.sh"
grep -Fq -- '--require-attestation' "$IMPORTER"
grep -Fq 'archive_sha256' "$IMPORTER"
grep -Fq 'attestation_sha256' "$IMPORTER"
grep -Fq 'image-import-remote.sh' "$IMPORTER"
grep -Fq 'validate_approval_artifact' "$IMPORTER"
grep -Fq 'Redacted image-import transition:' "$IMPORTER"
grep -Fq 'current_app_container_id' "$IMPORTER"
grep -Fq 'recovered_app_id' "$IMPORTER"
grep -Fq 'NEXTCLOUD_ACTIVE_IMAGES_MODE=recovered' "$IMPORTER"
grep -Fq 'failure.tsv' "$SCRIPT_DIR/lib/image-import-remote.sh"
grep -Fq 'import approval could not be atomically consumed' "$IMPORTER"
grep -Fq 'image_import_consume_approval "$ARGUMENT"' "$IMPORTER"
grep -Fq 'image_import_stage_payload' "$IMPORTER"
grep -Fq 'bash "$SCRIPT_DIR/health-check.sh"' "$IMPORTER"
grep -Fq 'source_image' "$SCRIPT_DIR/verify-image-recovery.sh"
grep -Fq 'remote "docker image inspect --format '\''{{.Id}}'\'' '\''$tag'\''" </dev/null' "$SCRIPT_DIR/export-image-recovery.sh"
grep -Fq 'isolated_result' "$SCRIPT_DIR/verify-image-recovery.sh"
grep -Fq 'attested_source_id' "$SCRIPT_DIR/verify-image-recovery.sh"
grep -Fq 'isolated_docker_host' "$SCRIPT_DIR/test-image-restore-readiness.sh"
grep -Fq 'sudo -n /usr/local/libexec/nextcloud-pi-validate-active-images' "$SCRIPT_DIR/test-runtime-recovery.sh"
grep -Fq 'record_value host' "$IMPORTER"
grep -Fq 'clock_skew_ok "$(date -u +%s)" "$(remote '\''date -u +%s'\'')"' "$IMPORTER"

extract_function() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\) \\{" { capture = 1 } capture { print } capture && $0 == "}" { exit }' "$IMPORTER"
}
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
extract_function clock_skew_ok >"$TEST_DIR/clock-skew-ok.sh"
source "$TEST_DIR/clock-skew-ok.sh"
clock_skew_ok 1000 1060
clock_skew_ok 1060 1000
if clock_skew_ok 1000 1061 || clock_skew_ok 1061 1000; then
  echo 'image-import clock-skew limit accepted more than 60 seconds' >&2
  exit 1
fi
echo 'image-import transaction regression checks passed'
