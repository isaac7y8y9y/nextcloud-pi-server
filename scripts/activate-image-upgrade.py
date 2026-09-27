#!/usr/bin/env python3
"""Stage one approved image, then separately approve acceptance; never release ingress."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from lib import db_cutover as db

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("restore_live_runtime", HERE / "restore-live-runtime.py")
assert SPEC and SPEC.loader
r = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(r)

FETCH_KEYS = set("format state transaction_id fingerprint candidate_sha256 source_lock_sha256 config_manifest_sha256 runtime_manifest_sha256 image_manifest_sha256 image_attestation_sha256 prestate_sha256 freeze_id freeze_table_sha256 tag index_digest manifest_digest config_digest host created remote_created expires actions exclusions".split())
FETCH_AUTHORITY = "transaction_id candidate_sha256 source_lock_sha256 config_manifest_sha256 runtime_manifest_sha256 image_manifest_sha256 image_attestation_sha256 prestate_sha256 freeze_id freeze_table_sha256 tag index_digest manifest_digest config_digest host created remote_created expires actions exclusions".split()
CONTAINERS = {"APP": "nextcloud-docker-app-1", "DB": "nextcloud-docker-db-1", "CADDY": "nextcloud-docker-caddy-1"}


def approval_root() -> Path:
    name = "NEXTCLOUD_IMAGE_ACTIVATION_APPROVAL_ROOT"
    root = Path(os.environ.get(name, Path(os.path.expanduser("~")) / "nextcloud-pi-image-activation-approvals"))
    if not root.is_absolute() or any(parent.is_symlink() for parent in (root, *root.parents)):
        r.reject("activation approval root is unsafe")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if stat.S_IMODE(root.stat().st_mode) != 0o700:
        r.reject("activation approval root must have mode 0700")
    if subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], capture_output=True).returncode == 0:
        r.reject("activation approval root must be outside Git")
    return root


def age(path: Path, now: int) -> None:
    stamp = r.manifest_fields(path).get("timestamp", "")
    try:
        epoch = int(datetime.strptime(stamp, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).timestamp())
    except ValueError as exc:
        raise r.RecoveryError("recovery timestamp is invalid") from exc
    if not 0 <= now - epoch <= 86400:
        r.reject("recovery artifact is older than 24 hours")


def fetch_record(path: Path, local: dict[str, object], metadata: dict[str, str],
                 freeze: dict[str, str], host: str, now: int, prestate_hash: str) -> dict[str, str]:
    r.private_file(path)
    record = r.fields(path)
    if set(record) != FETCH_KEYS or record["format"] != "image-upgrade-fetch-v1" or record["state"] != "consumed":
        r.reject("completed fetch approval schema differs")
    if not r.IDENTIFIER.fullmatch(record["transaction_id"]) or not r.HASH.fullmatch(record["fingerprint"]):
        r.reject("completed fetch approval identity is invalid")
    expected = {"candidate_sha256": local["candidate_manifest"],
                "source_lock_sha256": r.digest(r.ROOT / "config/image-lock.env"),
                "config_manifest_sha256": local["config_manifest"],
                "runtime_manifest_sha256": local["backup_manifest"],
                "image_manifest_sha256": local["image_manifest"],
                "image_attestation_sha256": local["image_attestation"],
                "prestate_sha256": prestate_hash,
                "freeze_id": freeze["id"], "freeze_table_sha256": freeze["table_sha256"],
                "tag": metadata["tag"], "index_digest": metadata["index_digest"],
                "manifest_digest": metadata["manifest_digest"], "config_digest": metadata["config_digest"],
                "host": host}
    if any(record.get(key) != value for key, value in expected.items()):
        r.reject("completed fetch differs from candidate, backups, or freeze")
    try:
        created, remote_created, expires = (int(record[key]) for key in ("created", "remote_created", "expires"))
    except ValueError as exc:
        raise r.RecoveryError("fetch approval clock is invalid") from exc
    if expires - created != 900 or abs(created - remote_created) > 60 or not created <= now:
        r.reject("completed fetch approval clock differs")
    if (record["actions"] != "pull-exact-digest,verify-loaded-id" or
            record["exclusions"] != "tag-change,compose,source-lock,active-record,container-start,container-stop,pruning,image-removal,runtime-restore,freeze-release"):
        r.reject("completed fetch approval actions differ")
    authority = "".join(f"{key}\t{record[key]}\n" for key in FETCH_AUTHORITY).encode()
    if hashlib.sha256(authority).hexdigest() != record["fingerprint"]:
        r.reject("completed fetch approval fingerprint differs")
    # The protected root marker is the replay authority; the local TSV is evidence only.
    return record


def running(target: r.Target, record: Path) -> dict[str, str]:
    values = {}
    for key, name in CONTAINERS.items():
        actual = target.ssh("docker inspect " + r.q(name) + " --format '{{.Id}} {{.Image}} {{.State.Running}}'")
        parts = actual.split()
        expected = r.record_value(record, f"NEXTCLOUD_ACTIVE_IMAGES_{key}_ID")
        if len(parts) != 3 or not re.fullmatch("[0-9a-f]{64}", parts[0]) or parts[1:] != [expected, "true"]:
            r.reject("running container differs from the approved image record")
        values[key] = parts[0]
    return values


def common(target: r.Target, candidate: Path, source: Path, config_backup: Path,
           runtime: Path, images: Path, now: int, *, before_stage: bool = True) -> tuple[dict[str, object], dict[str, str]]:
    local = r.verify_local(candidate, source, config_backup, runtime, images, target.config)
    if before_stage:
        for path in (config_backup / "manifest.tsv", runtime / "manifest.tsv",
                     images / "manifest.tsv", images / "restore-attestation.tsv"):
            age(path, now)
    metadata = r.fields(candidate / "registry-metadata.tsv")
    if before_stage:
        resolved = r.run(["python3", str(HERE / "resolve-image-upgrade.py"), metadata["tag"],
                          "--expected-index", metadata["index_digest"]], timeout=120)
        if resolved + "\n" != (candidate / "registry-metadata.tsv").read_text():
            r.reject("registry identity changed")
    if target.ssh("hostname") != target.config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"] or target.ssh("id -un") != target.config["NEXTCLOUD_PI_USER"]:
        r.reject("connected Pi identity differs")
    freeze = target.ops("upgrade-freeze", "status")
    held = r.manifest_fields(runtime / "manifest.tsv")
    if freeze.get("state") != "active" or freeze.get("id") != held.get("freeze_id") or freeze.get("table_sha256") != held.get("freeze_table_sha256"):
        r.reject("protected ingress freeze differs from held backup")
    if target.ops("background-jobs", "state").get("timer_active") != "no":
        r.reject("background jobs are not paused")
    if r.remote_hash(target, target.config["NEXTCLOUD_REMOTE_PROJECT_DIR"] + "/.env") != local["env_sha256"]:
        r.reject("live database environment differs from held backup")
    return local, dict(metadata, freeze_id=freeze["id"], freeze_table_sha256=freeze["table_sha256"])


def stage_evidence(target: r.Target, candidate: Path, source: Path, config_backup: Path,
                   runtime: Path, images: Path, fetch_path: Path, now: int,
                   *, before_stage: bool = True) -> dict[str, object]:
    local, metadata = common(target, candidate, source, config_backup, runtime, images, now, before_stage=before_stage)
    freeze = {"id": metadata["freeze_id"], "table_sha256": metadata["freeze_table_sha256"]}
    project = target.config["NEXTCLOUD_REMOTE_PROJECT_DIR"]
    for path, expected in ((project + "/docker-compose.yml", local["source_compose"]),
                           (project + "/caddy/Caddyfile", local["source_caddy"])):
        if r.remote_hash(target, path) != expected:
            r.reject("live source configuration changed")
    active = target.ops("active-images-state")
    if active.get("mode") != "source" or active.get("sha256") != local["source_record"]:
        r.reject("protected active record differs from source")
    if "maintenance: true" not in target.ssh("docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status"):
        r.reject("Nextcloud maintenance mode is not on")
    lines = [f"active_record\t{local['source_record']}", f"compose\t{local['source_compose']}",
             f"caddy\t{local['source_caddy']}"]
    for key in CONTAINERS:
        tag = local["old_tags"][key]
        if target.ssh("docker image inspect --format '{{.Id}}' " + r.q(tag)) != local["old_ids"][key]:
            r.reject("source image mapping changed")
        lines.append(f"source_image\t{tag}\t{local['old_ids'][key]}")
    before = running(target, source / "active-images/active-images.env")
    for key, name in CONTAINERS.items():
        lines.append(f"container\t{name}\t{before[key]} {local['old_ids'][key]} true")
    prestate_hash = hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()
    fetch = fetch_record(fetch_path, local, metadata, freeze, target.config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"], now, prestate_hash)
    status = target.ops("upgrade-fetch", "status", fetch["transaction_id"])
    expected_fetch = {"state": "complete", "id": fetch["transaction_id"], "fingerprint": fetch["fingerprint"],
                      "freeze_id": freeze["id"], "freeze_table_sha256": freeze["table_sha256"],
                      "ref": metadata["image"] + "@" + metadata["index_digest"],
                      "expected_id": metadata["config_digest"], "expires": fetch["expires"]}
    if status != expected_fetch:
        r.reject("protected fetch completion differs")
    ref = expected_fetch["ref"]
    if target.ssh("docker image inspect --format '{{.Id}}' " + r.q(ref)) != metadata["config_digest"]:
        r.reject("fetched digest image ID differs")
    tag = metadata["tag"]
    try:
        existing = target.ssh("docker image inspect --format '{{.Id}}' " + r.q(tag))
    except r.RecoveryError:
        existing = ""
    if existing and existing != metadata["config_digest"]:
        r.reject("candidate tag already points to another image")
    image_key = {"nextcloud": "APP", "mariadb": "DB", "caddy": "CADDY"}[metadata["image"]]
    return {"format": "image-activation-stage-v1", "stage_id": "", "host": target.config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"],
            "project": project, "freeze": freeze, "fetch_id": fetch["transaction_id"],
            "fetch_fingerprint": fetch["fingerprint"], "fetch_artifact_sha256": r.digest(fetch_path),
            "tag": tag, "ref": ref, "target": image_key.lower(), "expected_id": metadata["config_digest"],
            "source_running": before, "evidence": local,
            "actions": "tag-approved-digest,prepare-active-record,install-compose,mark-boundary,restart-target,stage-maintenance-off",
            "exclusions": "pull,prune,image-removal,source-lock-write,freeze-release,post-boundary-config-only-rollback"}


def private_inventory(root: Path, stage_id: str) -> Path:
    if not r.IDENTIFIER.fullmatch(stage_id):
        r.reject("database preparation ID is invalid")
    return root / f"db-inventory-{stage_id}.json"


def store_inventory(root: Path, stage_id: str, value: dict[str, object]) -> None:
    path = private_inventory(root, stage_id)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        stream.flush()
        os.fsync(stream.fileno())


def prepare_db_evidence(target: r.Target, candidate: Path, source: Path, config_backup: Path,
                        runtime: Path, images: Path, fetch_path: Path, now: int,
                        root: Path, stage_id: str | None = None,
                        *, resume: bool = False) -> tuple[dict[str, object], dict[str, object]]:
    base = stage_evidence(target, candidate, source, config_backup, runtime, images, fetch_path, now,
                          before_stage=not resume)
    if base["target"] != "db" or not str(base["tag"]).startswith("mariadb:11.4."):
        r.reject("clean database preparation requires an approved MariaDB 11.4 candidate")
    source_version = db.database_query(target, CONTAINERS["DB"], "SELECT VERSION()", r)
    app_status = target.ssh("docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status")
    if not source_version.startswith("11.8.") or "version: 30." not in app_status or "maintenance: true" not in app_status:
        r.reject("clean cutover requires frozen Nextcloud 30 with source MariaDB 11.8")
    base["stage_id"] = stage_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + str(os.getpid())
    source_inventory = db.source_inventory(target, r)
    base["format"] = "image-db-prepare-v1"
    base["inventory_sha256"] = db.inventory_hash(source_inventory)
    env = root / f"db-env-{base['stage_id']}"
    if not env.exists():
        db.restricted_env(config_backup / "compose/.env", env, r)
    elif r.private_file(env) != db.restricted_env_bytes(config_backup / "compose/.env", r):
        r.reject("restricted database environment differs from the bound backup")
    base["restricted_env_sha256"] = r.digest(env)
    base["actions"] = "initialize-clean-mariadb,import-held-sql,verify-inventory,attest-stopped-directory"
    base["exclusions"] = "source-database-move,source-container-stop,compose-change,active-record-change,freeze-release"
    return base, source_inventory


def consumed_prepare(path: Path, root: Path, stage_id: str) -> dict[str, object]:
    if path.parent != root or not path.name.startswith(f"prepare-db-{stage_id}-"):
        r.reject("database preparation approval path differs")
    record = json.loads(r.private_file(path))
    if not isinstance(record, dict) or record.get("format") != "image-db-prepare-v1" or record.get("state") != "consumed" or record.get("stage_id") != stage_id:
        r.reject("database preparation approval was not consumed")
    created = record.get("created")
    if not isinstance(created, int) or record.get("expires") != created + 900:
        r.reject("database preparation approval clock differs")
    original = dict(record, state="unused")
    original.pop("fingerprint", None)
    expected = r.fingerprint(original)
    if record.get("fingerprint") != expected:
        r.reject("database preparation approval fingerprint differs")
    marker = root / f"used-prepare-db-{stage_id}-{created}"
    if r.private_file(marker) != (expected + "\n").encode():
        r.reject("database preparation consumption marker differs")
    inventory_path = private_inventory(root, stage_id)
    if r.digest(inventory_path) != record.get("inventory_sha256"):
        r.reject("frozen database inventory sidecar differs")
    return record


def consumed_stage(path: Path, root: Path) -> dict[str, object]:
    record = json.loads(r.private_file(path))
    if not isinstance(record, dict) or record.get("format") != "image-activation-stage-v1" or record.get("state") != "consumed":
        r.reject("activation approval was not consumed")
    stage_id = record.get("stage_id", "")
    created = record.get("created")
    if (not isinstance(stage_id, str) or not r.IDENTIFIER.fullmatch(stage_id) or
            not isinstance(created, int) or record.get("expires") != created + 900 or
            path.parent != root or not path.name.startswith(f"stage-{stage_id}-")):
        r.reject("consumed activation approval identity differs")
    original = dict(record, state="unused")
    original.pop("fingerprint", None)
    expected = r.fingerprint(original)
    if record.get("fingerprint") != expected:
        r.reject("consumed activation approval fingerprint differs")
    marker = root / f"used-stage-{stage_id}-{created}"
    if r.private_file(marker) != (expected + "\n").encode():
        r.reject("consumed activation marker differs")
    return record


def db_stage_evidence(target: r.Target, base: dict[str, object], preparation: Path,
                      root: Path) -> dict[str, object]:
    record = json.loads(r.private_file(preparation))
    if not isinstance(record, dict) or not r.IDENTIFIER.fullmatch(str(record.get("stage_id", ""))):
        r.reject("database preparation approval identity is invalid")
    stage_id = str(record["stage_id"])
    prepared = consumed_prepare(preparation, root, stage_id)
    if (prepared.get("host") != base.get("host") or prepared.get("project") != base.get("project") or
            prepared.get("freeze") != base.get("freeze") or prepared.get("evidence") != base.get("evidence") or
            prepared.get("fetch_fingerprint") != base.get("fetch_fingerprint") or
            prepared.get("expected_id") != base.get("expected_id")):
        r.reject("database preparation differs from cutover candidate")
    if db.inventory_hash(db.source_inventory(target, r)) != prepared["inventory_sha256"]:
        r.reject("source database inventory changed since preparation")
    status = target.ops("db-cutover", "status", stage_id)
    if (status.get("phase") != "prepared" or status.get("id") != stage_id or
            status.get("prepare_fingerprint") != prepared["fingerprint"] or
            status.get("inventory_sha256") != prepared["inventory_sha256"] or
            status.get("candidate_record_sha256") != base["evidence"]["candidate_record"] or
            status.get("candidate_compose_sha256") != base["evidence"]["candidate_compose"] or
            not r.HASH.fullmatch(status.get("candidate_digest", ""))):
        r.reject("protected clean database attestation differs")
    base["stage_id"] = stage_id
    base["db_prepare_fingerprint"] = prepared["fingerprint"]
    base["db_prepare_sha256"] = r.digest(preparation)
    base["db_candidate_digest"] = status["candidate_digest"]
    base["db_inventory_sha256"] = prepared["inventory_sha256"]
    base["actions"] = "detach-source-containers,promote-attested-database,install-candidate,start,stage-maintenance-off"
    base["exclusions"] = "pull,prune,image-removal,source-lock-write,freeze-release,config-only-rollback"
    return base


def approval_plan(root: Path, base: dict[str, object], now: int, kind: str) -> Path:
    record = dict(base, state="unused", created=now, expires=now + 900)
    record["fingerprint"] = r.fingerprint(record)
    artifact = root / f"{kind}-{base['stage_id']}-{now}.json"
    descriptor = os.open(artifact, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(r.canonical(record) + b"\n")
    return artifact


def approval_consume(path: Path, root: Path, base: dict[str, object], now: int, kind: str) -> dict[str, object]:
    if path.parent != root or not path.name.startswith(f"{kind}-{base['stage_id']}-"):
        r.reject("approval path differs from stage")
    record = json.loads(r.private_file(path))
    if not isinstance(record, dict) or record.get("state") != "unused":
        r.reject("activation approval is not unused")
    if not isinstance(record.get("created"), int) or not isinstance(record.get("expires"), int):
        r.reject("activation approval clock is invalid")
    if record["expires"] - record["created"] != 900 or not record["created"] <= now <= record["expires"]:
        r.reject("activation approval expired")
    expected = dict(base, state="unused", created=record["created"], expires=record["expires"])
    expected["fingerprint"] = r.fingerprint(expected)
    if record != expected:
        r.reject("activation approval or bound evidence changed")
    marker = root / f"used-{kind}-{base['stage_id']}-{record['created']}"
    fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write((record["fingerprint"] + "\n").encode())
    consumed = dict(record, state="consumed")
    temporary = root / f".{path.name}.new"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(r.canonical(consumed) + b"\n")
    os.replace(temporary, path)
    return consumed


def consumed_acceptance(path: Path, root: Path, base: dict[str, object]) -> None:
    if path.parent != root or not path.name.startswith(f"accept-{base['stage_id']}-"):
        r.reject("consumed acceptance path differs")
    record = json.loads(r.private_file(path))
    if not isinstance(record, dict) or record.get("state") != "consumed":
        r.reject("acceptance approval is not consumed")
    created = record.get("created")
    if not isinstance(created, int):
        r.reject("acceptance approval clock is invalid")
    original = dict(base, state="unused", created=created, expires=created + 900)
    original["fingerprint"] = r.fingerprint(original)
    if record != dict(original, state="consumed"):
        r.reject("consumed acceptance evidence changed")
    marker = root / f"used-accept-{base['stage_id']}-{created}"
    if r.private_file(marker) != (original["fingerprint"] + "\n").encode():
        r.reject("consumed acceptance marker differs")


def install_compose(target: r.Target, stage_dir: str, source_name: str, project: str) -> None:
    target.ssh("set -eu; . " + r.q(stage_dir + "/atomic-transaction.sh") +
               "; atomic_replace_preserve " + r.q(stage_dir + "/" + source_name) + " " +
               r.q(project + "/docker-compose.yml") + " 0644")


def db_stage_apply(target: r.Target, base: dict[str, object], approval: dict[str, object],
                   candidate: Path, source: Path) -> None:
    stage_id = str(base["stage_id"])
    evidence = base["evidence"]
    assert isinstance(evidence, dict)
    project = str(base["project"])
    prep_fingerprint = str(base["db_prepare_fingerprint"])
    stage_fingerprint = str(approval["fingerprint"])
    stage_dir = project + "/.upgrade-stage-" + stage_id
    root_db = target.ops("db-cutover", "status", stage_id)
    if (root_db.get("prepare_fingerprint") != prep_fingerprint or
            root_db.get("candidate_digest") != base["db_candidate_digest"] or
            root_db.get("inventory_sha256") != base["db_inventory_sha256"]):
        r.reject("protected database cutover differs from approved preparation")
    try:
        stage = target.ops("upgrade-stage", "status", stage_id)
    except r.RecoveryError:
        stage = {}
    if not stage:
        result = target.ops("upgrade-stage", "consume", stage_id, stage_fingerprint,
                            str(base["freeze"]["id"]), str(base["freeze"]["table_sha256"]),
                            str(base["fetch_id"]), str(base["fetch_fingerprint"]), "db",
                            str(base["tag"]), str(evidence["source_record"]), str(evidence["source_compose"]),
                            str(evidence["candidate_record"]), str(evidence["candidate_compose"]),
                            str(approval["expires"]))
        if result != {"phase": "prepared", "id": stage_id}:
            r.reject("protected database activation stage differs")
        stage = target.ops("upgrade-stage", "status", stage_id)
    if stage.get("fingerprint") != stage_fingerprint or stage.get("target") != "db":
        r.reject("database activation journal differs")
    target.ssh("docker tag " + r.q(str(base["ref"])) + " " + r.q(str(base["tag"])))
    if target.ssh("docker image inspect --format '{{.Id}}' " + r.q(str(base["tag"]))) != base["expected_id"]:
        r.reject("candidate database tag differs")
    record = candidate / "active-images.env"
    presence = target.ops("active-record", "presence", stage_id)
    if presence.get("state") == "absent":
        target.ops("active-record", "prepare", stage_id, str(evidence["candidate_record"]),
                   str(record.stat().st_size), input_file=record)
    elif presence.get("state") != "present":
        r.reject("candidate record transaction is ambiguous")
    active = target.ops("active-record", "status", stage_id)
    if active.get("candidate_sha256") != evidence["candidate_record"] or active.get("pre_sha256") != evidence["source_record"]:
        r.reject("candidate record transaction differs")
    target.ssh("umask 077; if test -e " + r.q(stage_dir) + " || test -L " + r.q(stage_dir) +
               "; then test -d " + r.q(stage_dir) + " && test ! -L " + r.q(stage_dir) +
               " && test \"$(stat -c %a " + r.q(stage_dir) + ")\" = 700; else mkdir -m 0700 " + r.q(stage_dir) + "; fi")
    for local_path, name in ((candidate / "docker-compose.yml", "candidate.yml"),
                             (source / "docker-compose.yml", "source.yml"),
                             (HERE / "lib/atomic-transaction.sh", "atomic-transaction.sh")):
        target.ssh("test ! -L " + r.q(stage_dir + "/" + name))
        r.run(["scp", "-q", str(local_path), target.login + ":" + stage_dir + "/" + name])
        if r.remote_hash(target, stage_dir + "/" + name) != r.digest(local_path):
            r.reject("database cutover Compose input differs")
    phase = root_db["phase"]
    if phase == "prepared" and db.inventory_hash(db.source_inventory(target, r)) != base["db_inventory_sha256"]:
        r.reject("source database changed immediately before cutover")
    if phase in ("prepared", "detaching", "detached"):
        target.ops("db-cutover", "detach", stage_id, prep_fingerprint, stage_fingerprint, timeout=900)
        phase = "detached"
    stage = target.ops("upgrade-stage", "status", stage_id)
    if stage.get("phase") == "prepared":
        target.ops("upgrade-stage", "boundary", stage_id, stage_fingerprint)
    elif stage.get("phase") != "runtime-may-have-changed":
        r.reject("database cutover recovery boundary differs")
    if phase in ("detached", "switching"):
        target.ops("db-cutover", "switch", stage_id, prep_fingerprint, stage_fingerprint, timeout=900)
        phase = "switching"
    if phase == "switching":
        if active.get("state") == "prepared":
            target.ops("active-record", "apply", stage_id)
        elif active.get("state") != "applied":
            r.reject("candidate record application phase differs")
        if r.remote_hash(target, project + "/docker-compose.yml") != evidence["candidate_compose"]:
            install_compose(target, stage_dir, "candidate.yml", project)
        target.ops("db-cutover", "candidate-ready", stage_id, prep_fingerprint, stage_fingerprint)
        phase = "candidate-ready"
    if phase in ("candidate-ready", "starting", "running"):
        service = target.ssh("systemctl is-active nextcloud.service 2>/dev/null || true")
        if service in ("inactive", "failed"):
            target.ops("service", "start", timeout=600)
        elif service != "active":
            r.reject("candidate service state is unknown")
        target.ops("db-cutover", "running", stage_id, prep_fingerprint, stage_fingerprint)
        running(target, candidate / "active-images.env")
        return
    r.reject("database cutover phase cannot resume safely")


def stage_apply(target: r.Target, base: dict[str, object], approval: dict[str, object],
                candidate: Path, source: Path) -> None:
    if base["target"] == "db":
        if not all(key in base for key in ("db_prepare_fingerprint", "db_candidate_digest", "db_inventory_sha256")):
            r.reject("database activation requires a separately verified clean-directory cutover")
        db_stage_apply(target, base, approval, candidate, source)
        return
    stage_id = str(base["stage_id"])
    evidence = base["evidence"]
    assert isinstance(evidence, dict)
    project = str(base["project"])
    stage_dir = project + "/.upgrade-stage-" + stage_id
    stage_created = False
    boundary_attempted = False
    try:
        result = target.ops("upgrade-stage", "consume", stage_id, str(approval["fingerprint"]),
                            str(base["freeze"]["id"]), str(base["freeze"]["table_sha256"]),
                            str(base["fetch_id"]), str(base["fetch_fingerprint"]), str(base["target"]),
                            str(base["tag"]), str(evidence["source_record"]), str(evidence["source_compose"]),
                            str(evidence["candidate_record"]), str(evidence["candidate_compose"]),
                            str(approval["expires"]))
        if result != {"phase": "prepared", "id": stage_id}:
            r.reject("root stage consumption differed")
        target.ssh("docker tag " + r.q(str(base["ref"])) + " " + r.q(str(base["tag"])))
        if target.ssh("docker image inspect --format '{{.Id}}' " + r.q(str(base["tag"]))) != base["expected_id"]:
            r.reject("candidate tag identity differs")
        record = candidate / "active-images.env"
        target.ops("active-record", "prepare", stage_id, str(evidence["candidate_record"]),
                   str(record.stat().st_size), input_file=record)
        target.ops("active-record", "apply", stage_id)
        target.ssh("umask 077; mkdir -m 0700 " + r.q(stage_dir))
        stage_created = True
        for local_path, name in ((candidate / "docker-compose.yml", "candidate.yml"),
                                 (source / "docker-compose.yml", "source.yml"),
                                 (HERE / "lib/atomic-transaction.sh", "atomic-transaction.sh")):
            r.run(["scp", "-q", str(local_path), target.login + ":" + stage_dir + "/" + name])
            if r.remote_hash(target, stage_dir + "/" + name) != r.digest(local_path):
                r.reject("staged Compose input differs")
        install_compose(target, stage_dir, "candidate.yml", project)
        if r.remote_hash(target, project + "/docker-compose.yml") != evidence["candidate_compose"]:
            r.reject("candidate Compose installation differs")
        if r.remote_hash(target, project + "/caddy/Caddyfile") != evidence["source_caddy"]:
            r.reject("Caddyfile changed during stage")
        boundary_attempted = True
        result = target.ops("upgrade-stage", "boundary", stage_id, str(approval["fingerprint"]))
        if result != {"phase": "runtime-may-have-changed", "id": stage_id}:
            r.reject("root boundary result differed")
        target.ops("service", "restart", timeout=600)
        running(target, candidate / "active-images.env")
    except r.RecoveryError:
        # An ambiguous boundary response is treated as crossed. Never config-only
        # rollback unless protected root state positively proves `prepared`.
        try:
            stage = target.ops("upgrade-stage", "status", stage_id)
        except r.RecoveryError:
            stage = {}
        if stage.get("phase") == "prepared" and stage.get("fingerprint") == approval["fingerprint"]:
            try:
                if stage_created and r.remote_hash(target, project + "/docker-compose.yml") != evidence["source_compose"]:
                    install_compose(target, stage_dir, "source.yml", project)
                presence = target.ops("active-record", "presence", stage_id)
                if presence == {"state": "present", "id": stage_id}:
                    active = target.ops("active-record", "status", stage_id)
                    if active.get("state") in ("prepared", "applied"):
                        target.ops("active-record", "rollback", stage_id)
                    elif active.get("state") != "rolledback":
                        r.reject("active-record rollback state is invalid")
                elif presence == {"state": "absent", "id": stage_id}:
                    active = None
                else:
                    r.reject("active-record presence is ambiguous")
                if r.remote_hash(target, project + "/docker-compose.yml") != evidence["source_compose"]:
                    r.reject("pre-start Compose rollback differs")
                if target.ops("active-images-state").get("sha256") != evidence["source_record"]:
                    r.reject("pre-start active-record rollback differs")
                target.ops("upgrade-stage", "abort", stage_id, str(approval["fingerprint"]))
                if active is not None:
                    target.ops("active-record", "commit", stage_id)
            except r.RecoveryError:
                r.reject("pre-start rollback is incomplete; freeze must remain held")
            r.reject("activation stopped before first start; prior configuration restored; freeze remains held")
        if boundary_attempted:
            r.reject("activation may have crossed first start; full runtime restore or approved forward repair is required")
        raise


def accept_evidence(target: r.Target, candidate: Path, source: Path, config_backup: Path,
                    runtime: Path, images: Path, stage_approval: Path, now: int,
                    *, allow_accepted: bool = False, allow_maintenance_on: bool = False) -> dict[str, object]:
    local, metadata = common(target, candidate, source, config_backup, runtime, images, now, before_stage=False)
    stage = json.loads(r.private_file(stage_approval))
    if not isinstance(stage, dict) or stage.get("format") != "image-activation-stage-v1" or stage.get("state") != "consumed":
        r.reject("stage approval was not consumed")
    if stage.get("actions") not in ("tag-approved-digest,prepare-active-record,install-compose,mark-boundary,restart-target,stage-maintenance-off",
                                    "detach-source-containers,promote-attested-database,install-candidate,start,stage-maintenance-off"):
        r.reject("stage approval does not authorize maintenance-off")
    if stage_approval.parent != approval_root() or not stage_approval.name.startswith("stage-"):
        r.reject("stage approval path is unsafe")
    unsigned = dict(stage, state="unused")
    original_fingerprint = unsigned.pop("fingerprint", None)
    if original_fingerprint != r.fingerprint(unsigned):
        r.reject("stage approval fingerprint differs")
    stage_id = stage.get("stage_id", "")
    if not r.IDENTIFIER.fullmatch(stage_id):
        r.reject("stage ID is invalid")
    if not stage_approval.name.startswith(f"stage-{stage_id}-") or stage.get("host") != target.config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"]:
        r.reject("stage approval identity differs")
    if stage.get("evidence") != local or stage.get("freeze") != {"id": metadata["freeze_id"], "table_sha256": metadata["freeze_table_sha256"]}:
        r.reject("stage approval evidence differs")
    root_stage = target.ops("upgrade-stage", "status", stage_id)
    active = target.ops("active-record", "status", stage_id)
    expected = {"phase": "runtime-may-have-changed", "id": stage_id,
                "fingerprint": stage["fingerprint"], "freeze_id": metadata["freeze_id"],
                "freeze_table_sha256": metadata["freeze_table_sha256"],
                "fetch_id": stage["fetch_id"], "target": stage["target"],
                "tag": metadata["tag"], "expected_id": metadata["config_digest"],
                "pre_record_sha256": local["source_record"], "pre_compose_sha256": local["source_compose"],
                "candidate_record_sha256": local["candidate_record"], "candidate_compose_sha256": local["candidate_compose"]}
    if allow_accepted and root_stage.get("phase") == "accepted":
        expected["phase"] = "accepted"
    if root_stage != expected or any(active.get(key) != value for key, value in
                                      {"id": stage_id, "state": "applied", "pre_sha256": local["source_record"],
                                       "candidate_sha256": local["candidate_record"]}.items()):
        r.reject("protected stage or active transaction differs")
    if stage.get("target") == "db":
        cutover = target.ops("db-cutover", "status", stage_id)
        if (cutover.get("phase") not in (("running", "accepted") if allow_accepted else ("running",)) or
                cutover.get("prepare_fingerprint") != stage.get("db_prepare_fingerprint") or
                cutover.get("candidate_digest") != stage.get("db_candidate_digest") or
                cutover.get("inventory_sha256") != stage.get("db_inventory_sha256")):
            r.reject("protected database cutover is not running on the attested directory")
        mount = target.config["NEXTCLOUD_STORAGE_MOUNT"]
        for path, expected_inode in ((mount + "/nextcloud_db", cutover["candidate_inode"]),
                                     (mount + "/.nextcloud-db-before-" + stage_id, cutover["source_inode"])):
            if target.ssh("test -d " + r.q(path) + " && test ! -L " + r.q(path) +
                          " && stat -c '%d:%i' " + r.q(path)) != expected_inode:
                r.reject("database cutover directory identity differs")
        if db.database_query(target, CONTAINERS["DB"], "SELECT 1", r, user=True) != "1":
            r.reject("application database login failed after cutover")
    project = target.config["NEXTCLOUD_REMOTE_PROJECT_DIR"]
    for path, expected_hash in ((project + "/docker-compose.yml", local["candidate_compose"]),
                                (project + "/caddy/Caddyfile", local["source_caddy"])):
        if r.remote_hash(target, path) != expected_hash:
            r.reject("live candidate configuration differs")
    if target.ops("active-images-state").get("sha256") != local["candidate_record"]:
        r.reject("candidate active record differs")
    identities = running(target, candidate / "active-images.env")
    target.ssh("! docker port nextcloud-docker-app-1 80/tcp >/dev/null 2>&1")
    status = target.ssh("docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status")
    if stage.get("target") == "db" and ("needsDbUpgrade: true" in status or "version: 30." not in status):
        r.reject("Nextcloud 30 status reports an unexpected database upgrade")
    if "maintenance: false" in status:
        r.run([str(HERE / "health-check.sh"), "--caddyfile", str(candidate / "Caddyfile")], timeout=300)
    elif not allow_maintenance_on or "maintenance: true" not in status:
        r.reject("Nextcloud maintenance mode remains on or is unknown")
    result = {"format": "image-activation-accept-v1", "stage_id": stage_id,
            "stage_fingerprint": stage["fingerprint"], "stage_artifact_sha256": r.digest(stage_approval),
            "host": target.config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"], "freeze_id": metadata["freeze_id"],
            "candidate_record": local["candidate_record"], "candidate_compose": local["candidate_compose"],
            "running": identities, "actions": "mark-stage-accepted,commit-active-record",
            "exclusions": "freeze-release,pruning,image-removal,automatic-migration"}
    if stage.get("target") == "db":
        result["db_prepare_fingerprint"] = stage["db_prepare_fingerprint"]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    for name in ("plan", "apply", "maintenance-off", "plan-accept", "accept",
                 "plan-prepare-db", "prepare-db", "resume-prepare-db", "resume-db", "abort-db"):
        mode.add_argument("--" + name, action="store_true")
    parser.add_argument("candidate", type=Path)
    parser.add_argument("source_rendered", type=Path)
    parser.add_argument("config_backup", type=Path)
    parser.add_argument("held_runtime_backup", type=Path)
    parser.add_argument("prior_image_recovery", type=Path)
    parser.add_argument("--fetch-approval", type=Path)
    parser.add_argument("--stage-approval", type=Path)
    parser.add_argument("--prepare-approval", type=Path)
    parser.add_argument("--approval", type=Path)
    args = parser.parse_args()
    needs_fetch = args.plan or args.apply or args.plan_prepare_db or args.prepare_db or args.resume_prepare_db
    needs_stage = args.maintenance_off or args.plan_accept or args.accept or args.resume_db
    needs_approval = args.apply or args.accept or args.prepare_db or args.resume_prepare_db
    if (needs_fetch != (args.fetch_approval is not None) or
            (not args.abort_db and needs_stage != (args.stage_approval is not None)) or
            needs_approval != (args.approval is not None) or
            args.prepare_approval is not None and not (args.plan or args.apply or args.abort_db) or
            args.abort_db and args.prepare_approval is None):
        parser.error("approval inputs do not match the selected image activation mode")
    try:
        target = r.Target(r.deployment_config())
        now = int(time.time())
        remote_now = target.ssh("date -u +%s")
        if not remote_now.isdecimal() or abs(now - int(remote_now)) > 60:
            r.reject("local and Pi clocks differ by more than 60 seconds")
        root = approval_root()
        if args.abort_db:
            prep = json.loads(r.private_file(args.prepare_approval))
            if not isinstance(prep, dict) or not r.IDENTIFIER.fullmatch(str(prep.get("stage_id", ""))):
                r.reject("database abort preparation identity differs")
            stage_id = str(prep["stage_id"])
            prep = consumed_prepare(args.prepare_approval, root, stage_id)
            status = target.ops("db-cutover", "status", stage_id)
            if status.get("prepare_fingerprint") != prep["fingerprint"] or status.get("phase") not in ("preparing", "prepared", "detaching", "detached"):
                r.reject("database cutover cannot be aborted before the recovery boundary")
            db.remove_temporary(target, r, stage_id,
                                target.config["NEXTCLOUD_STORAGE_MOUNT"] + "/.db-cutover-" + stage_id + "/data",
                                str(prep["expected_id"]))
            if args.stage_approval is not None:
                stage = consumed_stage(args.stage_approval, root)
                if stage.get("stage_id") != stage_id or stage.get("db_prepare_fingerprint") != prep["fingerprint"]:
                    r.reject("database abort activation approval differs")
                presence = target.ops("active-record", "presence", stage_id)
                if presence.get("state") == "present":
                    target.ops("active-record", "rollback", stage_id)
                target.ops("upgrade-stage", "abort", stage_id, str(stage["fingerprint"]))
                if presence.get("state") == "present":
                    target.ops("active-record", "commit", stage_id)
            target.ops("db-cutover", "abort", stage_id, str(prep["fingerprint"]))
            if status["phase"] in ("detaching", "detached"):
                target.ops("service", "start", timeout=600)
            print(f"Pre-boundary database cutover aborted; stage={stage_id}. Ingress freeze remains held.")
            return 0
        if args.plan_prepare_db or args.prepare_db or args.resume_prepare_db:
            approval = None
            stage_id = None
            if args.prepare_db or args.resume_prepare_db:
                approval = json.loads(r.private_file(args.approval))
                if not isinstance(approval, dict) or not r.IDENTIFIER.fullmatch(str(approval.get("stage_id", ""))):
                    r.reject("database preparation approval identity is invalid")
                stage_id = str(approval["stage_id"])
            base, source_inventory = prepare_db_evidence(
                target, args.candidate, args.source_rendered, args.config_backup,
                args.held_runtime_backup, args.prior_image_recovery, args.fetch_approval,
                now, root, stage_id, resume=args.resume_prepare_db)
            inventory_path = private_inventory(root, str(base["stage_id"]))
            if args.plan_prepare_db:
                store_inventory(root, str(base["stage_id"]), source_inventory)
                artifact = approval_plan(root, base, now, "prepare-db")
                print(f"Redacted clean MariaDB preparation plan: stage={base['stage_id']} freeze-held=yes\nApproval artifact: {artifact}")
                return 0
            if r.digest(inventory_path) != base["inventory_sha256"]:
                r.reject("frozen source inventory differs")
            if args.resume_prepare_db:
                consumed = consumed_prepare(args.approval, root, str(base["stage_id"]))
                if any(consumed.get(key) != value for key, value in base.items()):
                    r.reject("database preparation resume evidence differs")
            else:
                consumed = approval_consume(args.approval, root, base, now, "prepare-db")
            db.prepare(target, r, str(base["stage_id"]), str(consumed["fingerprint"]), base,
                       args.candidate, args.config_backup, args.held_runtime_backup,
                       root, source_inventory, resume=args.resume_prepare_db)
            print(f"Clean MariaDB import attested; stage={base['stage_id']}. Ingress freeze remains held.")
            return 0
        if args.resume_db:
            approved = consumed_stage(args.stage_approval, root)
            if approved.get("target") != "db":
                r.reject("only a database cutover can use database resume")
            local = r.verify_local(args.candidate, args.source_rendered, args.config_backup,
                                   args.held_runtime_backup, args.prior_image_recovery, target.config)
            if local != approved.get("evidence") or approved.get("host") != target.config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"]:
                r.reject("database cutover resume evidence changed")
            freeze = target.ops("upgrade-freeze", "status")
            if freeze.get("state") != "active" or freeze.get("id") != approved["freeze"]["id"] or freeze.get("table_sha256") != approved["freeze"]["table_sha256"]:
                r.reject("database cutover ingress freeze changed")
            db_stage_apply(target, approved, approved, args.candidate, args.source_rendered)
            print(f"Database cutover resumed; stage={approved['stage_id']}. Ingress freeze remains held.")
            return 0
        if args.plan or args.apply:
            base = stage_evidence(target, args.candidate, args.source_rendered, args.config_backup,
                                  args.held_runtime_backup, args.prior_image_recovery, args.fetch_approval, now)
            if base["target"] == "db":
                if args.prepare_approval is None:
                    r.reject("database stage needs the consumed clean-import approval")
                base = db_stage_evidence(target, base, args.prepare_approval, root)
            elif args.prepare_approval is not None:
                r.reject("only database stages use a preparation approval")
            if args.plan:
                if base["target"] != "db":
                    base["stage_id"] = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + str(os.getpid())
                artifact = approval_plan(root, base, now, "stage")
                print(f"Redacted activation plan: stage={base['stage_id']} freeze-held=yes\nApproval artifact: {artifact}")
                return 0
            approval = json.loads(r.private_file(args.approval))
            if not isinstance(approval, dict):
                r.reject("stage approval schema is invalid")
            base["stage_id"] = approval.get("stage_id", "")
            if not r.IDENTIFIER.fullmatch(base["stage_id"]):
                r.reject("activation stage ID is invalid")
            consumed = approval_consume(args.approval, root, base, now, "stage")
            stage_apply(target, base, consumed, args.candidate, args.source_rendered)
            print(f"Candidate started; stage={base['stage_id']}. Ingress freeze remains held. Review runtime before separate acceptance.")
        else:
            base = accept_evidence(target, args.candidate, args.source_rendered, args.config_backup,
                                   args.held_runtime_backup, args.prior_image_recovery, args.stage_approval, now,
                                   allow_accepted=args.accept, allow_maintenance_on=args.maintenance_off)
            if args.maintenance_off:
                status = target.ssh("docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status")
                if "maintenance: true" in status:
                    result = target.ops("upgrade-stage", "maintenance-off", str(base["stage_id"]), str(base["stage_fingerprint"]))
                    if result != {"state": "maintenance-off", "id": base["stage_id"]}:
                        r.reject("protected stage maintenance-off result differs")
                elif "maintenance: false" not in status:
                    r.reject("Nextcloud maintenance state is unknown")
                r.run([str(HERE / "health-check.sh"), "--caddyfile", str(args.candidate / "Caddyfile")], timeout=300)
                print(f"Stage maintenance off and loopback health checked; stage={base['stage_id']}. Ingress freeze remains held.")
                return 0
            if args.plan_accept:
                artifact = approval_plan(root, base, now, "accept")
                print(f"Redacted acceptance plan: stage={base['stage_id']} freeze-held=yes\nApproval artifact: {artifact}")
                return 0
            phase = target.ops("upgrade-stage", "status", str(base["stage_id"])).get("phase")
            if phase == "accepted":
                consumed_acceptance(args.approval, root, base)
            else:
                approval_consume(args.approval, root, base, now, "accept")
                result = target.ops("upgrade-stage", "accept", str(base["stage_id"]), str(base["stage_fingerprint"]))
                if result != {"phase": "accepted", "id": base["stage_id"]}:
                    r.reject("protected acceptance result differs")
            if base.get("db_prepare_fingerprint") is not None:
                result = target.ops("db-cutover", "accepted", str(base["stage_id"]),
                                    str(base["db_prepare_fingerprint"]), str(base["stage_fingerprint"]))
                if result != {"phase": "accepted", "id": base["stage_id"]}:
                    r.reject("protected database acceptance differs")
            result = target.ops("active-record", "commit", str(base["stage_id"]))
            if result != {"state": "committed", "id": base["stage_id"]}:
                r.reject("active-record commit result differs")
            print(f"Candidate accepted; stage={base['stage_id']}. Ingress freeze remains held for separate release.")
        return 0
    except (r.RecoveryError, OSError, KeyError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"Image activation stopped: {exc}. Preserve recovery state and ingress freeze.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
