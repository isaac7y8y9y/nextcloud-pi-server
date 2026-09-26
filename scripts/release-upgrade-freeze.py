#!/usr/bin/env python3
"""Plan or apply a single-use, identity-bound ingress-freeze release."""

from __future__ import annotations

import argparse
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


def approval_root() -> Path:
    root = Path(os.environ.get("NEXTCLOUD_FREEZE_RELEASE_APPROVAL_ROOT",
                               Path(os.path.expanduser("~")) / "nextcloud-pi-freeze-release-approvals"))
    if not root.is_absolute() or root.is_symlink() or any(parent.is_symlink() for parent in root.parents):
        r.reject("release approval root is unsafe")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if stat.S_IMODE(root.stat().st_mode) != 0o700:
        r.reject("release approval root must have mode 0700")
    if subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"],
                      capture_output=True).returncode == 0:
        r.reject("release approval root must be outside Git")
    return root


def evidence(target: r.Target, *, allow_releasing: bool = False) -> tuple[dict[str, object], str]:
    config = target.config
    if target.ssh("hostname") != config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"] or target.ssh("id -un") != config["NEXTCLOUD_PI_USER"]:
        r.reject("connected Pi identity differs")
    freeze = target.ops("upgrade-freeze", "status")
    phase = freeze.get("state", "")
    if phase not in (("active", "releasing") if allow_releasing else ("active",)) or not r.IDENTIFIER.fullmatch(freeze.get("id", "")) or not r.HASH.fullmatch(freeze.get("table_sha256", "")):
        r.reject("protected ingress freeze is not active")
    if freeze.get("timer_was_active") not in ("yes", "no"):
        r.reject("prior timer state is unknown")
    if target.ops("background-jobs", "state").get("timer_active") != "no":
        r.reject("background-job timer is active")
    service = target.ssh("systemctl is-active nextcloud-background-jobs.service 2>/dev/null || true")
    if service not in ("inactive", "failed", "unknown"):
        r.reject("background-job service is not inactive")
    project = config["NEXTCLOUD_REMOTE_PROJECT_DIR"]
    compose = r.remote_hash(target, project + "/docker-compose.yml")
    caddy = r.remote_hash(target, project + "/caddy/Caddyfile")
    active = target.ops("active-images-state")
    if not r.HASH.fullmatch(active.get("sha256", "")) or not r.HASH.fullmatch(active.get("source_lock_sha256", "")):
        r.reject("active-image record is invalid")
    local_lock = r.digest(r.ROOT / "config/image-lock.env")
    if active["source_lock_sha256"] != local_lock:
        r.reject("local source image lock differs from the active image record; retain ingress freeze")
    running = {}
    for key, name in (("app", "nextcloud-docker-app-1"), ("db", "nextcloud-docker-db-1"),
                      ("caddy", "nextcloud-docker-caddy-1")):
        parts = target.ssh("docker inspect " + r.q(name) + " --format '{{.Id}} {{.Image}} {{.State.Running}}'").split()
        if (len(parts) != 3 or not r.HASH.fullmatch(parts[0]) or
                not re.fullmatch(r"sha256:[0-9a-f]{64}", parts[1]) or parts[2] != "true" or
                parts[1] != active.get(key + "_id")):
            r.reject("running container differs from the active image record")
        running[name] = parts[:2]
    target.ssh("! docker port nextcloud-docker-app-1 80/tcp >/dev/null 2>&1")
    status = target.ssh("docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status")
    if "maintenance: true" in status:
        maintenance = "on"
    elif "maintenance: false" in status:
        maintenance = "off"
    else:
        r.reject("Nextcloud maintenance state is unknown")
    return {"format": "upgrade-freeze-release-v1", "host": config["NEXTCLOUD_PI_SYSTEM_HOSTNAME"],
            "freeze_id": freeze["id"], "freeze_table_sha256": freeze["table_sha256"],
            "timer_was_active": freeze["timer_was_active"],
            "compose_sha256": compose, "caddy_sha256": caddy,
            "active_record_sha256": active["sha256"], "source_lock_sha256": local_lock, "running": running,
            "actions": "maintenance-off,loopback-health,freeze-release,timer-restore",
            "exclusions": "image-change,restore,prune,backup-deletion"}, phase


