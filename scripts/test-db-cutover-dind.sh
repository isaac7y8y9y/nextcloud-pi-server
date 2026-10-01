#!/usr/bin/env bash
# Isolated daemon-restart proof for a synthetic clean-directory DB cutover.
set -euo pipefail

command -v docker >/dev/null 2>&1 || { printf 'Docker is required\n' >&2; exit 1; }
docker info >/dev/null
fixture="$(mktemp -d)"
name="nextcloud-db-cutover-fixture-$$"
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf -- "$fixture"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$fixture/storage/nextcloud_db" "$fixture/storage/.db-cutover-synthetic/data"
printf 'original\n' >"$fixture/storage/nextcloud_db/identity"
printf 'imported\n' >"$fixture/storage/.db-cutover-synthetic/data/identity"

docker image inspect docker:29-dind ubuntu:24.04 >/dev/null
docker run -d --privileged --name "$name" --network none \
  --mount "type=bind,source=$fixture/storage,target=/storage" \
  docker:29-dind --storage-driver=vfs >/dev/null
ready=no
for _ in {1..60}; do
  if docker exec "$name" docker info >/dev/null 2>&1; then ready=yes; break; fi
  sleep 1
done
[[ "$ready" == yes ]] || { printf 'isolated Docker daemon did not start\n' >&2; exit 1; }

docker save ubuntu:24.04 | docker exec -i "$name" docker load >/dev/null
docker exec "$name" docker run -d --network none --restart=always --name old-db \
  --mount type=bind,source=/storage/nextcloud_db,target=/db \
  ubuntu:24.04 bash -c 'trap "exit 0" TERM; while :; do sleep 1 & wait $!; done' >/dev/null
[[ "$(docker exec "$name" docker exec old-db cat /db/identity)" == original ]]

docker exec "$name" docker update --restart=no old-db >/dev/null
docker exec "$name" docker stop --time 30 old-db >/dev/null
docker exec "$name" docker rm old-db >/dev/null
[[ -z "$(docker exec "$name" docker ps -aq --no-trunc --filter name='^/old-db$')" ]]

docker exec "$name" mv -T --no-clobber -- /storage/nextcloud_db /storage/.nextcloud-db-before-synthetic
docker exec "$name" mv -T --no-clobber -- /storage/.db-cutover-synthetic/data /storage/nextcloud_db
[[ "$(<"$fixture/storage/.nextcloud-db-before-synthetic/identity")" == original ]]
[[ "$(<"$fixture/storage/nextcloud_db/identity")" == imported ]]

docker restart "$name" >/dev/null
ready=no
for _ in {1..60}; do
  if docker exec "$name" docker info >/dev/null 2>&1; then ready=yes; break; fi
  sleep 1
done
[[ "$ready" == yes ]] || { printf 'isolated Docker daemon did not restart\n' >&2; exit 1; }
[[ -z "$(docker exec "$name" docker ps -aq --no-trunc --filter name='^/old-db$')" ]]

docker exec "$name" docker run -d --network none --restart=always --name new-db \
  --mount type=bind,source=/storage/nextcloud_db,target=/db \
  ubuntu:24.04 bash -c 'trap "exit 0" TERM; while :; do sleep 1 & wait $!; done' >/dev/null
[[ "$(docker exec "$name" docker exec new-db cat /db/identity)" == imported ]]
[[ "$(docker exec "$name" docker inspect --format '{{range .Mounts}}{{if eq .Destination "/db"}}{{.Source}}{{end}}{{end}}' new-db)" == /storage/nextcloud_db ]]
docker restart "$name" >/dev/null
ready=no
for _ in {1..60}; do
  if docker exec "$name" docker info >/dev/null 2>&1; then ready=yes; break; fi
  sleep 1
done
[[ "$ready" == yes ]] || { printf 'isolated Docker daemon did not restart with candidate\n' >&2; exit 1; }
[[ "$(docker exec "$name" docker inspect --format '{{.State.Running}}' new-db)" == true ]]
[[ "$(docker exec "$name" docker exec new-db cat /db/identity)" == imported ]]
[[ -z "$(docker exec "$name" docker ps -aq --no-trunc --filter name='^/old-db$')" ]]

printf 'isolated Docker daemon restart and database mount proof passed\n'
