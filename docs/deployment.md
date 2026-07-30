# Deployment

This repository is preparing for future deployment from the Mac to the Raspberry Pi, but deployment is currently blocked.

Planned deployment model:

```text
Mac repository
    ↓ preflight
Remote configuration backup
    ↓
Safe .env preparation
    ↓
Configuration synchronization
    ↓
Remote validation
    ↓
Explicitly approved restart
    ↓
Post-deployment health check
```

The current live Compose file on the Pi contains inline database credentials. The repository version uses `.env` references instead:

```text
MYSQL_ROOT_PASSWORD
MYSQL_PASSWORD
MYSQL_DATABASE
MYSQL_USER
```

That means the repository Compose file must not be deployed over the live file until the Pi has a secure, untracked `.env` file prepared at:

```text
/srv/example/nextcloud-docker/.env
```

Use `compose/.env.example` as the shape of that file, but never commit the real `.env` file.

## Prepare the Pi-only `.env`

After creating and verifying a fresh configuration backup, use the guarded
helper from a feature worktree:

```sh
./scripts/prepare-env-migration.sh --check
./scripts/prepare-env-migration.sh --apply \
  "$HOME/Projects/nextcloud-pi-backups/config-backup-YYYYMMDDTHHMMSSZ"
```

`--check` is read-only. `--apply` first verifies the selected backup, confirms
it is no more than one hour old, and binds it to the connected Pi, user,
project path, and current live Compose file. The backup must remain at the
canonical path recorded in its manifest. The helper then creates a new `0600`
`.env` from the running MariaDB container's existing database environment. It
refuses to overwrite an existing `.env`, suppresses secret values, and does not
replace Compose configuration or restart services. Both modes validate the
resolved live Compose configuration with quiet output. Set
`NEXTCLOUD_BACKUP_MAX_AGE_SECONDS` only when an intentionally reviewed
maintenance window requires a different freshness limit.
The generated values are single-quoted so Docker Compose preserves literal
characters such as `$`. To avoid changing credentials through parser-specific
escaping, the helper refuses values containing a single quote, backslash, or
line break.
Stop and use an intentionally reviewed manual secret-provisioning procedure if
that check fails.
Use `--apply` only after explicitly approving creation of the exact Pi target
file.

Re-run `--check` after the command succeeds. The later deployment phase must
validate a staged copy of the sanitized Compose configuration before it can
replace the current inline-credential Compose file.

Deployment remains blocked until:

1. The live configuration is backed up.
2. A secure untracked `.env` is prepared on the Pi.
3. The repository Compose file is validated on the Pi.
4. A rollback procedure exists.
5. The user explicitly approves restarting the stack.

The preflight script is read-only. It checks whether the Pi is reachable, whether Docker and storage are available, whether the expected containers exist, and whether safe configuration elements still match this repository. It must not restart services, copy files, or print live database credentials.

Deployment must never overwrite or synchronize these live data paths:

```text
/mnt/example-storage/nextcloud
/mnt/example-storage/nextcloud/data
/mnt/example-storage/nextcloud_db
```

Those directories contain the live Nextcloud application state, uploaded user data, and MariaDB database files. They require separate backup and restore procedures, not Git synchronization.

Future deployment work must invoke the verified configuration backup workflow
before any file replacement, then add a validated `.env` migration, a dry-run
comparison, rollback instructions, and a final approval gate before any
restart. See [`backup-and-rollback.md`](backup-and-rollback.md).
