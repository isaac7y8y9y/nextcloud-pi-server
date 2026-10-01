#!/usr/bin/env python3
"""Build a private one-image candidate from a rendered baseline and registry record."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


KEYS = ("APP", "DB", "CADDY")
SERVICES = {"APP": "app", "DB": "db", "CADDY": "caddy"}
IMAGES = {"APP": "nextcloud", "DB": "mariadb", "CADDY": "caddy"}
METADATA_KEYS = (
    "format", "image", "tag", "platform", "index_digest", "manifest_digest", "config_digest"
)
HASH = re.compile(r"[0-9a-f]{64}\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")


class CandidateError(Exception):
    """A candidate violates the source lock or expected rendered baseline."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def regular_bytes(path: Path) -> bytes:
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise CandidateError("candidate input is not a regular file")
        return path.read_bytes()
    except OSError as exc:
        raise CandidateError("candidate input is unavailable") from exc


def fields(data: bytes, sep: str, allowed: set[str], comments: bool = False) -> dict[str, str]:
    result = {}
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise CandidateError("candidate input is not UTF-8") from exc
    for line in lines:
        if comments and (not line or line.startswith("#")):
            continue
        key, found, value = line.partition(sep)
        if not found or key not in allowed or key in result or not value or "\t" in value or "\r" in value:
            raise CandidateError("candidate input has an invalid or duplicate field")
        result[key] = value
    if set(result) != allowed:
        raise CandidateError("candidate input has missing or unknown fields")
    return result


def substitute_field(data: bytes, key: str, old: str, new: str) -> bytes:
    before = f"{key}={old}\n".encode()
    after = f"{key}={new}\n".encode()
    if data.count(before) != 1:
        raise CandidateError("rendered baseline does not match its image lock")
    return data.replace(before, after, 1)


def replace_service_image(compose: bytes, service: str, old: str, new: str) -> bytes:
    try:
        content = compose.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CandidateError("rendered Compose is not UTF-8") from exc
    pattern = rf"(?m)^(  {re.escape(service)}:\n)(    image: ){re.escape(old)}$"
    updated, count = re.subn(pattern, lambda match: match[1] + match[2] + new, content)
    if count != 1:
        raise CandidateError("rendered Compose image differs from the source lock")
    return updated.encode()


