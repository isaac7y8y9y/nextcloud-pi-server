#!/usr/bin/env python3
"""Offline identity and rejection tests for upgrade image metadata."""

import importlib.util
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).with_name("resolve-image-upgrade.py")
SPEC = importlib.util.spec_from_file_location("resolve_image_upgrade", SCRIPT)
assert SPEC and SPEC.loader
upgrade = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upgrade)


def raw(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()


class ImageUpgradeMetadataTests(unittest.TestCase):
    def setUp(self):
        self.config = "sha256:" + "a" * 64
        self.manifest = raw(
            {
                "schemaVersion": 2,
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": {"digest": self.config},
            }
        )
        self.manifest_digest = upgrade.digest(self.manifest)
        self.index = raw(
            {
                "schemaVersion": 2,
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "manifests": [
                    {
                        "mediaType": "application/vnd.oci.image.manifest.v1+json",
                        "digest": self.manifest_digest,
                        "platform": {"os": "linux", "architecture": "arm64", "variant": "v8"},
                    },
                    {
                        "mediaType": "application/vnd.oci.image.manifest.v1+json",
                        "digest": "sha256:" + "b" * 64,
                        "platform": {"os": "linux", "architecture": "amd64"},
                    },
                ],
            }
        )

    def test_resolves_expected_loaded_id(self):
        result = upgrade.resolve("nextcloud:31.0.14-apache", self.index, self.manifest)
        self.assertEqual(result["index_digest"], upgrade.digest(self.index))
        self.assertEqual(result["manifest_digest"], self.manifest_digest)
        self.assertEqual(result["config_digest"], self.config)
        self.assertEqual(result["platform"], "linux/arm64/v8")

    def test_rejects_wrong_manifest_bytes(self):
        with self.assertRaisesRegex(upgrade.MetadataError, "bytes differ"):
            upgrade.resolve("nextcloud:31.0.14-apache", self.index, self.manifest + b" ")

    def test_rejects_missing_or_duplicate_arm64(self):
        index = json.loads(self.index)
        index["manifests"][0]["platform"]["variant"] = "v7"
        with self.assertRaisesRegex(upgrade.MetadataError, "exactly one"):
            upgrade.resolve("mariadb:11.4.13", raw(index), self.manifest)
        index["manifests"][0]["platform"]["variant"] = "v8"
        index["manifests"].append(index["manifests"][0])
        with self.assertRaisesRegex(upgrade.MetadataError, "exactly one"):
            upgrade.resolve("caddy:2.11.4", raw(index), self.manifest)

    def test_rejects_unpinned_or_unknown_tags(self):
        for tag in ("nextcloud:31", "nextcloud:latest", "mariadb:11", "caddy:2", "other:1.2.3"):
            with self.subTest(tag=tag), self.assertRaises(upgrade.MetadataError):
                upgrade.resolve(tag, self.index, self.manifest)

    def test_rejects_single_platform_manifest_as_index(self):
        with self.assertRaisesRegex(upgrade.MetadataError, "multi-platform"):
            upgrade.resolve("caddy:2.11.4", self.manifest, self.manifest)

    def test_rejects_invalid_config_digest(self):
        manifest = json.loads(self.manifest)
        manifest["config"]["digest"] = "sha256:bad"
        changed = raw(manifest)
        index = json.loads(self.index)
        index["manifests"][0]["digest"] = upgrade.digest(changed)
        with self.assertRaisesRegex(upgrade.MetadataError, "config digest"):
            upgrade.resolve("caddy:2.11.4", raw(index), changed)


if __name__ == "__main__":
    unittest.main()
