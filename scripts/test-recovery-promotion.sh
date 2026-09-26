#!/usr/bin/env bash
# Fault-inject every directory move in the guarded recovery promotion sequence.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
wrapper="$fixture/move"
cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count="$(<"$RECOVERY_TEST_ROOT/count")"
count=$((count + 1))
printf '%s\n' "$count" >"$RECOVERY_TEST_ROOT/count"
[[ "$count" != "$(<"$RECOVERY_TEST_ROOT/fail")" ]] || exit 1
shift 3
mv -- "$1" "$2"
SH
chmod 700 "$wrapper"
export RECOVERY_TEST_ROOT="$fixture"
function_text="$(sed -n '/^recovery_promote_pair() {/,/^}/p' "$root/privileged/nextcloud-pi-ops")"
[[ -n "$function_text" ]] || exit 1
function_text="${function_text//\/usr\/bin\/mv/$wrapper}"
eval "$function_text"
no_nested_mounts() { return 0; }
die() { printf '%s\n' "$1" >&2; exit 1; }

for failure in {1..8}; do
  test_dir="$fixture/case-$failure"
  mkdir -p "$test_dir"
  for index in {1..4}; do
    mkdir "$test_dir/staged-$index" "$test_dir/live-$index"
    printf 'restored\n' >"$test_dir/staged-$index/data"
    printf 'failed\n' >"$test_dir/live-$index/data"
  done
  printf '0\n' >"$fixture/count"
  printf '%s\n' "$failure" >"$fixture/fail"
  if (
    for index in {1..4}; do
      recovery_promote_pair "$test_dir/staged-$index" "$test_dir/live-$index" "$test_dir/failed-$index"
    done
  ) >/dev/null 2>&1; then
    printf 'promotion did not fail at move %s\n' "$failure" >&2
    exit 1
  fi
  printf '0\n' >"$fixture/fail"
  for index in {1..4}; do
    recovery_promote_pair "$test_dir/staged-$index" "$test_dir/live-$index" "$test_dir/failed-$index"
    [[ ! -e "$test_dir/staged-$index" && "$(<"$test_dir/live-$index/data")" == restored && "$(<"$test_dir/failed-$index/data")" == failed ]]
  done
done
printf 'recovery promotion interruption tests passed\n'
