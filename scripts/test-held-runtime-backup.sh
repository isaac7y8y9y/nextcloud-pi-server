#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
grep -Fq "upgrade-freeze quiescence" "$SCRIPT_DIR/backup-runtime-state.sh"
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT HUP INT TERM
fixture_root="$(cd -- "$fixture_root" && pwd -P)"
backup="$fixture_root/runtime-backup-20260924T000000Z"
mkdir -m 700 "$backup" "$backup/nextcloud" "$backup/database" "$backup/caddy" "$fixture_root/source-nextcloud" "$fixture_root/source-caddy"
mkdir -m 700 "$fixture_root/source-nextcloud/nextcloud"
printf 'data\n' >"$fixture_root/source-nextcloud/nextcloud/example.txt"
printf 'tls\n' >"$fixture_root/source-caddy/data.txt"
COPYFILE_DISABLE=1 tar --format=ustar -cpf "$backup/nextcloud/nextcloud.tar" -C "$fixture_root/source-nextcloud" nextcloud
COPYFILE_DISABLE=1 tar --format=ustar -cpf "$backup/caddy/data.tar" -C "$fixture_root/source-caddy" .
COPYFILE_DISABLE=1 tar --format=ustar -cpf "$backup/caddy/config.tar" -C "$fixture_root/source-caddy" .
printf 'SELECT 1;\n' >"$backup/database/nextcloud.sql"
chmod 600 "$backup/nextcloud/nextcloud.tar" "$backup/database/nextcloud.sql" "$backup/caddy/data.tar" "$backup/caddy/config.tar"

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
payload() { printf 'payload\t%s\t%s\t%s\n' "$1" "$(wc -c <"$backup/$1" | tr -d '[:space:]')" "$(sha256 "$backup/$1")"; }
write_manifest() {
  local format="$1"
  {
    printf 'format\t%s\n' "$format"
    printf 'state\tcomplete\n'
    printf 'timestamp\t20260924T000000Z\n'
    printf 'remote_host\ttest-host\n'
    printf 'remote_user\ttest-user\n'
    printf 'source_nextcloud\t/test/nextcloud\n'
    printf 'app_container\ttest-app\n'
    printf 'database_container\ttest-db\n'
    printf 'database_image\tmariadb:test\n'
    printf 'caddy_data_volume\ttest-caddy-data\n'
    printf 'caddy_config_volume\ttest-caddy-config\n'
    printf 'backup_path\t%s\n' "$backup"
    if [[ "$format" == runtime-backup-v2 ]]; then
      printf 'freeze_id\t20260924T000000Z-101\n'
      printf 'freeze_table_sha256\t%s\n' "$(printf 'table' | if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | awk '{print $1}')"
    fi
    payload nextcloud/nextcloud.tar
    payload database/nextcloud.sql
    payload caddy/data.tar
    payload caddy/config.tar
  } >"$backup/manifest.tsv"
  chmod 600 "$backup/manifest.tsv"
}

write_manifest runtime-backup-v1
"$SCRIPT_DIR/verify-runtime-backup.sh" "$backup" >/dev/null
write_manifest runtime-backup-v2
"$SCRIPT_DIR/verify-runtime-backup.sh" "$backup" >/dev/null
sed -e 's/^freeze_id\t.*/freeze_id\tbad/' "$backup/manifest.tsv" >"$fixture_root/bad-manifest"
cp "$fixture_root/bad-manifest" "$backup/manifest.tsv"
chmod 600 "$backup/manifest.tsv"
if "$SCRIPT_DIR/verify-runtime-backup.sh" "$backup" >/dev/null 2>&1; then
  printf 'invalid held-freeze binding was accepted\n' >&2
  exit 1
fi
printf 'held runtime backup manifest tests passed\n'
