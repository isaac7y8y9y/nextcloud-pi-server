# Startup

The live systemd service is named:

```text
nextcloud.service
```

It starts the Docker Compose stack from:

```text
/srv/example/nextcloud-docker
```

This directory name is also important for the current Caddy setup. Caddy proxies to `nextcloud-docker-app-1:80`, which is the application container name produced by the `nextcloud-docker` Compose project. Running the stack from a different project name may produce a different container name and break HTTPS proxying.

Changing Caddy to target the Compose service name `app:80` is a possible future improvement. It is intentionally not changed in this baseline.

Start command:

```text
/usr/local/bin/docker-compose up -d
```

Stop command:

```text
/usr/local/bin/docker-compose down
```

The live deployment needs an untracked file at:

```text
/srv/example/nextcloud-docker/.env
```

Use `compose/.env.example` as the template, then enter the real values on the Pi. Do not commit the real `.env` file.

The unit is `Type=oneshot` with `RemainAfterExit=yes`. Seeing `active (exited)` is expected because systemd starts the Compose stack and then the Docker containers continue running independently.

Docker restart policies also help keep containers running:

```text
app:   unless-stopped
db:    always
caddy: unless-stopped
```

Known startup risk: the service depends on Docker, but it does not explicitly require `/mnt/example-storage` to be mounted first. If Nextcloud starts before the storage mount is available, Docker or the host may create ordinary local directories at the expected mount paths. That can lead to confusing state and should be addressed in a future improvement.
