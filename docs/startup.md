# Startup

Docker is the authoritative boot owner because it owns the Compose restart
policies. Its rendered `nextcloud-storage.conf` drop-in and the retained
`nextcloud.service` both use `RequiresMountsFor=` for the configured storage
mount. Containers therefore cannot restart before that mount is ready.

The root-only launcher validates `/etc/nextcloud-pi/active-images.env` before
every image-resolving Compose create or recreate. It resolves the project once
into a root-only temporary snapshot, requires exactly the `app`, `db`, and
`caddy` services with the record's three tags, and starts that same snapshot
with `--pull never`. A changed project file therefore cannot select another
cached image or add a service after validation. The record selects either
normal source IDs or verified archive-recovery IDs.
Docker's automatic restart of an existing container does not resolve a tag or
pull; it remains protected by the Docker mount gate. The systemd stop action
uses `docker compose stop`, not `down`, so shutdown retains the container
objects and their image identities for that automatic restart path.
