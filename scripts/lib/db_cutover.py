"""Private clean MariaDB preparation used by the image activation driver."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import time
from typing import Any


ENV_KEYS = ("MYSQL_ROOT_PASSWORD", "MYSQL_PASSWORD", "MYSQL_DATABASE", "MYSQL_USER")
TABLE = re.compile(r"[A-Za-z0-9_]+\Z")
QUERIES = {
    "tables": "SELECT TABLE_NAME,TABLE_TYPE,ENGINE,ROW_FORMAT,TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() ORDER BY TABLE_NAME",
    "columns": "SELECT TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,COLUMN_TYPE,IS_NULLABLE,COALESCE(COLUMN_DEFAULT,'<NULL>'),EXTRA,COALESCE(CHARACTER_SET_NAME,''),COALESCE(COLLATION_NAME,'') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() ORDER BY TABLE_NAME,ORDINAL_POSITION",
    "indexes": "SELECT TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX,COLUMN_NAME,NON_UNIQUE,INDEX_TYPE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX",
    "constraints": "SELECT TABLE_NAME,CONSTRAINT_NAME,COLUMN_NAME,REFERENCED_TABLE_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=DATABASE() ORDER BY TABLE_NAME,CONSTRAINT_NAME,ORDINAL_POSITION",
    "routines": "SELECT ROUTINE_NAME,ROUTINE_TYPE,ROUTINE_DEFINITION FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=DATABASE() ORDER BY ROUTINE_NAME",
    "triggers": "SELECT TRIGGER_NAME,EVENT_MANIPULATION,EVENT_OBJECT_TABLE,ACTION_STATEMENT FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=DATABASE() ORDER BY TRIGGER_NAME",
    "events": "SELECT EVENT_NAME,STATUS,EVENT_DEFINITION FROM information_schema.EVENTS WHERE EVENT_SCHEMA=DATABASE() ORDER BY EVENT_NAME",
}


def database_query(target: Any, name: str, sql: str, r: Any, *, user: bool = False) -> str:
    password = "MYSQL_PASSWORD" if user else "MYSQL_ROOT_PASSWORD"
    account = '-u"$MYSQL_USER"' if user else "-uroot"
    shell = (f'export MYSQL_PWD="${password}"; exec mariadb --protocol=tcp '
             f'--host=127.0.0.1 {account} -N --batch --raw "$MYSQL_DATABASE" -e "$1"')
    return target.ssh("docker exec " + r.q(name) + " sh -eu -c " + r.q(shell) + " sh " + r.q(sql), timeout=120)


def inventory(target: Any, name: str, r: Any, prefix: str) -> dict[str, object]:
    if not TABLE.fullmatch(prefix):
        r.reject("Nextcloud table prefix is unsafe")
    result: dict[str, object] = {}
    for label, sql in QUERIES.items():
        result[label] = database_query(target, name, sql, r).splitlines()
    tables = []
    for line in result["tables"]:
        columns = line.split("\t")
        if len(columns) != 5 or not TABLE.fullmatch(columns[0]) or columns[1] != "BASE TABLE" or not columns[0].startswith(prefix):
            r.reject("database contains an unexpected object or table prefix")
        tables.append(columns[0])
    if not tables:
        r.reject("application database has no tables")
    counts: dict[str, int] = {}
    for table in tables:
        raw = database_query(target, name, "SELECT COUNT(*) FROM `" + table + "`", r)
        if not raw.isdecimal():
            r.reject("database row inventory is invalid")
        counts[table] = int(raw)
    result["rows"] = counts
    result["prefix"] = prefix
    return result


def inventory_hash(value: dict[str, object]) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def source_inventory(target: Any, r: Any) -> dict[str, object]:
    prefix = target.ssh("docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ config:system:get dbtableprefix")
    scheduler = database_query(target, "nextcloud-docker-db-1", "SHOW VARIABLES LIKE 'event_scheduler'", r)
    if scheduler.split("\t")[-1].upper() != "OFF":
        r.reject("database event scheduler must be off during cutover")
    return inventory(target, "nextcloud-docker-db-1", r, prefix)


def restricted_env_bytes(path: Path, r: Any) -> bytes:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or key not in ENV_KEYS or key in values or len(value) < 3 or not value.startswith("'") or not value.endswith("'"):
            r.reject("protected database environment schema differs")
        plain = value[1:-1]
        if not plain or "'" in plain or "\\" in plain or any(character.isspace() for character in plain):
            r.reject("protected database environment value is unsafe")
        values[key] = plain
    if set(values) != set(ENV_KEYS):
        r.reject("protected database environment is incomplete")
    return "".join(f"{key}={values[key]}\n" for key in ENV_KEYS).encode()


def restricted_env(path: Path, destination: Path, r: Any) -> None:
    content = restricted_env_bytes(path, r)
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())


def temporary_container(target: Any, r: Any, stage_id: str, data: str, expected_id: str,
                        recorded_id: str | None = None) -> str:
    name = "nextcloud-cutover-db-" + stage_id
    template = ('{{.Id}} {{index .Config.Labels "nextcloud-pi-db-cutover"}} {{.Image}} '
                '{{.HostConfig.RestartPolicy.Name}} {{.HostConfig.NetworkMode}} '
                '{{len .HostConfig.PortBindings}} {{len .Mounts}} '
                '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Source}}{{end}}{{end}}')
    details = target.ssh("docker inspect --format " + r.q(template) + " " + r.q(name))
    fields = details.split(" ", 1)
    if (len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]) or
            fields[1] != f"{stage_id} {expected_id} no none 0 1 {data}" or
            recorded_id not in (None, "pending", fields[0])):
        r.reject("temporary database container identity differs")
    return name


def remove_temporary(target: Any, r: Any, stage_id: str, data: str, expected_id: str) -> None:
    name = "nextcloud-cutover-db-" + stage_id
    recorded = target.ops("db-cutover", "status", stage_id).get("temp_container_id")
    try:
        temporary_container(target, r, stage_id, data, expected_id, recorded)
    except r.RecoveryError:
        if target.ssh("docker ps -aq --no-trunc --filter " + r.q("name=^/" + name + "$")):
            raise
        return
    state = target.ssh("docker inspect --format '{{.State.Running}}' " + r.q(name))
    if state == "true":
        target.ssh("docker stop --time 120 " + r.q(name) + " >/dev/null", timeout=180)
    elif state != "false":
        r.reject("temporary database state is unknown")
    target.ssh("docker rm " + r.q(name) + " >/dev/null")


def prepare(target: Any, r: Any, stage_id: str, fingerprint: str, base: dict[str, object],
            candidate: Path, config_backup: Path, runtime: Path, root: Path,
            source: dict[str, object], *, resume: bool = False) -> dict[str, str]:
    local = base["evidence"]
    assert isinstance(local, dict)
    project = str(base["project"])
    env = root / f"db-env-{stage_id}"
    if not env.exists():
        restricted_env(config_backup / "compose/.env", env, r)
    elif r.digest(env) != base["restricted_env_sha256"]:
        r.reject("restricted database environment changed")
    result = target.ops("db-cutover", "begin", stage_id, fingerprint,
                        str(base["freeze"]["id"]), str(base["freeze"]["table_sha256"]),
                        str(local["source_record"]), str(local["source_compose"]),
                        str(local["candidate_record"]), str(local["candidate_compose"]),
                        str(base["expected_id"]), str(local["env_sha256"]),
                        str(base["restricted_env_sha256"]),
                        str(local["sql_sha256"]), str(base["inventory_sha256"]))
    data = target.config["NEXTCLOUD_STORAGE_MOUNT"] + "/.db-cutover-" + stage_id + "/data"
    if result != {"phase": "preparing", "id": stage_id, "data": data}:
        r.reject("protected database preparation differs")
    if resume:
        remove_temporary(target, r, stage_id, data, str(base["expected_id"]))
        target.ops("db-cutover", "reset-preparing", stage_id, fingerprint)
    target.ops("db-cutover", "env-install", stage_id, fingerprint,
               str(base["restricted_env_sha256"]), str(env.stat().st_size), input_file=env)
    name = "nextcloud-cutover-db-" + stage_id
    started = target.ops("db-cutover", "temp-start", stage_id, fingerprint)
    if not re.fullmatch(r"[0-9a-f]{64}", started.get("container_id", "")):
        r.reject("temporary database container ID was not recorded")
    temporary_container(target, r, stage_id, data, str(base["expected_id"]), started["container_id"])
    ready = False
    for _ in range(90):
        try:
            if database_query(target, name, "SELECT 1", r) == "1":
                ready = True
                break
        except r.RecoveryError:
            time.sleep(2)
    if not ready:
        r.reject("clean MariaDB container did not become ready")
    sql = runtime / "database/nextcloud.sql"
    target.ssh("docker exec -i " + r.q(name) + " sh -eu -c " +
               r.q('export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb --protocol=tcp --host=127.0.0.1 -uroot "$MYSQL_DATABASE"'),
               input_file=sql, timeout=3600)
    imported = inventory(target, name, r, str(source["prefix"]))
    if imported != source:
        r.reject("clean MariaDB inventory differs from the frozen source")
    table, rows = next(iter(source["rows"].items()))
    if database_query(target, name, "SELECT COUNT(*) FROM `" + table + "`", r, user=True) != str(rows):
        r.reject("application database account cannot read the imported schema")
    target.ssh("docker exec " + r.q(name) + " sh -eu -c " +
               r.q('export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb-check --protocol=tcp --host=127.0.0.1 -uroot --all-databases --silent'), timeout=900)
    target.ssh("docker stop --time 120 " + r.q(name) + " >/dev/null", timeout=180)
    if target.ssh("docker inspect --format '{{.State.ExitCode}}' " + r.q(name)) != "0":
        r.reject("clean MariaDB shutdown was not graceful")
    temporary_container(target, r, stage_id, data, str(base["expected_id"]), started["container_id"])
    target.ssh("docker rm " + r.q(name) + " >/dev/null")
    result = target.ops("db-cutover", "attest", stage_id, fingerprint, timeout=3600)
    if result.get("phase") != "prepared" or result.get("id") != stage_id:
        r.reject("protected database attestation differs")
    return result
