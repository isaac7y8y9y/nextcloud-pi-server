#!/usr/bin/env python3
"""Unit gates for the private Nextcloud 30→31 rehearsal."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("rehearse-nextcloud-upgrade.py")
SPEC = importlib.util.spec_from_file_location("nextcloud_rehearsal", SCRIPT)
assert SPEC and SPEC.loader
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)


class NextcloudRehearsalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="nextcloud-rehearsal-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "state"
        self.backup = Path(self.temp.name) / "backup"
        self.metadata = tuple(Path(self.temp.name) / str(i) for i in range(3))
        self.evidence = {"backup_manifest_sha256": "a" * 64}

    def test_approval_is_private_single_use_and_bound(self) -> None:
        with mock.patch.object(app, "inputs", return_value=self.evidence):
            app.plan(self.backup, self.metadata, self.root)
            artifact = next(self.root.glob("approval-*.json"))
            self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(artifact.stat().st_mode), 0o600)
            with mock.patch.object(app, "rehearse") as run:
                app.apply(artifact, self.backup, self.metadata, self.root)
                run.assert_called_once()
                with self.assertRaises(app.base.RehearsalError):
                    app.apply(artifact, self.backup, self.metadata, self.root)
            self.assertEqual(json.loads(artifact.read_text())["state"], "consumed")

    def test_changed_backup_and_expiry_reject(self) -> None:
        with mock.patch.object(app, "inputs", return_value=self.evidence):
            app.plan(self.backup, self.metadata, self.root)
        artifact = next(self.root.glob("approval-*.json"))
        with mock.patch.object(app, "inputs", return_value={"backup_manifest_sha256": "b" * 64}):
            with self.assertRaises(app.base.RehearsalError):
                app.apply(artifact, self.backup, self.metadata, self.root)
        with mock.patch.object(app, "inputs", return_value=self.evidence):
            with mock.patch.object(app.time, "time", return_value=2**32):
                with self.assertRaises(app.base.RehearsalError):
                    app.apply(artifact, self.backup, self.metadata, self.root)

    def test_status_requires_version_maintenance_and_db_gate(self) -> None:
        healthy = "  - versionstring: 30.0.17\n  - maintenance: false\n  - needsDbUpgrade: false\n"
        with mock.patch.object(app.base, "docker", return_value=healthy):
            app.status("app", "30.0.17")
        for bad in (healthy.replace("30.0.17", "31.0.14"),
                    healthy.replace("maintenance: false", "maintenance: true"),
                    healthy.replace("needsDbUpgrade: false", "needsDbUpgrade: true")):
            with mock.patch.object(app.base, "docker", return_value=bad):
                with mock.patch.object(app.time, "sleep"):
                    with self.assertRaises(app.base.RehearsalError):
                        app.status("app", "30.0.17")

    def test_failed_pull_stops_named_containers_and_retains_private_state(self) -> None:
        self.root.mkdir(mode=0o700)
        evidence = {f"{key}_index_digest": "sha256:" + letter * 64 for key, letter in
                    (("db", "a"), ("app30", "b"), ("app31", "c"))}
        calls: list[tuple[str, ...]] = []

        def fake_docker(*args: str, **kwargs: object) -> str:
            calls.append(args)
            if args[0] == "pull":
                raise app.base.RehearsalError("interrupted pull")
            return ""

        with mock.patch.object(app, "resource_absent"):
            with mock.patch.object(app.base, "docker", side_effect=fake_docker):
                with self.assertRaises(app.base.RehearsalError):
                    app.rehearse("20260925T000000Z-abcdef123456", self.backup, evidence, self.root)
        self.assertEqual(len([args for args in calls if args[0] == "stop"]), 3)
        self.assertEqual(len(list(self.root.glob("rehearsal-*/database.env"))), 1)


if __name__ == "__main__":
    unittest.main()
