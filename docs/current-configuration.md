# Configuration model

Deployment-specific configuration is intentionally not recorded as a live
baseline in Git. The local `config/deployment.env` supplies the Pi connection,
project directory, storage mount and UUID, and public hostname.

The Pi-only Compose `.env` file contains only the MariaDB/Nextcloud credential
variables declared in `compose/.env.example`. It is separate from the local
deployment environment and must remain mode `0600` and untracked.

To compare tracked intent with the live deployment, follow the
[read-only Pi checks](operations.md#read-only-pi-checks). Readiness mode permits
only the reviewed candidate transition before deployment; conformance mode
requires the hardened live state to match without checked drift. Both modes
render sanitized templates locally and compare them to the remote configuration
without printing credential values.

`/etc/nextcloud-pi/active-images.env` is Pi-local, root-owned state. It selects
the allowed image IDs for the next image-resolving start; it is never tracked or
edited manually. The deployment transaction installs source mode, while the
separately approved archive-import transaction may install recovered mode.
