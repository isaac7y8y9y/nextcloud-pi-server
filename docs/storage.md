# Storage

The server depends on the external storage mounted at:

```text
/mnt/example-storage
```

Nextcloud application and state path:

```text
/mnt/example-storage/nextcloud
```

This path is mounted into the application container at:

```text
/var/www/html
```

Nextcloud data directory:

```text
/mnt/example-storage/nextcloud/data
```

This contains uploaded user files and app-managed data. It is not tracked in Git.

MariaDB data path:

```text
/mnt/example-storage/nextcloud_db
```

This is mounted into the database container at:

```text
/var/lib/mysql
```

It contains database files and is not tracked in Git.

Caddy runtime state:

```text
caddy_data
caddy_config
```

These are Docker named volumes mounted at `/data` and `/config` inside the Caddy container. They can contain TLS authority state, private keys, certificates, and runtime configuration. They are not tracked in Git.

Git tracks sanitized configuration and documentation only. User files, database files, Caddy runtime state, certificate material, and backups require separate backup handling.

