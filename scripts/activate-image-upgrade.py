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
    if expires - created != 900 or abs(created - remote_created) > 60 or not created <= now <= expires:
        r.reject("completed fetch approval expired")
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
    if metadata["image"] == "mariadb":
        r.reject("database activation requires a separately verified clean-directory cutover")
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
                   runtime: Path, images: Path, fetch_path: Path, now: int) -> dict[str, object]:
    local, metadata = common(target, candidate, source, config_backup, runtime, images, now)
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


def stage_apply(target: r.Target, base: dict[str, object], approval: dict[str, object],
                candidate: Path, source: Path) -> None:
    if base["target"] == "db":
        r.reject("database activation requires a separately verified clean-directory cutover")
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
    if stage.get("actions") != "tag-approved-digest,prepare-active-record,install-compose,mark-boundary,restart-target,stage-maintenance-off":
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
    if "maintenance: false" in status:
        r.run([str(HERE / "health-check.sh"), "--caddyfile", str(candidate / "Caddyfile")], timeout=300)
    elif not allow_maintenance_on or "maintenance: true" not in status:
        r.reject("Nextcloud maintenance mode remains on or is unknown")
    return {"format": "image-activation-accept-v1", "stage_id": stage_id,
            "stage_fingerprint": stage["fingerprint"], "stage_artifact_sha256": r.digest(stage_approval),
            "host": target.config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"], "freeze_id": metadata["freeze_id"],
            "candidate_record": local["candidate_record"], "candidate_compose": local["candidate_compose"],
            "running": identities, "actions": "mark-stage-accepted,commit-active-record",
            "exclusions": "freeze-release,pruning,image-removal,automatic-migration"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    for name in ("plan", "apply", "maintenance-off", "plan-accept", "accept"):
        mode.add_argument("--" + name, action="store_true")
    parser.add_argument("candidate", type=Path)
    parser.add_argument("source_rendered", type=Path)
    parser.add_argument("config_backup", type=Path)
    parser.add_argument("held_runtime_backup", type=Path)
    parser.add_argument("prior_image_recovery", type=Path)
    parser.add_argument("--fetch-approval", type=Path)
    parser.add_argument("--stage-approval", type=Path)
    parser.add_argument("--approval", type=Path)
    args = parser.parse_args()
    if (args.plan or args.apply) != (args.fetch_approval is not None) or (args.maintenance_off or args.plan_accept or args.accept) != (args.stage_approval is not None) or (args.apply or args.accept) != (args.approval is not None):
        parser.error("stage needs --fetch-approval; maintenance-off/acceptance need --stage-approval; apply/accept need --approval")
    try:
        target = r.Target(r.deployment_config())
        now = int(time.time())
        remote_now = target.ssh("date -u +%s")
        if not remote_now.isdecimal() or abs(now - int(remote_now)) > 60:
            r.reject("local and Pi clocks differ by more than 60 seconds")
        root = approval_root()
        if args.plan or args.apply:
            base = stage_evidence(target, args.candidate, args.source_rendered, args.config_backup,
                                  args.held_runtime_backup, args.prior_image_recovery, args.fetch_approval, now)
            if args.plan:
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
