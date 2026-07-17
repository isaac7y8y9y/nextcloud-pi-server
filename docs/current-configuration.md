# Current Configuration

This document records confirmed facts from the working Raspberry Pi installation as of the staged discovery material from 2026-07-17.

## Confirmed Facts

Docker Compose project:

```text
Project name: nextcloud-docker
Pi directory: /srv/example/nextcloud-docker
Compose file: /srv/example/nextcloud-docker/docker-compose.yml
```

The Compose project name must remain `nextcloud-docker` while Caddy proxies to `nextcloud-docker-app-1:80`. That target is a Compose-generated container name. Running the same Compose file under a different project name may create a differently named application container and break Caddy proxying.

Changing the Caddy target to the Compose service name `app:80` is a possible future improvement, but this baseline preserves the working architecture.

Services:

```text
db
app
caddy
```

Images:

```text
db:    mariadb:11
app:   nextcloud:30
caddy: caddy:2
```

Nextcloud status:

```text
Installed version: 30.0.17
Maintenance mode: disabled
Database upgrade required: no
```

Restart policies:

```text
nextcloud-docker-app-1   unless-stopped
nextcloud-docker-db-1    always
nextcloud-docker-caddy-1 unless-stopped
```

Published ports:

```text
app:   8080:80
caddy: 80:80
caddy: 443:443
```

Bind mounts:

```text
/mnt/example-storage/nextcloud    -> /var/www/html
/mnt/example-storage/nextcloud_db -> /var/lib/mysql
```

Caddy volumes:

```text
caddy_data
caddy_config
```

Working hostname:

```text
cloud.example.invalid
```

Working Caddy route:

```text
cloud.example.invalid -> nextcloud-docker-app-1:80
```

The live deployment also requires an untracked environment file at:

```text
/srv/example/nextcloud-docker/.env
```

Create that file from `compose/.env.example` and fill in the real database values only on the deployment target. The real `.env` file must remain excluded from Git.

## Unresolved Items

The Nextcloud background-job mode is unknown. The previous discovery command did not return the mode.

The live trusted-domain list included a recovered legacy anomaly, `192.0.2.10`, which appears erroneous. It is not included in deployable configuration here.
