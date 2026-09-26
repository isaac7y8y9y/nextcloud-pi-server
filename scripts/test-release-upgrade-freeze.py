#!/usr/bin/env python3
"""Offline approval/release-order contract tests."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
from unittest import mock

spec = importlib.util.spec_from_file_location("release_upgrade_freeze", Path(__file__).with_name("release-upgrade-freeze.py"))
assert spec and spec.loader
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

base = {"format": "upgrade-freeze-release-v1", "freeze_id": "20260926T000000Z-123",
        "freeze_table_sha256": "a" * 64, "timer_was_active": "yes",
        "maintenance": "on", "actions": "maintenance-off,loopback-health,freeze-release,timer-restore"}
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    path = release.plan(root, base, 1000)
    release.authorize(path, root, base, 1001)
    try:
        release.authorize(path, root, base, 1002)
    except release.r.RecoveryError:
        pass
    else:
        raise AssertionError("consumed approval replayed")
    tampered = release.plan(root, base, 2000)
    try:
        release.authorize(tampered, root, dict(base, timer_was_active="no"), 2001)
    except release.r.RecoveryError:
        pass
    else:
        raise AssertionError("changed prior timer state accepted")
    try:
        release.authorize(tampered, root, base, 2901)
    except release.r.RecoveryError:
        pass
    else:
        raise AssertionError("expired release approval accepted")

source = Path(__file__).with_name("release-upgrade-freeze.py").read_text()
assert source.index('authorize(args.approval, root, base, now)') < source.index('target.ops("upgrade-freeze", "maintenance-off"')
assert source.index('r.run([str(HERE / "health-check.sh")') < source.index('target.ops("upgrade-freeze", "release"')
assert source.index('target.ops("upgrade-freeze", "release"') < source.index('target.ops("upgrade-freeze", "status") != {"state": "absent"}')
print("freeze release approval tests passed")
