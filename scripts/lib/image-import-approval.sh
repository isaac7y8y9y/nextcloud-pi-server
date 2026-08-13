#!/usr/bin/env bash

# Atomically consume one image-import approval. The caller's cleanup trap uses
# IMAGE_IMPORT_APPROVAL_LOCK if a signal arrives while the lock is held.
image_import_consume_approval() {
  local artifact="$1" consumed="$1.consumed"
  IMAGE_IMPORT_APPROVAL_LOCK="$artifact.lock"
  if ! mkdir -m 700 "$IMAGE_IMPORT_APPROVAL_LOCK" 2>/dev/null; then
    IMAGE_IMPORT_APPROVAL_LOCK=""
    return 1
  fi
  if ! awk -F $'\t' '$1 == "state" && $2 == "unused" { count++ } END { exit count == 1 ? 0 : 1 }' "$artifact" ||
     ! sed 's/^state\tunused$/state\tconsumed/' "$artifact" >"$consumed" ||
     ! chmod 600 "$consumed" ||
     ! mv "$consumed" "$artifact"; then
    rm -f "$consumed"
    rmdir "$IMAGE_IMPORT_APPROVAL_LOCK" || true
    IMAGE_IMPORT_APPROVAL_LOCK=""
    return 1
  fi
  if ! rmdir "$IMAGE_IMPORT_APPROVAL_LOCK"; then
    return 1
  fi
  IMAGE_IMPORT_APPROVAL_LOCK=""
}
