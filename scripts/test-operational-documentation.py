#!/usr/bin/env python3
"""Keep operator runbooks aligned with human-facing script contracts."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def require(text: str, value: str, context: str) -> None:
    if value not in text:
        raise AssertionError(f"{context} is missing {value!r}")


def require_order(text: str, values: tuple[str, ...], context: str) -> None:
    position = -1
    for value in values:
        next_position = text.find(value, position + 1)
        if next_position < 0:
            raise AssertionError(f"{context} is missing ordered value {value!r}")
        position = next_position


def main() -> int:
    deployment = read("docs/deployment.md")
    backup = read("docs/backup-and-rollback.md")
    recovery = read("docs/recovery.md")
    operations = read("docs/operations.md")
    agents = read("AGENTS.md")

    canonical_coverage = {
        deployment: (
            "render-deployment-config.sh",
            "preflight.sh",
            "prepare-env-migration.sh",
            "test-deploy-transaction.sh",
            "deploy-config.sh",
            "health-check.sh",
        ),
        backup: (
            "backup-config.sh",
            "verify-config-backup.sh",
            "backup-runtime-state.sh",
            "verify-runtime-backup.sh",
        ),
        recovery: (
            "test-runtime-recovery.sh",
            "export-image-recovery.sh",
            "verify-image-recovery.sh",
            "run-image-restore-readiness.sh",
            "test-image-restore-readiness.sh",
            "restore-image-recovery.sh",
            "health-check.sh",
        ),
        operations: (
            "check-documentation-links.py",
            "test-documentation-links.py",
            "test-operational-documentation.py",
            "check-public-safety.py",
            "test-public-safety.py",
            "test-public-config.sh",
        ),
        agents: ("worktree-create.sh", "worktree-cleanup.sh"),
    }
    for document, scripts in canonical_coverage.items():
        for script in scripts:
            require(document, script, "canonical operator documentation")

    require_order(
        deployment,
        (
            "scripts/deploy-config.sh --plan",
            '"$CONFIG_BACKUP"',
            '"$RUNTIME_BACKUP"',
            '"$IMAGE_RECOVERY"',
            "scripts/deploy-config.sh --apply",
            '"$APPROVAL_ARTIFACT"',
            '"$CONFIG_BACKUP"',
            '"$RUNTIME_BACKUP"',
            '"$IMAGE_RECOVERY"',
        ),
        "deployment plan/apply contract",
    )
    deployer = read("scripts/deploy-config.sh")
    require(
        deployer,
        "--plan <config-backup> <runtime-backup> <image-recovery>",
        "deploy script usage",
    )
    require(
        deployer,
        "--apply <approval-artifact> <config-backup> <runtime-backup> <image-recovery>",
        "deploy script usage",
    )

    require_order(
        recovery,
        (
            'restore-image-recovery.sh --plan "$IMAGE_RECOVERY"',
            "IMAGE_IMPORT_APPROVAL=",
            "restore-image-recovery.sh --apply",
            '"$IMAGE_IMPORT_APPROVAL"',
            '"$IMAGE_RECOVERY"',
        ),
        "image import plan/apply contract",
    )
    importer = read("scripts/restore-image-recovery.sh")
    require(
        importer,
        "--plan <recovery-directory> | --apply <approval-artifact> <recovery-directory>",
        "image import script usage",
    )

    for mode in ("--check", "--apply", "--cleanup"):
        require(recovery, f"run-image-restore-readiness.sh {mode}", "readiness lifecycle runbook")
        require(
            read("scripts/run-image-restore-readiness.sh"),
            f"run-image-restore-readiness.sh {mode}",
            "readiness lifecycle usage",
        )

    required_safety_language = (
        "human approval pause",
        "not human approval by itself",
        "single-use",
        "15 minutes",
        "one hour old",
        "There is no script that restores a runtime backup into live",
        "consumed approval cannot be replayed",
    )
    combined_runbooks = " ".join("\n".join((deployment, backup, recovery)).split())
    for phrase in required_safety_language:
        require(combined_runbooks, phrase, "operator safety contract")

    # A shell command documented without an interpreter wrapper is promised as
    # directly executable. Keep that promise synchronized with its mode bits.
    documentation_paths = [ROOT / "AGENTS.md", *sorted((ROOT / "docs").glob("*.md"))]
    direct_shell_commands: set[str] = set()
    for documentation_path in documentation_paths:
        direct_shell_commands.update(
            re.findall(
                r"(?m)^[ \t]*(?:\./)?(scripts/[A-Za-z0-9._-]+\.sh)\b",
                documentation_path.read_text(encoding="utf-8"),
            )
        )
    for relative_path in sorted(direct_shell_commands):
        script_path = ROOT / relative_path
        if not script_path.is_file():
            raise AssertionError(f"documented executable does not exist: {relative_path}")
        if script_path.stat().st_mode & 0o111 == 0:
            raise AssertionError(f"documented command is not executable: {relative_path}")

    print("operational documentation contract tests passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AssertionError as error:
        print(f"operational documentation contract failed: {error}", file=sys.stderr)
        sys.exit(1)
