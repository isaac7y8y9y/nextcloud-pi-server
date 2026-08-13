# Deployment

## Current status

Deployment is controlled by `scripts/deploy-config.sh`. `--plan` is read-only
on the Pi and requires fresh verified configuration, runtime, and image-recovery
artifacts; it binds their manifest hashes, the candidate, the Pi pre-state, and
both UTC clocks into one protected approval artifact. The artifact expires after
15 minutes and rejects clock skew over 60 seconds. `--apply <artifact> ...`
consumes that artifact before any remote mutation and cannot be replayed. It is
never an authorization to create recovery material, import an image, or recover
runtime data.

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

## Controlled rollout

Before `--plan`, create and verify configuration, runtime, and image-recovery
artifacts under their separately approved procedures. Confirm the exact plan,
artifact fingerprint, restart, and rollback authority, then run the one-time
apply with those same artifacts. `scripts/health-check.sh` verifies storage, locked images, service
health, no direct app port, Caddy, Nextcloud, and HTTPS without exposing
credentials.

Before a live deployment, run `scripts/test-deploy-transaction.sh --check`
and, under explicit approval, `--apply`. Apply creates a uniquely named `/tmp`
directory and harmless test units only. It forces a dependency failure after a
disposable replacement, proves rollback and that its marker did not run, then
removes every test artifact. It does not access live Nextcloud configuration,
Docker containers, images, volumes, mounts, runtime data, or `.env`.

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
7. Restore only verified configuration following a failed application change;
   runtime recovery is always separately approved.
