# Architecture

The current server is a Docker Compose based Nextcloud installation on a Raspberry Pi.

Request flow:

```text
Mac browser or Nextcloud client
        ↓
https://cloud.example.invalid
        ↓
Caddy on ports 80/443
        ↓
Nextcloud application container
        ↓
MariaDB container
```

Caddy provides HTTPS for `cloud.example.invalid` using its internal certificate authority. It reverse proxies traffic to the existing Nextcloud application container target:

```text
nextcloud-docker-app-1:80
```

The Docker Compose project has three services:

- `db`: MariaDB database.
- `app`: Nextcloud application.
- `caddy`: HTTPS reverse proxy.

Storage mappings:

```text
/mnt/example-storage/nextcloud    -> /var/www/html
/mnt/example-storage/nextcloud_db -> /var/lib/mysql
```

Nextcloud reports its data directory as:

```text
/var/www/html/data
```

Because `/var/www/html` is bind-mounted from `/mnt/example-storage/nextcloud`, the host-side data directory is:

```text
/mnt/example-storage/nextcloud/data
```

Caddy uses Docker named volumes for runtime state:

```text
caddy_data   -> /data
caddy_config -> /config
```

The Caddy data volume includes internal TLS authority state and private key material. It must not be committed to Git.

