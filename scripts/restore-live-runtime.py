#!/usr/bin/env python3
"""Plan or apply a held, approval-bound full-runtime recovery after an upgrade boundary."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent
OPS = "/usr/local/libexec/nextcloud-pi-ops"
IDENTIFIER = re.compile(r"[0-9]{8}T[0-9]{6}Z-[0-9]+\Z")
HASH = re.compile(r"[0-9a-f]{64}\Z")
SAFE_NAME = re.compile(r"[A-Za-z0-9._/-]+\Z")
CONFIG_KEYS = {"NEXTCLOUD_PI_HOST", "NEXTCLOUD_PI_SYSTEM_HOSTNAME", "NEXTCLOUD_PI_USER",
               "NEXTCLOUD_REMOTE_PROJECT_DIR", "NEXTCLOUD_STORAGE_MOUNT"}
PATHS = ("nextcloud/nextcloud.tar", "caddy/data.tar", "caddy/config.tar")


class RecoveryError(Exception):
    pass


def reject(message: str) -> None:
    raise RecoveryError(message)


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def run(args: list[str], *, input_file: Path | None = None, timeout: int = 120) -> str:
    try:
        with input_file.open("rb") if input_file is not None else open(os.devnull, "rb") as source:
            result = subprocess.run(args, stdin=source, capture_output=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RecoveryError("required local or remote command did not complete") from exc
    if result.returncode:
        reject("required local or remote check failed; ingress freeze must remain held")
    return result.stdout.decode("utf-8", errors="replace").strip()


def fields(path: Path, *, separator: str = "\t") -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text().splitlines():
        parts = line.split(separator)
        if len(parts) != 2 or not parts[0] or not parts[1] or parts[0] in result:
            reject("evidence schema is invalid")
        result[parts[0]] = parts[1]
    return result


def manifest_fields(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue  # Closed payload-row schemas are checked by the artifact verifier.
        if not parts[0] or not parts[1] or parts[0] in result:
            reject("recovery manifest singleton schema is invalid")
        result[parts[0]] = parts[1]
    return result


def output_fields(raw: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) != 2 or not parts[0] or not parts[1] or parts[0] in result:
            reject("protected status schema is invalid")
        result[parts[0]] = parts[1]
    return result


def deployment_config() -> dict[str, str]:
    path = Path(os.environ.get("NEXTCLOUD_DEPLOYMENT_ENV_FILE", ROOT / "config/deployment.env"))
    if path.is_symlink() or not path.is_file() or stat.S_IMODE(path.stat().st_mode) != 0o600:
        reject("private deployment configuration is missing or unsafe")
    result: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or key not in CONFIG_KEYS or key in result or not value:
            reject("private deployment configuration schema is invalid")
        if not SAFE_NAME.fullmatch(value) or ".." in value.split("/"):
            reject("private deployment configuration value is unsafe")
        result[key] = value
    if set(result) != CONFIG_KEYS:
        reject("private deployment configuration is incomplete")
    for key in ("NEXTCLOUD_REMOTE_PROJECT_DIR", "NEXTCLOUD_STORAGE_MOUNT"):
        if not result[key].startswith("/"):
            reject("private deployment path is not absolute")
    return result


def q(value: str) -> str:
    return shlex.quote(value)


def remote_hash(target: "Target", path: str) -> str:
    output = target.ssh("sha256sum " + q(path)).split()
    if not output or not HASH.fullmatch(output[0]):
        reject("remote file hash is invalid")
    return output[0]


class Target:
    def __init__(self, config: dict[str, str]):
        self.config = config
        self.login = f"{config['NEXTCLOUD_PI_USER']}@{config['NEXTCLOUD_PI_HOST']}"

    def ssh(self, command: str, *, input_file: Path | None = None, timeout: int = 120) -> str:
        return run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=12",
                    self.login, command], input_file=input_file, timeout=timeout)

    def ops(self, *args: str, input_file: Path | None = None, timeout: int = 120) -> dict[str, str]:
        command = "sudo -n " + q(OPS) + " " + " ".join(q(arg) for arg in args)
        return output_fields(self.ssh(command, input_file=input_file, timeout=timeout))


def private_artifact_root() -> Path:
    root = Path(os.environ.get("NEXTCLOUD_LIVE_RESTORE_APPROVAL_ROOT",
                               Path(os.path.expanduser("~")) / "nextcloud-pi-live-restore-approvals"))
    if not root.is_absolute() or root.is_symlink():
        reject("approval root is unsafe")
    for parent in root.parents:
        if parent.is_symlink():
            reject("approval root parent is symbolic-linked")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if stat.S_IMODE(root.stat().st_mode) != 0o700:
        reject("approval root must have mode 0700")
    if subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"],
                      capture_output=True, check=False).returncode == 0:
        reject("approval root must be outside Git")
    return root


def private_file(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file() or stat.S_IMODE(path.stat().st_mode) != 0o600:
        reject("approval artifact is missing or unsafe")
    return path.read_bytes()


def record_value(path: Path, key: str) -> str:
    return fields(path, separator="=")[key]


def verify_local(candidate: Path, source: Path, config_backup: Path,
                 runtime: Path, images: Path, config: dict[str, str]) -> dict[str, str]:
    for path in (candidate, source, config_backup, runtime, images):
        if path.is_symlink() or not path.is_dir():
            reject("recovery input directory is missing or symbolic-linked")
    checks = (
        ["python3", str(ROOT / "scripts/verify-image-upgrade.py"), str(candidate),
         "--source-lock", str(ROOT / "config/image-lock.env"), "--source-rendered", str(source)],
        [str(ROOT / "scripts/verify-config-backup.sh"), str(config_backup)],
        [str(ROOT / "scripts/verify-runtime-backup.sh"), str(runtime)],
        [str(ROOT / "scripts/verify-image-recovery.sh"), "--require-attestation", str(images)],
    )
    for command in checks:
        run(command, timeout=600)
    env = config_backup / "compose/.env"
    if env.is_symlink() or not env.is_file() or stat.S_IMODE(env.stat().st_mode) != 0o600:
        reject("verified configuration backup lacks protected database environment")
    backup = manifest_fields(runtime / "manifest.tsv")
    configuration = manifest_fields(config_backup / "manifest.tsv")
    recovery = manifest_fields(images / "manifest.tsv")
    expected = config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"]
    if (backup.get("format") != "runtime-backup-v2" or
            backup.get("remote_host") != expected or
            backup.get("remote_user") != config["NEXTCLOUD_PI_USER"] or
            backup.get("source_nextcloud") != config["NEXTCLOUD_STORAGE_MOUNT"] + "/nextcloud" or
            configuration.get("remote_host") != expected or
            configuration.get("source_project") != config["NEXTCLOUD_REMOTE_PROJECT_DIR"] or
            recovery.get("remote_host") != expected or
            recovery.get("source_project") != config["NEXTCLOUD_REMOTE_PROJECT_DIR"] or
            recovery.get("storage_mount") != config["NEXTCLOUD_STORAGE_MOUNT"]):
        reject("recovery artifacts do not belong to the configured Pi")
    for relative, source_file in (("compose/docker-compose.yml", source / "docker-compose.yml"),
                                  ("caddy/Caddyfile", source / "caddy/Caddyfile")):
        if digest(config_backup / relative) != digest(source_file):
            reject("configuration backup differs from source stage")
    source_record = source / "active-images/active-images.env"
    old_ids = {key: record_value(source_record, f"NEXTCLOUD_ACTIVE_IMAGES_{key}_ID")
               for key in ("APP", "DB", "CADDY")}
    old_tags = {key: record_value(source_record, f"NEXTCLOUD_ACTIVE_IMAGES_{key}_TAG")
                for key in ("APP", "DB", "CADDY")}
    if backup.get("database_image") != old_tags["DB"]:
        reject("held database image differs from the prior image record")
    image_rows = [line.split("\t") for line in (images / "manifest.tsv").read_text().splitlines()
                  if line.startswith("image\t")]
    image_map = {row[1]: row[2] for row in image_rows if len(row) == 3}
    if len(image_rows) != 3 or any(image_map.get(old_tags[key]) != old_ids[key]
                                   for key in old_tags):
        reject("prior image archive does not match the source record")
    return {"backup_manifest": digest(runtime / "manifest.tsv"),
            "config_manifest": digest(config_backup / "manifest.tsv"),
            "image_manifest": digest(images / "manifest.tsv"),
            "image_attestation": digest(images / "restore-attestation.tsv"),
            "candidate_manifest": digest(candidate / "candidate-manifest.tsv"),
            "source_record": digest(source_record),
            "source_compose": digest(source / "docker-compose.yml"),
            "source_caddy": digest(source / "caddy/Caddyfile"),
            "candidate_record": digest(candidate / "active-images.env"),
            "candidate_compose": digest(candidate / "docker-compose.yml"),
            "sql_sha256": digest(runtime / "database/nextcloud.sql"),
            "env_sha256": digest(env),
            "old_tags": old_tags, "old_ids": old_ids}


def evidence(target: Target, stage_id: str, candidate: Path, source: Path,
             config_backup: Path, runtime: Path, images: Path) -> dict[str, object]:
    if not IDENTIFIER.fullmatch(stage_id):
        reject("upgrade stage ID is invalid")
    config = target.config
    local = verify_local(candidate, source, config_backup, runtime, images, config)
    if target.ssh("hostname") != config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"] or target.ssh("id -un") != config["NEXTCLOUD_PI_USER"]:
        reject("connected Pi identity differs")
    freeze = target.ops("upgrade-freeze", "status")
    stage = target.ops("upgrade-stage", "status", stage_id)
    active = target.ops("active-record", "status", stage_id)
    manifest = manifest_fields(runtime / "manifest.tsv")
    metadata = manifest_fields(candidate / "registry-metadata.tsv")
    try:
        stage_time = datetime.strptime(stage_id[:16], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        backup_time = datetime.strptime(manifest["timestamp"], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, KeyError) as exc:
        raise RecoveryError("held backup or stage timestamp is invalid") from exc
    if not 0 <= (stage_time - backup_time).total_seconds() <= 86400:
        reject("held backup was not captured within 24 hours before the stage")
    if (freeze.get("state") != "active" or
            freeze.get("id") != manifest.get("freeze_id") or
            freeze.get("table_sha256") != manifest.get("freeze_table_sha256") or
            stage.get("phase") != "runtime-may-have-changed" or
            stage.get("id") != stage_id or
            stage.get("freeze_id") != freeze.get("id") or
            stage.get("freeze_table_sha256") != freeze.get("table_sha256") or
            stage.get("pre_record_sha256") != local["source_record"] or
            stage.get("pre_compose_sha256") != local["source_compose"] or
            stage.get("candidate_record_sha256") != local["candidate_record"] or
            stage.get("candidate_compose_sha256") != local["candidate_compose"] or
            stage.get("tag") != metadata.get("tag") or
            stage.get("expected_id") != metadata.get("config_digest") or
            active.get("state") != "applied" or
            active.get("id") != stage_id or
            active.get("pre_sha256") != local["source_record"] or
            active.get("candidate_sha256") != local["candidate_record"]):
        reject("protected upgrade stage, held backup, and active transaction differ")
    project = config["NEXTCLOUD_REMOTE_PROJECT_DIR"]
    for remote_path, local_hash in ((project + "/.env", local["env_sha256"]),
                                    (project + "/docker-compose.yml", local["candidate_compose"]),
                                    (project + "/caddy/Caddyfile", local["source_caddy"])):
        if remote_hash(target, remote_path) != local_hash:
            reject("live project configuration differs from the bound stage")
    active_state = target.ops("active-images-state")
    if active_state.get("sha256") != local["candidate_record"]:
        reject("protected active record differs from candidate")
    timer = target.ops("background-jobs", "state")
    if timer.get("timer_active") != "no":
        reject("background jobs are not paused")
    return {"format": "live-runtime-restore-v1", "stage_id": stage_id,
            "stage_fingerprint": stage["fingerprint"], "freeze_id": freeze["id"],
            "freeze_table_sha256": freeze["table_sha256"], "host": config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"],
            "project": project, "mount": config["NEXTCLOUD_STORAGE_MOUNT"],
            "evidence": local,
            "actions": "load-prior-images,restore-four-datasets,verify-database,stop-stack,preserve-failed-state,restore-prior-config,start,verify-health,mark-recovered",
            "exclusions": "freeze-release,pruning,image-removal,in-place-downgrade,post-open-data-overwrite"}


def canonical(record: dict[str, object]) -> bytes:
    return json.dumps(record, sort_keys=True, separators=(",", ":")).encode()


def fingerprint(record: dict[str, object]) -> str:
    return hashlib.sha256(canonical(record)).hexdigest()


def plan(root: Path, base: dict[str, object], now: int) -> Path:
    artifact = root / f"restore-{base['stage_id']}-{now}.json"
    record = dict(base, state="unused", created=now, expires=now + 900)
    record["fingerprint"] = fingerprint(record)
    descriptor = os.open(artifact, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(canonical(record) + b"\n")
    return artifact


def consume(artifact: Path, root: Path, base: dict[str, object], now: int) -> dict[str, object]:
    if artifact.parent != root or not artifact.name.startswith(f"restore-{base['stage_id']}-"):
        reject("approval artifact path differs from this stage")
    record = json.loads(private_file(artifact))
    if not isinstance(record, dict) or record.get("state") != "unused":
        reject("restore approval is not unused")
    if not isinstance(record.get("created"), int) or not isinstance(record.get("expires"), int):
        reject("restore approval clock is invalid")
    if record["expires"] - record["created"] != 900 or not record["created"] <= now <= record["expires"]:
        reject("restore approval expired")
    expected = dict(base, state="unused", created=record["created"], expires=record["expires"])
    expected["fingerprint"] = fingerprint(expected)
    if record != expected:
        reject("restore approval or bound evidence changed")
    marker = root / f"used-{base['stage_id']}-{record['created']}"
    descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write((record["fingerprint"] + "\n").encode())
    consumed = dict(record, state="consumed")
    temporary = root / f".{artifact.name}.new"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(canonical(consumed) + b"\n")
    os.replace(temporary, artifact)
    return consumed


def consumed_for_resume(artifact: Path, root: Path, stage_id: str) -> dict[str, object]:
    if artifact.parent != root or not artifact.name.startswith(f"restore-{stage_id}-"):
        reject("restore resume approval path differs")
    record = json.loads(private_file(artifact))
    if not isinstance(record, dict) or record.get("state") != "consumed" or record.get("stage_id") != stage_id:
        reject("restore resume approval is not consumed for this stage")
    created = record.get("created")
    if not isinstance(created, int) or record.get("expires") != created + 900:
        reject("restore resume approval clock differs")
    original = dict(record, state="unused")
    original.pop("fingerprint", None)
    expected = fingerprint(original)
    if record.get("fingerprint") != expected:
        reject("restore resume approval fingerprint differs")
    marker = root / f"used-{stage_id}-{created}"
    if private_file(marker) != (expected + "\n").encode():
        reject("restore resume consumption marker differs")
    return record


def resume(target: Target, base: dict[str, object], candidate: Path, source: Path,
           config_backup: Path, runtime: Path, images: Path) -> None:
    stage_id = str(base["stage_id"])
    local = verify_local(candidate, source, config_backup, runtime, images, target.config)
    if local != base.get("evidence") or base.get("host") != target.config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"]:
        reject("restore resume material differs from consumed approval")
    if target.ssh("hostname") != base["host"] or target.ssh("id -un") != target.config["NEXTCLOUD_PI_USER"]:
        reject("restore resume target identity differs")
    freeze = target.ops("upgrade-freeze", "status")
    stage = target.ops("upgrade-stage", "status", stage_id)
    if (freeze.get("state") != "active" or freeze.get("id") != base.get("freeze_id") or
            freeze.get("table_sha256") != base.get("freeze_table_sha256") or
            stage.get("phase") != "runtime-may-have-changed" or
            stage.get("fingerprint") != base.get("stage_fingerprint")):
        reject("restore resume stage or ingress freeze differs")
    if target.ops("background-jobs", "state").get("timer_active") != "no":
        reject("background-job timer resumed")
    if remote_hash(target, target.config["NEXTCLOUD_REMOTE_PROJECT_DIR"] + "/.env") != local["env_sha256"]:
        reject("database environment changed during restore")
    recovery = target.ops("runtime-recovery", "status", stage_id)
    if recovery.get("state") not in ("promoting", "promoted") or recovery.get("id") != stage_id:
        reject("runtime recovery has not reached the promotion boundary")
    service = target.ssh("systemctl is-active nextcloud.service 2>/dev/null || true")
    if service == "active":
        target.ops("service", "stop")
    elif service not in ("inactive", "failed"):
        reject("Nextcloud service state is unknown during restore resume")
    target.ops("runtime-recovery", "promote", stage_id, str(base["stage_fingerprint"]), timeout=3600)
    finish_promoted(target, base, config_backup)


def checked(target: Target, command: str, *, input_file: Path | None = None, timeout: int = 120) -> None:
    target.ssh(command, input_file=input_file, timeout=timeout)


def finish_promoted(target: Target, base: dict[str, object], config_backup: Path) -> None:
    stage_id = str(base["stage_id"])
    project = target.config["NEXTCLOUD_REMOTE_PROJECT_DIR"]
    local = base["evidence"]
    assert isinstance(local, dict)
    stage = project + "/.restore-stage-" + stage_id
    for name, expected in (("docker-compose.yml", local["source_compose"]),
                           ("Caddyfile", local["source_caddy"]),
                           ("atomic-transaction.sh", digest(ROOT / "scripts/lib/atomic-transaction.sh"))):
        if remote_hash(target, stage + "/" + name) != expected:
            reject("staged prior configuration differs during restore resume")
    for source_name, destination, old_hash, new_hash in (
        ("docker-compose.yml", project + "/docker-compose.yml", local["candidate_compose"], local["source_compose"]),
        ("Caddyfile", project + "/caddy/Caddyfile", local["source_caddy"], local["source_caddy"]),
    ):
        current = remote_hash(target, destination)
        if current not in (old_hash, new_hash):
            reject("live configuration changed during restore")
        if current != new_hash:
            checked(target, "set -eu; . " + q(stage + "/atomic-transaction.sh") +
                    "; atomic_replace_preserve " + q(stage + "/" + source_name) + " " +
                    q(destination) + " 0644")
        if remote_hash(target, destination) != new_hash:
            reject("prior configuration did not restore")
    presence = target.ops("active-record", "presence", stage_id)
    if presence.get("state") == "present":
        active = target.ops("active-record", "status", stage_id)
        if active.get("state") not in ("applied", "rolledback"):
            reject("active-record restore phase differs")
        target.ops("active-record", "rollback", stage_id)
        target.ops("active-record", "commit", stage_id)
    elif presence.get("state") != "absent":
        reject("active-record restore presence differs")
    if target.ops("active-images-state").get("sha256") != local["source_record"]:
        reject("prior active record was not restored")
    target.ops("service", "start", timeout=600)
    maintenance_off = False
    for _ in range(12):
        try:
            status = target.ssh("docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status")
            if "maintenance: true" in status:
                checked(target, "docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ maintenance:mode --off >/dev/null", timeout=30)
            elif "maintenance: false" not in status:
                reject("restored Nextcloud maintenance state is unknown")
            maintenance_off = True
            break
        except RecoveryError:
            time.sleep(5)
    if not maintenance_off:
        reject("restored Nextcloud did not leave maintenance mode")
    checked(target, "! docker port nextcloud-docker-app-1 80/tcp >/dev/null 2>&1")
    run([str(ROOT / "scripts/health-check.sh"), "--caddyfile", str(config_backup / "caddy/Caddyfile")], timeout=300)
    stage_state = target.ops("upgrade-stage", "status", stage_id)
    if stage_state.get("phase") == "runtime-may-have-changed":
        target.ops("upgrade-stage", "recovered", stage_id, str(base["stage_fingerprint"]))
    elif stage_state.get("phase") != "recovered":
        reject("upgrade stage recovery phase differs")


def apply(target: Target, base: dict[str, object], source: Path,
          config_backup: Path, runtime: Path, images: Path) -> None:
    stage_id = str(base["stage_id"])
    project = target.config["NEXTCLOUD_REMOTE_PROJECT_DIR"]
    mount = target.config["NEXTCLOUD_STORAGE_MOUNT"]
    local = base["evidence"]
    assert isinstance(local, dict)
    old_tags = local["old_tags"]
    old_ids = local["old_ids"]
    assert isinstance(old_tags, dict) and isinstance(old_ids, dict)
    prior_ok = True
    for key in ("APP", "DB", "CADDY"):
        try:
            found = target.ssh("docker image inspect --format '{{.Id}}' " + q(str(old_tags[key])))
        except RecoveryError:
            found = ""
        prior_ok &= found == old_ids[key]
    if not prior_ok:
        checked(target, "docker load >/dev/null", input_file=images / "images.tar", timeout=3600)
    for key in ("APP", "DB", "CADDY"):
        if target.ssh("docker image inspect --format '{{.Id}}' " + q(str(old_tags[key]))) != old_ids[key]:
            reject("loaded prior image identity differs; ingress freeze remains held")

    prepared = target.ops("runtime-recovery", "prepare", stage_id)
    restore_root = prepared.get("root", "")
    if prepared.get("state") != "prepared" or restore_root != mount + "/.recovery-" + stage_id:
        reject("protected recovery staging root differs from policy")
    for dataset, relative in (("nextcloud", PATHS[0]), ("caddy-data", PATHS[1]),
                              ("caddy-config", PATHS[2])):
        archive = runtime / relative
        target.ops("runtime-recovery", "restore", stage_id, dataset, digest(archive),
                   str(archive.stat().st_size), input_file=archive, timeout=3600)

    database_dir = restore_root + "/mariadb-data"
    database_container = "nextcloud-restore-db-" + stage_id
    db_tag = str(old_tags["DB"])
    db_command = ("docker run --pull=never --network none -d --name " + q(database_container) +
                  " --env-file " + q(project + "/.env") + " --mount " +
                  q("type=bind,source=" + database_dir + ",target=/var/lib/mysql") + " " + q(db_tag) + " >/dev/null")
    checked(target, db_command)
    try:
        ready = False
        query = ("docker exec " + q(database_container) + " sh -eu -c " +
                 q('export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb --protocol=tcp --host=127.0.0.1 -uroot -N --batch "$MYSQL_DATABASE" -e "$1"') + " sh ")
        for _ in range(90):
            try:
                if target.ssh(query + q("SELECT 1")) == "1":
                    ready = True
                    break
            except RecoveryError:
                time.sleep(2)
        if not ready:
            reject("staged MariaDB server did not become ready")
        sql = runtime / "database/nextcloud.sql"
        checked(target, "docker exec -i " + q(database_container) + " sh -eu -c " +
                q('export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb --protocol=tcp --host=127.0.0.1 -uroot "$MYSQL_DATABASE"'),
                input_file=sql, timeout=3600)
        count = target.ssh(query + q("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()"))
        columns = target.ssh(query + q("SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE()"))
        files = target.ssh(query + q("SELECT COUNT(*) FROM oc_filecache"))
        if any(not value.isdecimal() or int(value) < 1 for value in (count, columns, files)):
            reject("staged MariaDB schema or file cache is incomplete")
        checked(target, "docker exec " + q(database_container) + " sh -eu -c " +
                q('export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb-check --protocol=tcp --host=127.0.0.1 -uroot --all-databases --silent'),
                timeout=900)
    finally:
        try:
            checked(target, "docker stop --time 60 " + q(database_container) + " >/dev/null", timeout=120)
        except RecoveryError:
            pass
    checked(target, "docker rm " + q(database_container) + " >/dev/null")
    target.ops("runtime-recovery", "attest-database", stage_id, str(local["sql_sha256"]), count, columns, files)

    stage = project + "/.restore-stage-" + stage_id
    checked(target, "umask 077; mkdir -m 0700 " + q(stage))
    files = ((config_backup / "compose/docker-compose.yml", "docker-compose.yml"),
             (config_backup / "caddy/Caddyfile", "Caddyfile"),
             (ROOT / "scripts/lib/atomic-transaction.sh", "atomic-transaction.sh"))
    for local_file, name in files:
        run(["scp", "-q", str(local_file), target.login + ":" + stage + "/" + name], timeout=120)
        if remote_hash(target, stage + "/" + name) != digest(local_file):
            reject("staged prior configuration differs")

    target.ops("service", "stop")
    target.ops("runtime-recovery", "promote", stage_id, str(base["stage_fingerprint"]), timeout=3600)
    finish_promoted(target, base, config_backup)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true")
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--resume", action="store_true")
    parser.add_argument("stage_id")
    parser.add_argument("candidate", type=Path)
    parser.add_argument("source_rendered", type=Path)
    parser.add_argument("config_backup", type=Path)
    parser.add_argument("held_runtime_backup", type=Path)
    parser.add_argument("prior_image_recovery", type=Path)
    parser.add_argument("--approval", type=Path)
    args = parser.parse_args()
    if (args.apply or args.resume) != (args.approval is not None):
        parser.error("--apply/--resume require --approval, and --plan does not accept it")
    try:
        target = Target(deployment_config())
        remote_time = target.ssh("date -u +%s")
        now = int(time.time())
        if not remote_time.isdecimal() or abs(now - int(remote_time)) > 60:
            reject("local and Pi clocks differ by more than 60 seconds")
        root = private_artifact_root()
        if args.resume:
            base = consumed_for_resume(args.approval, root, args.stage_id)
            resume(target, base, args.candidate, args.source_rendered,
                   args.config_backup, args.held_runtime_backup, args.prior_image_recovery)
            print("Interrupted full-runtime promotion resumed and verified; ingress freeze remains held.")
            return 0
        base = evidence(target, args.stage_id, args.candidate, args.source_rendered,
                        args.config_backup, args.held_runtime_backup, args.prior_image_recovery)
        if args.plan:
            artifact = plan(root, base, now)
            print(f"Redacted full-runtime restore plan: stage={args.stage_id} host={base['host']} freeze-held=yes")
            print(f"Approval artifact: {artifact}")
            return 0
        assert args.approval is not None
        consume(args.approval, root, base, now)
        print(f"Restore approval consumed; stage={args.stage_id}. Ingress freeze remains held.")
        apply(target, base, args.source_rendered, args.config_backup,
              args.held_runtime_backup, args.prior_image_recovery)
        print("Full prior runtime restored and verified; ingress freeze remains held for separate release.")
        return 0
    except (RecoveryError, OSError, KeyError, ValueError, json.JSONDecodeError) as exc:
        print(f"Live restore stopped: {exc}. Preserve all recovery state and ingress freeze.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
