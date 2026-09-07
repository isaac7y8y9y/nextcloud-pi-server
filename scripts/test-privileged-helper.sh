#!/usr/bin/env bash
set -euo pipefail
readonly HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/privileged/nextcloud-pi-ops"
bash -n "$HELPER"
for command in cmd_recovery_check cmd_active_prepare cmd_readiness_start cmd_drill_apply; do grep -Fq "$command" "$HELPER"; done
grep -Fq 'valid_id' "$HELPER"; grep -Fq 'reject_stdin' "$HELPER"; grep -Fq 'active-record-current' "$HELPER"; grep -Fq 'no_nested_mounts' "$HELPER"
! grep -Fq 'eval ' "$HELPER"
python3 - "$HELPER" <<'PY'
import io
import pathlib
import sys
import tarfile
import tempfile

helper = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
prefix = "validate_archive() { /usr/bin/python3 - \"$1\" <<'PY'\n"
validator = helper.split(prefix, 1)[1].split("\nPY\n}", 1)[0]
with tempfile.TemporaryDirectory() as directory:
    safe = pathlib.Path(directory, "caddy.tar")
    with tarfile.open(safe, "w") as archive:
        root = tarfile.TarInfo("./")
        root.type = tarfile.DIRTYPE
        archive.addfile(root)
    sys.argv = ["validate_archive", str(safe)]
    exec(compile(validator, "validate_archive", "exec"), {"__name__": "__main__"})
    unsafe = pathlib.Path(directory, "unsafe.tar")
    with tarfile.open(unsafe, "w") as archive:
        payload = b"bad"
        member = tarfile.TarInfo("/escape")
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
    sys.argv = ["validate_archive", str(unsafe)]
    try:
        exec(compile(validator, "validate_archive", "exec"), {"__name__": "__main__"})
    except SystemExit:
        pass
    else:
        raise SystemExit("unsafe archive was accepted")
PY
printf 'privileged helper contract tests passed\n'
