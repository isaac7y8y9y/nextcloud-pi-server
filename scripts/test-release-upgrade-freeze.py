#!/usr/bin/env python3
"""Offline approval/release-order contract tests."""

import importlib.util
from pathlib import Path
import tempfile
from unittest import mock

spec = importlib.util.spec_from_file_location("release_upgrade_freeze", Path(__file__).with_name("release-upgrade-freeze.py"))
assert spec and spec.loader
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

base = {"format": "upgrade-freeze-release-v1", "freeze_id": "20260926T000000Z-123",
        "freeze_table_sha256": "a" * 64, "timer_was_active": "yes",
        "actions": "maintenance-off,loopback-health,freeze-release,timer-restore"}
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    path = release.plan(root, base, 1000)
    assert release.authorize(path, root, base, 1001, "active") is False
    assert release.authorize(path, root, base, 1002, "releasing") is True
    try:
        release.authorize(path, root, base, 1002, "active")
    except release.r.RecoveryError:
        pass
    else:
        raise AssertionError("consumed approval replayed")
    tampered = release.plan(root, base, 2000)
    try:
        release.authorize(tampered, root, dict(base, timer_was_active="no"), 2001, "active")
    except release.r.RecoveryError:
        pass
    else:
        raise AssertionError("changed prior timer state accepted")
    try:
        release.authorize(tampered, root, base, 2901, "active")
    except release.r.RecoveryError:
        pass
    else:
        raise AssertionError("expired release approval accepted")

class WrongLockTarget:
    config = {"NEXTCLOUD_PI_SYSTEM_HOSTNAME": "pi.example.invalid", "NEXTCLOUD_PI_USER": "test",
              "NEXTCLOUD_REMOTE_PROJECT_DIR": "/private/nextcloud-docker"}
    def ssh(self, command):
        if command == "hostname":
            return "pi.example.invalid"
        if command == "id -un":
            return "test"
        if command.startswith("systemctl is-active"):
            return "inactive"
        return ""
    def ops(self, *args):
        if args == ("upgrade-freeze", "status"):
            return {"state": "active", "id": base["freeze_id"], "table_sha256": "a" * 64,
                    "timer_was_active": "yes"}
        if args == ("background-jobs", "state"):
            return {"timer_active": "no"}
        if args == ("active-images-state",):
            return {"sha256": "a" * 64, "source_lock_sha256": "0" * 64}
        raise AssertionError(args)

with mock.patch.object(release.r, "remote_hash", return_value="a" * 64):
    try:
        release.evidence(WrongLockTarget())
    except release.r.RecoveryError as error:
        assert "source image lock differs" in str(error)
    else:
        raise AssertionError("release accepted source-lock/active-record mismatch")

class MatchedTarget(WrongLockTarget):
    phase = "active"
    timer_active = "no"
    def ssh(self, command):
        if command.startswith("docker inspect "):
            return "a" * 64 + " sha256:" + "b" * 64 + " true"
        if "occ status" in command:
            return "  - maintenance: false"
        return super().ssh(command)
    def ops(self, *args):
        if args == ("upgrade-freeze", "status"):
            return {"state": self.phase, "id": base["freeze_id"], "table_sha256": "a" * 64,
                    "timer_was_active": "yes"}
        if args == ("background-jobs", "state"):
            return {"timer_active": self.timer_active}
        if args == ("active-images-state",):
            return {"sha256": "a" * 64,
                    "source_lock_sha256": release.r.digest(release.r.ROOT / "config/image-lock.env"),
                    "app_id": "sha256:" + "b" * 64, "db_id": "sha256:" + "b" * 64,
                    "caddy_id": "sha256:" + "b" * 64}
        return super().ops(*args)

with mock.patch.object(release.r, "remote_hash", return_value="a" * 64):
    checked, phase = release.evidence(MatchedTarget())
    assert phase == "active" and len(checked["running"]) == 3
    retry_target = MatchedTarget()
    retry_target.phase = "releasing"
    retry_target.timer_active = "yes"
    checked, phase = release.evidence(retry_target, allow_releasing=True)
    assert phase == "releasing" and checked["timer_was_active"] == "yes"
    try:
        release.evidence(retry_target)
    except release.r.RecoveryError:
        pass
    else:
        raise AssertionError("active timer accepted before release phase")

source = Path(__file__).with_name("release-upgrade-freeze.py").read_text()
assert source.index('authorize(args.approval, root, base, now, phase)') < source.index('target.ops("upgrade-freeze", "maintenance-off"')
assert source.index('r.run([str(HERE / "health-check.sh")') < source.index('target.ops("upgrade-freeze", "release"')
assert source.index('target.ops("upgrade-freeze", "release"') < source.index('target.ops("upgrade-freeze", "status") != {"state": "absent"}')
print("freeze release approval tests passed")
