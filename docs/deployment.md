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

Future deployment work should add an explicit remote backup step before any file replacement, a validated `.env` migration, a dry-run comparison, rollback instructions, and a final approval gate before any restart.

