#!/usr/bin/env bash

# Stage the protected image-import payload and remove an incomplete exact stage
# before returning. Status 2 means cleanup itself failed and must be reported.
image_import_stage_payload() {
  local stage="$1" recovery="$2" recovered_record="$3" helper="$4" remote_target="$5"
  remote "umask 077; test ! -e '$stage'; mkdir -m 0700 '$stage'" || return 1
  if scp -q "$recovery/images.tar" "$recovery/restore-attestation.tsv" "$recovered_record" "$helper" "$remote_target:$stage/"; then
    return 0
  fi
  remote "rm -rf '$stage' && test ! -e '$stage'" || return 2
  return 1
}
