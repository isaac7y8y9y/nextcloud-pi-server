#!/usr/bin/env python3
"""Unit gates for the private, local-only MariaDB rehearsal."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("rehearse-mariadb-upgrade.py")
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("rehearse_mariadb_upgrade", SCRIPT)
assert SPEC and SPEC.loader
rehearsal = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rehearsal)


class RehearsalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="mariadb-rehearsal-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "private"
        self.backup = Path(self.temp.name) / "backup"
        self.metadata = (Path(self.temp.name) / "114", Path(self.temp.name) / "118")
        self.evidence = {"sql_sha256": "a" * 64}

    def test_root_rejects_git_and_symlink(self) -> None:
        with self.assertRaises(rehearsal.RehearsalError):
            rehearsal.safe_root(SCRIPT.parent / "private")
        link = Path(self.temp.name) / "linked"
        link.symlink_to(self.temp.name, target_is_directory=True)
        with self.assertRaises(rehearsal.RehearsalError):
            rehearsal.safe_root(link / "private")

    def test_plan_is_private_and_apply_consumes_once(self) -> None:
        with mock.patch.object(rehearsal, "prerequisites", return_value=self.evidence):
            rehearsal.create_plan(self.backup, self.metadata, self.root)
            artifact = next(self.root.glob("approval-*.json"))
            self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(artifact.stat().st_mode), 0o600)
            with mock.patch.object(rehearsal, "rehearse") as run:
                rehearsal.approved_apply(artifact, self.backup, self.metadata, self.root)
                run.assert_called_once()
                with self.assertRaises(rehearsal.RehearsalError):
                    rehearsal.approved_apply(artifact, self.backup, self.metadata, self.root)
            self.assertEqual(json.loads(artifact.read_text())["state"], "consumed")

    def test_changed_evidence_and_expiry_reject(self) -> None:
        with mock.patch.object(rehearsal, "prerequisites", return_value=self.evidence):
            rehearsal.create_plan(self.backup, self.metadata, self.root)
        artifact = next(self.root.glob("approval-*.json"))
        with mock.patch.object(rehearsal, "prerequisites", return_value={"sql_sha256": "b" * 64}):
            with self.assertRaises(rehearsal.RehearsalError):
                rehearsal.approved_apply(artifact, self.backup, self.metadata, self.root)
        with mock.patch.object(rehearsal, "prerequisites", return_value=self.evidence):
            with mock.patch.object(rehearsal.time, "time", return_value=2**32):
                with self.assertRaises(rehearsal.RehearsalError):
                    rehearsal.approved_apply(artifact, self.backup, self.metadata, self.root)

    def test_failure_stops_both_containers_and_retains_data(self) -> None:
        self.root.mkdir(mode=0o700)
        calls: list[tuple[str, ...]] = []

        def fake_docker(*args: str, **kwargs: object) -> str:
            calls.append(args)
            if args[0] == "pull":
                raise rehearsal.RehearsalError("interrupted pull")
            return ""

        evidence = {"mariadb_114_index": "sha256:" + "a" * 64,
                    "mariadb_118_index": "sha256:" + "b" * 64}
        with mock.patch.object(rehearsal, "docker", side_effect=fake_docker):
            with self.assertRaises(rehearsal.RehearsalError):
                rehearsal.rehearse("20260925T000000Z-abcdef123456", self.backup / "nextcloud.sql", evidence, self.root)
        self.assertEqual(len([call for call in calls if call[0] == "stop"]), 2)
        self.assertEqual(len(list(self.root.glob("rehearsal-*/database.env"))), 1)

    def test_loaded_image_requires_bound_digest_and_platform(self) -> None:
        ref = "mariadb@sha256:" + "a" * 64
        evidence = {"mariadb_114_id": "sha256:" + "b" * 64,
                    "mariadb_114_manifest": "sha256:" + "c" * 64}
        image = {"Id": evidence["mariadb_114_manifest"], "Architecture": "arm64",
                 "Os": "linux", "RepoDigests": [ref]}
        with mock.patch.object(rehearsal, "docker", return_value=json.dumps(image)):
            rehearsal.verify_loaded_image(ref, evidence, "114")
            image["Architecture"] = "amd64"
        with mock.patch.object(rehearsal, "docker", return_value=json.dumps(image)):
            with self.assertRaises(rehearsal.RehearsalError):
                rehearsal.verify_loaded_image(ref, evidence, "114")


if __name__ == "__main__":
    unittest.main()
