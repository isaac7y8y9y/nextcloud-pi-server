#!/usr/bin/env bash

# Shared loader for local-only deployment identity. Values are literal, never
# evaluated as shell code, and environment variables supplied by the caller
# take precedence over the ignored configuration file.

deployment_config_die() {
  # Keep loader errors generic so a captured terminal log cannot reveal a value.
  printf 'Error: %s\n' "$1" >&2
  return 1
}

deployment_config_mode() {
  # macOS and GNU stat use different flags for the octal permission mode.
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

deployment_config_allowed_key() {
  # The private file is a fixed schema, not a general-purpose shell environment.
  case "$1" in
    NEXTCLOUD_PI_HOST|NEXTCLOUD_PI_SYSTEM_HOSTNAME|NEXTCLOUD_PI_USER|NEXTCLOUD_REMOTE_PROJECT_DIR|NEXTCLOUD_STORAGE_MOUNT|NEXTCLOUD_STORAGE_UUID|NEXTCLOUD_PUBLIC_HOSTNAME)
      return 0
      ;;
    *) return 1 ;;
  esac
}

deployment_config_get() {
  # Read a named setting indirectly without evaluating its contents as shell code.
  local key="$1"
  printf '%s' "${!key-}"
}

deployment_config_set_if_unset() {
  # Caller-supplied environment values intentionally override the private file.
  local key="$1"
  local value="$2"

  if [[ -z "${!key-}" ]]; then
    printf -v "$key" '%s' "$value"
  fi
}

deployment_config_validate_path() {
  # These paths are interpolated into remote commands by operational scripts.
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$1" != *"/../"* ]] && [[ "$1" != */.. ]]
}

load_deployment_config() {
  # The optional override lets tests and automation select a private 0600 file;
  # normal use reads the ignored deployment file beneath the repository.
  local repository_root="$1"
  local config_file="${NEXTCLOUD_DEPLOYMENT_ENV_FILE:-$repository_root/config/deployment.env}"
  local line key value seen='|'
  local required_key
  local required_keys=(
    NEXTCLOUD_PI_HOST
    NEXTCLOUD_PI_SYSTEM_HOSTNAME
    NEXTCLOUD_PI_USER
    NEXTCLOUD_REMOTE_PROJECT_DIR
    NEXTCLOUD_STORAGE_MOUNT
    NEXTCLOUD_STORAGE_UUID
    NEXTCLOUD_PUBLIC_HOSTNAME
  )

  # Reject symlinks and permissive files before reading deployment identity.
  [[ -f "$config_file" && ! -L "$config_file" ]] || {
    deployment_config_die "missing local deployment configuration"
    return 1
  }
  [[ "$(deployment_config_mode "$config_file")" == "600" ]] || {
    deployment_config_die "deployment configuration must have mode 0600"
    return 1
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Parse literal KEY=value records; never source the file as shell code.
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || {
      deployment_config_die "deployment configuration contains an invalid line"
      return 1
    }
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    deployment_config_allowed_key "$key" || {
      deployment_config_die "deployment configuration contains an unknown key: $key"
      return 1
    }
    case "$seen" in
      *"|$key|"*) deployment_config_die "deployment configuration contains a duplicate key: $key"; return 1 ;;
    esac
    seen+="$key|"
    [[ -n "$value" && "$value" != *$'\r'* && "$value" != *[[:space:]]* ]] || {
      deployment_config_die "deployment configuration contains an unsafe value for $key"
      return 1
    }
    # A copied example is never deployable unless the caller explicitly supplies
    # an override for that setting.
    if [[ -z "${!key-}" ]]; then
      case "$value" in
        pi.example.invalid|pi-example|pi-user|/srv/nextcloud-docker|/mnt/example-nextcloud|00000000-0000-0000-0000-000000000000|nextcloud.example.invalid)
          deployment_config_die "deployment configuration still contains a placeholder for $key"
          return 1
          ;;
      esac
    fi
    deployment_config_set_if_unset "$key" "$value"
  done <"$config_file"

  # Ensure every consumer receives a complete set of validated settings.
  for required_key in "${required_keys[@]}"; do
    [[ -n "$(deployment_config_get "$required_key")" ]] || {
      deployment_config_die "missing required deployment setting: $required_key"
      return 1
    }
  done

  # Validate the syntax permitted by downstream SSH, filesystem, and template
  # interpolation; this also prevents shell metacharacters reaching remote calls.
  [[ "$(deployment_config_get NEXTCLOUD_PI_HOST)" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { deployment_config_die "NEXTCLOUD_PI_HOST contains unsupported characters"; return 1; }
  [[ "$(deployment_config_get NEXTCLOUD_PI_SYSTEM_HOSTNAME)" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { deployment_config_die "NEXTCLOUD_PI_SYSTEM_HOSTNAME contains unsupported characters"; return 1; }
  [[ "$(deployment_config_get NEXTCLOUD_PI_USER)" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { deployment_config_die "NEXTCLOUD_PI_USER contains unsupported characters"; return 1; }
  deployment_config_validate_path "$(deployment_config_get NEXTCLOUD_REMOTE_PROJECT_DIR)" || { deployment_config_die "NEXTCLOUD_REMOTE_PROJECT_DIR must be a simple absolute path"; return 1; }
  [[ "${NEXTCLOUD_REMOTE_PROJECT_DIR##*/}" == "nextcloud-docker" ]] || { deployment_config_die "NEXTCLOUD_REMOTE_PROJECT_DIR must end in nextcloud-docker"; return 1; }
  deployment_config_validate_path "$(deployment_config_get NEXTCLOUD_STORAGE_MOUNT)" || { deployment_config_die "NEXTCLOUD_STORAGE_MOUNT must be a simple absolute path"; return 1; }
  [[ "$(deployment_config_get NEXTCLOUD_STORAGE_UUID)" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || { deployment_config_die "NEXTCLOUD_STORAGE_UUID must be a UUID"; return 1; }
  [[ "$(deployment_config_get NEXTCLOUD_PUBLIC_HOSTNAME)" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { deployment_config_die "NEXTCLOUD_PUBLIC_HOSTNAME contains unsupported characters"; return 1; }

  # Export only the file location so child checks can compare values in memory.
  export NEXTCLOUD_DEPLOYMENT_ENV_FILE="$config_file"
}
