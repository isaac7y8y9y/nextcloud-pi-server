#!/usr/bin/env python3
"""Small, value-safe regression tests for the public-safety scanner."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path


# Load the scanner as a module so these tests exercise its real regexes/helpers.
sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("check-public-safety.py")
SPEC = importlib.util.spec_from_file_location("public_safety", SCRIPT)
assert SPEC and SPEC.loader
SCANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCANNER)


def main() -> None:
    # Generic detectors should catch unsafe forms but allow Compose references.
    assert SCANNER.CREDENTIAL_ASSIGNMENT.search("API_TOKEN=" + "test-token-value")
    assert not SCANNER.CREDENTIAL_ASSIGNMENT.search("MYSQL_PASSWORD=${MYSQL_PASSWORD}")
    assert SCANNER.KEY_MATERIAL.search("-----BEGIN " + "PRIVATE KEY-----")
    assert SCANNER.AUTHORIZATION_HEADER.search("Authorization: Bearer " + "test-token-value")
    assert SCANNER.CONNECTION_STRING.search("mysql://user:" + "test-password@db.example.invalid")

    # Documentation ranges and GitHub noreply attribution remain intentional allowlists.
    documented_ipv6 = SCANNER.IPV6.findall("2001:db8::1")
    assert documented_ipv6
    assert SCANNER.is_documentation_ipv6(__import__("ipaddress").ip_address(documented_ipv6[0]))
    assert SCANNER.is_allowed_email("person" + "@example.invalid")
    assert SCANNER.is_allowed_email("42550425+account@users.noreply.github.com")

    # Short identities match as standalone tokens, not inside variable names,
    # placeholders, or longer usernames.
    assert SCANNER.exact_value_matches("ssh pi@example.invalid", "pi", True)
    assert not SCANNER.exact_value_matches("NEXTCLOUD_PI_HOST", "pi", True)
    assert not SCANNER.exact_value_matches("pi-user", "pi", True)
    assert SCANNER.exact_value_matches("/srv/example-nextcloud/config", "/srv/example-nextcloud", False)

    forbidden_paths = (
        "backup.sql.gz",
        "runtime.tar.gz",
        "old.bak",
        "compose/.env.production",
        "config/deployment.env",
        "nextcloud/data/user/files/photo.jpg",
        "staging/output.txt",
        "caddy_data/certificates/item.json",
    )
    assert all(SCANNER.is_forbidden_path(path) for path in forbidden_paths)
    assert not SCANNER.is_forbidden_path("compose/.env.example")
    assert not SCANNER.is_forbidden_path("docs/backup-and-rollback.md")

    # Exercise private Compose parsing with an ephemeral 0600 file only.
    with tempfile.TemporaryDirectory() as temporary_directory:
        env_file = Path(temporary_directory) / ".env"
        env_file.write_text(
            "\n".join(
                (
                    "MYSQL_ROOT_PASSWORD=" + "'test-root-password'",
                    "MYSQL_PASSWORD=" + "'test-user-password'",
                    "MYSQL_DATABASE=" + "'nextcloud'",
                    "MYSQL_USER=" + "'nextcloud'",
                )
            )
            + "\n",
            encoding="utf-8",
        )
        env_file.chmod(0o600)
        values = SCANNER.load_literal_env(
            env_file,
            {"MYSQL_ROOT_PASSWORD", "MYSQL_PASSWORD", "MYSQL_DATABASE", "MYSQL_USER"},
        )
        assert values["MYSQL_ROOT_PASSWORD"] == "test-root-password"
        # A permissions regression must fail rather than silently scan secrets.
        env_file.chmod(0o644)
        try:
            SCANNER.load_literal_env(env_file, {"MYSQL_ROOT_PASSWORD", "MYSQL_PASSWORD", "MYSQL_DATABASE", "MYSQL_USER"})
        except ValueError:
            pass
        else:
            raise AssertionError("expected non-0600 private environment file to be rejected")

    print("public-safety scanner tests passed")


if __name__ == "__main__":
    main()
