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
            f"index_digest\tsha256:{'c' * 64}\n"
            f"manifest_digest\tsha256:{'d' * 64}\n"
            f"config_digest\t{self.new}\n"
        ).encode()

    def build(self, metadata=None, lock=None, compose=None, record=None, store="classic"):
        return upgrade.prepare(
            "APP", metadata or self.metadata, lock or self.lock,
            compose or self.compose, record or self.record, b"caddy\n", image_store=store
        )

    def test_changes_only_target_mapping_and_compose(self):
        output = self.build()
        self.assertIn(b"image: nextcloud:31.0.14-apache\n", output["docker-compose.yml"])
        self.assertIn(b"image: mariadb:11\n", output["docker-compose.yml"])
        self.assertIn(f"NEXTCLOUD_IMAGE_APP_ID={self.new}\n".encode(), output["image-lock.env"])
        self.assertIn(f"NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256={checksum(output['image-lock.env'])}\n".encode(), output["active-images.env"])
        self.assertEqual(output["Caddyfile"], b"caddy\n")

    def test_containerd_binds_index_without_relabeling_config(self):
        output = self.build(store="containerd")
        index = "sha256:" + "c" * 64
        self.assertIn(f"NEXTCLOUD_IMAGE_APP_ID={index}\n".encode(), output["image-lock.env"])
        self.assertIn(f"expected_id\t{index}\n".encode(), output["image-identity.tsv"])
        self.assertEqual(output["registry-metadata.tsv"], self.metadata)

    def test_rejects_unknown_store(self):
        with self.assertRaisesRegex(upgrade.CandidateError, "unsupported target"):
            self.build(store="guess")

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
                [sys.executable, str(SCRIPT), "--image-store", "classic", "--target", "app", "--metadata", str(root / "metadata.tsv"),
                 "--image-lock", str(root / "image-lock.env"), "--rendered", str(rendered),
                 "--output-dir", str(output)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual((output / "candidate-manifest.tsv").stat().st_mode & 0o777, 0o600)
            self.assertIn(b"image: nextcloud:31.0.14-apache", (output / "docker-compose.yml").read_bytes())
            self.assertEqual(len((output / "candidate-manifest.tsv").read_text().splitlines()), 6)
            self.assertEqual(verify_module.verify(output)["config_digest"], self.new)
            self.assertEqual(
                verify_module.verify(output, root / "image-lock.env", rendered)["config_digest"],
                self.new,
            )
            containerd_output = root / "containerd-candidate"
            containerd_args = list(result.args)
            containerd_args[containerd_args.index("--image-store") + 1] = "containerd"
            containerd_args[containerd_args.index("--output-dir") + 1] = str(containerd_output)
            containerd_result = subprocess.run(containerd_args, capture_output=True, text=True)
            self.assertEqual(containerd_result.returncode, 0, containerd_result.stderr)
            containerd_metadata = verify_module.verify(containerd_output, root / "image-lock.env", rendered)
            self.assertEqual(containerd_metadata["expected_id"], "sha256:" + "c" * 64)
            self.assertEqual(containerd_metadata["config_digest"], self.new)
            identity = output / "image-identity.tsv"
            identity_raw = identity.read_bytes()
            identity.write_bytes(identity_raw.replace(b"classic", b"containerd"))
            manifest_path = output / "candidate-manifest.tsv"
            manifest_raw = manifest_path.read_bytes()
            manifest_path.write_bytes(manifest_raw.replace(checksum(identity_raw).encode(), checksum(identity.read_bytes()).encode()))
            with self.assertRaisesRegex(verify_module.candidate.CandidateError, "registry/store contract"):
                verify_module.verify(output)
            identity.write_bytes(identity_raw)
            manifest_path.write_bytes(manifest_raw)
            identity.unlink()
            with self.assertRaisesRegex(verify_module.candidate.CandidateError, "missing or extra"):
                verify_module.verify(output)
            identity.write_bytes(identity_raw)
            identity.chmod(0o600)
            with self.assertRaisesRegex(verify_module.candidate.CandidateError, "together"):
                verify_module.verify(output, root / "image-lock.env")
            (rendered / "docker-compose.yml").write_bytes(self.compose.replace(b"nextcloud:30", b"nextcloud:29"))
            with self.assertRaisesRegex(verify_module.candidate.CandidateError, "Compose image"):
                verify_module.verify(output, root / "image-lock.env", rendered)
            (rendered / "docker-compose.yml").write_bytes(self.compose)
            (output / "Caddyfile").write_bytes(b"changed caddy\n")
            manifest = output / "candidate-manifest.tsv"
            manifest.write_bytes(manifest.read_bytes().replace(checksum(b"caddy\n").encode(), checksum(b"changed caddy\n").encode()))
            with self.assertRaisesRegex(verify_module.candidate.CandidateError, "one-image source transition"):
                verify_module.verify(output, root / "image-lock.env", rendered)
            (output / "docker-compose.yml").write_bytes(b"changed\n")
            with self.assertRaisesRegex(verify_module.candidate.CandidateError, "digest differs"):
                verify_module.verify(output)


if __name__ == "__main__":
    unittest.main()
