#!/usr/bin/env bash
set -euo pipefail

# Separately authenticated lifecycle for the root-owned bundle. Routine deploy
# never calls this script.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/deployment-config.sh"
source "$SCRIPT_DIR/lib/image-lock.sh"
load_deployment_config "$ROOT"; image_lock_load "$ROOT"
readonly REMOTE="${NEXTCLOUD_PI_USER}@${NEXTCLOUD_PI_HOST}"
readonly APPROVAL_ROOT="${NEXTCLOUD_PRIVILEGED_APPROVAL_ROOT:-$HOME/nextcloud-pi-privileged-approvals}"
readonly TRACKED_MANIFEST="$ROOT/privileged/bundle-manifest.tsv"
TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
die() { printf 'Privileged-interface management failed: %s\n' "$1" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$@"; }
render() { sed -e "s|@NEXTCLOUD_PI_USER@|$NEXTCLOUD_PI_USER|g" -e "s|@NEXTCLOUD_PI_SYSTEM_HOSTNAME@|$NEXTCLOUD_PI_SYSTEM_HOSTNAME|g" -e "s|@NEXTCLOUD_REMOTE_PROJECT_DIR@|$NEXTCLOUD_REMOTE_PROJECT_DIR|g" -e "s|@NEXTCLOUD_STORAGE_MOUNT@|$NEXTCLOUD_STORAGE_MOUNT|g" -e "s|@NEXTCLOUD_STORAGE_UUID@|$NEXTCLOUD_STORAGE_UUID|g" -e "s|@NEXTCLOUD_IMAGE_PLATFORM@|$NEXTCLOUD_IMAGE_PLATFORM|g" "$1" >"$2"; }
build_package() {
  local package="$1" kind logical source installed mode digest target
  mkdir -p "$package/files"; umask 077
  while IFS=$'\t' read -r kind logical source installed mode digest; do
    [[ "$kind" == file ]] || continue
    [[ "$digest" =~ ^[0-9a-f]{64}$ && "$(sha256 "$ROOT/$source")" == "$digest" ]] || die "tracked bundle source differs: $logical"
    target="$package/files/$logical"
    case "$source" in systemd/*) render "$ROOT/$source" "$target";; *) cp "$ROOT/$source" "$target";; esac
    chmod "$mode" "$target"
  done <"$TRACKED_MANIFEST"
  render "$ROOT/privileged/privileged-policy.conf.example" "$package/privileged-policy.conf"
  render "$ROOT/privileged/nextcloud-pi-automation.sudoers.in" "$package/nextcloud-pi-automation.sudoers"
  cp "$ROOT/privileged/nextcloud-pi-bundle-installer" "$package/nextcloud-pi-bundle-installer"; chmod 700 "$package/nextcloud-pi-bundle-installer"
  { printf 'format\tnextcloud-pi-bundle-manifest-v1\nversion\t1\n'; while IFS=$'\t' read -r kind logical source installed mode digest; do [[ "$kind" == file ]] || continue; printf 'file\t%s\t%s\t%s\t%s\t%s\n' "$logical" "$source" "$installed" "$mode" "$(sha256 "$package/files/$logical")"; done <"$TRACKED_MANIFEST"; } >"$package/bundle-manifest.tsv"
  { printf 'format\tnextcloud-pi-package-manifest-v1\n'; for name in bundle-manifest.tsv privileged-policy.conf nextcloud-pi-automation.sudoers nextcloud-pi-bundle-installer; do printf 'file\t%s\t%s\n' "$name" "$(sha256 "$package/$name")"; done; } >"$package/package-manifest.tsv"
  chmod 600 "$package"/*.tsv "$package"/privileged-policy.conf "$package"/nextcloud-pi-automation.sudoers
}
value() { awk -F $'\t' -v key="$2" '$1 == key { n++; v=$2 } END { if (n == 1) print v; else exit 1 }' "$1"; }
validate_approval() {
  awk -F '\t' '
    BEGIN { split("format state id fingerprint host created expires package", keys, " "); for (i in keys) expected[keys[i]] = 1 }
    NF != 2 || !($1 in expected) || seen[$1]++ { bad = 1 }
    END { for (key in expected) if (seen[key] != 1) bad = 1; exit bad }
  ' "$1" || die "approval schema is invalid"
}
consume() { local file="$1" lock="$1.lock" tmp="$1.used"; mkdir -m 700 "$lock" 2>/dev/null || die "approval is already consumed"; [[ "$(value "$file" state)" == unused ]] || die "approval is already consumed"; sed 's/^state\tunused$/state\tconsumed/' "$file" >"$tmp"; chmod 600 "$tmp"; mv "$tmp" "$file"; rmdir "$lock"; }
root_installer() {
  local stage="$1"; shift; local copy="/var/tmp/nextcloud-pi-installer-$(date -u +%Y%m%dT%H%M%SZ)-$$" args='' argument script_hash command
  script_hash="$(sha256 "$ROOT/privileged/nextcloud-pi-bundle-installer")"
  for argument in "$@"; do printf -v args '%s %q' "$args" "$argument"; done
  printf -v command 'set -euo pipefail; trap %q EXIT; /usr/bin/install -m 0700 -o root -g root %q %q; test "$(/usr/bin/sha256sum %q | /usr/bin/awk '\''{print $1}'\'')" = %q; %q%s' "/usr/bin/rm -f -- $copy" "$stage/nextcloud-pi-bundle-installer" "$copy" "$copy" "$script_hash" "$copy" "$args"
  ssh -tt -o ConnectTimeout=10 "$REMOTE" "sudo /bin/bash -c $(printf '%q' "$command")"
}
plan() {
  local package="$TMP_DIR/package" id now fingerprint artifact expected
  build_package "$package"; expected="$(sha256 "$package/bundle-manifest.tsv")"
  remote "test \"\$(hostname)\" = '$NEXTCLOUD_PI_SYSTEM_HOSTNAME' && test \"\$(id -un)\" = '$NEXTCLOUD_PI_USER' && test \"\$(findmnt -rn --target '$NEXTCLOUD_STORAGE_MOUNT' -o TARGET)\" = '$NEXTCLOUD_STORAGE_MOUNT' && test \"\$(findmnt -rn --target '$NEXTCLOUD_STORAGE_MOUNT' -o FSTYPE)\" = ext4" || die "target identity differs"
  id="$(date -u +%Y%m%dT%H%M%SZ)-$$"; now="$(date -u +%s)"; fingerprint="$(sha256 "$package/package-manifest.tsv")"; mkdir -p "$APPROVAL_ROOT/package-$id"; chmod 700 "$APPROVAL_ROOT" "$APPROVAL_ROOT/package-$id"; cp -R "$package/." "$APPROVAL_ROOT/package-$id/"
  artifact="$APPROVAL_ROOT/approval-$id.tsv"; printf 'format\tprivileged-interface-approval-v1\nstate\tunused\nid\t%s\nfingerprint\t%s\nhost\t%s\ncreated\t%s\nexpires\t%s\npackage\t%s\n' "$id" "$fingerprint" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$now" "$((now + 900))" "$APPROVAL_ROOT/package-$id" >"$artifact"; chmod 600 "$artifact"
  printf 'Privileged-interface plan:\n  target: %s\n  bundle manifest: %s\n  fingerprint: %s\n  actions: validate,snapshot,install,sudoers-last,prove-dispatcher\nApproval artifact: %s\n' "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$expected" "$fingerprint" "$artifact"
}
apply() {
  local artifact="$1" id fingerprint package stage rebuilt="$TMP_DIR/rebuilt"
  [[ -f "$artifact" && ! -L "$artifact" ]] || die "approval is invalid"
  validate_approval "$artifact"
  [[ "$(value "$artifact" format)" == privileged-interface-approval-v1 && "$(value "$artifact" state)" == unused && "$(value "$artifact" host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" && $(date -u +%s) -le $(value "$artifact" expires) ]] || die "approval is invalid"
  id="$(value "$artifact" id)"; fingerprint="$(value "$artifact" fingerprint)"; package="$(value "$artifact" package)"; [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ && "$fingerprint" =~ ^[0-9a-f]{64}$ && -d "$package" && ! -L "$package" && -f "$package/package-manifest.tsv" && ! -L "$package/package-manifest.tsv" ]] || die "approval fields are invalid"; build_package "$rebuilt"; [[ "$(sha256 "$rebuilt/package-manifest.tsv")" == "$fingerprint" && "$(sha256 "$package/package-manifest.tsv")" == "$fingerprint" ]] || die "approved bundle differs"
  consume "$artifact"; stage="$NEXTCLOUD_REMOTE_PROJECT_DIR/.privileged-interface-$id"; remote "umask 077; test ! -e '$stage'; mkdir -m 0700 '$stage'" || die "remote stage failed"; scp -q -r "$rebuilt/." "$REMOTE:$stage/" || die "bundle transfer failed"; root_installer "$stage" install "$stage" "$id" "$fingerprint" "$NEXTCLOUD_PI_USER" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$NEXTCLOUD_STORAGE_MOUNT" "$NEXTCLOUD_STORAGE_UUID" "$NEXTCLOUD_IMAGE_PLATFORM" "$NEXTCLOUD_REMOTE_PROJECT_DIR"; remote "rm -rf '$stage'" || die "bundle installed but remote stage remains"
}
build_repair_package() {
  local package="$1" original="$2" freeze_id="$3" observed="$4" installed="$5" size original_hash
  [[ -f "$original" && ! -L "$original" && "$freeze_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ && "$observed" =~ ^[0-9a-f]{64}$ && "$installed" =~ ^[0-9a-f]{64}$ ]] || die "repair proof fields are invalid"
  [[ "$(deployment_config_mode "$original")" == 600 ]] || die "repair snapshot must have mode 0600"
  size="$(wc -c <"$original" | tr -d '[:space:]')"; [[ "$size" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$size <= 65536 )) || die "repair snapshot size is invalid"
  original_hash="$(sha256 "$original")"
  build_package "$package"
  cp "$original" "$package/original-freeze.json"; chmod 600 "$package/original-freeze.json"
  printf 'format\theld-freeze-repair-v1\nfreeze_id\t%s\noriginal_sha256\t%s\ncurrent_raw_sha256\t%s\nsize\t%s\ninstalled_manifest_sha256\t%s\n' "$freeze_id" "$original_hash" "$observed" "$size" "$installed" >"$package/repair-binding.tsv"
  for name in repair-binding.tsv original-freeze.json; do printf 'file\t%s\t%s\n' "$name" "$(sha256 "$package/$name")" >>"$package/package-manifest.tsv"; done
}
plan_repair() {
  local original="$1" freeze_id="$2" observed="$3" installed id now package="$TMP_DIR/repair" fingerprint artifact
  installed="$(remote 'sudo -n /usr/local/libexec/nextcloud-pi-ops version' | awk -F '\t' '$1 == "manifest_sha256" {n++; value=$2} END {if (n == 1) print value; else exit 1}')" || die "cannot read installed bundle identity"
  build_repair_package "$package" "$original" "$freeze_id" "$observed" "$installed"
  id="$(date -u +%Y%m%dT%H%M%SZ)-$$"; now="$(date -u +%s)"; fingerprint="$(sha256 "$package/package-manifest.tsv")"
  mkdir -p "$APPROVAL_ROOT/package-$id"; chmod 700 "$APPROVAL_ROOT" "$APPROVAL_ROOT/package-$id"; cp -R "$package/." "$APPROVAL_ROOT/package-$id/"
  artifact="$APPROVAL_ROOT/approval-$id.tsv"
  {
    printf 'format\theld-freeze-repair-approval-v1\nstate\tunused\nid\t%s\nfingerprint\t%s\nhost\t%s\ncreated\t%s\nexpires\t%s\npackage\t%s\nmode\trepair-held-freeze\n' "$id" "$fingerprint" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$now" "$((now + 900))" "$APPROVAL_ROOT/package-$id"
    awk -F '\t' '$1 != "format"' "$package/repair-binding.tsv"
  } >"$artifact"; chmod 600 "$artifact"
  printf 'Held-freeze repair plan:\n  fingerprint: %s\n  actions: prove-closed,snapshot-two-files,install-helper-and-manifest,adopt-original-proof,start-guarded-runtime\n  ingress and scheduler remain held; stage is not accepted\nApproval artifact: %s\n' "$fingerprint" "$artifact"
}
apply_repair() {
  local artifact="$1" id fingerprint package rebuilt="$TMP_DIR/rebuilt" stage key created expires now
  [[ -f "$artifact" && ! -L "$artifact" ]] || die "repair approval is invalid"
  awk -F '\t' 'BEGIN {split("format state id fingerprint host created expires package mode freeze_id original_sha256 current_raw_sha256 size installed_manifest_sha256", a, " "); for (i in a) keys[a[i]]=1} NF != 2 || !($1 in keys) || seen[$1]++ {bad=1} END {for (key in keys) if (seen[key] != 1) bad=1; exit bad}' "$artifact" || die "repair approval schema is invalid"
  created="$(value "$artifact" created)"; expires="$(value "$artifact" expires)"; now="$(date -u +%s)"
  [[ "$created" =~ ^[0-9]{10}$ && "$expires" =~ ^[0-9]{10}$ ]] && (( now >= created && now <= expires && expires - created == 900 )) || die "repair approval expired or invalid"
  [[ "$(value "$artifact" format)" == held-freeze-repair-approval-v1 && "$(value "$artifact" mode)" == repair-held-freeze && "$(value "$artifact" state)" == unused && "$(value "$artifact" host)" == "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" ]] || die "repair approval differs"
  id="$(value "$artifact" id)"; fingerprint="$(value "$artifact" fingerprint)"; package="$(value "$artifact" package)"
  [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ && "$fingerprint" =~ ^[0-9a-f]{64}$ && "$package" == "$APPROVAL_ROOT/package-$id" && -d "$package" && ! -L "$package" && -f "$package/package-manifest.tsv" && ! -L "$package/package-manifest.tsv" ]] || die "repair approval fields are invalid"
  build_repair_package "$rebuilt" "$package/original-freeze.json" "$(value "$artifact" freeze_id)" "$(value "$artifact" current_raw_sha256)" "$(value "$artifact" installed_manifest_sha256)"
  for key in freeze_id original_sha256 current_raw_sha256 size installed_manifest_sha256; do
    [[ "$(value "$rebuilt/repair-binding.tsv" "$key")" == "$(value "$artifact" "$key")" ]] || die "repair proof changed"
  done
  [[ "$(sha256 "$rebuilt/package-manifest.tsv")" == "$fingerprint" && "$(sha256 "$package/package-manifest.tsv")" == "$fingerprint" ]] || die "approved repair bundle differs"
  consume "$artifact"
  stage="$NEXTCLOUD_REMOTE_PROJECT_DIR/.privileged-interface-$id"
  remote "umask 077; test ! -e '$stage'; mkdir -m 0700 '$stage'" || die "remote stage failed"
  scp -q -r "$rebuilt/." "$REMOTE:$stage/" || die "repair transfer failed"
  root_installer "$stage" repair-held-freeze "$stage" "$id" "$fingerprint" "$NEXTCLOUD_PI_USER" "$NEXTCLOUD_PI_SYSTEM_HOSTNAME" "$NEXTCLOUD_STORAGE_MOUNT" "$NEXTCLOUD_STORAGE_UUID" "$NEXTCLOUD_IMAGE_PLATFORM" "$NEXTCLOUD_REMOTE_PROJECT_DIR"
  remote "rm -rf '$stage'" || die "repair completed but remote stage remains"
}

mode="${1:-}"
case "$mode" in
  --plan-held-freeze-repair) [[ $# == 4 ]] || die 'usage: --plan-held-freeze-repair ORIGINAL_SNAPSHOT FREEZE_ID CURRENT_RAW_SHA'; plan_repair "$2" "$3" "$4";;
  --apply-held-freeze-repair) [[ $# == 2 ]] || die 'usage: --apply-held-freeze-repair APPROVAL'; apply_repair "$2";;
  --plan) [[ $# == 1 ]] || die 'usage: --plan'; plan;;
  --apply) [[ $# == 2 ]] || die 'usage: --apply APPROVAL'; apply "$2";;
  --rollback) [[ $# == 2 ]] || die 'usage: --rollback ID'; id="$(date -u +%Y%m%dT%H%M%SZ)-$$"; stage="$NEXTCLOUD_REMOTE_PROJECT_DIR/.privileged-admin-$id"; remote "mkdir -m 0700 '$stage'"; scp -q "$ROOT/privileged/nextcloud-pi-bundle-installer" "$REMOTE:$stage/"; root_installer "$stage" rollback "$2"; remote "rm -rf '$stage'";;
  --revoke|--remove) [[ $# == 1 ]] || die "usage: $mode"; id="$(date -u +%Y%m%dT%H%M%SZ)-$$"; stage="$NEXTCLOUD_REMOTE_PROJECT_DIR/.privileged-admin-$id"; remote "mkdir -m 0700 '$stage'"; scp -q "$ROOT/privileged/nextcloud-pi-bundle-installer" "$REMOTE:$stage/"; root_installer "$stage" "${mode#--}"; remote "rm -rf '$stage'";;
  *) die 'usage: --plan | --apply APPROVAL | --plan-held-freeze-repair SNAPSHOT FREEZE_ID CURRENT_RAW_SHA | --apply-held-freeze-repair APPROVAL | --rollback ID | --revoke | --remove';;
esac
