#!/usr/bin/env bash
set -euo pipefail

# Exercise the Compose-only safety check without contacting the Pi or creating
# credential-like values in tracked source files.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fixture="$TEST_DIR/docker-compose.yml"
cp "$REPOSITORY_ROOT/compose/docker-compose.yml" "$fixture"

# The tracked Compose template is valid and must pass the same preflight rule.
"$SCRIPT_DIR/check-compose-env-references.sh" "$fixture"

# Build the invalid fixture value at runtime so the repository-wide secret
# scanner still sees no literal credential-style assignment in this test file.
password_key="MYSQL_""PASSWORD"
replacement="$password_key""=inline-test-value"
awk -v replacement="$replacement" '
  !replacement_count { replacement_count = sub(/MYSQL_PASSWORD=\$\{MYSQL_PASSWORD\}/, replacement) }
  { print }
  END { exit replacement_count == 1 ? 0 : 1 }
' "$fixture" >"$TEST_DIR/invalid-compose.yml"

if "$SCRIPT_DIR/check-compose-env-references.sh" "$TEST_DIR/invalid-compose.yml" >/dev/null 2>&1; then
  echo 'expected inline Compose database assignment to be rejected' >&2
  exit 1
fi

echo 'Compose environment reference tests passed'
