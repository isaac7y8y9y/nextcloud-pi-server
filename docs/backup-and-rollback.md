# Backup and rollback

Configuration and runtime backups are separate protected artifacts. Run these
procedures from the repository root in a clean linked worktree with a valid
mode-`0600` `config/deployment.env`. See [operations](operations.md) for the
worktree and read-only readiness checks.

Configuration backups may contain rendered deployment identifiers and the
credential-bearing Pi Compose `.env`. Runtime backups additionally contain user
data, a database dump, certificates, and private keys. Keep every backup
outside Git, encrypted where available, and readable only by the operator. Do
not publish manifests, archive contents, or raw command output.

## Configuration backup

Creating a configuration backup reads the Pi but does not change it. Choose an
absolute private directory outside every Git worktree:

```sh
export NEXTCLOUD_BACKUP_ROOT=/absolute/private/nextcloud-backups
scripts/preflight.sh --readiness
scripts/backup-config.sh
```

The backup command prints a protected `config-backup-<UTC timestamp>` path. Set
that exact path explicitly; do not obtain it by reading or parsing the private
manifest:

```sh
CONFIG_BACKUP=/absolute/private/nextcloud-backups/config-backup-YYYYMMDDTHHMMSSZ
scripts/verify-config-backup.sh "$CONFIG_BACKUP"
```

Continue only after the verifier prints `Backup verified`. Verification is
offline and repeatable. It proves the closed payload, permissions, sizes,
checksums, and provenance; it does not authorize deployment, migration, or
restore.

A configuration backup used by `prepare-env-migration.sh --apply` or
`deploy-config.sh --plan` must also be fresh and bound to the configured Pi.
Those consumers enforce their own target, pre-state, and age checks.

## Runtime backup

A runtime backup captures the Nextcloud tree, a transaction-consistent MariaDB
dump, and both Caddy runtime volumes. Its check mode is Pi-read-only:

```sh
export NEXTCLOUD_RUNTIME_BACKUP_ROOT=/absolute/private/nextcloud-backups
scripts/backup-runtime-state.sh --check
```

Review the reported prerequisites and aggregate sizes. This command creates no
approval artifact. Stop here until the operator has explicitly approved the
temporary maintenance-mode transition and private local backup creation.

After that human approval pause, create the backup:

```sh
scripts/backup-runtime-state.sh --apply
```

`--apply` enables Nextcloud maintenance mode only while capturing consistent
state, disables it before publishing the artifact, verifies the completed
backup offline, and prints a protected `runtime-backup-<UTC timestamp>` path.
Set and reverify that exact path:

```sh
RUNTIME_BACKUP=/absolute/private/nextcloud-backups/runtime-backup-YYYYMMDDTHHMMSSZ
scripts/verify-runtime-backup.sh "$RUNTIME_BACKUP"
```

Continue only after `Runtime backup verified`. A deployment requires the
runtime manifest to be no more than one hour old when its plan is created. The
timestamp is recorded when capture begins, so recreate the backup if a long
capture has already exceeded that window.

## Interrupted runtime backup

The runtime backup trap makes a best effort to leave maintenance mode disabled
and prints a recovery command if that cannot be confirmed. Do not run the
following command as a routine step. If and only if the failed backup reports
that maintenance mode may remain enabled, obtain explicit approval for that
recovery mutation and run:

```sh
scripts/backup-runtime-state.sh --maintenance-off
```

The command disables maintenance mode and verifies that it is off. It does not
create a backup. After recovery, restart the runtime-backup procedure at
`--check`; never reuse an incomplete staging directory.

## Prove runtime recoverability

Offline verification proves integrity but not that the archives and database
dump can be restored. Use the separately approved disposable recovery drill in
the [runtime recovery procedure](recovery.md#runtime-recovery-drill). The drill
never targets live Nextcloud, MariaDB, or Caddy paths.

## Rollback boundaries

The configuration deployment transaction carries the verified Compose and
Caddy pre-state from `CONFIG_BACKUP`. If application installation, restart, or
health validation fails, it automatically restores those two files, reloads
systemd, restarts the service, and checks rollback health.

There is no standalone general configuration-restore command and no automated
live runtime-restore command in this repository. A configuration backup must
not be copied over live files manually. A runtime backup has only the disposable
recovery drill described above; live data recovery requires a separately
designed and approved procedure. Image rollback and import are independent and
documented in [recovery](recovery.md#image-recovery-and-restore-readiness).
