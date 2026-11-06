#!/usr/bin/env python3
"""Behavioral gates for adjacent core rehearsal authority and isolation."""

from __future__ import annotations

import importlib.util
import copy
import json
import os
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
        self.evidence = {"backup_manifest_sha256": "a" * 64,
                         "source_version": "33.0.10", "target_version": "34.0.5",
                         "docker_context": "desktop-linux", "docker_endpoint": "unix:///tmp/test-docker.sock",
                         "docker_id": "approved-daemon"}

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
        def response(output):
            return lambda *args, **kwargs: "apache2" if args[-1] == "/proc/1/comm" else output
        with mock.patch.object(app.base, "docker", side_effect=response(healthy)):
            app.status("app", "30.0.17")
        for bad in (healthy.replace("30.0.17", "31.0.14"),
                    healthy.replace("maintenance: false", "maintenance: true"),
                    healthy.replace("needsDbUpgrade: false", "needsDbUpgrade: true")):
            with mock.patch.object(app.base, "docker", side_effect=response(bad)):
                with mock.patch.object(app.time, "sleep"):
                    with self.assertRaises(app.base.RehearsalError):
                        app.status("app", "30.0.17")

    def test_status_waits_for_apache_before_any_php_probe(self) -> None:
        healthy = "  - versionstring: 34.0.5\n  - maintenance: false\n  - needsDbUpgrade: false\n"
        with mock.patch.object(app.base, "docker", side_effect=["docker-entrypoi", "apache2", healthy]) as docker, \
             mock.patch.object(app.time, "sleep") as sleep:
            app.status("target", "34.0.5")
        self.assertEqual([call.args for call in docker.call_args_list[:2]],
                         [("exec", "target", "cat", "/proc/1/comm")] * 2)
        self.assertEqual(docker.call_args_list[2].args,
                         ("exec", "--user", "www-data", "target", "php", "/var/www/html/occ", "status"))
        sleep.assert_called_once_with(2)

    def test_status_never_runs_php_when_initialization_does_not_finish(self) -> None:
        for result in ("docker-entrypoi", app.base.RehearsalError("container is not ready")):
            with self.subTest(result=result), \
                 mock.patch.object(app.base, "docker", side_effect=result if isinstance(result, Exception) else None,
                                   return_value=result) as docker, \
                 mock.patch.object(app.time, "sleep"):
                with self.assertRaises(app.base.RehearsalError):
                    app.status("target", "34.0.5")
                self.assertEqual(docker.call_count, 180)
                self.assertTrue(all(call.args == ("exec", "target", "cat", "/proc/1/comm")
                                    for call in docker.call_args_list))

    def test_status_recovers_from_failed_read_without_early_php(self) -> None:
        healthy = "  - versionstring: 34.0.5\n  - maintenance: false\n  - needsDbUpgrade: false\n"
        with mock.patch.object(app.base, "docker", side_effect=[app.base.RehearsalError("starting"), "apache2", healthy]) as docker, \
             mock.patch.object(app.time, "sleep"):
            app.status("target", "34.0.5")
        self.assertTrue(all("php" not in call.args for call in docker.call_args_list[:2]))

    def test_failed_pull_stops_only_verified_owned_containers_and_retains_state(self) -> None:
        self.root.mkdir(mode=0o700)
        evidence = {f"{key}_index_digest": "sha256:" + letter * 64 for key, letter in
                    (("db", "a"), ("source", "b"), ("target", "c"))}
        calls: list[tuple[str, ...]] = []

        def fake_docker(*args: str, **kwargs: object) -> str:
            calls.append(args)
            if args[0] == "pull":
                raise app.base.RehearsalError("interrupted pull")
            if args[0] == "inspect":
                return json.dumps({"nextcloud-pi.rehearsal": "20260925T000000Z-abcdef123456"})
            return ""

        with mock.patch.object(app, "resource_absent"):
            with mock.patch.object(app.base, "docker", side_effect=fake_docker):
                with self.assertRaises(app.base.RehearsalError):
                    app.rehearse("20260925T000000Z-abcdef123456", self.backup, evidence, self.root)
        self.assertEqual(len([args for args in calls if args[0] == "stop"]), 3)
        self.assertEqual(len(list(self.root.glob("rehearsal-*/database.env"))), 1)

    def test_successful_rehearsal_passes_bound_prefix_to_both_db_checks(self) -> None:
        self.root.mkdir(mode=0o700)
        evidence = {f"{key}_index_digest": "sha256:" + letter * 64 for key, letter in
                    (("db", "a"), ("source", "b"), ("target", "c"))}
        evidence["dbtableprefix"] = "cloud_"
        evidence.update(source_version="33.0.10", target_version="34.0.5")
        checks: list[tuple[str, str]] = []
        with mock.patch.object(app, "resource_absent"), \
             mock.patch.object(app, "inspect_loaded"), \
             mock.patch.object(app, "status") as status, \
             mock.patch.object(app, "install_auth"), \
             mock.patch.object(app, "webdav"), \
             mock.patch.object(app.base, "wait_ready"), \
             mock.patch.object(app.base, "check_database", side_effect=lambda name, prefix: checks.append((name, prefix))), \
             mock.patch.object(app.base, "docker", return_value=""):
            app.rehearse("20260925T000000Z-abcdef123456", self.backup, evidence, self.root)
        self.assertEqual(len(checks), 2)
        self.assertTrue(all(prefix == "cloud_" for _, prefix in checks))
        self.assertEqual([call.args[1] for call in status.call_args_list], ["33.0.10", "34.0.5"])

    def test_adjacent_tags_and_legacy_cli(self) -> None:
        self.assertEqual(app.versions(app.TAGS), ("30.0.17", "31.0.14"))
        self.assertEqual(app.versions(("mariadb:11.8.9", "nextcloud:33.0.10-apache", "nextcloud:34.0.5-apache")),
                         ("33.0.10", "34.0.5"))
        for tags in (("mariadb:11.8.9", "nextcloud:33.0.10-apache", "nextcloud:35.0.2-apache"),
                     ("mariadb:11.8.9", "nextcloud:33.0.10-apache", "nextcloud:33.0.11-apache"),
                     ("nextcloud:33.0.10-apache", "nextcloud:33.0.10-apache", "nextcloud:34.0.5-apache")):
            with self.assertRaises(app.base.RehearsalError):
                app.versions(tags)
        with mock.patch.object(sys, "argv", [str(SCRIPT), "--plan", "--runtime-backup", "backup",
                               "--mariadb-metadata", "db", "--nextcloud-30-metadata", "old",
                               "--nextcloud-31-metadata", "new", "--output-root", "out"]):
            args = app.options()
        self.assertEqual((args.source_metadata, args.target_metadata), (Path("old"), Path("new")))
        self.assertEqual((args.mariadb_tag, args.source_tag, args.target_tag), app.TAGS)

    def test_local_target_rejects_remote_context_and_overrides(self) -> None:
        clean = {key: "" for key in app.DOCKER_OVERRIDES}
        with mock.patch.dict(os.environ, clean), \
             mock.patch.object(app.base, "execute", side_effect=["remote", "ssh://production"]):
            with self.assertRaises(app.base.RehearsalError):
                app.local_daemon()
        for key in app.DOCKER_OVERRIDES:
            with mock.patch.dict(os.environ, dict(clean, **{key: "remote"})), \
                 mock.patch.object(app.base, "execute") as execute:
                with self.assertRaises(app.base.RehearsalError):
                    app.local_daemon()
                execute.assert_not_called()

    def test_local_target_binds_context_endpoint_daemon_and_arm64(self) -> None:
        clean = {key: "" for key in app.DOCKER_OVERRIDES}
        with mock.patch.dict(os.environ, clean), \
             mock.patch.object(app.base, "execute", side_effect=["desktop-linux", "unix:///tmp/test-docker.sock", "linux/aarch64", "approved-daemon"]):
            self.assertEqual(app.local_daemon(), {k: self.evidence[k] for k in ("docker_context", "docker_endpoint", "docker_id")})
        for arch, identifier in (("linux/amd64", "daemon"), ("linux/aarch64", "")):
            with mock.patch.dict(os.environ, clean), \
                 mock.patch.object(app.base, "execute", side_effect=["local", "unix:///tmp/docker.sock", arch, identifier]):
                with self.assertRaises(app.base.RehearsalError):
                    app.local_daemon()

    def test_changed_version_endpoint_or_daemon_rejects_before_consumption(self) -> None:
        with mock.patch.object(app, "inputs", return_value=self.evidence):
            app.plan(self.backup, self.metadata, self.root)
        artifact = next(self.root.glob("approval-*.json"))
        for key in ("source_version", "target_version", "docker_context", "docker_endpoint", "docker_id", "source_index_pin", "db_index_pin"):
            with mock.patch.object(app, "inputs", return_value=dict(self.evidence, **{key: "changed"})), \
                 mock.patch.object(app, "rehearse") as run:
                with self.assertRaises(app.base.RehearsalError):
                    app.apply(artifact, self.backup, self.metadata, self.root)
                run.assert_not_called()
            self.assertEqual(json.loads(artifact.read_text())["state"], "unused")

    def test_pinned_routing_and_daemon_drift_protect_cleanup(self) -> None:
        clean = {key: "" for key in app.DOCKER_OVERRIDES}
        original = app.base.docker
        with mock.patch.dict(os.environ, clean), \
             mock.patch.object(app.base, "execute", side_effect=["approved-daemon", "stopped"]) as execute:
            with app.pinned_daemon(self.evidence):
                self.assertEqual(app.base.docker("stop", "owned"), "stopped")
            self.assertEqual(execute.call_args_list[1].args[0],
                             ["docker", "--host", self.evidence["docker_endpoint"], "stop", "owned"])
        self.assertIs(app.base.docker, original)
        with mock.patch.dict(os.environ, clean), \
             mock.patch.object(app.base, "execute", return_value="different-daemon") as execute:
            with app.pinned_daemon(self.evidence):
                with self.assertRaises(app.base.RehearsalError):
                    app.base.docker("stop", "owned")
            self.assertEqual(execute.call_count, 1)

    def test_failure_does_not_stop_foreign_container(self) -> None:
        with mock.patch.object(app.base, "docker", return_value='{"nextcloud-pi.rehearsal":"other"}') as docker:
            app.stop_if_present("foreign", "mine")
        self.assertEqual(docker.call_count, 1)

    def test_resource_absence_fails_closed_and_uses_pinned_primitive(self) -> None:
        with mock.patch.object(app.base, "docker", return_value="existing\nother"):
            with self.assertRaises(app.base.RehearsalError):
                app.resource_absent("container", "existing")
            app.resource_absent("container", "absent")
        with mock.patch.object(app.base, "docker", side_effect=app.base.RehearsalError("daemon unavailable")):
            with self.assertRaises(app.base.RehearsalError):
                app.resource_absent("volume", "absent")

    def test_backup_source_version_must_match_selected_tag(self) -> None:
        (self.backup / "nextcloud").mkdir(parents=True)
        (self.backup / "database").mkdir()
        (self.backup / "nextcloud/nextcloud.tar").write_bytes(b"private archive")
        (self.backup / "database/nextcloud.sql").write_bytes(b"private sql")
        manifest = self.backup / "manifest.tsv"
        manifest.write_text("format\truntime-backup-v2\ndbtableprefix\tcloud_\n")
        manifest.chmod(0o600)
        tags = ("mariadb:11.8.9", "nextcloud:33.0.10-apache", "nextcloud:34.0.5-apache")
        fields = {name: "sha256:" + "a" * 64 for name in ("index_digest", "manifest_digest", "config_digest")}
        with mock.patch.object(app.base, "safe_root"), \
             mock.patch.object(app, "local_daemon", return_value={}), \
             mock.patch.object(app.base, "verify_metadata", return_value=(fields, "a" * 64)) as verify:
            with mock.patch.object(app.base, "execute", return_value="$OC_VersionString = '30.0.17';"):
                with self.assertRaises(app.base.RehearsalError):
                    app.inputs(self.backup, self.metadata, self.root, tags)
            with mock.patch.object(app.base, "execute", return_value="$OC_VersionString = '33.0.10';"):
                pins = ("sha256:" + "b" * 64, "sha256:" + "c" * 64)
                evidence = app.inputs(self.backup, self.metadata, self.root, tags, pins)
            self.assertEqual((evidence["source_version"], evidence["target_version"], evidence["db_tag"]),
                             ("33.0.10", "34.0.5", "mariadb:11.8.9"))
            self.assertEqual([call.kwargs["expected_index"] for call in verify.call_args_list], [pins[1], pins[0], None])
            self.assertEqual((evidence["source_index_pin"], evidence["db_index_pin"]), pins)

    def loaded_fixture(self):
        evidence = {f"target_{key}_digest": "sha256:" + letter * 64 for key, letter in
                    (("index", "a"), ("manifest", "b"), ("config", "c"))}
        ref = "nextcloud@" + evidence["target_index_digest"]
        image = {"Id": evidence["target_index_digest"], "Architecture": "arm64", "Os": "linux", "Variant": "v8",
                 "RepoDigests": [ref], "Descriptor": {"digest": evidence["target_index_digest"],
                 "mediaType": "application/vnd.oci.image.index.v1+json"}}
        store = {"driver": "overlayfs", "status": [["driver-type", "io.containerd.snapshotter.v1"]]}
        return evidence, ref, image, store

    def test_loaded_config_and_manifest_ids_keep_existing_behavior(self) -> None:
        evidence, ref, image, _ = self.loaded_fixture()
        for kind in ("config", "manifest"):
            image["Id"] = evidence[f"target_{kind}_digest"]
            image.pop("Descriptor", None)
            with mock.patch.object(app.base, "docker", return_value=json.dumps(image)) as docker:
                app.inspect_loaded(ref, evidence, "target")
                self.assertEqual(docker.call_count, 1)

    def test_loaded_index_requires_explicit_containerd_and_matching_descriptor(self) -> None:
        evidence, ref, image, store = self.loaded_fixture()
        for media_type in ("application/vnd.oci.image.index.v1+json",
                           "application/vnd.docker.distribution.manifest.list.v2+json"):
            image["Descriptor"]["mediaType"] = media_type
            with mock.patch.object(app.base, "docker", side_effect=[json.dumps(image), json.dumps(store)]) as docker:
                app.inspect_loaded(ref, evidence, "target")
                self.assertEqual(docker.call_args_list[1].args[:2], ("info", "--format"))

    def test_loaded_index_rejects_store_descriptor_and_platform_drift(self) -> None:
        evidence, ref, image, store = self.loaded_fixture()
        stores = [{"driver": "overlay2", "status": []}, {"driver": "overlayfs", "status": []},
                  {"driver": "overlayfs", "status": [["driver-type", "future"]]},
                  {"driver": "overlayfs", "status": store["status"] * 2}, {}, [], None]
        for wrong in stores:
            with self.subTest(store=wrong), mock.patch.object(app.base, "docker", side_effect=[json.dumps(image), json.dumps(wrong)]):
                with self.assertRaises(app.base.RehearsalError):
                    app.inspect_loaded(ref, evidence, "target")
        changes = [{"Id": "sha256:" + "d" * 64}, {"Architecture": "amd64"}, {"Os": "windows"},
                   {"Variant": "v9"}, {"RepoDigests": []}, {"RepoDigests": {ref: "wrong-schema"}},
                   {"Descriptor": None}, {"Descriptor": {"digest": evidence["target_manifest_digest"],
                       "mediaType": image["Descriptor"]["mediaType"]}},
                   {"Descriptor": {"digest": evidence["target_index_digest"], "mediaType": "application/vnd.oci.image.manifest.v1+json"}}]
        for change in changes:
            changed = dict(copy.deepcopy(image), **change)
            with self.subTest(change=change), mock.patch.object(app.base, "docker", side_effect=[json.dumps(changed), json.dumps(store)]):
                with self.assertRaises(app.base.RehearsalError):
                    app.inspect_loaded(ref, evidence, "target")


if __name__ == "__main__":
    unittest.main()
