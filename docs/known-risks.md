# Known Risks

These are documented for initial fidelity. Do not treat this first repository version as a cleanup pass.

- The Nextcloud background-job mode remains unknown.
- The recovered live trusted-domain list contained `192.0.2.10`, which appears erroneous. It is not included in deployable configuration.
- `nextcloud.service` does not explicitly require `/mnt/example-storage` before starting.
- Caddy currently targets the generated container name `nextcloud-docker-app-1` instead of the Compose service name.
- Because of that generated target name, the Compose project name must remain `nextcloud-docker` until the Caddy target is intentionally changed.
- Image tags use major versions, such as `nextcloud:30`, `mariadb:11`, and `caddy:2`, rather than immutable versions or digests.
- The live Compose file previously contained inline database credentials. This repository moves those values to `.env`.
- The configuration-only backup workflow does not back up or restore the
  database, Nextcloud application state, uploaded files, or Caddy runtime TLS
  state.
