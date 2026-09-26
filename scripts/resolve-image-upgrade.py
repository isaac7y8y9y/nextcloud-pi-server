#!/usr/bin/env python3
"""Resolve an exact ARM64 image identity without loading or tagging an image."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys


DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
TAGS = {
    "nextcloud": re.compile(r"nextcloud:[0-9]+\.[0-9]+\.[0-9]+-apache\Z"),
    "mariadb": re.compile(r"mariadb:[0-9]+\.[0-9]+\.[0-9]+\Z"),
    "caddy": re.compile(r"caddy:[0-9]+\.[0-9]+\.[0-9]+\Z"),
}
INDEX_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}
MANIFEST_TYPES = {
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
}


class MetadataError(Exception):
    """The registry candidate is not an exact supported ARM64 image."""


def digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def parse_json(data: bytes, kind: str) -> dict:
    try:
        value = json.loads(data)
    except (ValueError, UnicodeDecodeError) as exc:
        raise MetadataError(f"{kind} is not valid JSON") from exc
    if not isinstance(value, dict) or value.get("schemaVersion") != 2:
        raise MetadataError(f"{kind} has an unsupported schema")
    return value


def select_arm64(index_raw: bytes) -> str:
    index = parse_json(index_raw, "image index")
    if index.get("mediaType") not in INDEX_TYPES:
        raise MetadataError("image reference is not a multi-platform index")
    entries = index.get("manifests")
    if not isinstance(entries, list):
        raise MetadataError("image index has no manifest list")
    matches = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise MetadataError("image index has an invalid descriptor")
        platform = entry.get("platform")
        if not isinstance(platform, dict):
            continue
        if platform.get("os") == "linux" and platform.get("architecture") == "arm64" and platform.get("variant") == "v8":
            if entry.get("mediaType") not in MANIFEST_TYPES or not DIGEST.fullmatch(str(entry.get("digest", ""))):
                raise MetadataError("ARM64 manifest descriptor is invalid")
            matches.append(entry["digest"])
    if len(matches) != 1:
        raise MetadataError("expected exactly one linux/arm64/v8 manifest")
    return matches[0]


def image_config(manifest_raw: bytes, expected_manifest: str) -> str:
    if digest(manifest_raw) != expected_manifest:
        raise MetadataError("ARM64 manifest bytes differ from the index descriptor")
    manifest = parse_json(manifest_raw, "ARM64 manifest")
    if manifest.get("mediaType") not in MANIFEST_TYPES:
        raise MetadataError("ARM64 manifest media type is invalid")
    config = manifest.get("config")
    if not isinstance(config, dict) or not DIGEST.fullmatch(str(config.get("digest", ""))):
        raise MetadataError("ARM64 image config digest is invalid")
    return config["digest"]


def validate_tag(tag: str) -> str:
    for name, pattern in TAGS.items():
        if pattern.fullmatch(tag):
            return name
    raise MetadataError("only exact Nextcloud Apache, MariaDB, and Caddy patch tags are allowed")


def registry_raw(reference: str) -> bytes:
    try:
        result = subprocess.run(
            ["docker", "buildx", "imagetools", "inspect", "--raw", reference],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise MetadataError("could not read image metadata from the registry") from exc
    return result.stdout


def resolve(tag: str, index_raw: bytes, manifest_raw: bytes) -> dict[str, str]:
    image = validate_tag(tag)
    manifest_digest = select_arm64(index_raw)
    config_digest = image_config(manifest_raw, manifest_digest)
    return {
        "format": "nextcloud-upgrade-image-v1",
        "image": image,
        "tag": tag,
        "platform": "linux/arm64/v8",
        "index_digest": digest(index_raw),
        "manifest_digest": manifest_digest,
        "config_digest": config_digest,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="exact patch tag, such as nextcloud:31.0.14-apache")
    parser.add_argument("--expected-index", help="reject a changed multi-platform index digest")
    args = parser.parse_args()
    try:
        image = validate_tag(args.tag)
        index_raw = registry_raw(args.tag)
        index_digest = digest(index_raw)
        if args.expected_index and (not DIGEST.fullmatch(args.expected_index) or args.expected_index != index_digest):
            raise MetadataError("index digest differs from the expected candidate")
        manifest_digest = select_arm64(index_raw)
        manifest_raw = registry_raw(f"{image}@{manifest_digest}")
        result = resolve(args.tag, index_raw, manifest_raw)
    except MetadataError as exc:
        print(f"Image candidate rejected: {exc}", file=sys.stderr)
        return 1
    for key, value in result.items():
        print(f"{key}\t{value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
