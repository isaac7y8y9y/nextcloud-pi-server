#!/usr/bin/env python3
"""Reject tracked deployment identity and secret-like material without printing it."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import re
import subprocess
import sys
from pathlib import Path


# ROOT is the repository to scan, not the caller's current working directory.
ROOT = Path(__file__).resolve().parents[1]
# These patterns deliberately favor strict detection. Findings contain only
# fingerprints, never the matched text.
ALLOWED_EMAILS = {"noreply@github.com", "git@github.com"}
EMAIL = re.compile(r"(?i)\b[A-Z0-9._%+-]+@(?:[A-Z0-9-]+\.)+[A-Z]{2,63}\b")
IPV4 = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")
IPV6 = re.compile(r"(?i)(?<![0-9a-f:])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:]+(?![0-9a-f:])")
HOME_PATH = re.compile(r"/(?:Users|home)/[^/\s\"'`]+")
UUID = re.compile(r"(?i)\b(?:UUID|PARTUUID)=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
PRIVATE_HOSTNAME = re.compile(r"(?i)\b[a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)*\.(?:home|local|lan|internal)\b")
SAFE_NON_HOST_TOKENS = {"normalized.local", "fstab.local"}
KEY_MATERIAL = re.compile(
    r"-----BEGIN " + r"(?:[A-Z0-9 ]+ )?(?:PRIVATE|PUBLIC) KEY-----|" + r"-----BEGIN " + r"CERTIFICATE-----"
)
AUTHORIZATION_HEADER = re.compile(r"(?im)^\s*authorization\s*:\s*(?:bearer|basic)\s+[^\s\"']{8,}")
COOKIE_HEADER = re.compile(r"(?im)^\s*cookie\s*:\s*[^\r\n]{8,}")
CONNECTION_STRING = re.compile(r"(?i)\b(?:mysql|mariadb|postgres(?:ql)?|mongodb|redis)://[^\s/:]+:[^\s@]+@")
CREDENTIAL_ASSIGNMENT = re.compile(
    r"(?im)^\s*(?:[A-Z][A-Z0-9_]*(?:PASSWORD|TOKEN|SECRET|API_KEY)|(?:password|token|secret|api[_-]?key))\s*[:=]\s*"
    r"(?![\"']?(?:\$|\{|<|set-on-deployment-target|replace-with-|example|placeholder))[^\s\"']{8,}"
)
IDENTITY_DEFAULT = re.compile(
    r"(?m)^\s*(?:NEXTCLOUD_PI_HOST|NEXTCLOUD_PI_SYSTEM_HOSTNAME|NEXTCLOUD_PI_USER|NEXTCLOUD_REMOTE_PROJECT_DIR|NEXTCLOUD_STORAGE_MOUNT|NEXTCLOUD_PUBLIC_HOSTNAME|NEXTCLOUD_STORAGE_UUID)=?\"?\$?\{[^}]*:-[^}]+\}"
)
FORBIDDEN_PATH = re.compile(
    r"(?i)(?:^|/)(?:\.env(?:\..+)?|config\.php)$|"
    r"\.(?:sql(?:\.gz)?|sqlite|sqlite3|db|dump|key|pem|p12|pfx|crt|tar(?:\.gz)?|tgz|zip|7z|rar|bak|backup)$"
)
FORBIDDEN_DIRECTORY = re.compile(
    r"(?i)(?:^|/)(?:reports/raw|staging|nextcloud|nextcloud_db|mysql|mariadb|caddy_data|caddy_config)(?:/|$)"
)
ALLOWED_ENV_TEMPLATES = {"compose/.env.example"}
BOUNDED_DEPLOYMENT_KEYS = {
    "NEXTCLOUD_PI_HOST",
    "NEXTCLOUD_PI_SYSTEM_HOSTNAME",
    "NEXTCLOUD_PI_USER",
    "NEXTCLOUD_PUBLIC_HOSTNAME",
}


def fingerprint(value: str) -> str:
    """Return a non-reversible reference for a finding or path."""
    return hashlib.sha256(value.encode("utf-8", "surrogatepass")).hexdigest()[:16]


def load_literal_env(path: Path, accepted: set[str]) -> dict[str, str]:
    """Read a narrow private-env schema without executing or printing values."""
    # Both supported private files are policy boundaries: regular files, 0600 only.
    if not path.is_file() or path.is_symlink() or (path.stat().st_mode & 0o777) != 0o600:
        raise ValueError("private environment file must be a regular 0600 file")
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        # Only simple, non-duplicated KEY=value records are accepted.
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or key not in accepted or not value:
            raise ValueError("invalid private environment schema")
        if key in values or "\r" in value or any(character.isspace() for character in value):
            raise ValueError("invalid private environment schema")
        # Compose values are single-quoted by the migration script; strip only
        # that known representation so exact credential matching remains safe.
        if value.startswith("'"):
            if len(value) < 3 or not value.endswith("'"):
                raise ValueError("invalid private environment schema")
            value = value[1:-1]
            if not value or "'" in value or "\\" in value:
                raise ValueError("invalid private environment schema")
        elif path.name == ".env":
            raise ValueError("private Compose environment values must be single-quoted")
        values[key] = value
    return values


def is_allowed_email(value: str) -> bool:
    """Allow GitHub attribution and explicit documentation-only addresses."""
    lowered = value.lower()
    return (
        lowered in ALLOWED_EMAILS
        or lowered.endswith("@users.noreply.github.com")
        or lowered.endswith((".example.invalid", ".example.com", ".test", ".invalid"))
    )


def is_documentation_address(value: ipaddress.IPv4Address) -> bool:
    """RFC 5737 IPv4 ranges are safe examples in documentation."""
    return any(
        value in ipaddress.ip_network(network)
        for network in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")
    )


def is_documentation_ipv6(value: ipaddress.IPv6Address) -> bool:
    """RFC 3849 IPv6 range is safe for documentation."""
    return value in ipaddress.ip_network("2001:db8::/32")


def is_forbidden_path(path: str) -> bool:
    """Reject tracked runtime, credential, archive, and raw-report paths."""
    normalized = path.replace("\\", "/")
    if normalized in ALLOWED_ENV_TEMPLATES:
        return False
    if normalized == "config/deployment.env":
        return True
    return bool(FORBIDDEN_PATH.search(normalized) or FORBIDDEN_DIRECTORY.search(normalized))


def exact_value_matches(content: str, value: str, bounded: bool) -> bool:
    """Match identity tokens on boundaries while keeping paths/secrets exact."""
    if not bounded:
        return value in content
    boundary_pattern = re.compile(rf"(?<![A-Za-z0-9_.-]){re.escape(value)}(?![A-Za-z0-9_.-])")
    return bool(boundary_pattern.search(content))


def git_output(*args: str) -> str:
    """Run Git against ROOT while suppressing incidental Git diagnostics."""
    return subprocess.check_output(["git", "-C", str(ROOT), *args], stderr=subprocess.DEVNULL).decode("utf-8", "replace")


def iter_current() -> list[tuple[str, str, str]]:
    """Return tracked and candidate files so local preflight catches new files too."""
    entries: list[tuple[str, str, str]] = []
    for relative_path in git_output("ls-files", "--cached", "--others", "--exclude-standard").splitlines():
        file_path = ROOT / relative_path
        if file_path.is_file():
            entries.append(("worktree", f"file:{fingerprint(relative_path)}", file_path.read_text(encoding="utf-8", errors="replace")))
    return entries


def iter_history() -> list[tuple[str, str, str]]:
    """Return every reachable blob plus commit/tag metadata for a full history scan."""
    entries: list[tuple[str, str, str]] = []
    object_ids = {line.partition(" ")[0] for line in git_output("rev-list", "--objects", "--all").splitlines() if line}
    for object_id in sorted(object_ids):
        object_type = git_output("cat-file", "-t", object_id).strip()
        if object_type not in {"blob", "commit", "tag"}:
            continue
        entries.append(("git_history", f"git-object:{object_id}", git_output("cat-file", "-p", object_id)))
    return entries


def iter_history_paths() -> set[str]:
    """Collect historical path names, which are not preserved by blob-only scans."""
    paths: set[str] = set()
    for commit in git_output("rev-list", "--all").splitlines():
        paths.update(path for path in git_output("ls-tree", "-r", "--name-only", commit).splitlines() if path)
    return paths


def main() -> int:
    # --history changes the surface from the current checkout to all reachable
    # Git objects; private env options add exact in-memory comparison values.
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="scan every reachable Git object")
    parser.add_argument("--deployment-env", type=Path, help="scan exact values from a private deployment environment")
    parser.add_argument("--compose-env", type=Path, help="scan exact credential values from a private Compose environment")
    args = parser.parse_args()

    # Keep each private value's matching mode; values never appear in output.
    exact_values: list[tuple[str, str, bool]] = []
    if args.deployment_env:
        for key, value in load_literal_env(args.deployment_env, {
            "NEXTCLOUD_PI_HOST", "NEXTCLOUD_PI_SYSTEM_HOSTNAME", "NEXTCLOUD_PI_USER", "NEXTCLOUD_REMOTE_PROJECT_DIR",
            "NEXTCLOUD_STORAGE_MOUNT", "NEXTCLOUD_STORAGE_UUID", "NEXTCLOUD_PUBLIC_HOSTNAME",
        }).items():
            exact_values.append((value, "deployment_identifier", key in BOUNDED_DEPLOYMENT_KEYS))
    if args.compose_env:
        for key, value in load_literal_env(args.compose_env, {"MYSQL_ROOT_PASSWORD", "MYSQL_PASSWORD", "MYSQL_DATABASE", "MYSQL_USER"}).items():
            if key in {"MYSQL_ROOT_PASSWORD", "MYSQL_PASSWORD"} and len(value) >= 8:
                exact_values.append((value, "live_credential", False))

    # A set de-duplicates repeated matches while retaining a safe reference.
    findings: set[tuple[str, str, str, str]] = set()
    entries = iter_history() if args.history else iter_current()
    for surface, reference, content in entries:
        # First compare known live values, then apply strict generic detectors.
        for value, category, bounded in exact_values:
            if exact_value_matches(content, value, bounded):
                findings.add(("critical", category, surface, reference + ":" + fingerprint(value)))
        for value in EMAIL.findall(content):
            if not is_allowed_email(value):
                findings.add(("sensitive", "personal_email", surface, reference + ":" + fingerprint(value)))
        for value in IPV4.findall(content):
            try:
                address = ipaddress.ip_address(value)
            except ValueError:
                continue
            if not address.is_loopback and not is_documentation_address(address):
                findings.add(("sensitive", "ipv4_address", surface, reference + ":" + fingerprint(value)))
        for value in IPV6.findall(content):
            try:
                address = ipaddress.ip_address(value)
            except ValueError:
                continue
            if isinstance(address, ipaddress.IPv6Address) and not address.is_loopback and not is_documentation_ipv6(address):
                findings.add(("sensitive", "ipv6_address", surface, reference + ":" + fingerprint(value)))
        for value in HOME_PATH.findall(content):
            findings.add(("sensitive", "identity_bearing_home_path", surface, reference + ":" + fingerprint(value)))
        for value in UUID.findall(content):
            findings.add(("sensitive", "storage_identifier", surface, reference + ":" + fingerprint(value)))
        for value in PRIVATE_HOSTNAME.findall(content):
            if value.lower() not in SAFE_NON_HOST_TOKENS:
                findings.add(("sensitive", "private_hostname", surface, reference + ":" + fingerprint(value)))
        if KEY_MATERIAL.search(content):
            findings.add(("critical", "key_or_certificate_material", surface, reference))
        if AUTHORIZATION_HEADER.search(content):
            findings.add(("critical", "authorization_header", surface, reference))
        if COOKIE_HEADER.search(content):
            findings.add(("critical", "cookie_header", surface, reference))
        if CONNECTION_STRING.search(content):
            findings.add(("critical", "connection_string", surface, reference))
        if CREDENTIAL_ASSIGNMENT.search(content):
            findings.add(("critical", "credential_assignment", surface, reference))
        if IDENTITY_DEFAULT.search(content):
            findings.add(("sensitive", "hard_coded_deployment_default", surface, reference))

    # Path policy is checked separately because a forbidden empty file has no
    # content match; history mode includes names from every reachable tree.
    tracked_paths = set(git_output("ls-files", "--cached", "--others", "--exclude-standard").splitlines())
    if args.history:
        tracked_paths.update(iter_history_paths())
    for relative_path in tracked_paths:
        if is_forbidden_path(relative_path):
            findings.add(("critical", "forbidden_tracked_path", "git_history" if args.history else "worktree", "path:" + fingerprint(relative_path)))

    # Output is intentionally tabular and value-free for CI and audit reports.
    for severity, category, surface, reference in sorted(findings):
        print(f"{severity}\t{category}\t{surface}\t{reference}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
