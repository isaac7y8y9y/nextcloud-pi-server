#!/usr/bin/env python3
"""Offline candidate-building checks; no Docker daemon or Pi required."""

import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).with_name("prepare-image-upgrade.py")
SPEC = importlib.util.spec_from_file_location("prepare_image_upgrade", SCRIPT)
assert SPEC and SPEC.loader
upgrade = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upgrade)
VERIFY_SPEC = importlib.util.spec_from_file_location("verify_image_upgrade", SCRIPT.with_name("verify-image-upgrade.py"))
assert VERIFY_SPEC and VERIFY_SPEC.loader
verify_module = importlib.util.module_from_spec(VERIFY_SPEC)
VERIFY_SPEC.loader.exec_module(verify_module)


def checksum(data):
    return hashlib.sha256(data).hexdigest()


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.old = "sha256:" + "a" * 64
        self.new = "sha256:" + "b" * 64
        self.lock = (
            "# source image lock\n"
            "NEXTCLOUD_IMAGE_PLATFORM=linux/arm64/v8\n"
            "NEXTCLOUD_IMAGE_APP_TAG=nextcloud:30\n"
            f"NEXTCLOUD_IMAGE_APP_ID={self.old}\n"
            "NEXTCLOUD_IMAGE_DB_TAG=mariadb:11\n"
            f"NEXTCLOUD_IMAGE_DB_ID={self.old}\n"
            "NEXTCLOUD_IMAGE_CADDY_TAG=caddy:2\n"
            f"NEXTCLOUD_IMAGE_CADDY_ID={self.old}\n"
        ).encode()
        self.record = (
            "NEXTCLOUD_ACTIVE_IMAGES_FORMAT=nextcloud-active-images-v1\n"
            "NEXTCLOUD_ACTIVE_IMAGES_MODE=source\n"
            "NEXTCLOUD_ACTIVE_IMAGES_HOST=example\n"
            "NEXTCLOUD_ACTIVE_IMAGES_PROJECT=/srv/nextcloud-docker\n"
            "NEXTCLOUD_ACTIVE_IMAGES_STORAGE=/srv/storage\n"
            "NEXTCLOUD_ACTIVE_IMAGES_PLATFORM=linux/arm64/v8\n"
            f"NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256={checksum(self.lock)}\n"
            "NEXTCLOUD_ACTIVE_IMAGES_APP_TAG=nextcloud:30\n"
            f"NEXTCLOUD_ACTIVE_IMAGES_APP_ID={self.old}\n"
            "NEXTCLOUD_ACTIVE_IMAGES_DB_TAG=mariadb:11\n"
            f"NEXTCLOUD_ACTIVE_IMAGES_DB_ID={self.old}\n"
            "NEXTCLOUD_ACTIVE_IMAGES_CADDY_TAG=caddy:2\n"
            f"NEXTCLOUD_ACTIVE_IMAGES_CADDY_ID={self.old}\n"
        ).encode()
        self.compose = b"services:\n  db:\n    image: mariadb:11\n  app:\n    image: nextcloud:30\n  caddy:\n    image: caddy:2\n"
        self.metadata = (
            "format\tnextcloud-upgrade-image-v1\n"
            "image\tnextcloud\n"
            "tag\tnextcloud:31.0.14-apache\n"
            "platform\tlinux/arm64/v8\n"
            f"index_digest\t{self.old}\n"
            f"manifest_digest\t{self.old}\n"
            f"config_digest\t{self.new}\n"
        ).encode()

    def build(self, metadata=None, lock=None, compose=None, record=None):
        return upgrade.prepare(
            "APP", metadata or self.metadata, lock or self.lock,
            compose or self.compose, record or self.record, b"caddy\n"
        )

    def test_changes_only_target_mapping_and_compose(self):
        output = self.build()
        self.assertIn(b"image: nextcloud:31.0.14-apache\n", output["docker-compose.yml"])
        self.assertIn(b"image: mariadb:11\n", output["docker-compose.yml"])
        self.assertIn(f"NEXTCLOUD_IMAGE_APP_ID={self.new}\n".encode(), output["image-lock.env"])
        self.assertIn(f"NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256={checksum(output['image-lock.env'])}\n".encode(), output["active-images.env"])
        self.assertEqual(output["Caddyfile"], b"caddy\n")

    def test_rejects_wrong_prestate_provenance(self):
        bad_record = self.record.replace(checksum(self.lock).encode(), b"0" * 64)
        with self.assertRaisesRegex(upgrade.CandidateError, "provenance"):
            self.build(record=bad_record)

    def test_rejects_compose_drift(self):
        with self.assertRaisesRegex(upgrade.CandidateError, "Compose image"):
            self.build(compose=self.compose.replace(b"nextcloud:30", b"nextcloud:29"))

    def test_rejects_floating_target(self):
        with self.assertRaisesRegex(upgrade.CandidateError, "unsafe"):
            self.build(metadata=self.metadata.replace(b"nextcloud:31.0.14-apache", b"nextcloud:latest"))

    def test_rejects_same_loaded_id(self):
        with self.assertRaisesRegex(upgrade.CandidateError, "must both change"):
            self.build(metadata=self.metadata.replace(self.new.encode(), self.old.encode()))

    def test_rejects_duplicate_mapping(self):
        with self.assertRaisesRegex(upgrade.CandidateError, "duplicate"):
            self.build(lock=self.lock + b"NEXTCLOUD_IMAGE_APP_TAG=nextcloud:29\n")

    def test_cli_publishes_private_candidate_with_manifest_last(self):
        with tempfile.TemporaryDirectory(dir=os.path.realpath(tempfile.gettempdir())) as temporary:
            root = Path(temporary)
            rendered = root / "rendered"
            (rendered / "active-images").mkdir(parents=True)
            (rendered / "caddy").mkdir()
            (rendered / "docker-compose.yml").write_bytes(self.compose)
            (rendered / "active-images" / "active-images.env").write_bytes(self.record)
            (rendered / "caddy" / "Caddyfile").write_bytes(b"caddy\n")
            (root / "metadata.tsv").write_bytes(self.metadata)
            (root / "image-lock.env").write_bytes(self.lock)
            output = root / "candidate"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--target", "app", "--metadata", str(root / "metadata.tsv"),
                 "--image-lock", str(root / "image-lock.env"), "--rendered", str(rendered),
                 "--output-dir", str(output)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual((output / "candidate-manifest.tsv").stat().st_mode & 0o777, 0o600)
            self.assertIn(b"image: nextcloud:31.0.14-apache", (output / "docker-compose.yml").read_bytes())
            self.assertEqual(len((output / "candidate-manifest.tsv").read_text().splitlines()), 5)
            self.assertEqual(verify_module.verify(output)["config_digest"], self.new)
            (output / "docker-compose.yml").write_bytes(b"changed\n")
            with self.assertRaisesRegex(verify_module.candidate.CandidateError, "digest differs"):
                verify_module.verify(output)


if __name__ == "__main__":
    unittest.main()
