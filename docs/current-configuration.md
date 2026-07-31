# Configuration model

Deployment-specific configuration is intentionally not recorded as a live
baseline in Git. The local `config/deployment.env` supplies the Pi connection,
project directory, storage mount and UUID, and public hostname.

The Pi-only Compose `.env` file contains only the MariaDB/Nextcloud credential
variables declared in `compose/.env.example`. It is separate from the local
deployment environment and must remain mode `0600` and untracked.

To compare tracked intent with the live deployment, run
`scripts/preflight.sh`. It renders sanitized templates locally and compares
them to the remote configuration without printing credential values.
