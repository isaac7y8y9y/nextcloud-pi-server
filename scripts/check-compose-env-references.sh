#!/usr/bin/env bash
set -euo pipefail

# Validate only the deployable Compose database assignments. Test fixtures and
# documentation may contain illustrative assignment text, so they are not a
# deployment safety signal.

usage() {
  cat <<'EOF'
Usage: ./scripts/check-compose-env-references.sh <compose-file>

Verify that the database variables in a Compose file use only their matching
${MYSQL_*} references and appear in the expected services.
EOF
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }

# COMPOSE_FILE is a tracked deployment input in preflight and a disposable
# fixture in tests. Never print its contents because it may be rendered later.
readonly COMPOSE_FILE="$1"
[[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]] || {
  printf 'Compose file is missing or symbolic-linked\n' >&2
  exit 1
}

# The database receives all four values; the app receives the user/database
# values too. A non-reference value or a missing/extra assignment fails closed.
awk '
  BEGIN {
    expected["MYSQL_ROOT_PASSWORD"] = 1
    expected["MYSQL_PASSWORD"] = 2
    expected["MYSQL_DATABASE"] = 2
    expected["MYSQL_USER"] = 2
  }
  {
    line = $0
    sub(/^[[:space:]]*-[[:space:]]*/, "", line)
    for (key in expected) {
      prefix = key "="
      if (index(line, prefix) == 1) {
        total[key]++
        reference = sprintf("%c{%s}", 36, key)
        value = substr(line, length(prefix) + 1)
        sub(/[[:space:]]*$/, "", value)
        if (value == reference) references[key]++
        else non_reference[key]++
      }
    }
  }
  END {
    failed = 0
    for (key in expected) {
      if (total[key] != expected[key] || references[key] != total[key] || non_reference[key] != 0) failed = 1
    }
    exit failed
  }
' "$COMPOSE_FILE"
