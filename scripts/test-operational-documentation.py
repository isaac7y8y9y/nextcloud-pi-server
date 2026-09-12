#!/usr/bin/env python3
"""Keep testing inventory, runner, workflow, and operator runbooks aligned."""

from __future__ import annotations

import re
import shlex
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INVENTORY_START = "<!-- test-inventory:start -->"
INVENTORY_END = "<!-- test-inventory:end -->"
TIERS = {"PR-direct", "PR-transitive", "Operator-only"}
EXPECTED_PR_COMMANDS = (
    "bash -n scripts/*.sh scripts/lib/*.sh privileged/nextcloud-pi-ops privileged/nextcloud-pi-bundle-installer systemd/nextcloud-pi-validate-active-images",
    "bash scripts/test-privileged-helper.sh",
    "bash scripts/test-privileged-installer.sh",
    "bash scripts/test-privileged-locks.sh",
    "bash scripts/test-privileged-sudoers.sh",
    "bash scripts/check-privileged-sudo-calls.sh",
    "bash scripts/test-deployment-config.sh",
    "bash scripts/test-compose-env-references.sh",
    "bash scripts/test-image-lock.sh",
    "bash scripts/test-active-images.sh",
    "bash scripts/test-compose-launcher.sh",
    "bash scripts/test-atomic-transaction.sh",
    "bash scripts/test-image-import.sh",
    "bash scripts/test-image-import-transaction.sh",
    "bash scripts/test-image-import-interruption.sh",
    "bash scripts/test-image-recovery-attestation.sh",
    "bash scripts/test-image-readiness-lifecycle.sh",
    "bash scripts/test-runtime-recovery-regression.sh",
    "bash scripts/test-ssh-keepalive.sh",
    "bash scripts/test-deploy-config.sh",
    "bash scripts/test-health-check.sh",
    "bash scripts/test-preflight.sh",
    "python3 scripts/test-documentation-links.py",
    "python3 scripts/check-documentation-links.py",
    "python3 scripts/test-operational-documentation.py",
    "python3 scripts/test-public-safety.py",
    "python3 scripts/check-public-safety.py",
    "python3 scripts/check-public-safety.py --history",
    "bash scripts/test-public-config.sh",
)


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


def tracked_test_scripts() -> set[str]:
    result = subprocess.run(
        ["git", "ls-files", "scripts/test-*", "scripts/check-*"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return {line for line in result.stdout.splitlines() if line}


def inventory_rows(testing: str) -> dict[str, str]:
    match = re.search(
        rf"{re.escape(INVENTORY_START)}\n(?P<table>.*?){re.escape(INVENTORY_END)}",
        testing,
        flags=re.DOTALL,
    )
    if not match:
        raise AssertionError("testing guide has no delimited inventory")

    rows: dict[str, str] = {}
    for line in match.group("table").splitlines():
        if not line.startswith("|") or "Script" in line or "---" in line:
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 6:
            raise AssertionError(f"inventory row has {len(cells)} cells: {line}")
        script = cells[0].strip("`")
        if not re.fullmatch(r"scripts/(?:test|check)-[A-Za-z0-9_.-]+\.(?:sh|py)", script):
            raise AssertionError(f"inventory path is not normalized: {script!r}")
        if script in rows:
            raise AssertionError(f"inventory has duplicate row: {script}")
        if cells[-1] not in TIERS:
            raise AssertionError(f"inventory has invalid tier for {script}: {cells[-1]!r}")
        rows[script] = cells[-1]
    return rows


def runner_commands() -> tuple[str, ...]:
    result = subprocess.run(
        [str(ROOT / "scripts/run-tests.sh"), "--list", "pr"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return tuple(line for line in result.stdout.splitlines() if line)


def runner_script_counts(commands: tuple[str, ...]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for command in commands:
        for token in shlex.split(command):
            if re.fullmatch(r"scripts/(?:test|check)-[A-Za-z0-9_.-]+\.(?:sh|py)", token):
                counts[token] = counts.get(token, 0) + 1
    return counts


def verify_testing_governance() -> None:
    testing = read("docs/testing.md")
    rows = inventory_rows(testing)
    tracked = tracked_test_scripts()
    if set(rows) != tracked:
        missing = sorted(tracked - set(rows))
        stale = sorted(set(rows) - tracked)
        raise AssertionError(f"inventory differs from tracked tests: missing={missing}, stale={stale}")

    commands = runner_commands()
    if commands != EXPECTED_PR_COMMANDS:
        raise AssertionError("pull-request runner command order differs from the documented contract")

    counts = runner_script_counts(commands)
    direct = {script for script, tier in rows.items() if tier == "PR-direct"}
    transitive = {script for script, tier in rows.items() if tier == "PR-transitive"}
    operator_only = {script for script, tier in rows.items() if tier == "Operator-only"}
    if set(counts) != direct:
        raise AssertionError(
            f"runner direct scripts differ from inventory: missing={sorted(direct - set(counts))}, "
            f"unexpected={sorted(set(counts) - direct)}"
        )
    for script, count in counts.items():
        expected = 2 if script == "scripts/check-public-safety.py" else 1
        if count != expected:
            raise AssertionError(f"runner invokes {script} {count} times; expected {expected}")
    if transitive & set(counts):
        raise AssertionError(f"runner exposes PR-transitive scripts: {sorted(transitive & set(counts))}")
    if operator_only & set(counts):
        raise AssertionError(f"runner exposes operator-only scripts: {sorted(operator_only & set(counts))}")
    if len(direct) != 27 or len(transitive) != 1 or len(operator_only) != 3:
        raise AssertionError("inventory tier counts differ from the approved 27/1/3 split")

    for value in (
        "scripts/run-tests.sh pr",
        "scripts/run-tests.sh --list pr",
        "No aggregate operator tier exists",
        "#31: Restore hermetic end-to-end image restore-readiness coverage",
    ):
        require(testing, value, "testing guide")


def verify_workflow_delegation() -> None:
    workflow = read(".github/workflows/public-safety.yml")
    require(workflow, "run: bash scripts/run-tests.sh pr", "public-safety workflow")
    if re.search(r"(?m)^\s*(?:bash|python3)\s+scripts/(?:test|check)-", workflow):
        raise AssertionError("public-safety workflow owns an individual repository test command")


def main() -> int:
    deployment = read("docs/deployment.md")
    backup = read("docs/backup-and-rollback.md")
    recovery = read("docs/recovery.md")
    operations = read("docs/operations.md")
    testing = read("docs/testing.md")
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
        operations: ("scripts/run-tests.sh", "testing.md"),
        testing: (
            "scripts/test-deploy-transaction.sh --check",
            "scripts/run-image-restore-readiness.sh --check",
            "scripts/test-runtime-recovery.sh --check",
        ),
        agents: ("worktree-create.sh", "worktree-cleanup.sh"),
    }
    for document, scripts in canonical_coverage.items():
        for script in scripts:
            require(document, script, "canonical operator documentation")

    verify_testing_governance()
    verify_workflow_delegation()

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
        "--plan|--plan-rollback-test <recovery-directory> | --apply <approval-artifact> <recovery-directory>",
        "image import script usage",
    )
    require(
        recovery,
        'restore-image-recovery.sh --plan-rollback-test "$IMAGE_RECOVERY"',
        "image import rollback-test runbook",
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
        "24 hours old",
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
    except (AssertionError, subprocess.CalledProcessError) as error:
        print(f"operational documentation contract failed: {error}", file=sys.stderr)
        sys.exit(1)
