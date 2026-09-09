#!/usr/bin/env bash
set -euo pipefail
readonly LIFECYCLE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/run-image-restore-readiness.sh"
bash -n "$LIFECYCLE"
for action in 'image-readiness check' 'image-readiness start' 'image-readiness status' 'image-readiness stop' 'image-readiness cleanup'; do grep -Fq "$action" "$LIFECYCLE"; done
grep -Fq 'test-image-restore-readiness.sh" --docker-host "unix://$LOCAL_SOCKET" "$recovery"' "$LIFECYCLE"
! grep -Eq 'sudo -n (nohup|cat|awk|kill|rm|dockerd)' "$LIFECYCLE"
! grep -Fq '/var/run/docker.sock' "$LIFECYCLE"
printf 'isolated image-readiness lifecycle behavior tests passed\n'
