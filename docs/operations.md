# Operations

Run operational scripts from a clean linked worktree with a valid local
deployment environment. The scripts use non-interactive SSH and validate input
syntax before contacting the deployment target.

`scripts/preflight.sh` is read-only. Backup and recovery scripts require
separate explicit approval for mutation or restart operations. Preserve the
generated reports and backup manifests outside Git because they may identify
the deployment.

Use `scripts/check-public-safety.py` before publishing changes. It emits only
redacted finding references and fingerprints.
