#!/usr/bin/env python3
"""Keep operator runbooks aligned with human-facing script contracts."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# Every top-level executable interface must remain intentionally classified.
# Operator commands require a canonical document and ordered invocation
# fragments; internal regression helpers must be named explicitly instead of
# disappearing behind a filename convention.
OPERATOR_CONTRACTS: dict[str, tuple[str, tuple[str, ...]]] = {
    "backup-config.sh": (
        "docs/backup-and-rollback.md",
        ("scripts/backup-config.sh",),
    ),
    "backup-runtime-state.sh": (
        "docs/backup-and-rollback.md",
        (
            "scripts/backup-runtime-state.sh --check",
            "scripts/backup-runtime-state.sh --apply",
            "scripts/backup-runtime-state.sh --maintenance-off",
        ),
    ),
    "check-documentation-links.py": (
        "docs/operations.md",
        ("python3 scripts/check-documentation-links.py",),
    ),
    "check-public-safety.py": (
        "docs/operations.md",
        (
            "python3 scripts/check-public-safety.py",
            "python3 scripts/check-public-safety.py --history",
        ),
    ),
    "deploy-config.sh": (
        "docs/deployment.md",
        ("scripts/deploy-config.sh --plan", "scripts/deploy-config.sh --apply"),
    ),
    "export-image-recovery.sh": (
        "docs/recovery.md",
        ("scripts/export-image-recovery.sh --output-root",),
    ),
    "health-check.sh": ("docs/operations.md", ("scripts/health-check.sh",)),
    "preflight.sh": (
        "docs/operations.md",
        ("scripts/preflight.sh --readiness", "scripts/preflight.sh --conformance"),
    ),
    "prepare-env-migration.sh": (
        "docs/deployment.md",
        (
            "scripts/prepare-env-migration.sh --check",
            "scripts/prepare-env-migration.sh --apply",
        ),
    ),
    "render-deployment-config.sh": (
        "docs/deployment.md",
        ("scripts/render-deployment-config.sh --output-dir",),
    ),
    "restore-image-recovery.sh": (
        "docs/recovery.md",
        (
            "scripts/restore-image-recovery.sh --plan",
            "scripts/restore-image-recovery.sh --apply",
        ),
    ),
    "run-image-restore-readiness.sh": (
        "docs/recovery.md",
        (
            "scripts/run-image-restore-readiness.sh --check",
            "scripts/run-image-restore-readiness.sh --apply",
            "scripts/run-image-restore-readiness.sh --cleanup",
        ),
    ),
    "test-deploy-transaction.sh": (
        "docs/deployment.md",
        (
            "scripts/test-deploy-transaction.sh --check",
            "scripts/test-deploy-transaction.sh --apply",
        ),
    ),
    "test-documentation-links.py": (
        "docs/operations.md",
        ("python3 scripts/test-documentation-links.py",),
    ),
    "test-operational-documentation.py": (
        "docs/operations.md",
        ("python3 scripts/test-operational-documentation.py",),
    ),
    "test-public-config.sh": (
        "docs/operations.md",
        ("bash scripts/test-public-config.sh",),
    ),
    "test-public-safety.py": (
        "docs/operations.md",
        ("python3 scripts/test-public-safety.py",),
    ),
    "test-runtime-recovery.sh": (
        "docs/recovery.md",
        (
            "scripts/test-runtime-recovery.sh --check",
            "scripts/test-runtime-recovery.sh --apply",
            "scripts/test-runtime-recovery.sh --cleanup",
        ),
    ),
    "verify-config-backup.sh": (
        "docs/backup-and-rollback.md",
        ("scripts/verify-config-backup.sh",),
    ),
    "verify-image-recovery.sh": (
        "docs/recovery.md",
        (
            "scripts/verify-image-recovery.sh \"$IMAGE_RECOVERY\"",
            "scripts/verify-image-recovery.sh --require-attestation",
        ),
    ),
    "verify-runtime-backup.sh": (
        "docs/backup-and-rollback.md",
        ("scripts/verify-runtime-backup.sh",),
    ),
    "worktree-cleanup.sh": ("AGENTS.md", ("./scripts/worktree-cleanup.sh",)),
    "worktree-create.sh": ("AGENTS.md", ("./scripts/worktree-create.sh",)),
}

INTERNAL_SCRIPTS = {
    "check-compose-env-references.sh",
    "test-active-images.sh",
    "test-atomic-transaction.sh",
    "test-compose-env-references.sh",
    "test-compose-launcher.sh",
    "test-deploy-config.sh",
    "test-deployment-config.sh",
    "test-health-check.sh",
    "test-image-import-transaction.sh",
    "test-image-import.sh",
    "test-image-lock.sh",
    "test-image-readiness-lifecycle.sh",
    "test-image-recovery-attestation.sh",
    "test-image-restore-readiness.sh",
    "test-preflight.sh",
    "test-runtime-recovery-regression.sh",
}


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

    discovered_scripts = {
        path.name
        for path in (ROOT / "scripts").iterdir()
        if path.is_file() and path.suffix in {".sh", ".py"}
    }
    classified_scripts = set(OPERATOR_CONTRACTS) | INTERNAL_SCRIPTS
    if discovered_scripts != classified_scripts:
        unclassified = sorted(discovered_scripts - classified_scripts)
        missing = sorted(classified_scripts - discovered_scripts)
        raise AssertionError(
            f"script classification drift; unclassified={unclassified}, missing={missing}"
        )
    if set(OPERATOR_CONTRACTS) & INTERNAL_SCRIPTS:
        raise AssertionError("operator and internal script classifications overlap")

    for script, (document_path, invocation_fragments) in OPERATOR_CONTRACTS.items():
        require_order(
            read(document_path),
            invocation_fragments,
            f"{script} operator command contract in {document_path}",
        )

    # This low-level implementation is deliberately not an operator entry
    # point, but recovery documentation must still explain its socket and
    # attestation role through the guarded lifecycle owner.
    require(recovery, "test-image-restore-readiness.sh", "readiness implementation documentation")

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
