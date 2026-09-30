#!/usr/bin/env python3
"""Offline approval and boundary tests for one-image activation."""

from __future__ import annotations

import importlib.util
import hashlib
from datetime import datetime, timezone
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("activate_image_upgrade", HERE / "activate-image-upgrade.py")
assert SPEC and SPEC.loader
a = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(a)


class FakeTarget:
    def __init__(self, phase: str = "prepared", fail: str = ""):
        self.config = {"NEXTCLOUD_REMOTE_PROJECT_DIR": "/srv/project",
                       "NEXTCLOUD_PI_SYSTEM_HOSTNAME": "pi.example.invalid", "NEXTCLOUD_PI_USER": "test"}
        self.login = "test@example.invalid"
        self.phase = phase
        self.fail = fail
        self.calls: list[str] = []
        self.compose = "b" * 64
        self.active = "a" * 64
        self.has_tx = False
        self.commit_pending = False
        self.tx_state = "applied"
        self.stage_fields: dict[str, str] = {}

    def ssh(self, command: str, **_kwargs: object) -> str:
        self.calls.append("ssh " + command)
        if command.startswith("docker image inspect"):
            return "sha256:" + "1" * 64
        if command == "hostname":
            return "pi.example.invalid"
        if command == "id -un":
            return "test"
        if command.startswith("docker tag") and self.fail == "tag":
            raise a.r.RecoveryError("injected pre-prepare failure")
        if command.startswith("umask 077"):
            return ""
        if "atomic_replace_preserve" in command:
            self.compose = "c" * 64 if "candidate.yml" in command else "b" * 64
        if self.fail == "compose" and "candidate.yml" in command:
            raise a.r.RecoveryError("injected pre-boundary failure")
        return ""

    def ops(self, *args: str, **_kwargs: object) -> dict[str, str]:
        self.calls.append("ops " + " ".join(args))
        if args[:2] == ("upgrade-stage", "consume"):
            return {"phase": "prepared", "id": args[2]}
        if args[:2] == ("upgrade-stage", "status"):
            return {"phase": self.phase, "fingerprint": "f" * 64, **self.stage_fields}
        if args[:2] == ("upgrade-freeze", "status"):
            return {"state": "active", "id": "20260926T000000Z-123", "table_sha256": "e" * 64}
        if args[:2] == ("background-jobs", "state"):
            return {"timer_active": "no"}
        if args[:2] == ("upgrade-stage", "boundary"):
            if self.phase != "prepared":
                raise a.r.RecoveryError("runtime boundary is not permitted")
            self.phase = "runtime-may-have-changed"
            if self.fail == "boundary-response":
                raise a.r.RecoveryError("injected lost boundary response")
            return {"phase": self.phase, "id": args[2]}
        if args[:2] == ("upgrade-stage", "install-compose"):
            if self.phase != "prepared" or self.fail == "compose":
                raise a.r.RecoveryError("candidate Compose installation is not permitted")
            self.compose = "c" * 64
            return {"state": "installed", "id": args[2]}
        if args[:2] == ("upgrade-stage", "abort-claim"):
            if self.fail == "claim-race":
                self.phase = "runtime-may-have-changed"
            if self.phase not in ("prepared", "aborting"):
                raise a.r.RecoveryError("runtime boundary was reached")
            self.phase = "aborting"
            return {"phase": "aborting", "id": args[2]}
        if args[:2] == ("active-record", "prepare"):
            self.has_tx = True
            return {"state": "prepared"}
        if args[:2] == ("active-record", "presence"):
            if self.commit_pending:
                raise a.r.RecoveryError("interrupted commit marker")
            return {"state": "present" if self.has_tx else "absent", "id": args[2]}
        if args[:2] == ("active-record", "apply"):
            self.active = "d" * 64
            return {"state": "applied"}
        if args[:2] == ("active-record", "status"):
            if not self.has_tx:
                raise a.r.RecoveryError("no transaction")
            return {"state": self.tx_state, "pre_sha256": "a" * 64, "candidate_sha256": "d" * 64}
        if args[:2] == ("active-record", "rollback"):
            self.active = "a" * 64
            self.tx_state = "rolledback"
        if args[:2] == ("active-record", "commit"):
            self.has_tx = False
            self.commit_pending = False
            return {"state": "committed", "id": args[2]}
        if args[:2] == ("active-images-state",):
            return {"sha256": self.active}
        if args[:2] == ("upgrade-stage", "abort"):
            self.phase = "aborted"
        if args[:2] == ("service", "restart") and self.fail == "restart":
            raise a.r.RecoveryError("injected post-boundary failure")
        return {"state": "ok"}


class ActivationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.stage_id = "20260926T000000Z-123"
        self.base = {"format": "image-activation-stage-v1", "stage_id": self.stage_id,
                     "project": "/srv/project", "tag": "nextcloud:31.0.14-apache",
                     "ref": "nextcloud@sha256:" + "2" * 64,
                     "expected_id": "sha256:" + "1" * 64, "target": "app",
                     "freeze": {"id": self.stage_id, "table_sha256": "e" * 64},
                     "fetch_id": self.stage_id, "fetch_fingerprint": "3" * 64,
                     "evidence": {"source_record": "a" * 64, "source_compose": "b" * 64,
                                  "candidate_record": "d" * 64, "candidate_compose": "c" * 64,
                                  "source_caddy": "e" * 64}}
        self.candidate = self.root / "candidate"
        self.source = self.root / "source"
        self.candidate.mkdir()
        self.source.mkdir()
        (self.candidate / "active-images.env").write_text("candidate")
        (self.candidate / "docker-compose.yml").write_text("candidate")
        (self.source / "docker-compose.yml").write_text("source")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def remote_hash(self, target: FakeTarget, path: str) -> str:
        if path.endswith("/candidate.yml"):
            return a.r.digest(self.candidate / "docker-compose.yml")
        if path.endswith("/source.yml"):
            return a.r.digest(self.source / "docker-compose.yml")
        if path.endswith("/atomic-transaction.sh"):
            return a.r.digest(HERE / "lib/atomic-transaction.sh")
        if path.endswith("/docker-compose.yml"):
            return target.compose
        return "e" * 64

    def prepared_approval(self, target: FakeTarget) -> dict[str, object]:
        base = dict(self.base, host="pi.example.invalid", evidence=dict(self.base["evidence"], env_sha256="e" * 64))
        artifact = a.approval_plan(self.root, base, 1000, "stage")
        a.approval_consume(artifact, self.root, base, 1001, "stage")
        approval = a.consumed_stage(artifact, self.root)
        evidence = approval["evidence"]
        target.stage_fields = {"id": self.stage_id, "fingerprint": str(approval["fingerprint"]),
                               "target": "app", "pre_record_sha256": evidence["source_record"],
                               "pre_compose_sha256": evidence["source_compose"],
                               "candidate_record_sha256": evidence["candidate_record"],
                               "candidate_compose_sha256": evidence["candidate_compose"]}
        return approval

    def test_approval_tamper_expiry_and_replay(self) -> None:
        artifact = a.approval_plan(self.root, self.base, 1000, "stage")
        self.assertEqual(stat.S_IMODE(artifact.stat().st_mode), 0o600)
        with self.assertRaisesRegex(a.r.RecoveryError, "expired"):
            a.approval_consume(artifact, self.root, self.base, 1901, "stage")
        changed = dict(self.base, tag="nextcloud:32.0.0-apache")
        with self.assertRaisesRegex(a.r.RecoveryError, "evidence changed"):
            a.approval_consume(artifact, self.root, changed, 1001, "stage")
        self.assertEqual(a.approval_consume(artifact, self.root, self.base, 1001, "stage")["state"], "consumed")
        with self.assertRaisesRegex(a.r.RecoveryError, "not unused"):
            a.approval_consume(artifact, self.root, self.base, 1002, "stage")

    def test_consumed_acceptance_can_only_finish_same_evidence(self) -> None:
        base = dict(self.base, format="image-activation-accept-v1")
        artifact = a.approval_plan(self.root, base, 1000, "accept")
        a.approval_consume(artifact, self.root, base, 1001, "accept")
        a.consumed_acceptance(artifact, self.root, base)
        with self.assertRaisesRegex(a.r.RecoveryError, "evidence changed"):
            a.consumed_acceptance(artifact, self.root, dict(base, tag="changed"))

    def test_completed_fetch_authority_rejects_action_tampering(self) -> None:
        local = {"candidate_manifest": "a" * 64, "config_manifest": "b" * 64,
                 "backup_manifest": "c" * 64, "image_manifest": "d" * 64,
                 "image_attestation": "e" * 64}
        metadata = {"tag": "nextcloud:31.0.14-apache", "index_digest": "sha256:" + "1" * 64,
                    "manifest_digest": "sha256:" + "2" * 64, "config_digest": "sha256:" + "3" * 64}
        record = {"format": "image-upgrade-fetch-v1", "state": "consumed",
                  "transaction_id": self.stage_id, "candidate_sha256": local["candidate_manifest"],
                  "source_lock_sha256": a.r.digest(a.r.ROOT / "config/image-lock.env"),
                  "config_manifest_sha256": local["config_manifest"],
                  "runtime_manifest_sha256": local["backup_manifest"],
                  "image_manifest_sha256": local["image_manifest"],
                  "image_attestation_sha256": local["image_attestation"],
                  "prestate_sha256": "f" * 64, "freeze_id": self.stage_id,
                  "freeze_table_sha256": "9" * 64, "tag": metadata["tag"],
                  "index_digest": metadata["index_digest"],
                  "manifest_digest": metadata["manifest_digest"],
                  "config_digest": metadata["config_digest"], "host": "test.example.invalid",
                  "created": "999", "remote_created": "999", "expires": "1899",
                  "actions": "pull-exact-digest,verify-loaded-id",
                  "exclusions": "tag-change,compose,source-lock,active-record,container-start,container-stop,pruning,image-removal,runtime-restore,freeze-release"}
        record["fingerprint"] = hashlib.sha256("".join(f"{key}\t{record[key]}\n" for key in a.FETCH_AUTHORITY).encode()).hexdigest()
        path = self.root / "fetch.tsv"
        path.write_text("".join(f"{key}\t{value}\n" for key, value in record.items()))
        path.chmod(0o600)
        self.assertEqual(a.fetch_record(path, local, metadata,
                                        {"id": self.stage_id, "table_sha256": "9" * 64},
                                        "test.example.invalid", 1000, "f" * 64)["fingerprint"], record["fingerprint"])
        path.write_text(path.read_text().replace("pull-exact-digest,verify-loaded-id", "pull-floating-tag"))
        with self.assertRaisesRegex(a.r.RecoveryError, "actions differ"):
            a.fetch_record(path, local, metadata,
                           {"id": self.stage_id, "table_sha256": "9" * 64},
                           "test.example.invalid", 1000, "f" * 64)

    def test_stale_recovery_evidence_is_rejected_before_stage(self) -> None:
        path = self.root / "manifest.tsv"
        path.write_text("timestamp\t20260924T000000Z\n")
        now = int(datetime(2026, 9, 26, tzinfo=timezone.utc).timestamp())
        with self.assertRaisesRegex(a.r.RecoveryError, "older than 24 hours"):
            a.age(path, now)

    def test_pre_boundary_failure_rolls_back_without_restart(self) -> None:
        target = FakeTarget(fail="compose")
        with mock.patch.object(a.r, "run", return_value=""), mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash):
            with self.assertRaisesRegex(a.r.RecoveryError, "prior configuration restored"):
                a.stage_apply(target, self.base, {"fingerprint": "f" * 64, "expires": 1000}, self.candidate, self.source)
        self.assertEqual(target.phase, "aborted")
        self.assertEqual(target.compose, "b" * 64)
        self.assertEqual(target.active, "a" * 64)
        self.assertFalse(any("ops service restart" in call for call in target.calls))

    def test_consumed_approval_aborts_interrupted_prepared_stage(self) -> None:
        target = FakeTarget()
        target.has_tx = True
        target.active = "d" * 64
        target.compose = "c" * 64
        approval = self.prepared_approval(target)
        with mock.patch.object(a.r, "verify_local", return_value=approval["evidence"]), \
             mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash), \
             mock.patch.object(a.r, "run", return_value=""):
            a.abort_prepared(target, approval, self.candidate, self.source, self.root, self.root, self.root)
            a.abort_prepared(target, approval, self.candidate, self.source, self.root, self.root, self.root)
        self.assertEqual(target.phase, "aborted")
        self.assertEqual((target.compose, target.active, target.has_tx), ("b" * 64, "a" * 64, False))
        self.assertFalse(any("ops service " in call for call in target.calls))

    def test_prepared_abort_before_active_record_preparation(self) -> None:
        target = FakeTarget()
        approval = self.prepared_approval(target)
        with mock.patch.object(a.r, "verify_local", return_value=approval["evidence"]), \
             mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash), \
             mock.patch.object(a.r, "run", return_value=""):
            a.abort_prepared(target, approval, self.candidate, self.source, self.root, self.root, self.root)
        self.assertEqual(target.phase, "aborted")
        self.assertFalse(any(call.startswith("ops active-record rollback") for call in target.calls))

    def test_prepared_abort_resumes_after_active_rollback(self) -> None:
        target = FakeTarget()
        target.has_tx = True
        target.tx_state = "rolledback"
        target.compose = "c" * 64
        approval = self.prepared_approval(target)
        with mock.patch.object(a.r, "verify_local", return_value=approval["evidence"]), \
             mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash), \
             mock.patch.object(a.r, "run", return_value=""):
            a.abort_prepared(target, approval, self.candidate, self.source, self.root, self.root, self.root)
        self.assertEqual(target.phase, "aborted")
        self.assertFalse(target.has_tx)
        self.assertFalse(any(call.startswith("ops active-record rollback") for call in target.calls))

    def test_prepared_abort_finishes_interrupted_active_commit(self) -> None:
        target = FakeTarget(phase="aborted")
        target.commit_pending = True
        approval = self.prepared_approval(target)
        with mock.patch.object(a.r, "verify_local", return_value=approval["evidence"]), \
             mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash):
            a.abort_prepared(target, approval, self.candidate, self.source, self.root, self.root, self.root)
        self.assertFalse(target.commit_pending)
        self.assertIn("ops active-record commit " + self.stage_id, target.calls)

    def test_prepared_abort_refuses_crossed_boundary(self) -> None:
        target = FakeTarget(phase="runtime-may-have-changed")
        target.has_tx = True
        target.active = "d" * 64
        target.compose = "c" * 64
        approval = self.prepared_approval(target)
        with mock.patch.object(a.r, "verify_local", return_value=approval["evidence"]), \
             mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash):
            with self.assertRaisesRegex(a.r.RecoveryError, "protected prepared stage differs"):
                a.abort_prepared(target, approval, self.candidate, self.source, self.root, self.root, self.root)
        self.assertEqual((target.compose, target.active), ("c" * 64, "d" * 64))
        self.assertFalse(any(call.startswith("ops active-record rollback") for call in target.calls))

    def test_prepared_abort_claim_loses_boundary_race_without_rollback(self) -> None:
        target = FakeTarget(fail="claim-race")
        target.has_tx = True
        target.active = "d" * 64
        target.compose = "c" * 64
        approval = self.prepared_approval(target)
        with mock.patch.object(a.r, "verify_local", return_value=approval["evidence"]), \
             mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash):
            with self.assertRaisesRegex(a.r.RecoveryError, "runtime boundary was reached"):
                a.abort_prepared(target, approval, self.candidate, self.source, self.root, self.root, self.root)
        self.assertEqual((target.compose, target.active), ("c" * 64, "d" * 64))
        self.assertFalse(any(call.startswith("ops active-record rollback") for call in target.calls))

    def test_pre_prepare_failure_aborts_without_active_transaction(self) -> None:
        target = FakeTarget(fail="tag")
        with mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash):
            with self.assertRaisesRegex(a.r.RecoveryError, "prior configuration restored"):
                a.stage_apply(target, self.base, {"fingerprint": "f" * 64, "expires": 1000}, self.candidate, self.source)
        self.assertEqual(target.phase, "aborted")
        self.assertFalse(any("ops active-record rollback" in call or "ops active-record commit" in call for call in target.calls))

    def test_post_boundary_failure_never_rolls_back_configuration(self) -> None:
        target = FakeTarget(fail="restart")
        with mock.patch.object(a.r, "run", return_value=""), mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash):
            with self.assertRaisesRegex(a.r.RecoveryError, "full runtime restore"):
                a.stage_apply(target, self.base, {"fingerprint": "f" * 64, "expires": 1000}, self.candidate, self.source)
        self.assertEqual(target.phase, "runtime-may-have-changed")
        self.assertEqual(target.compose, "c" * 64)
        self.assertEqual(target.active, "d" * 64)
        self.assertFalse(any("ops active-record rollback" in call for call in target.calls))

    def test_lost_boundary_response_is_not_prestart_rollback(self) -> None:
        target = FakeTarget(fail="boundary-response")
        with mock.patch.object(a.r, "run", return_value=""), mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash):
            with self.assertRaisesRegex(a.r.RecoveryError, "full runtime restore"):
                a.stage_apply(target, self.base, {"fingerprint": "f" * 64, "expires": 1000}, self.candidate, self.source)
        self.assertEqual(target.phase, "runtime-may-have-changed")
        self.assertEqual(target.compose, "c" * 64)
        self.assertFalse(any("ops active-record rollback" in call for call in target.calls))

    def test_running_id_failure_after_restart_retains_candidate(self) -> None:
        target = FakeTarget()
        with mock.patch.object(a.r, "run", return_value=""), mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash), mock.patch.object(a, "running", side_effect=a.r.RecoveryError("image ID mismatch")):
            with self.assertRaisesRegex(a.r.RecoveryError, "full runtime restore"):
                a.stage_apply(target, self.base, {"fingerprint": "f" * 64, "expires": 1000}, self.candidate, self.source)
        self.assertEqual(target.phase, "runtime-may-have-changed")
        self.assertEqual(target.active, "d" * 64)
        self.assertFalse(any("ops active-record rollback" in call for call in target.calls))

    def test_success_stops_before_acceptance_or_freeze_release(self) -> None:
        target = FakeTarget()
        with mock.patch.object(a.r, "run", return_value=""), mock.patch.object(a.r, "remote_hash", side_effect=self.remote_hash), mock.patch.object(a, "running", return_value={"APP": "id"}):
            a.stage_apply(target, self.base, {"fingerprint": "f" * 64, "expires": 1000}, self.candidate, self.source)
        self.assertEqual(target.phase, "runtime-may-have-changed")
        self.assertFalse(any("upgrade-stage accept" in call or "upgrade-freeze release" in call for call in target.calls))

    def test_database_stage_refuses_to_start_without_clean_cutover(self) -> None:
        target = FakeTarget()
        base = dict(self.base, target="db", tag="mariadb:11.4.13")
        with self.assertRaisesRegex(a.r.RecoveryError, "clean-directory cutover"):
            a.stage_apply(target, base, {"fingerprint": "f" * 64}, self.candidate, self.source)
        self.assertEqual(target.calls, [])


if __name__ == "__main__":
    unittest.main()
