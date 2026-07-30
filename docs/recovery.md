# Recovery

## Runtime-state recovery

The configuration backup does not contain a recoverable copy of the Nextcloud
files, MariaDB contents, or Caddy TLS state. Capture those private runtime
assets separately:

```sh
./scripts/backup-runtime-state.sh --check
./scripts/backup-runtime-state.sh --apply
```

`--apply` is an approval-gated maintenance operation. It enables Nextcloud
maintenance mode while it streams the Nextcloud tree, a transaction-consistent
MariaDB dump, and both Caddy volumes into a protected `runtime-backup-*`
directory outside Git. A trap attempts to disable maintenance mode on every
exit. If SSH cleanup fails, immediately run the maintenance-off command printed
by the script.

Verify the exact published directory offline:

```sh
./scripts/verify-runtime-backup.sh \
  "$HOME/Projects/nextcloud-pi-backups/runtime-backup-YYYYMMDDTHHMMSSZ"
```

Exercise recovery without writing to any live path:

```sh
./scripts/test-runtime-recovery.sh --check \
  "$HOME/Projects/nextcloud-pi-backups/runtime-backup-YYYYMMDDTHHMMSSZ"

./scripts/test-runtime-recovery.sh --apply \
  "$HOME/Projects/nextcloud-pi-backups/runtime-backup-YYYYMMDDTHHMMSSZ"
```

The drill restores the Nextcloud and Caddy archives under a disposable,
protected directory on `/mnt/example-storage`, compares them with their archives, imports
MariaDB into a disposable container backed by the same protected test
directory, runs `mariadb-check`, and then verifies removal of every test
target. It never restores over the live Nextcloud tree, database volume, or
Caddy volumes.

Runtime backups contain user files, database records, application secrets,
certificate private keys, and internal host details. Keep every directory and
file private, outside Git, and off issue attachments, screenshots, logs, and
public storage.

High-level recovery order:

1. Install Debian and Docker prerequisites.
2. Restore the `/mnt/example-storage` storage mount.
3. Restore the Nextcloud files under `/mnt/example-storage/nextcloud`.
4. Restore MariaDB data under `/mnt/example-storage/nextcloud_db`.
5. Restore or recreate required secrets.
6. Deploy the sanitized repository configuration to the Pi deployment directory.
7. Start the Docker Compose stack through `nextcloud.service`.
8. Restore Caddy trust on client devices, including the Mac.
9. Verify login, file upload, and file download.

The repository now provides configuration-backup creation and verification plus
a manual, approval-gated configuration rollback procedure in
[`backup-and-rollback.md`](backup-and-rollback.md). It does not restore
uploaded files or the database.
