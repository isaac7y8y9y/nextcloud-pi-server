# Architecture

The deployment has three Compose services:

- MariaDB stores Nextcloud metadata on the configured storage mount.
- Nextcloud serves the application and uploaded-data directory.
- Caddy terminates HTTPS and proxies to the application service.

The tracked Compose file, Caddyfile, systemd unit, and fstab entry are
templates. `scripts/render-deployment-config.sh` substitutes values from the
ignored local deployment environment into a protected output directory. The
rendered output places `docker-compose.yml` beside `caddy/Caddyfile` so the
relative bind source is self-consistent; systemd and fstab remain separate
review inputs. Rendered files, database credentials, runtime volumes, and user
data must remain outside Git.

The configured project directory must end in `nextcloud-docker`. Both legacy
and current Compose derive the project name from that basename, and operational
scripts rely on the resulting stable container and volume names. The parent
path and all other deployment-specific identities remain local inputs only.
