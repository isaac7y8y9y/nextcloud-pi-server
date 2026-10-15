#!/usr/bin/env python3
"""Exact registry/store identity derivation and unknown-store rejection."""

import json
import unittest
from lib import image_identity as identity


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.metadata = {"index_digest": "sha256:" + "1" * 64,
                         "manifest_digest": "sha256:" + "2" * 64,
                         "config_digest": "sha256:" + "3" * 64}

    def test_derivation_preserves_three_distinct_digests(self):
        self.assertEqual(identity.expected_id(self.metadata, "containerd"), self.metadata["index_digest"])
        self.assertEqual(identity.expected_id(self.metadata, "classic"), self.metadata["config_digest"])
        with self.assertRaises(ValueError):
            identity.expected_id(self.metadata, "auto")

    def test_closed_contract_rejects_manifest_or_config_substitution(self):
        contract = {"format": "nextcloud-image-identity-v1", "image_store": "containerd",
                    "expected_id": self.metadata["index_digest"]}
        identity.validate(contract, self.metadata)
        for bad in (dict(contract, expected_id=self.metadata["manifest_digest"]),
                    dict(contract, expected_id=self.metadata["config_digest"]),
                    dict(contract, format="legacy"), dict(contract, extra="ignored")):
            with self.assertRaises(ValueError):
                identity.validate(bad, self.metadata)

    def test_store_requires_explicit_containerd_marker(self):
        evidence = json.dumps({"driver": "overlayfs", "status": [["driver-type", "io.containerd.snapshotter.v1"]]})
        identity.require_store(evidence, "containerd")
        with self.assertRaises(ValueError):
            identity.require_store(evidence, "classic")
        for driver in ("overlay2", "vfs", "fuse-overlayfs"):
            evidence = json.dumps({"driver": driver, "status": []})
            identity.require_store(evidence, "classic")
            with self.assertRaises(ValueError):
                identity.require_store(evidence, "containerd")

    def test_unknown_malformed_or_duplicate_store_marker_fails_closed(self):
        for value in ({"driver": "overlayfs", "status": []},
                      {"driver": "overlay2", "status": [["driver-type", "future"]]},
                      {"driver": "overlay2", "status": [["driver-type", "io.containerd.snapshotter.v1"]] * 2},
                      {"driver": "overlay2", "status": ["broken"]}, {}, []):
            with self.assertRaises(ValueError):
                identity.classify(json.dumps(value))


if __name__ == "__main__":
    unittest.main()
