#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bad=0
while IFS= read -r line; do
  text="${line#*:}:"
  remainder="${text//sudo -n \/usr\/local\/libexec\/nextcloud-pi-ops/}"
  if [[ "$remainder" == *'sudo -n '* ]]; then printf 'direct sudo use: %s\n' "$line" >&2; bad=1; fi
done < <(rg -n --glob '*.sh' --glob '!check-privileged-sudo-calls.sh' 'sudo -n' "$ROOT/scripts" | rg -v '/test-' || true)
(( bad == 0 )) || exit 1
printf 'privileged sudo-call policy passed\n'
