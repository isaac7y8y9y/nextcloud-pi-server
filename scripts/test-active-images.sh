#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$SCRIPT_DIR/lib/active-images.sh"
grep -Fq "stat -c '%u' \"\$RECORD\")\" == 0" "$REPOSITORY_ROOT/systemd/nextcloud-pi-validate-active-images"

record="$TEST_DIR/active-images.env"
cat >"$record" <<'EOF'
NEXTCLOUD_ACTIVE_IMAGES_FORMAT=nextcloud-active-images-v1
NEXTCLOUD_ACTIVE_IMAGES_MODE=recovered
NEXTCLOUD_ACTIVE_IMAGES_HOST=pi-test
NEXTCLOUD_ACTIVE_IMAGES_PROJECT=/srv/nextcloud-docker
NEXTCLOUD_ACTIVE_IMAGES_STORAGE=/mnt/test-nextcloud
NEXTCLOUD_ACTIVE_IMAGES_PLATFORM=linux/arm64/v8
NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEXTCLOUD_ACTIVE_IMAGES_APP_TAG=nextcloud:30
NEXTCLOUD_ACTIVE_IMAGES_APP_ID=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEXTCLOUD_ACTIVE_IMAGES_DB_TAG=mariadb:11
NEXTCLOUD_ACTIVE_IMAGES_DB_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NEXTCLOUD_ACTIVE_IMAGES_CADDY_TAG=caddy:2
NEXTCLOUD_ACTIVE_IMAGES_CADDY_ID=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF
active_images_validate_file "$record" pi-test /srv/nextcloud-docker /mnt/test-nextcloud

sed -i.bak 's/NEXTCLOUD_ACTIVE_IMAGES_MODE=recovered/NEXTCLOUD_ACTIVE_IMAGES_MODE=source/' "$record"
active_images_validate_file "$record" pi-test /srv/nextcloud-docker /mnt/test-nextcloud
sed -i.bak 's/NEXTCLOUD_ACTIVE_IMAGES_MODE=source/NEXTCLOUD_ACTIVE_IMAGES_MODE=recovered/' "$record"

if active_images_validate_file "$record" wrong-host /srv/nextcloud-docker /mnt/test-nextcloud >/dev/null 2>&1; then
  echo 'expected active-image target tampering to fail' >&2
  exit 1
fi

sed -i.bak 's/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/not-an-image-id/' "$record"
if active_images_validate_file "$record" pi-test /srv/nextcloud-docker /mnt/test-nextcloud >/dev/null 2>&1; then
  echo 'expected active-image mapping tampering to fail' >&2
  exit 1
fi
sed -i.bak 's/not-an-image-id/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$record"

sed -i.bak 's/NEXTCLOUD_ACTIVE_IMAGES_MODE=recovered/NEXTCLOUD_ACTIVE_IMAGES_MODE=invalid/' "$record"
if active_images_validate_file "$record" pi-test /srv/nextcloud-docker /mnt/test-nextcloud >/dev/null 2>&1; then
  echo 'expected invalid active-image mode to fail' >&2
  exit 1
fi
sed -i.bak 's/NEXTCLOUD_ACTIVE_IMAGES_MODE=invalid/NEXTCLOUD_ACTIVE_IMAGES_MODE=recovered/' "$record"
printf 'NEXTCLOUD_ACTIVE_IMAGES_MODE=recovered\n' >>"$record"
if active_images_validate_file "$record" pi-test /srv/nextcloud-docker /mnt/test-nextcloud >/dev/null 2>&1; then
  echo 'expected duplicate active-image key to fail' >&2
  exit 1
fi
sed -i.bak '$d' "$record"
printf 'NEXTCLOUD_ACTIVE_IMAGES_EXTRA=value\n' >>"$record"
if active_images_validate_file "$record" pi-test /srv/nextcloud-docker /mnt/test-nextcloud >/dev/null 2>&1; then
  echo 'expected an unknown active-image key to fail' >&2
  exit 1
fi

rm -f "$record.bak"
ln -s "$record" "$TEST_DIR/active-images-link.env"
if active_images_validate_file "$TEST_DIR/active-images-link.env" pi-test /srv/nextcloud-docker /mnt/test-nextcloud >/dev/null 2>&1; then
  echo 'expected symbolic-linked active-image record to fail' >&2
  exit 1
fi
echo 'active-image record tests passed'
