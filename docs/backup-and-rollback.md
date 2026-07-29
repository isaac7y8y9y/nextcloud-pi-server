# Configuration Backup and Rollback

This workflow creates and verifies a recovery point for **configuration only**.
It does not back up or restore the MariaDB database, Nextcloud application
state, uploaded files, the Nextcloud data directory, Caddy runtime volumes, or
certificates. Those need separate recovery projects.

The backup includes the live Compose file, the matching live `.env` file when
one already exists, the Caddyfile, the Nextcloud systemd unit, the active
`/mnt/example-storage` fstab entry, and safe Compose, container, mount, and Nextcloud
metadata. The Compose and `.env` files may contain credentials. Backups are
therefore private operational material: do not email them, attach them to
issues, or add them to Git.

## Create and verify a backup

From the feature worktree on the Mac, run:

```sh
./scripts/backup-config.sh
```

The script reads the Pi over SSH and creates an atomically published directory
under `${NEXTCLOUD_BACKUP_ROOT:-$HOME/Projects/nextcloud-pi-backups}`. It uses
`0700` directories and `0600` files. It copies credential-bearing files
directly into that directory without printing their contents. An interrupted or
failed collection is removed as an `.incomplete-...` staging directory and is
never published as a backup.

Set the documented connection variables only when the defaults are not right:

```sh
NEXTCLOUD_PI_HOST=ssh-host.example.invalid \
NEXTCLOUD_PI_USER=example-operator \
NEXTCLOUD_BACKUP_ROOT="$HOME/Projects/nextcloud-pi-backups" \
./scripts/backup-config.sh
```

Before treating a backup as usable, verify its exact directory:

```sh
./scripts/verify-config-backup.sh \
  "$HOME/Projects/nextcloud-pi-backups/config-backup-YYYYMMDDTHHMMSSZ"
```

Verification is local and read-only. It rejects incomplete directories, bad
permissions, missing, unexpected, or symbolic-link payloads, checksum or size
mismatches, and any backup located in a Git worktree.

## Manual rollback procedure

This is a validation-driven manual procedure. Do not restart a service or
container until every validation below succeeds and the owner has explicitly
approved the restart.

1. Stop immediately if current deployment validation fails. Do not use rollback
   as a way to bypass an unexplained failure.
2. Preserve the current live configuration as a new, separately verified
   backup. Never overwrite the selected recovery point or the live files in
   place without a current recovery copy.
3. Verify the selected backup locally with `verify-config-backup.sh`. Stop on
   any failure.
4. On the Pi, copy only these configuration files from the backup into a
   prepared temporary location: `compose/docker-compose.yml`, `compose/.env`
   when present, `caddy/Caddyfile`, `systemd/nextcloud.service`, and
   `storage/fstab-entry.txt`. Do not copy `metadata/`, data directories,
   databases, Caddy volumes, or certificates.
5. Compare the temporary files with the intended live targets. Restore the
   Compose file to `/srv/example/nextcloud-docker/docker-compose.yml`,
   the matching `.env` file to `/srv/example/nextcloud-docker/.env`
   only when the selected backup contains it, the Caddyfile to
   `/srv/example/nextcloud-docker/caddy/Caddyfile`,
   and the systemd unit to `/etc/systemd/system/nextcloud.service`. Apply the
   saved fstab entry only after confirming it is the one intended for
   `/mnt/example-storage`; do not replace unrelated fstab entries.
6. Restore the ownership and permissions required by the existing deployment.
   Confirm them from the preserved current configuration rather than guessing.
   Keep credential-bearing Compose files non-world-readable.
7. Validate without restart. In the project directory, use `docker compose
   config` when `docker compose version` succeeds; otherwise use the deployed
   `/usr/local/bin/docker-compose config`. Validate the restored mounted
   Caddyfile through the existing Caddy container with `docker exec
   nextcloud-docker-caddy-1 caddy validate --config /etc/caddy/Caddyfile
   --adapter caddyfile`. Then run `systemd-analyze verify` for the unit,
   `findmnt --verify --fstab` for fstab, and read-only Nextcloud `occ status`,
   data-directory, and trusted-domain checks.
8. Run `./scripts/preflight.sh` from this repository. Stop on every hard
   failure or unexpected drift.
9. Obtain explicit user approval for the exact restart action. Approval must
   name the systemd/Compose action and confirm that all preceding validation
   passed. Without that approval, leave services running and investigate.
10. Only after approval, perform the minimum necessary restart. Then run the
    preflight again and perform post-restart health checks: container state,
    `/mnt/example-storage` mount, Nextcloud `occ status`, and an HTTPS request to
    `https://cloud.example.invalid`.

If any restore validation or post-restart health check fails, stop and preserve
the evidence. Do not attempt database, application-data, or user-data recovery
through this configuration workflow.
