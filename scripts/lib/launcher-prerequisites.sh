#!/usr/bin/env bash

# Keep deployment planning and conformance aligned with the root launcher's
# runtime dependencies. The caller provides the non-interactive remote helper.
launcher_prerequisites_remote() {
  remote "set -eu; command -v python3 >/dev/null; docker compose up --help | grep -F -- '--pull' >/dev/null; snapshot=\$(printf 'services:\n  probe:\n    image: busybox:latest\n' | docker compose -f - config --format json); printf '%s\n' \"\$snapshot\" | docker compose -f - config --format json >/dev/null"
}
