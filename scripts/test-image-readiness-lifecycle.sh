#!/usr/bin/env bash
# Static guard for dispatcher-owned image-readiness isolation; it does not run
# the live lifecycle or load a recovery archive.
set -euo pipefail
readonly LIFECYCLE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/run-image-restore-readiness.sh"
readonly HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/privileged/nextcloud-pi-ops"
bash -n "$LIFECYCLE"
for action in 'image-readiness check' 'image-readiness start' 'image-readiness status' 'image-readiness stop' 'image-readiness cleanup'; do grep -Fq "$action" "$LIFECYCLE"; done
grep -Fq 'test-image-restore-readiness.sh" --docker-host "unix://$LOCAL_SOCKET" "$recovery"' "$LIFECYCLE"
grep -Fq '"--containerd-namespace=nextcloud-pi-readiness-$id"' "$HELPER"
grep -Fq '"--containerd-plugins-namespace=nextcloud-pi-readiness-plugins-$id"' "$HELPER"
grep -Fq 'mapfile -t expected < <(readiness_args "$id")' "$HELPER"
! grep -Eq 'sudo -n (nohup|cat|awk|kill|rm|dockerd)' "$LIFECYCLE"
! grep -Fq '/var/run/docker.sock' "$LIFECYCLE"
! grep -Fq -- '--containerd-namespace=moby' "$HELPER"
! grep -Fq -- '--containerd-plugins-namespace=plugins.moby' "$HELPER"
printf 'isolated image-readiness static contract tests passed\n'
