#!/usr/bin/env bash
set -euo pipefail

# The fake transport proves approval consumption without contacting the Pi;
# a live network/daemon rehearsal remains a separate gate.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly FETCH="$SCRIPT_DIR/fetch-image-upgrade.sh"
bash -n "$FETCH"
for expected in \
  'verify-image-upgrade.py' \
  'verify-config-backup.sh' \
  'verify-runtime-backup.sh' \
  'verify-image-recovery.sh' \
  'runtime-backup-v2' \
  'upgrade-freeze status' \
  'resolve-image-upgrade.py' \
  'candidate, recovery evidence, or Pi pre-state changed' \
  'pull-exact-digest,verify-loaded-id' \
  'docker pull --platform linux/arm64/v8' \
  'docker image inspect --format' \
  'approval was consumed'; do
  grep -Fq "$expected" "$FETCH"
done
! grep -Eq 'docker (compose pull|image prune|system prune|rmi|tag|run|create|start|stop)' "$FETCH"
! grep -Eq 'active-record (prepare|apply|rollback|commit)|upgrade-freeze release|service (restart|stop|start)' "$FETCH"
awk '/^chmod 600 "\$TMP_DIR\/consumed.tsv"/ { consumed=NR } /remote "docker pull --platform/ { pull=NR } END { exit !(consumed > 0 && pull > consumed) }' "$FETCH"

fixture="$(mktemp -d)"
fixture="$(cd -- "$fixture" && pwd -P)"
trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/repo/scripts/lib" "$fixture/repo/config" "$fixture/bin" "$fixture/rendered/caddy" "$fixture/rendered/active-images" "$fixture/candidate" "$fixture/config-backup/compose" "$fixture/config-backup/caddy" "$fixture/runtime-backup" "$fixture/image-recovery"
cp "$FETCH" "$fixture/repo/scripts/fetch-image-upgrade.sh"
cp "$SCRIPT_DIR/lib/deployment-config.sh" "$SCRIPT_DIR/lib/image-lock.sh" "$fixture/repo/scripts/lib/"
cp "$SCRIPT_DIR/../config/image-lock.env" "$fixture/repo/config/image-lock.env"
printf 'NEXTCLOUD_PI_HOST=test-pi.example.invalid\nNEXTCLOUD_PI_SYSTEM_HOSTNAME=test-pi\nNEXTCLOUD_PI_USER=tester\nNEXTCLOUD_REMOTE_PROJECT_DIR=/srv/test/nextcloud-docker\nNEXTCLOUD_STORAGE_MOUNT=/srv/test/storage\nNEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111\nNEXTCLOUD_PUBLIC_HOSTNAME=cloud.test.invalid\n' >"$fixture/deployment.env"
chmod 600 "$fixture/deployment.env"
printf 'services:\n' >"$fixture/rendered/docker-compose.yml"
printf 'test caddy\n' >"$fixture/rendered/caddy/Caddyfile"
printf 'source record\n' >"$fixture/rendered/active-images/active-images.env"
printf 'candidate\n' >"$fixture/candidate/candidate-manifest.tsv"
printf 'format\tnextcloud-upgrade-image-v1\nimage\tnextcloud\ntag\tnextcloud:31.0.14-apache\nplatform\tlinux/arm64/v8\nindex_digest\tsha256:%064d\nmanifest_digest\tsha256:%064d\nconfig_digest\tsha256:%064d\n' 0 1 2 >"$fixture/candidate/registry-metadata.tsv"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
printf 'timestamp\t%s\nremote_host\ttest-pi\nremote_user\ttester\nsource_project\t/srv/test/nextcloud-docker\n' "$timestamp" >"$fixture/config-backup/manifest.tsv"
cp "$fixture/rendered/docker-compose.yml" "$fixture/config-backup/compose/docker-compose.yml"
cp "$fixture/rendered/caddy/Caddyfile" "$fixture/config-backup/caddy/Caddyfile"
printf 'timestamp\t%s\nformat\truntime-backup-v2\nremote_host\ttest-pi\nremote_user\ttester\nsource_nextcloud\t/srv/test/storage/nextcloud\nfreeze_id\t20260924T000000Z-101\nfreeze_table_sha256\t%s\n' "$timestamp" "$(printf '%064d' 3)" >"$fixture/runtime-backup/manifest.tsv"
printf 'timestamp\t%s\nremote_host\ttest-pi\nremote_user\ttester\nsource_project\t/srv/test/nextcloud-docker\nstorage_mount\t/srv/test/storage\n' "$timestamp" >"$fixture/image-recovery/manifest.tsv"
printf 'timestamp\t%s\n' "$timestamp" >"$fixture/image-recovery/restore-attestation.tsv"
for verifier in verify-config-backup.sh verify-runtime-backup.sh verify-image-recovery.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/repo/scripts/$verifier"
  chmod 755 "$fixture/repo/scripts/$verifier"
