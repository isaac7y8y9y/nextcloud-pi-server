# Nextcloud Pi Server

This repository contains sanitized configuration, operational scripts, and
documentation for a Nextcloud deployment. It is not a backup of uploaded
files, database contents, certificates, or runtime state.

## Local deployment identity

Copy `config/deployment.env.example` to `config/deployment.env`, replace every
placeholder locally, and set its mode to `0600`. The file is ignored by Git.
Operational scripts load it without evaluating shell code; environment variables
provided by the caller take precedence.

Use `scripts/render-deployment-config.sh --output-dir <absolute-empty-directory>`
to render Caddy, Compose, systemd, and fstab configuration for review or drift
comparison. Rendering is not an installation procedure; deployment is permitted
only through [the explicitly approved deployment workflow](docs/deployment.md).
Never commit rendered output.

## Development workflow

The permanent checkout stays on `main`; use a named linked worktree for every
change. See [AGENTS.md](AGENTS.md) for the required lifecycle.

Read [security boundaries](docs/security-boundaries.md) before handling backups
or deployment configuration.
