#!/usr/bin/env python3
"""Verify a private, one-image upgrade candidate without contacting the Pi."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
from pathlib import Path
import stat
import sys


sys.dont_write_bytecode = True
HERE = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("prepare_image_upgrade", HERE / "prepare-image-upgrade.py")
assert SPEC and SPEC.loader
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)
EXPECTED = {
    "registry-metadata.tsv", "image-lock.env", "docker-compose.yml",
    "active-images.env", "Caddyfile", "candidate-manifest.tsv",
}


def verify(directory: Path) -> dict[str, str]:
    if not directory.is_dir() or directory.is_symlink() or stat.S_IMODE(directory.stat().st_mode) != 0o700:
        raise candidate.CandidateError("candidate directory is unsafe")
    if {entry.name for entry in directory.iterdir()} != EXPECTED:
        raise candidate.CandidateError("candidate directory has missing or extra files")
    contents = {}
    for name in EXPECTED:
        path = directory / name
        if not path.is_file() or path.is_symlink() or stat.S_IMODE(path.stat().st_mode) != 0o600:
            raise candidate.CandidateError("candidate file protection is invalid")
        contents[name] = path.read_bytes()
    manifest = candidate.fields(
        contents["candidate-manifest.tsv"], "\t", EXPECTED - {"candidate-manifest.tsv"}
    )
    for name, expected in manifest.items():
        if not candidate.HASH.fullmatch(expected) or hashlib.sha256(contents[name]).hexdigest() != expected:
            raise candidate.CandidateError("candidate manifest digest differs")
    metadata = candidate.fields(contents["registry-metadata.tsv"], "\t", set(candidate.METADATA_KEYS))
    if metadata["format"] != "nextcloud-upgrade-image-v1" or metadata["platform"] != "linux/arm64/v8":
        raise candidate.CandidateError("candidate registry metadata is invalid")
    for field in ("index_digest", "manifest_digest", "config_digest"):
        if not candidate.DIGEST.fullmatch(metadata[field]):
            raise candidate.CandidateError("candidate registry digest is invalid")
    lock_keys = {"NEXTCLOUD_IMAGE_PLATFORM"}
    record_keys = {
        "NEXTCLOUD_ACTIVE_IMAGES_FORMAT", "NEXTCLOUD_ACTIVE_IMAGES_MODE",
        "NEXTCLOUD_ACTIVE_IMAGES_HOST", "NEXTCLOUD_ACTIVE_IMAGES_PROJECT",
        "NEXTCLOUD_ACTIVE_IMAGES_STORAGE", "NEXTCLOUD_ACTIVE_IMAGES_PLATFORM",
        "NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256",
    }
    for key in candidate.KEYS:
        lock_keys.update({f"NEXTCLOUD_IMAGE_{key}_TAG", f"NEXTCLOUD_IMAGE_{key}_ID"})
        record_keys.update({f"NEXTCLOUD_ACTIVE_IMAGES_{key}_TAG", f"NEXTCLOUD_ACTIVE_IMAGES_{key}_ID"})
    lock = candidate.fields(contents["image-lock.env"], "=", lock_keys, comments=True)
    record = candidate.fields(contents["active-images.env"], "=", record_keys)
    if lock["NEXTCLOUD_IMAGE_PLATFORM"] != "linux/arm64/v8" or record["NEXTCLOUD_ACTIVE_IMAGES_PLATFORM"] != "linux/arm64/v8":
        raise candidate.CandidateError("candidate platform differs")
    if record["NEXTCLOUD_ACTIVE_IMAGES_FORMAT"] != "nextcloud-active-images-v1" or record["NEXTCLOUD_ACTIVE_IMAGES_MODE"] != "source":
        raise candidate.CandidateError("candidate active record mode differs")
    if record["NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256"] != candidate.sha256(contents["image-lock.env"]):
        raise candidate.CandidateError("candidate active record provenance differs")
    for key in candidate.KEYS:
        tag = lock[f"NEXTCLOUD_IMAGE_{key}_TAG"]
        image_id = lock[f"NEXTCLOUD_IMAGE_{key}_ID"]
        if record[f"NEXTCLOUD_ACTIVE_IMAGES_{key}_TAG"] != tag or record[f"NEXTCLOUD_ACTIVE_IMAGES_{key}_ID"] != image_id:
            raise candidate.CandidateError("candidate active record mapping differs")
        if not candidate.DIGEST.fullmatch(image_id):
            raise candidate.CandidateError("candidate loaded image ID is invalid")
        candidate.replace_service_image(contents["docker-compose.yml"], candidate.SERVICES[key], tag, tag)
    targets = [key for key in candidate.KEYS if metadata["image"] == candidate.IMAGES[key]]
    if len(targets) != 1:
        raise candidate.CandidateError("candidate registry image is invalid")
    target = targets[0]
    candidate.validate_exact_tag(metadata["image"], metadata["tag"])
    if lock[f"NEXTCLOUD_IMAGE_{target}_TAG"] != metadata["tag"] or lock[f"NEXTCLOUD_IMAGE_{target}_ID"] != metadata["config_digest"]:
        raise candidate.CandidateError("candidate registry identity differs from its lock")
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        metadata = verify(args.directory)
    except (candidate.CandidateError, OSError) as exc:
        print(f"Image candidate rejected: {exc}", file=sys.stderr)
        return 1
    print(f"Image candidate verified: {metadata['image']} {metadata['tag']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