done
printf '#!/usr/bin/env bash\ncase "$1" in *verify-image-upgrade.py) exit 0;; *resolve-image-upgrade.py) cat "$FETCH_FIXTURE/candidate/registry-metadata.tsv";; *) exit 1;; esac\n' >"$fixture/bin/python3"
chmod 755 "$fixture/bin/python3"
printf '%b' '#!/usr/bin/env bash\nset -euo pipefail\nfor arg; do command_text="$arg"; done\ncase "$command_text" in\n  *"upgrade-freeze status"*) printf "state\\tactive\\nid\\t20260924T000000Z-101\\ntable_sha256\\t%064d\\n" 3;;\n  *"background-jobs state"*) printf "timer_active\\tno\\n";;\n  *"occ status"*) printf "  - maintenance: true\\n";;\n  hostname) printf "test-pi\\n";;\n  "id -un") printf "tester\\n";;\n  "date -u +%s") date -u +%s;;\n  *"sha256sum"*"docker-compose.yml"*) shasum -a 256 "$FETCH_FIXTURE/rendered/docker-compose.yml";;\n  *"sha256sum"*"Caddyfile"*) shasum -a 256 "$FETCH_FIXTURE/rendered/caddy/Caddyfile";;\n  *"active-images-state"*) printf "mode\\tsource\\nsha256\\t%s\\n" "$(shasum -a 256 "$FETCH_FIXTURE/rendered/active-images/active-images.env" | awk "{print \\$1}")";;\n  *"docker image inspect"*"nextcloud:30"*) awk -F= "\\$1 == \\"NEXTCLOUD_IMAGE_APP_ID\\" {print \\$2}" "$FETCH_FIXTURE/repo/config/image-lock.env";;\n  *"docker image inspect"*"mariadb:11"*) awk -F= "\\$1 == \\"NEXTCLOUD_IMAGE_DB_ID\\" {print \\$2}" "$FETCH_FIXTURE/repo/config/image-lock.env";;\n  *"docker image inspect"*"caddy:2"*) awk -F= "\\$1 == \\"NEXTCLOUD_IMAGE_CADDY_ID\\" {print \\$2}" "$FETCH_FIXTURE/repo/config/image-lock.env";;\n  *"docker inspect"*"nextcloud-docker-app-1"*) printf "%064d %s true\\n" 4 "$(awk -F= "\\$1 == \\"NEXTCLOUD_IMAGE_APP_ID\\" {print \\$2}" "$FETCH_FIXTURE/repo/config/image-lock.env")";;\n  *"docker inspect"*"nextcloud-docker-db-1"*) printf "%064d %s true\\n" 5 "$(awk -F= "\\$1 == \\"NEXTCLOUD_IMAGE_DB_ID\\" {print \\$2}" "$FETCH_FIXTURE/repo/config/image-lock.env")";;\n  *"docker inspect"*"nextcloud-docker-caddy-1"*) printf "%064d %s true\\n" 6 "$(awk -F= "\\$1 == \\"NEXTCLOUD_IMAGE_CADDY_ID\\" {print \\$2}" "$FETCH_FIXTURE/repo/config/image-lock.env")";;\n  *"docker pull"*) printf "pull\\n" >>"$FETCH_FIXTURE/pulls";;\n  *"docker image inspect"*"nextcloud@sha256:"*) printf "sha256:%064d\\n" 2;;\n  *) printf "Unexpected fake SSH command: %s\\n" "$command_text" >&2; exit 1;;\nesac\n' >"$fixture/bin/ssh"
chmod 755 "$fixture/bin/ssh"
mv "$fixture/bin/ssh" "$fixture/bin/ssh-base"
printf '%b' '#!/usr/bin/env bash\nset -euo pipefail\ncase "$*" in\n  *"upgrade-fetch consume"*) [[ ! -e "$FETCH_FIXTURE/root-fetch" ]] || exit 1; printf "pending\\n" >"$FETCH_FIXTURE/root-fetch";;\n  *"upgrade-fetch complete"*) [[ "$(cat "$FETCH_FIXTURE/root-fetch")" == pending ]] || exit 1; printf "complete\\n" >"$FETCH_FIXTURE/root-fetch";;\n  *) exec "$FETCH_FIXTURE/bin/ssh-base" "$@";;\nesac\n' >"$fixture/bin/ssh"
chmod 755 "$fixture/bin/ssh"

