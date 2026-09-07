#!/usr/bin/env bash

# Atomic replacement for deployment-user-owned Compose and Caddy files only.
atomic_install_root() {
  # Compatibility primitive for the isolated regression fixture. Production
  # root writes are exclusively handled by nextcloud-pi-ops.
  local source="$1" target="$2" expected_mode="$3" temp
  temp="$(dirname -- "$target")/.nextcloud-pi-$(basename -- "$target").$$.new"
  if ! install -m "$expected_mode" "$source" "$temp" || ! mv -f "$temp" "$target"; then rm -f "$temp"; return 1; fi
}

atomic_replace_preserve() {
  local source="$1" target="$2" mode="$3" uid gid tmp
  [[ -f "$target" && ! -L "$target" ]] || return 1
  uid="$(stat -c '%u' "$target")" || return 1
  gid="$(stat -c '%g' "$target")" || return 1
  tmp="$(dirname -- "$target")/.nextcloud-pi-$(basename -- "$target").$$.replace"
  if ! cp "$source" "$tmp" || ! chmod "$mode" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ "$(stat -c '%g' "$tmp")" != "$gid" ]] && ! chgrp "$gid" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv -f "$tmp" "$target"; then rm -f "$tmp"; return 1; fi
}