def artifact_record(base: dict[str, object], created: int) -> dict[str, object]:
    record = dict(base, state="unused", created=created, expires=created + 900)
    record["fingerprint"] = r.fingerprint(record)
    return record


def plan(root: Path, base: dict[str, object], now: int) -> Path:
    record = artifact_record(base, now)
    path = root / f"release-{base['freeze_id']}-{now}.json"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(r.canonical(record) + b"\n")
    return path


def authorize(path: Path, root: Path, base: dict[str, object], now: int, phase: str) -> bool:
    if path.parent != root or not path.name.startswith(f"release-{base['freeze_id']}-"):
        r.reject("release approval path differs")
    record = json.loads(r.private_file(path))
    if not isinstance(record, dict) or not isinstance(record.get("created"), int):
        r.reject("release approval schema is invalid")
    expected = artifact_record(base, record["created"])
    consumed = dict(expected, state="consumed")
    marker = root / f"used-release-{base['freeze_id']}-{record['created']}"
    if phase == "releasing":
        if record != consumed or r.private_file(marker) != (expected["fingerprint"] + "\n").encode():
            r.reject("interrupted release approval differs")
        return True
    if record != expected or not expected["created"] <= now <= expected["expires"]:
        r.reject("release approval expired or evidence changed")
    fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write((record["fingerprint"] + "\n").encode())
    consumed = dict(record, state="consumed")
    temporary = root / f".{path.name}.new"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(r.canonical(consumed) + b"\n")
    os.replace(temporary, path)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true")
    mode.add_argument("--apply", action="store_true")
    parser.add_argument("--approval", type=Path)
    parser.add_argument("--caddyfile", type=Path, required=True)
    args = parser.parse_args()
    if args.apply != (args.approval is not None):
        parser.error("--apply requires --approval; --plan does not accept one")
    try:
        target = r.Target(r.deployment_config())
        now = int(time.time())
        remote_now = target.ssh("date -u +%s")
        if not remote_now.isdecimal() or abs(now - int(remote_now)) > 60:
            r.reject("local and Pi clocks differ by more than 60 seconds")
        base, phase = evidence(target, allow_releasing=args.apply)
        if args.caddyfile.is_symlink() or not args.caddyfile.is_file() or r.digest(args.caddyfile) != base["caddy_sha256"]:
            r.reject("local Caddyfile differs from the live configuration")
        root = approval_root()
        if args.plan:
            path = plan(root, base, now)
            print(f"Redacted release plan: freeze={base['freeze_id']}\nApproval artifact: {path}")
            return 0
        retry = authorize(args.approval, root, base, now, phase)
        status = target.ssh("docker exec --user www-data nextcloud-docker-app-1 php /var/www/html/occ status")
        if not retry and "maintenance: true" in status:
            if target.ops("upgrade-freeze", "maintenance-off", str(base["freeze_id"])) != {"state": "maintenance-off", "id": base["freeze_id"]}:
                r.reject("protected maintenance-off result differs")
        elif "maintenance: false" not in status:
            r.reject("Nextcloud maintenance state is unknown")
        if not retry:
            r.run([str(HERE / "health-check.sh"), "--caddyfile", str(args.caddyfile)], timeout=300)
        if target.ops("upgrade-freeze", "release", str(base["freeze_id"])) != {"state": "released", "id": base["freeze_id"]}:
            r.reject("protected freeze release result differs")
        if target.ops("upgrade-freeze", "status") != {"state": "absent"}:
            r.reject("protected freeze remains after release")
        timer = target.ops("background-jobs", "state").get("timer_active")
        if timer != base["timer_was_active"]:
            r.reject("background-job timer was not restored to its prior state")
        print(f"Ingress released; freeze={base['freeze_id']}. Verify LAN upload/download now.")
        return 0
    except (r.RecoveryError, OSError, KeyError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"Freeze release stopped: {exc}. Inspect protected state before recovery.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
