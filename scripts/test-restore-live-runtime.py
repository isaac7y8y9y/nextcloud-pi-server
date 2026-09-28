#!/usr/bin/env python3
"""Offline approval and interruption tests for live-runtime restoration."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import os
import stat
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("restore_live_runtime", HERE / "restore-live-runtime.py")
assert SPEC and SPEC.loader
restore = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(restore)


class FakeTarget:
    def __init__(self, mount: str, project: str, old: dict[str, str], *, fail_promote: bool = False,
                 fail_import: bool = False, recovery_phase: str = "promoting"):
        self.config = {"NEXTCLOUD_STORAGE_MOUNT": mount, "NEXTCLOUD_REMOTE_PROJECT_DIR": project,
                       "NEXTCLOUD_PI_SYSTEM_HOSTNAME": "pi.example.invalid", "NEXTCLOUD_PI_USER": "test"}
        self.login = "test@pi.example.invalid"
        self.old = old
        self.fail_promote = fail_promote
        self.fail_import = fail_import
        self.recovery_phase = recovery_phase
        self.cutover_phase = ""
        self.cutover_prepare_fingerprint = ""
        self.fail_recovery_detach = False
        self.calls: list[str] = []
        self.inputs: list[bytes] = []

    def ssh(self, command: str, **kwargs: object) -> str:
        self.calls.append(command)
        if kwargs.get("input_bytes") is not None:
            self.inputs.append(kwargs["input_bytes"])
        if command.startswith("docker image inspect"):
            return next(value for tag, value in self.old.items() if tag in command)
        if command.startswith("docker exec -i") and self.fail_import:
            raise restore.RecoveryError("injected SQL import failure")
        if "SELECT COUNT(*)" in command:
            if "information_schema.columns" in command:
                return "1291"
            if "filecache`" in command:
                return "15"
            return "169"
        if "SELECT 1" in command:
            return "1"
        if command.startswith("sha256sum"):
            name = command.rsplit("/", 1)[-1]
            return restore.digest(self.files[name]) + "  staged-file"
        if "occ status" in command:
            return "  - maintenance: false"
        if command == "hostname":
            return "pi.example.invalid"
        if command == "id -un":
            return "test"
        if command.startswith("systemctl is-active nextcloud.service"):
            return "inactive"
        return ""

    def ops(self, *args: str, **_kwargs: object) -> dict[str, str]:
        self.calls.append("ops " + " ".join(args))
        if args[:2] == ("db-cutover", "status"):
            return {"phase": self.cutover_phase, "prepare_fingerprint": self.cutover_prepare_fingerprint}
        if args[:2] == ("db-cutover", "switch"):
            self.cutover_phase = "switching"
        if args[:2] == ("db-cutover", "recovery-detach"):
            if self.fail_recovery_detach:
                raise restore.RecoveryError("injected candidate-detach failure")
            self.cutover_phase = "recovering"
        if args[:2] == ("db-cutover", "source-ready"):
            self.cutover_phase = "source-ready"
            return {"phase": "source-ready", "id": args[2]}
        if args[:2] == ("db-cutover", "recovered"):
            self.cutover_phase = "recovered"
            return {"phase": "recovered", "id": args[2]}
        if args[:2] == ("runtime-recovery", "prepare"):
            return {"state": "prepared", "root": self.config["NEXTCLOUD_STORAGE_MOUNT"] + "/.recovery-" + args[2]}
        if args[:2] == ("runtime-recovery", "promote") and self.fail_promote:
            raise restore.RecoveryError("injected promotion failure")
        if args[:2] == ("active-record", "presence"):
            return {"state": "present"}
        if args[:2] == ("active-record", "status"):
            return {"state": "applied"}
        if args[:1] == ("active-images-state",):
            return {"sha256": self.source_record}
        if args[:2] == ("upgrade-stage", "status"):
            return {"phase": "runtime-may-have-changed", "fingerprint": "f" * 64}
        if args[:2] == ("upgrade-freeze", "status"):
            return {"state": "active", "id": "20260926T000000Z-999", "table_sha256": "b" * 64}
        if args[:2] == ("background-jobs", "state"):
            return {"timer_active": "no"}
        if args[:2] == ("runtime-recovery", "status"):
            return {"state": self.recovery_phase, "id": args[2]}
        if args[:2] == ("runtime-recovery", "reset-prepared"):
            return {"state": "prepared", "id": args[2], "root": self.config["NEXTCLOUD_STORAGE_MOUNT"] + "/.recovery-" + args[2]}
        return {"state": "ok"}


class ApprovalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.stage_id = "20260926T000000Z-123"
        self.base: dict[str, object] = {"format": "live-runtime-restore-v1", "stage_id": self.stage_id,
                                        "host": "pi.example.invalid", "evidence": {"source_record": "a" * 64}}

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_documented_deployment_config_is_accepted(self) -> None:
        path = self.root / "deployment.env"
        path.write_bytes((restore.ROOT / "config/deployment.env.example").read_bytes())
        path.chmod(0o600)
        overrides = {"NEXTCLOUD_DEPLOYMENT_ENV_FILE": str(path),
                     "NEXTCLOUD_PI_HOST": "pi.test.invalid", "NEXTCLOUD_PI_SYSTEM_HOSTNAME": "pi-test",
                     "NEXTCLOUD_PI_USER": "test-user", "NEXTCLOUD_REMOTE_PROJECT_DIR": "/srv/nextcloud-docker",
                     "NEXTCLOUD_STORAGE_MOUNT": "/mnt/test-nextcloud",
                     "NEXTCLOUD_STORAGE_UUID": "11111111-1111-1111-1111-111111111111",
                     "NEXTCLOUD_PUBLIC_HOSTNAME": "nextcloud.test.invalid"}
        with mock.patch.dict(os.environ, overrides, clear=True):
            config = restore.deployment_config()
            self.assertEqual(set(config), restore.CONFIG_KEYS)
            self.assertEqual(config["NEXTCLOUD_PI_HOST"], "pi.test.invalid")
            os.environ["NEXTCLOUD_STORAGE_UUID"] = "invalid-uuid"
            with self.assertRaisesRegex(restore.RecoveryError, "storage UUID"):
                restore.deployment_config()

    def test_deployment_config_uses_partial_override_before_target_validation(self) -> None:
        path = self.root / "deployment.env"
        path.write_text("NEXTCLOUD_PI_HOST=old.test.invalid\nNEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-old\n"
                        "NEXTCLOUD_PI_USER=test-user\nNEXTCLOUD_REMOTE_PROJECT_DIR=/opt/nextcloud-docker\n"
                        "NEXTCLOUD_STORAGE_MOUNT=/mnt/test-nextcloud\n"
                        "NEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111\n"
                        "NEXTCLOUD_PUBLIC_HOSTNAME=nextcloud.test.invalid\n")
        path.chmod(0o600)
        with mock.patch.dict(os.environ, {"NEXTCLOUD_DEPLOYMENT_ENV_FILE": str(path),
                                          "NEXTCLOUD_PI_HOST": "new.test.invalid"}, clear=True):
            self.assertEqual(restore.deployment_config()["NEXTCLOUD_PI_HOST"], "new.test.invalid")
            os.environ["NEXTCLOUD_REMOTE_PROJECT_DIR"] = "/unsafe/other"
            with self.assertRaisesRegex(restore.RecoveryError, "project path"):
                restore.deployment_config()

    def test_approval_is_single_use_and_bound_to_evidence(self) -> None:
        artifact = restore.plan(self.root, self.base, 1000)
        self.assertEqual(stat.S_IMODE(artifact.stat().st_mode), 0o600)
        changed = dict(self.base, host="other.example.invalid")
        with self.assertRaisesRegex(restore.RecoveryError, "evidence changed"):
            restore.consume(artifact, self.root, changed, 1001)
        self.assertEqual(restore.consume(artifact, self.root, self.base, 1001)["state"], "consumed")
        with self.assertRaisesRegex(restore.RecoveryError, "not unused"):
            restore.consume(artifact, self.root, self.base, 1002)

    def test_expired_approval_does_not_create_used_marker(self) -> None:
        artifact = restore.plan(self.root, self.base, 1000)
        with self.assertRaisesRegex(restore.RecoveryError, "expired"):
            restore.consume(artifact, self.root, self.base, 1901)
        self.assertEqual(list(self.root.glob("used-*")), [])

    def fixture(self, *, fail_promote: bool = False, fail_import: bool = False):
        candidate = self.root / "candidate"
        source = self.root / "source"
        config = self.root / "config"
        runtime = self.root / "runtime"
        images = self.root / "images"
        for path in (candidate, source, config, runtime, images, runtime / "nextcloud", runtime / "caddy",
                     runtime / "database", config / "compose", config / "caddy"):
            path.mkdir(exist_ok=True)
        for path in (runtime / "nextcloud/nextcloud.tar", runtime / "caddy/data.tar",
                     runtime / "caddy/config.tar", runtime / "database/nextcloud.sql",
                     config / "compose/docker-compose.yml", config / "caddy/Caddyfile", images / "images.tar"):
            path.write_bytes(b"fixture\n")
        (config / "compose/.env").write_text("MYSQL_ROOT_PASSWORD='root value'\nMYSQL_PASSWORD='app value'\n"
                                             "MYSQL_DATABASE='nextcloud'\nMYSQL_USER='nextcloud'\n")
        (config / "compose/.env").chmod(0o600)
        old_tags = {"APP": "nextcloud:30.0.17-apache", "DB": "mariadb:11.8.6", "CADDY": "caddy:2.10.2"}
        old_ids = {key: "sha256:" + str(index) * 64 for index, key in enumerate(old_tags, 1)}
        base = {"stage_id": self.stage_id, "stage_fingerprint": "f" * 64,
                "evidence": {"old_tags": old_tags, "old_ids": old_ids,
                             "dbtableprefix": "oc_",
                             "sql_sha256": restore.digest(runtime / "database/nextcloud.sql"),
                             "source_compose": restore.digest(config / "compose/docker-compose.yml"),
                             "candidate_compose": restore.digest(config / "compose/docker-compose.yml"),
                             "source_record": "a" * 64,
                             "source_caddy": restore.digest(config / "caddy/Caddyfile")}}
        target = FakeTarget("/mnt/storage", "/mnt/storage/nextcloud-docker",
                            dict(zip(old_tags.values(), old_ids.values())),
                            fail_promote=fail_promote, fail_import=fail_import)
        target.files = {"docker-compose.yml": config / "compose/docker-compose.yml",
                        "Caddyfile": config / "caddy/Caddyfile",
                        "atomic-transaction.sh": restore.ROOT / "scripts/lib/atomic-transaction.sh"}
        target.source_record = "a" * 64
        return target, base, source, config, runtime, images

    def test_promotion_failure_retains_freeze_and_failed_state(self) -> None:
        target, base, source, config, runtime, images = self.fixture(fail_promote=True)
        with mock.patch.object(restore, "run", return_value=""):
            with self.assertRaisesRegex(restore.RecoveryError, "promotion failure"):
                restore.apply(target, base, source, config, runtime, images)
        self.assertIn("ops service stop", target.calls)
        self.assertTrue(any(call.startswith("ops runtime-recovery promote") for call in target.calls))
        self.assertFalse(any("upgrade-freeze release" in call or "runtime-recovery cleanup" in call
                             or "active-record commit" in call for call in target.calls))

    def test_sql_failure_stops_temporary_db_before_live_stack(self) -> None:
        target, base, source, config, runtime, images = self.fixture(fail_import=True)
        with mock.patch.object(restore, "run", return_value=""):
            with self.assertRaisesRegex(restore.RecoveryError, "SQL import failure"):
                restore.apply(target, base, source, config, runtime, images)
        self.assertTrue(any(call.startswith("docker stop --time 60 nextcloud-restore-db-") for call in target.calls))
        self.assertFalse(any(call.startswith("ops service stop") or "runtime-recovery promote" in call
                             or "upgrade-freeze release" in call for call in target.calls))

    def test_success_marks_recovered_without_releasing_freeze(self) -> None:
        target, base, source, config, runtime, images = self.fixture()
        with mock.patch.object(restore, "run", return_value=""):
            restore.apply(target, base, source, config, runtime, images)
        lifecycle = [call for call in target.calls if call.startswith("ops ")]
        self.assertLess(lifecycle.index("ops service stop"),
                        next(index for index, call in enumerate(lifecycle) if call.startswith("ops runtime-recovery promote")))
        self.assertLess(lifecycle.index("ops active-record rollback " + self.stage_id),
                        lifecycle.index("ops active-record commit " + self.stage_id))
        self.assertEqual(lifecycle[-1], "ops upgrade-stage recovered " + self.stage_id + " " + "f" * 64)
        self.assertFalse(any("upgrade-freeze release" in call or "runtime-recovery cleanup" in call
                             for call in target.calls))

    def test_restore_database_receives_unquoted_restricted_environment(self) -> None:
        target, base, source, config, runtime, images = self.fixture()
        with mock.patch.object(restore, "run", return_value=""):
            restore.apply(target, base, source, config, runtime, images)
        self.assertEqual(target.inputs, [b"MYSQL_ROOT_PASSWORD=root value\nMYSQL_PASSWORD=app value\n"
                                         b"MYSQL_DATABASE=nextcloud\nMYSQL_USER=nextcloud\n"])
        self.assertTrue(any("--env-file /dev/stdin" in call for call in target.calls))
        self.assertFalse(any("--env-file /srv" in call for call in target.calls))

    def test_restore_uses_bound_nondefault_table_prefix(self) -> None:
        target, base, source, config, runtime, images = self.fixture()
        base["evidence"]["dbtableprefix"] = "cloud_"
        with mock.patch.object(restore, "run", return_value=""):
            restore.apply(target, base, source, config, runtime, images)
        self.assertTrue(any("cloud_filecache`" in call for call in target.calls))
        self.assertFalse(any("oc_filecache" in call for call in target.calls))

    def test_database_restore_detaches_candidate_before_promotion_and_start(self) -> None:
        target, base, source, config, runtime, images = self.fixture()
        target.cutover_phase = "switching"
        base["db_prepare_fingerprint"] = "b" * 64
        with mock.patch.object(restore, "run", return_value=""):
            restore.apply(target, base, source, config, runtime, images)
        lifecycle = [call for call in target.calls if call.startswith("ops ")]
        ordered = ("ops db-cutover switch", "ops db-cutover recovery-detach",
                   "ops runtime-recovery promote", "ops db-cutover source-ready",
                   "ops service start", "ops upgrade-stage recovered", "ops db-cutover recovered")
        indexes = [next(index for index, call in enumerate(lifecycle) if call.startswith(action)) for action in ordered]
        self.assertEqual(indexes, sorted(indexes))
        self.assertEqual(target.cutover_phase, "recovered")
        self.assertFalse(any("upgrade-freeze release" in call for call in target.calls))

    def test_database_candidate_detach_failure_blocks_runtime_promotion(self) -> None:
        target, base, source, config, runtime, images = self.fixture()
        target.cutover_phase = "candidate-ready"
        target.fail_recovery_detach = True
        base["db_prepare_fingerprint"] = "b" * 64
        with mock.patch.object(restore, "run", return_value=""):
            with self.assertRaisesRegex(restore.RecoveryError, "candidate-detach failure"):
                restore.apply(target, base, source, config, runtime, images)
        self.assertFalse(any(call.startswith("ops runtime-recovery promote") for call in target.calls))
        self.assertFalse(any("upgrade-freeze release" in call for call in target.calls))

    def test_consumed_approval_can_resume_partial_promotion(self) -> None:
        target, base, source, config, runtime, images = self.fixture()
        base.update(host="pi.example.invalid", freeze_id="20260926T000000Z-999",
                    freeze_table_sha256="b" * 64, project=target.config["NEXTCLOUD_REMOTE_PROJECT_DIR"],
                    mount=target.config["NEXTCLOUD_STORAGE_MOUNT"])
        base["evidence"]["env_sha256"] = "e" * 64
        artifact = restore.plan(self.root, base, 1000)
        restore.consume(artifact, self.root, base, 1001)
        consumed = restore.consumed_for_resume(artifact, self.root, self.stage_id)
        def remote_hash(_target, path):
            name = path.rsplit("/", 1)[-1]
            if name == ".env":
                return "e" * 64
            return restore.digest(target.files[name])
        with mock.patch.object(restore, "verify_local", return_value=base["evidence"]), \
             mock.patch.object(restore, "remote_hash", side_effect=remote_hash), \
             mock.patch.object(restore, "run", return_value=""):
            restore.resume(target, consumed, self.root / "candidate", source, config, runtime, images)
        self.assertTrue(any(call.startswith("ops runtime-recovery promote") for call in target.calls))
        self.assertFalse(any("upgrade-freeze release" in call for call in target.calls))

    def test_promoted_source_ready_resume_skips_promotion_and_startup_gate(self) -> None:
        target, base, source, config, runtime, images = self.fixture()
        target.recovery_phase = "promoted"
        target.cutover_phase = "source-ready"
        target.cutover_prepare_fingerprint = "b" * 64
        base.update(host="pi.example.invalid", freeze_id="20260926T000000Z-999",
                    freeze_table_sha256="b" * 64, project=target.config["NEXTCLOUD_REMOTE_PROJECT_DIR"],
                    mount=target.config["NEXTCLOUD_STORAGE_MOUNT"], db_prepare_fingerprint="b" * 64,
                    db_cutover_identity={})
        base["evidence"]["env_sha256"] = "e" * 64
        artifact = restore.plan(self.root, base, 1000)
        consumed = restore.consume(artifact, self.root, base, 1001)
        def remote_hash(_target, path):
            name = path.rsplit("/", 1)[-1]
            return "e" * 64 if name == ".env" else restore.digest(target.files[name])
        with mock.patch.object(restore, "verify_local", return_value=base["evidence"]), \
             mock.patch.object(restore, "remote_hash", side_effect=remote_hash), \
             mock.patch.object(restore, "run", return_value=""):
            restore.resume(target, consumed, self.root / "candidate", source, config, runtime, images)
        self.assertFalse(any(call.startswith("ops runtime-recovery promote") or
                             call.startswith("ops db-cutover source-ready") for call in target.calls))
        self.assertIn("ops service start", target.calls)
        self.assertEqual(target.cutover_phase, "recovered")

    def test_consumed_approval_resets_prepared_restore_before_retry(self) -> None:
        target, base, source, config, runtime, images = self.fixture()
        target.recovery_phase = "prepared"
        base.update(host="pi.example.invalid", freeze_id="20260926T000000Z-999",
                    freeze_table_sha256="b" * 64, project=target.config["NEXTCLOUD_REMOTE_PROJECT_DIR"],
                    mount=target.config["NEXTCLOUD_STORAGE_MOUNT"])
        base["evidence"].update(env_sha256="e" * 64, candidate_record="a" * 64)
        artifact = restore.plan(self.root, base, 1000)
        consumed = restore.consume(artifact, self.root, base, 1001)
        def remote_hash(_target, path):
            name = path.rsplit("/", 1)[-1]
            return "e" * 64 if name == ".env" else restore.digest(target.files[name])
        with mock.patch.object(restore, "verify_local", return_value=base["evidence"]), \
             mock.patch.object(restore, "remote_hash", side_effect=remote_hash), \
             mock.patch.object(restore, "reset_staged_database") as reset_db, \
             mock.patch.object(restore, "run", return_value=""):
            restore.resume(target, consumed, self.root / "candidate", source, config, runtime, images)
        reset_db.assert_called_once_with(target, self.stage_id)
        reset_call = "ops runtime-recovery reset-prepared " + self.stage_id + " " + "f" * 64
        self.assertIn(reset_call, target.calls)
        self.assertLess(target.calls.index(reset_call), next(i for i, call in enumerate(target.calls) if call.startswith("ops runtime-recovery restore")))
        self.assertTrue(any("test -d" in call and ".restore-stage-" in call for call in target.calls))
        self.assertFalse(any("upgrade-freeze release" in call for call in target.calls))

    def test_prepared_retry_only_removes_bound_temporary_database(self) -> None:
        target, _, _, _, _, _ = self.fixture()
        target.ssh = mock.Mock(return_value="other-stage /unexpected/mariadb-data")
        with self.assertRaisesRegex(restore.RecoveryError, "identity differs"):
            restore.reset_staged_database(target, self.stage_id)
        self.assertEqual(target.ssh.call_count, 1)
        target.ssh.reset_mock(return_value=True)
        target.ssh.return_value = self.stage_id + " /mnt/storage/.recovery-" + self.stage_id + "/mariadb-data"
        restore.reset_staged_database(target, self.stage_id)
        self.assertEqual(target.ssh.call_count, 2)
        self.assertIn("docker rm -f nextcloud-restore-db-", target.ssh.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
