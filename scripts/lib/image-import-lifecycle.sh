#!/usr/bin/env bash

# Phase-aware Mac-side recovery for an approval-bound image import. Callers arm
# it before remote apply and disarm it only after verified rollback or commit.
image_import_remote_action() {
  local action="$1"
  case "$action" in apply|rollback|commit) ;; *) return 2 ;; esac
  remote "bash '$IMAGE_IMPORT_REMOTE_STAGE/image-import-remote.sh' '$action' '$IMAGE_IMPORT_TRANSACTION_ID' '$IMAGE_IMPORT_REMOTE_STAGE' '$NEXTCLOUD_REMOTE_PROJECT_DIR' '$NEXTCLOUD_IMAGE_APP_TAG' '$NEXTCLOUD_IMAGE_DB_TAG' '$NEXTCLOUD_IMAGE_CADDY_TAG' '$NEXTCLOUD_IMAGE_PLATFORM'" </dev/null
}

image_import_remove_remote_stage() {
  remote "rm -rf '$IMAGE_IMPORT_REMOTE_STAGE' && test ! -e '$IMAGE_IMPORT_REMOTE_STAGE'" </dev/null
}

image_import_recover() {
  local failed=0
  image_import_remote_action rollback || failed=1
  bash "$SCRIPT_DIR/health-check.sh" || failed=1
  if (( failed == 0 )); then
    image_import_remote_action commit || failed=1
  fi
  if (( failed == 0 )); then
    image_import_remove_remote_stage || failed=1
  fi
  (( failed == 0 ))
}
