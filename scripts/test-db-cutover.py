#!/usr/bin/env python3
"""Focused tests for clean-import evidence and the cutover call order."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from lib import db_cutover as db


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("activate_image_upgrade", HERE / "activate-image-upgrade.py")
assert SPEC and SPEC.loader
a = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(a)


class DatabaseCutoverTests(unittest.TestCase):
    def test_stage_approval_marker_survives_lost_artifact_replace(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            stage_id = "20260927T000000Z-12"
            base = {"format": "image-activation-stage-v1", "stage_id": stage_id,
                    "target": "db", "db_prepare_fingerprint": "a" * 64}
            approval = a.approval_plan(root, base, 1000, "stage")
            with mock.patch.object(a.os, "replace", side_effect=OSError("injected lost replacement")):
                with self.assertRaisesRegex(OSError, "injected lost replacement"):
                    a.approval_consume(approval, root, base, 1001, "stage")
            self.assertEqual(a.consumed_stage(approval, root)["fingerprint"],
                             a.r.fingerprint(dict(base, state="unused", created=1000, expires=1900)))
            self.assertEqual(a.approval_consume(approval, root, base, 1002, "stage")["state"], "consumed")

    def test_prepare_approval_marker_survives_lost_artifact_replace(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            stage_id = "20260927T000000Z-12"
            inventory = {"tables": ["oc_filecache"], "rows": {"oc_filecache": 1}}
            a.store_inventory(root, stage_id, inventory)
            base = {"format": "image-db-prepare-v1", "stage_id": stage_id,
                    "inventory_sha256": db.inventory_hash(inventory)}
            approval = a.approval_plan(root, base, 1000, "prepare-db")
            with mock.patch.object(a.os, "replace", side_effect=OSError("injected lost replacement")):
                with self.assertRaisesRegex(OSError, "injected lost replacement"):
                    a.approval_consume(approval, root, base, 1001, "prepare-db")
            self.assertEqual(a.consumed_prepare(approval, root, stage_id)["state"], "consumed")

    def test_acceptance_marker_survives_lost_artifact_replace(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            stage_id = "20260927T000000Z-12"
            base = {"format": "image-activation-accept-v1", "stage_id": stage_id}
            approval = a.approval_plan(root, base, 1000, "accept")
            with mock.patch.object(a.os, "replace", side_effect=OSError("injected lost replacement")):
                with self.assertRaisesRegex(OSError, "injected lost replacement"):
                    a.approval_consume(approval, root, base, 1001, "accept")
            a.consumed_acceptance(approval, root, base)
            self.assertEqual(a.approval_consume(approval, root, base, 1002, "accept")["state"], "consumed")

    def test_database_query_uses_literal_root_and_bound_application_account(self) -> None:
        class Target:
            commands: list[str] = []

            def ssh(self, command: str, **_kwargs: object) -> str:
                self.commands.append(command)
                return "1"

        target = Target()
        db.database_query(target, "database", "SELECT 1", a.r)
        db.database_query(target, "database", "SELECT 1", a.r, user=True)
        self.assertIn("-uroot", target.commands[0])
        self.assertNotIn("$root", target.commands[0])
        self.assertIn("MYSQL_USER", target.commands[1])

    def test_restricted_environment_contains_only_four_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "compose.env"
            output = Path(temporary) / "restricted.env"
            source.write_text("MYSQL_ROOT_PASSWORD='root-value'\nMYSQL_PASSWORD='app-value'\n"
                              "MYSQL_DATABASE='nextcloud'\nMYSQL_USER='nextcloud'\n")
            db.restricted_env(source, output, a.r)
            self.assertEqual(output.read_text(), "MYSQL_ROOT_PASSWORD=root-value\nMYSQL_PASSWORD=app-value\n"
                             "MYSQL_DATABASE=nextcloud\nMYSQL_USER=nextcloud\n")
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            source.write_text(source.read_text() + "MARIADB_AUTO_UPGRADE='1'\n")
            with self.assertRaisesRegex(a.r.RecoveryError, "schema differs"):
                db.restricted_env(source, Path(temporary) / "rejected.env", a.r)

    def test_inventory_requires_exact_table_prefix_and_rows(self) -> None:
        def answer(_target: object, _name: str, sql: str, _module: object) -> str:
            if sql == db.QUERIES["tables"]:
                return "oc_filecache\tBASE TABLE\tInnoDB\tDynamic\tutf8mb4_general_ci"
            if sql.startswith("SELECT COUNT(*)"):
                return "17"
            return ""

        with mock.patch.object(db, "database_query", side_effect=answer):
            result = db.inventory(object(), "database", a.r, "oc_")
            self.assertEqual(result["rows"], {"oc_filecache": 17})
            self.assertEqual(db.inventory_hash(result), db.inventory_hash(dict(result)))
            with self.assertRaisesRegex(a.r.RecoveryError, "table prefix"):
                db.inventory(object(), "database", a.r, "other_")

    def test_temporary_container_requires_recorded_identity_and_isolation(self) -> None:
        container_id = "a" * 64
        image_id = "sha256:" + "b" * 64
        data = "/storage/.db-cutover-stage/data"

        class Target:
            details = f"{container_id} stage {image_id} no none 0 1 {data}"

            def ssh(self, _command: str) -> str:
                return self.details

        target = Target()
        self.assertEqual(db.temporary_container(target, a.r, "stage", data, image_id, container_id),
                         "nextcloud-cutover-db-stage")
        with self.assertRaisesRegex(a.r.RecoveryError, "identity differs"):
            db.temporary_container(target, a.r, "stage", data, image_id, "c" * 64)
        target.details = target.details.replace(" no none 0 1 ", " no bridge 0 1 ")
        with self.assertRaisesRegex(a.r.RecoveryError, "identity differs"):
            db.temporary_container(target, a.r, "stage", data, image_id, container_id)
        target.details = target.details.replace(" no bridge 0 1 ", " always none 0 1 ")
        with self.assertRaisesRegex(a.r.RecoveryError, "identity differs"):
            db.temporary_container(target, a.r, "stage", data, image_id, container_id)
        target.details = target.details.replace(data, "/wrong/mount")
        with self.assertRaisesRegex(a.r.RecoveryError, "identity differs"):
            db.temporary_container(target, a.r, "stage", data, image_id, container_id)

    def test_clean_import_failure_does_not_attest_or_detach_source(self) -> None:
        stage_id = "20260927T000000Z-12"
        image_id = "sha256:" + "b" * 64
        source_inventory = {"prefix": "oc_", "rows": {"oc_filecache": 1}}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config"
            runtime = root / "runtime"
            (config / "compose").mkdir(parents=True)
            (runtime / "database").mkdir(parents=True)
            (config / "compose/.env").write_text("MYSQL_ROOT_PASSWORD='root-value'\nMYSQL_PASSWORD='app-value'\n"
                                                 "MYSQL_DATABASE='nextcloud'\nMYSQL_USER='nextcloud'\n")
            (runtime / "database/nextcloud.sql").write_text("SELECT 1;\n")
            env = root / f"db-env-{stage_id}"
            db.restricted_env(config / "compose/.env", env, a.r)
            base = {"stage_id": stage_id, "project": "/srv/project", "expected_id": image_id,
                    "freeze": {"id": stage_id, "table_sha256": "c" * 64},
                    "restricted_env_sha256": a.r.digest(env),
                    "inventory_sha256": db.inventory_hash(source_inventory),
                    "evidence": {"source_record": "1" * 64, "source_compose": "2" * 64,
                                 "candidate_record": "3" * 64, "candidate_compose": "4" * 64,
                                 "env_sha256": "5" * 64, "sql_sha256": a.r.digest(runtime / "database/nextcloud.sql")}}

            class Target:
                config = {"NEXTCLOUD_STORAGE_MOUNT": "/mnt/storage"}
                calls: list[str] = []
                fail_sql = True

                def ops(self, *args: str, **_kwargs: object) -> dict[str, str]:
                    self.calls.append(" ".join(args[:2]))
                    if args[:2] == ("db-cutover", "begin"):
                        return {"phase": "preparing", "id": stage_id,
                                "data": "/mnt/storage/.db-cutover-" + stage_id + "/data"}
                    if args[:2] == ("db-cutover", "temp-start"):
                        return {"container_id": "a" * 64}
                    return {"state": "ok"}

                def ssh(self, command: str, **_kwargs: object) -> str:
                    self.calls.append(command)
                    if command.startswith("docker exec -i") and self.fail_sql:
                        raise a.r.RecoveryError("injected SQL import failure")
                    return ""

            target = Target()
            with mock.patch.object(db, "temporary_container", return_value="temporary"), \
                 mock.patch.object(db, "database_query", return_value="1"):
                with self.assertRaisesRegex(a.r.RecoveryError, "SQL import failure"):
                    db.prepare(target, a.r, stage_id, "a" * 64, base, root / "candidate", config,
                               runtime, root, source_inventory)
            self.assertNotIn("db-cutover attest", target.calls)
            self.assertNotIn("db-cutover detach", target.calls)
            target.calls.clear()
            target.fail_sql = False
            with mock.patch.object(db, "temporary_container", return_value="temporary"), \
                 mock.patch.object(db, "database_query", return_value="1"), \
                 mock.patch.object(db, "inventory", return_value={"prefix": "oc_", "rows": {"oc_filecache": 2}}):
                with self.assertRaisesRegex(a.r.RecoveryError, "inventory differs"):
                    db.prepare(target, a.r, stage_id, "a" * 64, base, root / "candidate", config,
                               runtime, root, source_inventory)
            self.assertNotIn("db-cutover attest", target.calls)
            target.calls.clear()
            env.write_text("MYSQL_ROOT_PASSWORD=changed\n")
            with self.assertRaisesRegex(a.r.RecoveryError, "restricted database environment changed"):
                db.prepare(target, a.r, stage_id, "a" * 64, base, root / "candidate", config,
                           runtime, root, source_inventory)
            self.assertNotIn("db-cutover begin", target.calls)

    def test_cutover_records_boundary_before_directory_switch_and_start(self) -> None:
        stage_id = "20260927T000000Z-12"
        calls: list[str] = []
        with tempfile.TemporaryDirectory() as temporary:
            candidate = Path(temporary) / "candidate"
            source = Path(temporary) / "source"
            candidate.mkdir()
            source.mkdir()
            for root, content in ((candidate, "candidate"), (source, "source")):
                (root / "docker-compose.yml").write_text(content)
            (candidate / "active-images.env").write_text("candidate")
            base = {"stage_id": stage_id, "project": "/srv/project", "target": "db",
                    "tag": "mariadb:11.4.13", "ref": "mariadb@sha256:" + "1" * 64,
                    "expected_id": "sha256:" + "2" * 64,
                    "fetch_id": stage_id, "fetch_fingerprint": "3" * 64,
                    "freeze": {"id": stage_id, "table_sha256": "4" * 64},
                    "db_prepare_fingerprint": "5" * 64,
                    "db_candidate_digest": "6" * 64,
                    "db_inventory_sha256": db.inventory_hash({}),
                    "evidence": {"source_record": "7" * 64, "source_compose": "8" * 64,
                                 "candidate_record": "9" * 64, "candidate_compose": "a" * 64}}

            class Target:
                config = {"NEXTCLOUD_REMOTE_PROJECT_DIR": "/srv/project"}
                login = "test@example.invalid"
                phase = "prepared"
                stage = "absent"
                active = "absent"
                service = "inactive"
                fault = ""

                def ssh(self, command: str, **_kwargs: object) -> str:
                    if command.startswith("docker image inspect"):
                        return str(base["expected_id"])
                    if command.startswith("systemctl is-active"):
                        return self.service
                    return ""

                def ops(self, *args: str, **_kwargs: object) -> dict[str, str]:
                    action = " ".join(args[:2])
                    calls.append(action)
                    if action == "db-cutover status":
                        return {"phase": self.phase, "prepare_fingerprint": str(base["db_prepare_fingerprint"]),
                                "candidate_digest": str(base["db_candidate_digest"]),
                                "inventory_sha256": str(base["db_inventory_sha256"])}
                    if action == "upgrade-stage status":
                        if self.stage == "absent":
                            raise a.r.RecoveryError("not yet consumed")
                        return {"phase": self.stage, "fingerprint": "f" * 64, "target": "db"}
                    if action == "upgrade-stage consume":
                        self.stage = "prepared"
                        self.inject(action)
                        return {"phase": "prepared", "id": stage_id}
                    if action == "upgrade-stage boundary":
                        self.stage = "runtime-may-have-changed"
                        self.inject(action)
                    if action == "active-record presence":
                        return {"state": "absent" if self.active == "absent" else "present"}
                    if action == "active-record prepare":
                        self.active = "prepared"
                        self.inject(action)
                    if action == "active-record status":
                        return {"state": self.active, "pre_sha256": "7" * 64,
                                "candidate_sha256": "9" * 64}
                    if action == "active-record apply":
                        self.active = "applied"
                        self.inject(action)
                    if action == "service start":
                        self.service = "active"
                        self.inject(action)
                    if action.startswith("db-cutover "):
                        self.phase = {"db-cutover detach": "detached", "db-cutover switch": "switching",
                                      "db-cutover candidate-ready": "candidate-ready",
                                      "db-cutover running": "running"}[action]
                        self.inject(action)
                    return {"state": "ok"}

                def inject(self, action: str) -> None:
                    if action == self.fault:
                        self.fault = ""
                        raise a.r.RecoveryError("injected lost response after " + action)

            def perform(target: Target) -> None:
                with (mock.patch.object(a.db, "source_inventory", return_value={}),
                      mock.patch.object(a.r, "run", return_value=""),
                      mock.patch.object(a.r, "remote_hash", side_effect=lambda _target, path: (
                          a.r.digest(candidate / "docker-compose.yml") if path.endswith("candidate.yml") else
                          a.r.digest(source / "docker-compose.yml") if path.endswith("source.yml") else
                          a.r.digest(HERE / "lib/atomic-transaction.sh") if path.endswith("atomic-transaction.sh") else
                          "a" * 64)),
                      mock.patch.object(a, "install_compose"),
                      mock.patch.object(a, "running", return_value={})):
                    a.db_stage_apply(target, base, {"fingerprint": "f" * 64, "expires": 1}, candidate, source)

            target = Target()
            perform(target)
            ordered = ("db-cutover detach", "upgrade-stage boundary", "db-cutover switch",
                       "active-record apply", "db-cutover candidate-ready", "service start", "db-cutover running")
            indices = [calls.index(action) for action in ordered]
            self.assertEqual(indices, sorted(indices))
            for fault in ("upgrade-stage consume", "active-record prepare", "db-cutover detach",
                          "upgrade-stage boundary", "db-cutover switch", "active-record apply",
                          "db-cutover candidate-ready", "service start", "db-cutover running"):
                with self.subTest(fault=fault):
                    calls.clear()
                    interrupted = Target()
                    interrupted.fault = fault
                    with self.assertRaisesRegex(a.r.RecoveryError, "injected lost response"):
                        perform(interrupted)
                    self.assertNotEqual(interrupted.phase, "running" if fault != "db-cutover running" else "prepared")
                    perform(interrupted)
                    self.assertEqual(interrupted.phase, "running")
                    self.assertEqual(interrupted.service, "active")


if __name__ == "__main__":
    unittest.main()
