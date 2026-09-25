#!/usr/bin/env python3
"""Rehearse a clean MariaDB 11.4 import and forward 11.8 upgrade locally."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import sys
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
IDENTIFIER = re.compile(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}\Z")
EXPECTED_TAGS = ("mariadb:11.4.13", "mariadb:11.8.9")
APPROVAL_SECONDS = 900
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("resolve_image_upgrade", HERE / "resolve-image-upgrade.py")
assert SPEC and SPEC.loader
resolver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resolver)


class RehearsalError(Exception):
    """A prerequisite or isolated rehearsal gate failed."""


def execute(args: list[str], *, input_file: Path | None = None,
            capture: bool = True, timeout: int = 120) -> str:
    try:
        with input_file.open("rb") if input_file else open(os.devnull, "rb") as source:
            result = subprocess.run(
                args, stdin=source, stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, check=True, timeout=timeout,
            )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise RehearsalError("a required command failed; private command output was suppressed") from exc
    return result.stdout.decode("utf-8", "strict").strip() if capture else ""


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def private_file(path: Path) -> bytes:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
        raise RehearsalError("rehearsal input file is unsafe")
    return path.read_bytes()


def manifest_value(raw: bytes, key: str) -> str:
    values = [line.partition(b"\t")[2] for line in raw.splitlines()
              if line.partition(b"\t")[0] == key.encode()]
    if len(values) != 1 or not values[0]:
        raise RehearsalError("backup manifest is incomplete")
    return values[0].decode("utf-8", "strict")


def verify_metadata(path: Path, tag: str) -> tuple[dict[str, str], str]:
    raw = private_file(path)
    fields = {}
    for line in raw.decode("utf-8", "strict").splitlines():
        key, sep, value = line.partition("\t")
        if not sep or key in fields or not value:
            raise RehearsalError("image metadata schema is invalid")
        fields[key] = value
    expected = {"format", "image", "tag", "platform", "index_digest", "manifest_digest", "config_digest"}
    if (set(fields) != expected or fields["format"] != "nextcloud-upgrade-image-v1"
            or fields["image"] != "mariadb" or fields["tag"] != tag
            or fields["platform"] != "linux/arm64/v8"
            or not all(DIGEST.fullmatch(fields[name]) for name in expected if name.endswith("digest"))):
        raise RehearsalError("image metadata is not the selected ARM64 release")
    index = resolver.registry_raw(tag)
    if resolver.digest(index) != fields["index_digest"]:
        raise RehearsalError("registry index changed")
    manifest_id = resolver.select_arm64(index)
    manifest = resolver.registry_raw(f"mariadb@{manifest_id}")
    if manifest_id != fields["manifest_digest"] or resolver.image_config(manifest, manifest_id) != fields["config_digest"]:
        raise RehearsalError("registry ARM64 image identity changed")
    return fields, hashlib.sha256(raw).hexdigest()


def safe_root(path: Path) -> Path:
    if not path.is_absolute() or path == Path("/") or ".." in path.parts:
        raise RehearsalError("rehearsal root is unsafe")
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise RehearsalError("rehearsal root parent is unsafe")
    ancestor = path.parent
    while ancestor != ancestor.parent:
        if ancestor.is_symlink():
            raise RehearsalError("rehearsal root parent contains a symbolic link")
        ancestor = ancestor.parent
    git = subprocess.run(["git", "-C", str(path.parent), "rev-parse", "--show-toplevel"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if git.returncode == 0:
        raise RehearsalError("rehearsal data must stay outside Git")
    if path.is_symlink() or (path.exists() and (not path.is_dir() or stat.S_IMODE(path.stat().st_mode) != 0o700)):
        raise RehearsalError("rehearsal root protection is invalid")
    return path


def prerequisites(backup: Path, metadata: tuple[Path, Path], root: Path) -> dict[str, str]:
    safe_root(root)
    execute([str(HERE / "verify-runtime-backup.sh"), str(backup)], capture=False, timeout=120)
    raw = private_file(backup / "manifest.tsv")
    if manifest_value(raw, "format") not in {"runtime-backup-v1", "runtime-backup-v2"}:
        raise RehearsalError("runtime backup format is unsupported")
    sql = backup / "database" / "nextcloud.sql"
    if not sql.is_file() or sql.is_symlink() or sql.stat().st_size == 0:
        raise RehearsalError("database dump is unavailable")
    if execute(["docker", "info", "--format", "{{.OSType}}/{{.Architecture}}"], timeout=20) not in {"linux/aarch64", "linux/arm64"}:
        raise RehearsalError("local Docker daemon is not ARM64 Linux")
    first, first_hash = verify_metadata(metadata[0], EXPECTED_TAGS[0])
    second, second_hash = verify_metadata(metadata[1], EXPECTED_TAGS[1])
    return {
        "backup_manifest_sha256": digest(backup / "manifest.tsv"),
        "sql_sha256": digest(sql),
        "mariadb_114_metadata_sha256": first_hash,
        "mariadb_118_metadata_sha256": second_hash,
        "mariadb_114_index": first["index_digest"],
        "mariadb_114_manifest": first["manifest_digest"],
        "mariadb_114_id": first["config_digest"],
        "mariadb_118_index": second["index_digest"],
        "mariadb_118_manifest": second["manifest_digest"],
        "mariadb_118_id": second["config_digest"],
    }


def authority(identifier: str, now: int, evidence: dict[str, str]) -> dict[str, str]:
    return {
        "format": "mariadb-upgrade-rehearsal-v1", "state": "unused",
        "id": identifier, "created": str(now), "expires": str(now + APPROVAL_SECONDS),
        "actions": "pull-two-digests,clean-import-11.4,check,forward-11.8,check,cleanup",
        "exclusions": "pi,live-runtime,host-ports,image-prune,tag-overwrite,downgrade",
        **evidence,
    }


def fingerprint(record: dict[str, str]) -> str:
    return hashlib.sha256(json.dumps({key: value for key, value in record.items() if key not in {"state", "fingerprint"}},
                                     sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def write_private(path: Path, data: bytes) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)


def create_plan(backup: Path, metadata: tuple[Path, Path], root: Path) -> None:
    evidence = prerequisites(backup, metadata, root)
    now = int(time.time())
    identifier = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now)) + "-" + secrets.token_hex(6)
    record = authority(identifier, now, evidence)
    record["fingerprint"] = fingerprint(record)
    root.mkdir(mode=0o700, exist_ok=True)
    path = root / f"approval-{identifier}.json"
    write_private(path, (json.dumps(record, sort_keys=True) + "\n").encode())
    print(f"Isolated MariaDB rehearsal plan: id={identifier}; old=11.4.13; forward=11.8.9")
    print(f"Approval artifact: {path}")


def approved_apply(artifact: Path, backup: Path, metadata: tuple[Path, Path], root: Path) -> None:
    evidence = prerequisites(backup, metadata, root)
    raw = private_file(artifact)
    record = json.loads(raw)
    if not isinstance(record, dict) or set(record) != set(authority("", 0, evidence)) | {"fingerprint"}:
        raise RehearsalError("approval schema is invalid")
    identifier = record["id"]
    if not isinstance(identifier, str) or not IDENTIFIER.fullmatch(identifier) or artifact != root / f"approval-{identifier}.json":
        raise RehearsalError("approval target is invalid")
    created = record["created"]
    if not isinstance(created, str) or not created.isdecimal():
        raise RehearsalError("approval clock is invalid")
    expected = authority(identifier, int(created), evidence)
    expected["fingerprint"] = fingerprint(expected)
    now = int(time.time())
    if record != expected or record["state"] != "unused" or not int(created) <= now <= int(record["expires"]):
        raise RehearsalError("approval expired, consumed, or evidence changed")
    marker = root / f"used-{identifier}"
    write_private(marker, (record["fingerprint"] + "\n").encode())
    consumed = dict(record, state="consumed")
    temporary = root / f".approval-{identifier}.new"
    write_private(temporary, (json.dumps(consumed, sort_keys=True) + "\n").encode())
    os.replace(temporary, artifact)
    rehearse(identifier, backup / "database" / "nextcloud.sql", evidence, root)


def docker(*args: str, timeout: int = 120, input_file: Path | None = None) -> str:
    return execute(["docker", *args], timeout=timeout, input_file=input_file)


def container_query(name: str, statement: str) -> str:
    return docker("exec", name, "sh", "-eu", "-c",
                  'export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"; exec mariadb --protocol=tcp --host=127.0.0.1 -uroot -N --batch "$MARIADB_DATABASE" -e "$1"',
                  "sh", statement)


def wait_ready(name: str) -> None:
    for _ in range(90):
        try:
            if container_query(name, "SELECT 1") == "1":
                return
        except RehearsalError:
            pass
        time.sleep(2)
    raise RehearsalError("isolated MariaDB server did not become ready")


def check_database(name: str) -> tuple[int, int, int, int]:
    queries = (
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()",
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE()",
        "SELECT COUNT(DISTINCT TABLE_COLLATION) FROM information_schema.tables WHERE table_schema = DATABASE() AND TABLE_COLLATION IS NOT NULL",
        "SELECT COUNT(*) FROM oc_filecache",
    )
    result = tuple(container_query(name, statement) for statement in queries)
    if any(not value.isdecimal() for value in result) or any(int(value) < 1 for value in result[:3]):
        raise RehearsalError("isolated database schema or collations are incomplete")
    docker("exec", name, "sh", "-eu", "-c",
           'export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"; exec mariadb-check --protocol=tcp --host=127.0.0.1 -uroot --all-databases --silent',
           timeout=600)
    return tuple(int(value) for value in result)


def verify_loaded_image(ref: str, evidence: dict[str, str], version: str) -> None:
    image = json.loads(docker("image", "inspect", "--platform", "linux/arm64/v8", "--format", "{{json .}}", ref))
    # Classic Docker reports the config digest as Id; Docker Desktop's
    # containerd image store reports the ARM64 manifest digest instead.
    if (not isinstance(image, dict)
            or image.get("Id") not in {evidence[f"mariadb_{version}_id"], evidence[f"mariadb_{version}_manifest"]}
            or image.get("Architecture") != "arm64" or image.get("Os") != "linux"
            or ref not in image.get("RepoDigests", [])):
        raise RehearsalError("isolated image identity differs from reviewed ARM64 metadata")


def rehearse(identifier: str, sql: Path, evidence: dict[str, str], root: Path) -> None:
    state = root / f"rehearsal-{identifier}"
    state.mkdir(mode=0o700)
    data = state / "mariadb-data"
    data.mkdir(mode=0o700)
    db_auth = secrets.token_hex(32)
    env = state / "database.env"
    write_private(env, f"MARIADB_ROOT_PASSWORD={db_auth}\nMARIADB_DATABASE=nextcloud_rehearsal\n".encode())
    first = f"mariadb-rehearsal-114-{identifier}"
    second = f"mariadb-rehearsal-118-{identifier}"
    label = f"nextcloud-pi.rehearsal={identifier}"
    try:
        for version in ("114", "118"):
            ref = f"mariadb@{evidence[f'mariadb_{version}_index']}"
            docker("pull", "--platform", "linux/arm64/v8", ref, timeout=1800)
            verify_loaded_image(ref, evidence, version)
        docker("run", "-d", "--pull", "never", "--platform", "linux/arm64/v8", "--network", "none",
               "--name", first, "--label", label, "--env-file", str(env),
               "--mount", f"type=bind,source={data},target=/var/lib/mysql",
               f"mariadb@{evidence['mariadb_114_index']}")
        wait_ready(first)
        docker("exec", "-i", first, "sh", "-eu", "-c",
               'export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"; exec mariadb --protocol=tcp --host=127.0.0.1 -uroot "$MARIADB_DATABASE"',
               input_file=sql, timeout=1800)
        before = check_database(first)
        docker("stop", "--time", "60", first, timeout=90)
        docker("run", "-d", "--pull", "never", "--platform", "linux/arm64/v8", "--network", "none",
               "--name", second, "--label", label, "--env-file", str(env),
               "--mount", f"type=bind,source={data},target=/var/lib/mysql",
               f"mariadb@{evidence['mariadb_118_index']}")
        wait_ready(second)
        docker("exec", second, "sh", "-eu", "-c",
               'export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"; exec mariadb-upgrade --protocol=tcp --host=127.0.0.1 -uroot --force',
               timeout=1800)
        after = check_database(second)
        if before != after:
            raise RehearsalError("application schema or file-cache count changed during forward upgrade")
        docker("stop", "--time", "60", second, timeout=90)
        for name in (first, second):
            docker("rm", name)
        shutil.rmtree(state)
    except Exception:
        for name in (first, second):
            try:
                docker("stop", "--time", "30", name, timeout=45)
            except RehearsalError:
                pass
        print(f"Rehearsal failed; private state retained for diagnosis: {state}", file=sys.stderr)
        raise
    print(f"Isolated MariaDB rehearsal passed: {before[0]} tables, {before[1]} columns; 11.4 clean import and 11.8 forward upgrade")
    print("Disposable rehearsal containers and data were removed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--plan", action="store_true")
    group.add_argument("--apply", type=Path, metavar="APPROVAL")
    parser.add_argument("--runtime-backup", type=Path, required=True)
    parser.add_argument("--mariadb-114-metadata", type=Path, required=True)
    parser.add_argument("--mariadb-118-metadata", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        metadata = (args.mariadb_114_metadata, args.mariadb_118_metadata)
        if args.plan:
            create_plan(args.runtime_backup, metadata, args.output_root)
        else:
            approved_apply(args.apply, args.runtime_backup, metadata, args.output_root)
    except (RehearsalError, OSError, UnicodeError, ValueError, json.JSONDecodeError, resolver.MetadataError) as exc:
        print(f"MariaDB rehearsal rejected: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
