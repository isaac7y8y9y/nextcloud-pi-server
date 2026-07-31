# Deployment

## Current status

Deployment is blocked. The renderer produces protected files for review and
drift comparison, but this repository does not yet provide an approved apply
procedure that atomically installs them and performs rollback and health
checks. Do not copy rendered files onto the Pi or restart services from this
branch.

## Safe preparation

Prepare the ignored local deployment environment from
`config/deployment.env.example`, replace its placeholders, and restrict it to
mode `0600`. Shell-provided `NEXTCLOUD_*` values override that file for
one-off automation. `NEXTCLOUD_REMOTE_PROJECT_DIR` must end in
`nextcloud-docker`; that basename preserves the existing Compose container and
volume names across legacy and current Compose implementations.

The tracked configuration is a template set. Render it into a new, empty,
protected directory for inspection:

```sh
scripts/render-deployment-config.sh --output-dir /absolute/private/output
```

The output root contains `docker-compose.yml` beside `caddy/Caddyfile`, so the
relative Caddy bind source resolves correctly. `systemd/` and `storage/` are
separate review inputs. Rendering does not contact or modify the Pi, and the
output must never be committed.

Database credentials stay in the Pi project’s untracked Compose `.env`.
`scripts/prepare-env-migration.sh --check` is read-only; its `--apply` mode
requires a verified configuration backup and does not restart services.

## Requirements before deployment is unblocked

An installation procedure must provide all of the following before it can be
used:

1. Validate the private deployment file, rendered Compose configuration, and
   exact target identity without printing private values.
2. Create and verify a current configuration backup and a usable runtime
   recovery point outside Git.
3. Compare rendered files with live files and show a value-redacted dry run.
4. Exclude uploaded data, database storage, Caddy runtime volumes, and the
   Pi-only `.env` from every copy or synchronization operation.
5. Obtain explicit approval immediately before replacing live configuration or
   restarting services.
6. Perform health checks for Docker, MariaDB, Nextcloud, HTTPS, storage mounts,
   and maintenance mode.
7. Roll back to the verified backup if installation or health checks fail.

The history-sanitization work in this branch does not authorize a Pi deployment
or service restart.
