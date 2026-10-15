"""Exact upgrade image IDs and fail-closed Docker image-store detection."""

from __future__ import annotations

import argparse
import json
import re
import sys


STORES = ("containerd", "classic")
KEYS = {"format", "image_store", "expected_id"}
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
INFO_COMMAND = "docker info --format '{\"driver\":{{json .Driver}},\"status\":{{json .DriverStatus}}}'"


def expected_id(metadata: dict[str, str], store: str) -> str:
    if store not in STORES:
        raise ValueError("unsupported target image store")
    value = metadata["index_digest" if store == "containerd" else "config_digest"]
    if not DIGEST.fullmatch(value):
        raise ValueError("invalid expected image ID")
    return value


def validate(identity: dict[str, str], metadata: dict[str, str]) -> dict[str, str]:
    if set(identity) != KEYS or identity["format"] != "nextcloud-image-identity-v1":
        raise ValueError("candidate image identity schema differs")
    if identity["expected_id"] != expected_id(metadata, identity["image_store"]):
        raise ValueError("candidate image identity differs from registry/store contract")
    return identity


def classify(raw: str) -> str:
    info = json.loads(raw)
    if not isinstance(info, dict) or set(info) != {"driver", "status"}:
        raise ValueError("Docker image-store evidence schema differs")
    status = info["status"]
    if status is None:
        status = []
    if not isinstance(status, list) or any(
        not isinstance(row, list) or len(row) != 2 or
        any(not isinstance(value, str) for value in row) for row in status
    ):
        raise ValueError("Docker image-store status is invalid")
    markers = [row[1] for row in status if row[0] == "driver-type"]
    if markers:
        if markers == ["io.containerd.snapshotter.v1"]:
            return "containerd"
        raise ValueError("unknown Docker image-store type")
    if info["driver"] in ("overlay2", "vfs", "fuse-overlayfs"):
        return "classic"
    raise ValueError("unrecognized classic Docker driver")


def require_store(raw: str, expected: str) -> None:
    if expected not in STORES or classify(raw) != expected:
        raise ValueError("target Docker image store differs from candidate")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-store", required=True, choices=STORES)
    args = parser.parse_args()
    try:
        require_store(sys.stdin.read(), args.check_store)
    except (ValueError, TypeError) as exc:
        print(f"Image identity rejected: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
