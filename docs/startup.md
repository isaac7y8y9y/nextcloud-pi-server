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

## Background jobs

`nextcloud-background-jobs.timer` runs a root-owned oneshot every five minutes
while the Pi is on. It waits ten minutes after boot, requires the storage
mount, and runs `cron.php` inside the existing app container as `www-data`.
It never starts a deliberately stopped Nextcloud stack, pulls an image, or
creates a container. A normal nightly shutdown simply pauses the monotonic
timer; processing resumes after the next boot.

Runtime backups pause future ticks and wait for any in-flight job to finish
before entering maintenance mode, then restore the timer's prior active state.

## Privileged startup boundary

Systemd invokes the root-owned launcher and active-image validator directly.
Routine Mac-to-Pi automation has no general-purpose passwordless sudo access:
its only privileged entry point is
`sudo -n /usr/local/libexec/nextcloud-pi-ops service ACTION`, where `ACTION`
is the fixed `start`, `stop`, or `restart` action for `nextcloud.service`.
The dispatcher rechecks the configured storage mount and UUID before a start
or restart. It cannot accept a unit name, path, shell command, or daemon flag.

The helper, launcher, validator, systemd unit/drop-in, policy, and sudoers
rule are installed or upgraded only through the separately authenticated
privileged-interface administrator workflow. Routine configuration deployment
cannot replace startup-related root code.
