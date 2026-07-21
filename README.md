# Nextcloud Pi Server

This repository documents and preserves the configuration for an existing working Nextcloud server running on a Raspberry Pi.

The MacBook is the source of truth for documentation, sanitized configuration, and future deployment scripts. A private GitHub repository can later be used for backup and version history of this configuration. The Raspberry Pi remains the live deployment target and host for Nextcloud runtime data.

This Git repository is not a backup of uploaded Nextcloud files, the Nextcloud data directory, or the MariaDB database. Those live data sets require separate backup and restore planning.

Current working URL:

```text
https://cloud.example.invalid
```

Start with:

- `docs/architecture.md` for the overall system shape.
- `docs/current-configuration.md` for confirmed live settings.
- `docs/security-boundaries.md` before adding any new files.
- `docs/known-risks.md` before making improvements.

## Development workflow

This repository keeps the primary checkout on `main` and uses a separate Git
worktree for every task. The complete lifecycle and safety rules are in
[`AGENTS.md`](AGENTS.md).

Create a task worktree from the latest `origin/main`:

```bash
./scripts/worktree-create.sh feat/example-change
```

After its GitHub pull request has merged, remove the clean local worktree and
branch:

```bash
./scripts/worktree-cleanup.sh feat/example-change
```

Cleanup leaves the remote branch unchanged.
