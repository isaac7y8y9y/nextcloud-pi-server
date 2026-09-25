#!/usr/bin/env python3
"""Rehearse Nextcloud 30 to 31 against a private clean MariaDB 11.4 copy."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time


HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("mariadb_rehearsal", HERE / "rehearse-mariadb-upgrade.py")
assert SPEC and SPEC.loader
base = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(base)

TAGS = ("mariadb:11.4.13", "nextcloud:30.0.17-apache", "nextcloud:31.0.14-apache")
APP_STATUS = re.compile(r"(?m)^\s*-\s*versionstring:\s*(\S+)\s*$")
MAINTENANCE = re.compile(r"(?m)^\s*-\s*maintenance:\s*false\s*$")
NO_DB_UPGRADE = re.compile(r"(?m)^\s*-\s*needsDbUpgrade:\s*false\s*$")
PHP_CONFIG = r'''
$path = "/var/www/html/config/config.php";
$CONFIG = [];
include $path;
if (empty($CONFIG["installed"])) exit(2);
$CONFIG["dbhost"] = "db";
$CONFIG["dbname"] = "nextcloud_rehearsal";
$CONFIG["dbuser"] = "root";
$CONFIG["dbpassword"] = getenv("MARIADB_ROOT_PASSWORD");
$CONFIG["trusted_domains"] = ["127.0.0.1", "localhost"];
$CONFIG["trusted_proxies"] = [];
$CONFIG["overwrite.cli.url"] = "http://127.0.0.1";
$CONFIG["overwriteprotocol"] = "http";
$CONFIG["maintenance"] = false;
$temporary = $path . ".rehearsal";
$content = "<?php\n" . "$" . "CONFIG = " . var_export($CONFIG, true) . ";\n";
if (file_put_contents($temporary, $content, LOCK_EX) === false) exit(3);
if (!chown($temporary, 33) || !chgrp($temporary, 33) || !chmod($temporary, 0640) || !rename($temporary, $path)) exit(4);
'''
PHP_WEBDAV = r'''
$user = $argv[1]; $name = $argv[2]; $payload = $argv[3]; $method = $argv[4];
$pass = trim(file_get_contents("/tmp/rehearsal-auth"));
$url = "http://127.0.0.1/remote.php/dav/files/" . rawurlencode($user) . "/" . rawurlencode($name);
$header = "Authorization: Basic " . base64_encode($user . ":" . $pass) . "\r\n";
$options = ["method" => $method, "header" => $header, "ignore_errors" => true, "timeout" => 30];
if ($method === "PUT") { $options["header"] .= "Content-Type: text/plain\r\n"; $options["content"] = $payload; }
$context = stream_context_create(["http" => $options]);
$body = file_get_contents($url, false, $context);
$status = $http_response_header[0] ?? "";
if ($method === "PUT" && !preg_match("~^HTTP/\\S+ (201|204) ~", $status)) exit(5);
if ($method === "GET" && (!preg_match("~^HTTP/\\S+ 200 ~", $status) || $body !== $payload)) exit(6);
'''


def options() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true")
    mode.add_argument("--apply", type=Path, metavar="APPROVAL")
    parser.add_argument("--runtime-backup", required=True, type=Path)
    parser.add_argument("--mariadb-metadata", required=True, type=Path)
    parser.add_argument("--nextcloud-30-metadata", required=True, type=Path)
    parser.add_argument("--nextcloud-31-metadata", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    return parser.parse_args()


def inputs(backup: Path, metadata: tuple[Path, Path, Path], root: Path) -> dict[str, str]:
    base.safe_root(root)
    base.execute([str(HERE / "verify-runtime-backup.sh"), str(backup)], capture=False, timeout=180)
    manifest = base.private_file(backup / "manifest.tsv")
    if base.manifest_value(manifest, "format") not in {"runtime-backup-v1", "runtime-backup-v2"}:
        raise base.RehearsalError("runtime backup format is unsupported")
    if base.execute(["docker", "info", "--format", "{{.OSType}}/{{.Architecture}}"], timeout=20) not in {"linux/aarch64", "linux/arm64"}:
        raise base.RehearsalError("local Docker daemon is not ARM64 Linux")
    archive = backup / "nextcloud" / "nextcloud.tar"
    sql = backup / "database" / "nextcloud.sql"
    if not archive.is_file() or archive.is_symlink() or not sql.is_file() or sql.is_symlink():
        raise base.RehearsalError("runtime backup lacks application files or SQL")
    old_version = base.execute(["tar", "-xOf", str(archive), "nextcloud/version.php"], timeout=180)
    if not re.search(r"(?m)^\$OC_VersionString\s*=\s*'30\.0\.17';$", old_version):
        raise base.RehearsalError("backup is not the expected Nextcloud 30.0.17 baseline")
    evidence = {"backup_manifest_sha256": base.digest(backup / "manifest.tsv"),
                "sql_sha256": base.digest(sql)}
    for key, path, tag in zip(("db", "app30", "app31"), metadata, TAGS, strict=True):
        record, checksum = base.verify_metadata(path, tag)
        evidence[f"{key}_metadata_sha256"] = checksum
        for field in ("index_digest", "manifest_digest", "config_digest"):
            evidence[f"{key}_{field}"] = record[field]
    return evidence


def authority(identifier: str, created: int, evidence: dict[str, str]) -> dict[str, str]:
    return {
        "format": "nextcloud-30-31-rehearsal-v1", "state": "unused", "id": identifier,
        "created": str(created), "expires": str(created + base.APPROVAL_SECONDS),
        "actions": "pull-three-digests,private-copy,clean-db-import,occ-30,webdav-30,core-31,occ-31,webdav-31,cleanup",
        "exclusions": "pi,live-runtime,host-ports,external-network,image-prune,tag-overwrite",
        **evidence,
    }


def plan(backup: Path, metadata: tuple[Path, Path, Path], root: Path) -> None:
    evidence = inputs(backup, metadata, root)
    now = int(time.time())
    identifier = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now)) + "-" + secrets.token_hex(6)
    record = authority(identifier, now, evidence)
    record["fingerprint"] = base.fingerprint(record)
    root.mkdir(mode=0o700, exist_ok=True)
    artifact = root / f"approval-{identifier}.json"
    base.write_private(artifact, (json.dumps(record, sort_keys=True) + "\n").encode())
    print("Isolated Nextcloud 30→31 rehearsal planned; no Pi or host port will be used")
    print(f"Approval artifact: {artifact}")


def apply(artifact: Path, backup: Path, metadata: tuple[Path, Path, Path], root: Path) -> None:
    evidence = inputs(backup, metadata, root)
    record = json.loads(base.private_file(artifact))
    if not isinstance(record, dict) or set(record) != set(authority("", 0, evidence)) | {"fingerprint"}:
        raise base.RehearsalError("approval schema is invalid")
    identifier = record["id"]
    if not isinstance(identifier, str) or not base.IDENTIFIER.fullmatch(identifier) or artifact != root / f"approval-{identifier}.json":
        raise base.RehearsalError("approval target is invalid")
    created = record["created"]
    if not isinstance(created, str) or not created.isdecimal():
        raise base.RehearsalError("approval clock is invalid")
    expected = authority(identifier, int(created), evidence)
    expected["fingerprint"] = base.fingerprint(expected)
    now = int(time.time())
    if record != expected or not int(created) <= now <= int(record["expires"]):
        raise base.RehearsalError("approval expired, consumed, or evidence changed")
    base.write_private(root / f"used-{identifier}", (record["fingerprint"] + "\n").encode())
    consumed = dict(record, state="consumed")
    temporary = root / f".approval-{identifier}.new"
    base.write_private(temporary, (json.dumps(consumed, sort_keys=True) + "\n").encode())
    temporary.replace(artifact)
    rehearse(identifier, backup, evidence, root)


def inspect_loaded(ref: str, evidence: dict[str, str], key: str) -> None:
    image = json.loads(base.docker("image", "inspect", "--platform", "linux/arm64/v8", "--format", "{{json .}}", ref))
    if (not isinstance(image, dict) or image.get("Id") not in
            {evidence[f"{key}_manifest_digest"], evidence[f"{key}_config_digest"]}
            or image.get("Architecture") != "arm64" or image.get("Os") != "linux"
            or ref not in image.get("RepoDigests", [])):
        raise base.RehearsalError("loaded image differs from approved ARM64 identity")


def resource_absent(kind: str, name: str) -> None:
    result = subprocess.run(["docker", kind, "inspect", name], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if result.returncode == 0:
        raise base.RehearsalError("isolated Docker resource already exists")


def status(name: str, version: str) -> None:
    for _ in range(180):
        try:
            output = base.docker("exec", "--user", "www-data", name, "php", "/var/www/html/occ", "status", timeout=30)
            match = APP_STATUS.search(output)
            if match and match.group(1) == version and MAINTENANCE.search(output) and NO_DB_UPGRADE.search(output):
                return
        except base.RehearsalError:
            pass
        time.sleep(2)
    raise base.RehearsalError("isolated Nextcloud did not reach the expected healthy version")


def install_auth(name: str, path: Path) -> None:
    base.docker("cp", str(path), f"{name}:/tmp/rehearsal-auth")
    base.docker("exec", "--user", "root", name, "chown", "33:33", "/tmp/rehearsal-auth")
    base.docker("exec", "--user", "root", name, "chmod", "0600", "/tmp/rehearsal-auth")


def webdav(name: str, user: str, phase: str, *, put: bool) -> None:
    filename = f"item4-{phase}.txt"
    content = f"isolated-rehearsal-{user}-{phase}"
    if put:
        base.docker("exec", "--user", "www-data", name, "php", "-r", PHP_WEBDAV,
                    user, filename, content, "PUT", timeout=90)
    base.docker("exec", "--user", "www-data", name, "php", "-r", PHP_WEBDAV,
                user, filename, content, "GET", timeout=90)


def stop_if_present(name: str) -> None:
    try:
        base.docker("stop", "--time", "30", name, timeout=45)
    except base.RehearsalError:
        pass


def rehearse(identifier: str, backup: Path, evidence: dict[str, str], root: Path) -> None:
    state = root / f"rehearsal-{identifier}"
    state.mkdir(mode=0o700)
    data = state / "mariadb-data"
    data.mkdir(mode=0o700)
    db_env = state / "database.env"
    db_auth = secrets.token_hex(32)
    base.write_private(db_env, f"MARIADB_ROOT_PASSWORD={db_auth}\nMARIADB_DATABASE=nextcloud_rehearsal\n".encode())
    user = "rehearsal_" + identifier[-12:]
    auth = state / "user-auth"
    base.write_private(auth, (secrets.token_hex(32) + "\n").encode())
    suffix = identifier.replace("T", "-").replace("Z", "")
    volume, network = f"nc-rh-files-{suffix}", f"nc-rh-net-{suffix}"
    db, app30, app31 = (f"nc-rh-db-{suffix}", f"nc-rh-30-{suffix}", f"nc-rh-31-{suffix}")
    names = (db, app30, app31)
    label = f"nextcloud-pi.rehearsal={identifier}"
    refs = {key: f"{image}@{evidence[f'{key}_index_digest']}" for key, image in
            (("db", "mariadb"), ("app30", "nextcloud"), ("app31", "nextcloud"))}
    try:
        for kind, name in (("volume", volume), ("network", network), *(("container", n) for n in names)):
            resource_absent(kind, name)
        for key in ("db", "app30", "app31"):
            base.docker("pull", "--platform", "linux/arm64/v8", refs[key], timeout=1800)
            inspect_loaded(refs[key], evidence, key)
        base.docker("volume", "create", "--label", label, volume)
        base.docker("network", "create", "--internal", "--label", label, network)
        base.docker("run", "--rm", "--pull", "never", "--network", "none",
                    "--mount", f"type=volume,source={volume},target=/restore",
                    "--mount", f"type=bind,source={backup / 'nextcloud' / 'nextcloud.tar'},target=/backup.tar,readonly",
                    "--entrypoint", "tar", refs["db"], "-xpf", "/backup.tar", "--strip-components=1",
                    "-C", "/restore", timeout=3600)
        base.docker("run", "--rm", "--pull", "never", "--network", "none", "--env-file", str(db_env),
                    "--mount", f"type=volume,source={volume},target=/var/www/html",
                    "--entrypoint", "php", refs["app30"], "-r", PHP_CONFIG, timeout=120)
        base.docker("run", "-d", "--pull", "never", "--network", network, "--network-alias", "db",
                    "--name", db, "--label", label, "--env-file", str(db_env),
                    "--mount", f"type=bind,source={data},target=/var/lib/mysql", refs["db"])
        base.wait_ready(db)
        base.docker("exec", "-i", db, "sh", "-eu", "-c",
                    'export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"; exec mariadb --protocol=tcp --host=127.0.0.1 -uroot "$MARIADB_DATABASE"',
                    input_file=backup / "database" / "nextcloud.sql", timeout=1800)
        base.check_database(db)
        base.docker("run", "-d", "--pull", "never", "--network", network, "--name", app30,
                    "--label", label, "--mount", f"type=volume,source={volume},target=/var/www/html", refs["app30"])
        status(app30, "30.0.17")
        install_auth(app30, auth)
        base.docker("exec", "--user", "www-data", app30, "sh", "-eu", "-c",
                    'export OC_PASS="$(cat /tmp/rehearsal-auth)"; exec php /var/www/html/occ user:add --password-from-env "$1"',
                    "sh", user, timeout=120)
        webdav(app30, user, "30", put=True)
        for app in ("calendar", "contacts", "mail", "notes", "richdocuments", "spreed"):
            base.docker("exec", "--user", "www-data", app30, "php", "/var/www/html/occ", "app:disable", app, timeout=120)
        base.docker("stop", "--time", "60", app30, timeout=90)
        base.docker("run", "-d", "--pull", "never", "--network", network, "--name", app31,
                    "--label", label, "--mount", f"type=volume,source={volume},target=/var/www/html", refs["app31"])
        status(app31, "31.0.14")
        install_auth(app31, auth)
        webdav(app31, user, "30", put=False)
        webdav(app31, user, "31", put=True)
        base.check_database(db)
        for name in (app31, db):
            base.docker("stop", "--time", "60", name, timeout=90)
        for name in names:
            base.docker("rm", name)
        base.docker("network", "rm", network)
        base.docker("volume", "rm", volume)
        shutil.rmtree(state)
    except Exception:
        for name in names:
            stop_if_present(name)
        print(f"Nextcloud rehearsal failed; private state and isolated resources retained: {state}", file=sys.stderr)
        raise
    print("Isolated Nextcloud 30→31 rehearsal passed: occ health and WebDAV file operations on both versions")


def main() -> int:
    args = options()
    metadata = (args.mariadb_metadata, args.nextcloud_30_metadata, args.nextcloud_31_metadata)
    try:
        if args.plan:
            plan(args.runtime_backup, metadata, args.output_root)
        else:
            apply(args.apply, args.runtime_backup, metadata, args.output_root)
    except (base.RehearsalError, OSError, ValueError, UnicodeError, base.resolver.MetadataError) as exc:
        print(f"Nextcloud rehearsal rejected: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
