#!/usr/bin/env bash
# Static policy guard: production shell code may use passwordless sudo only
# through the least-privilege dispatcher.
set -euo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v rg >/dev/null 2>&1 || {
  printf 'ripgrep is required to scan production sudo calls\n' >&2
  exit 1
}
bad=0
while IFS= read -r line; do
  text="${line#*:}:"
  remainder="${text//sudo -n \/usr\/local\/libexec\/nextcloud-pi-ops/}"
  if [[ "$remainder" == *'sudo -n '* ]]; then printf 'direct sudo use: %s\n' "$line" >&2; bad=1; fi
done < <(rg -n --glob '*.sh' --glob '!check-privileged-sudo-calls.sh' 'sudo -n' "$ROOT/scripts" | rg -v '/test-' || true)
(( bad == 0 )) || exit 1
printf 'privileged sudo-call policy passed\n'