def reject_git_destination(output: Path) -> None:
    parent = output.parent
    if not parent.is_dir() or parent.is_symlink():
        raise CandidateError("candidate output parent is unsafe")
    ancestor = parent
    while ancestor != ancestor.parent:
        if ancestor.is_symlink():
            raise CandidateError("candidate output parent contains a symbolic link")
        ancestor = ancestor.parent
    result = subprocess.run(
        ["git", "-C", str(parent), "rev-parse", "--show-toplevel"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if result.returncode == 0:
        raise CandidateError("candidate output must be outside Git")


def write_private(path: Path, data: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)


def validate_exact_tag(image: str, tag: str) -> None:
    # Keep the accepted patch-tag grammar in the resolver as one source of
    # truth; metadata files are untrusted even if their checksums are valid.
    import importlib.util
    sys.dont_write_bytecode = True
    resolver_path = Path(__file__).with_name("resolve-image-upgrade.py")
    spec = importlib.util.spec_from_file_location("resolve_image_upgrade", resolver_path)
    if not spec or not spec.loader:
        raise CandidateError("image resolver is unavailable")
    resolver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(resolver)
    try:
        if resolver.validate_tag(tag) != image:
            raise CandidateError("registry record tag differs from the selected image")
    except resolver.MetadataError as exc:
        raise CandidateError("registry record tag is unsafe") from exc


def prepare(target: str, metadata_raw: bytes, lock_raw: bytes, compose_raw: bytes,
            record_raw: bytes, caddy_raw: bytes) -> dict[str, bytes]:
    metadata = fields(metadata_raw, "\t", set(METADATA_KEYS))
    if metadata["format"] != "nextcloud-upgrade-image-v1" or metadata["image"] != IMAGES[target] or metadata["platform"] != "linux/arm64/v8":
        raise CandidateError("registry record does not match the selected service")
    for name in ("index_digest", "manifest_digest", "config_digest"):
        if not DIGEST.fullmatch(metadata[name]):
            raise CandidateError("registry record has an invalid digest")
    validate_exact_tag(metadata["image"], metadata["tag"])

    lock_keys = {"NEXTCLOUD_IMAGE_PLATFORM"}
    record_keys = {
        "NEXTCLOUD_ACTIVE_IMAGES_FORMAT", "NEXTCLOUD_ACTIVE_IMAGES_MODE",
        "NEXTCLOUD_ACTIVE_IMAGES_HOST", "NEXTCLOUD_ACTIVE_IMAGES_PROJECT",
        "NEXTCLOUD_ACTIVE_IMAGES_STORAGE", "NEXTCLOUD_ACTIVE_IMAGES_PLATFORM",
        "NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256",
    }
    for name in KEYS:
        lock_keys.update({f"NEXTCLOUD_IMAGE_{name}_TAG", f"NEXTCLOUD_IMAGE_{name}_ID"})
        record_keys.update({f"NEXTCLOUD_ACTIVE_IMAGES_{name}_TAG", f"NEXTCLOUD_ACTIVE_IMAGES_{name}_ID"})
    lock = fields(lock_raw, "=", lock_keys, comments=True)
    record = fields(record_raw, "=", record_keys)
    if lock["NEXTCLOUD_IMAGE_PLATFORM"] != "linux/arm64/v8" or record["NEXTCLOUD_ACTIVE_IMAGES_PLATFORM"] != "linux/arm64/v8":
        raise CandidateError("baseline platform differs")
    if record["NEXTCLOUD_ACTIVE_IMAGES_MODE"] != "source" or record["NEXTCLOUD_ACTIVE_IMAGES_FORMAT"] != "nextcloud-active-images-v1":
        raise CandidateError("baseline active-image record is not in source mode")
    if record["NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256"] != sha256(lock_raw):
        raise CandidateError("baseline active-image provenance differs")
    for name in KEYS:
        for field in ("TAG", "ID"):
            if lock[f"NEXTCLOUD_IMAGE_{name}_{field}"] != record[f"NEXTCLOUD_ACTIVE_IMAGES_{name}_{field}"]:
                raise CandidateError("baseline active-image mapping differs")
        locked_tag = lock[f"NEXTCLOUD_IMAGE_{name}_TAG"]
        locked_id = lock[f"NEXTCLOUD_IMAGE_{name}_ID"]
        if not DIGEST.fullmatch(locked_id):
            raise CandidateError("baseline image ID is invalid")
        replace_service_image(compose_raw, SERVICES[name], locked_tag, locked_tag)
    old_tag = lock[f"NEXTCLOUD_IMAGE_{target}_TAG"]
    old_id = lock[f"NEXTCLOUD_IMAGE_{target}_ID"]
    new_tag = metadata["tag"]
    new_id = metadata["config_digest"]
    if old_tag == new_tag or old_id == new_id:
        raise CandidateError("new image tag and loaded ID must both change")
    candidate_lock = substitute_field(lock_raw, f"NEXTCLOUD_IMAGE_{target}_TAG", old_tag, new_tag)
    candidate_lock = substitute_field(candidate_lock, f"NEXTCLOUD_IMAGE_{target}_ID", old_id, new_id)
    candidate_record = substitute_field(record_raw, f"NEXTCLOUD_ACTIVE_IMAGES_{target}_TAG", old_tag, new_tag)
    candidate_record = substitute_field(candidate_record, f"NEXTCLOUD_ACTIVE_IMAGES_{target}_ID", old_id, new_id)
    candidate_record = substitute_field(
        candidate_record, "NEXTCLOUD_ACTIVE_IMAGES_PROVENANCE_SHA256", sha256(lock_raw), sha256(candidate_lock)
    )
    candidate_compose = replace_service_image(compose_raw, SERVICES[target], old_tag, new_tag)
    return {
        "registry-metadata.tsv": metadata_raw,
        "image-lock.env": candidate_lock,
        "docker-compose.yml": candidate_compose,
        "active-images.env": candidate_record,
        "Caddyfile": caddy_raw,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("app", "db", "caddy"), required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--image-lock", type=Path, required=True)
    parser.add_argument("--rendered", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    target = args.target.upper()
    try:
        output = args.output_dir
        if not output.is_absolute() or output.exists() or output.is_symlink():
            raise CandidateError("candidate output must be a new absolute directory")
        reject_git_destination(output)
        rendered = args.rendered
        if not rendered.is_dir() or rendered.is_symlink():
            raise CandidateError("rendered baseline directory is unsafe")
        result = prepare(
            target,
            regular_bytes(args.metadata),
            regular_bytes(args.image_lock),
            regular_bytes(rendered / "docker-compose.yml"),
            regular_bytes(rendered / "active-images" / "active-images.env"),
            regular_bytes(rendered / "caddy" / "Caddyfile"),
        )
        output.mkdir(mode=0o700)
        for name, data in result.items():
            write_private(output / name, data)
        manifest = "".join(f"{name}\t{sha256(data)}\n" for name, data in result.items()).encode()
        write_private(output / "candidate-manifest.tsv", manifest)
    except (CandidateError, OSError) as exc:
        print(f"Image candidate rejected: {exc}", file=sys.stderr)
        return 1
    print(f"Private image candidate created: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