export FETCH_FIXTURE="$fixture"
export NEXTCLOUD_DEPLOYMENT_ENV_FILE="$fixture/deployment.env"
export NEXTCLOUD_UPGRADE_FETCH_APPROVAL_ROOT="$fixture/approvals"
export PATH="$fixture/bin:$PATH"
inputs=("$fixture/candidate" "$fixture/rendered" "$fixture/config-backup" "$fixture/runtime-backup" "$fixture/image-recovery" 20260924T000000Z-101)
bash "$fixture/repo/scripts/fetch-image-upgrade.sh" --plan "${inputs[@]}" >"$fixture/plan.out"
artifact="$(awk -F ': ' '$1 == "Approval artifact" {print $2}' "$fixture/plan.out")"
[[ -f "$artifact" && ! -e "$fixture/pulls" ]]
cp "$artifact" "$fixture/expired.tsv"
sed $'s/^expires\t[0-9][0-9]*$/expires\t1/' "$fixture/expired.tsv" >"$fixture/expired.new"
mv "$fixture/expired.new" "$fixture/expired.tsv"
chmod 600 "$fixture/expired.tsv"
if bash "$fixture/repo/scripts/fetch-image-upgrade.sh" --apply "$fixture/expired.tsv" "${inputs[@]}" >"$fixture/expired.out" 2>&1; then
  printf 'expired image-fetch approval was accepted\n' >&2
  exit 1
fi
[[ ! -e "$fixture/pulls" ]]
cp "$artifact" "$fixture/tampered.tsv"
sed 's/pull-exact-digest,verify-loaded-id/pull-all-tags/' "$fixture/tampered.tsv" >"$fixture/tampered.new"
mv "$fixture/tampered.new" "$fixture/tampered.tsv"
chmod 600 "$fixture/tampered.tsv"
if bash "$fixture/repo/scripts/fetch-image-upgrade.sh" --apply "$fixture/tampered.tsv" "${inputs[@]}" >"$fixture/tampered.out" 2>&1; then
  printf 'tampered image-fetch actions were accepted\n' >&2
  exit 1
fi
[[ ! -e "$fixture/pulls" ]]
bash "$fixture/repo/scripts/fetch-image-upgrade.sh" --apply "$artifact" "${inputs[@]}" >"$fixture/apply.out"
grep -Fx $'state\tconsumed' "$artifact" >/dev/null
[[ "$(wc -l <"$fixture/pulls" | tr -d '[:space:]')" == 1 ]]
[[ "$(cat "$fixture/root-fetch")" == complete ]]
if bash "$fixture/repo/scripts/fetch-image-upgrade.sh" --apply "$artifact" "${inputs[@]}" >"$fixture/replay.out" 2>&1; then
  printf 'consumed image-fetch approval was replayed\n' >&2
  exit 1
fi
[[ "$(wc -l <"$fixture/pulls" | tr -d '[:space:]')" == 1 ]]
printf 'upgrade image fetch approval fixture passed\n'
