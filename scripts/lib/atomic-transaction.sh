#!/usr/bin/env bash

# Shared privileged file primitives for the production deployment and its
# disposable drill. Callers own transaction ordering and rollback policy.

atomic_install_root() {
  local source="$1" target="$2" mode="$3" tmp
  tmp="$(dirname -- "$target")/.nextcloud-pi-$(basename -- "$target").$$.new"
  if ! sudo -n install -m "$mode" "$source" "$tmp" || ! sudo -n mv -f "$tmp" "$target"; then
    sudo -n rm -f "$tmp"
    return 1
  fi
}

atomic_restore_root() {
  local source="$1" target="$2" tmp
  tmp="$(dirname -- "$target")/.nextcloud-pi-$(basename -- "$target").$$.restore"
  if ! sudo -n cp -p "$source" "$tmp" || ! sudo -n mv -f "$tmp" "$target"; then
    sudo -n rm -f "$tmp"
    return 1
  fi
}

atomic_replace_preserve() {
  local source="$1" target="$2" mode="$3" uid gid tmp
  [[ -f "$target" && ! -L "$target" ]] || return 1
  uid="$(stat -c '%u' "$target")" || return 1
  gid="$(stat -c '%g' "$target")" || return 1
  tmp="$(dirname -- "$target")/.nextcloud-pi-$(basename -- "$target").$$.replace"
  if ! sudo -n install -m "$mode" -o "$uid" -g "$gid" "$source" "$tmp" || ! sudo -n mv -f "$tmp" "$target"; then
    sudo -n rm -f "$tmp"
    return 1
  fi
}
