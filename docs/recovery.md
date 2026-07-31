# Recovery

Recover only from a verified backup that is bound to the configured deployment
target and project directory. Begin with the read-only validation mode, then
obtain explicit approval before restoring data or restarting services.

The runtime recovery drill targets disposable paths and containers; it must not
write to live Nextcloud, MariaDB, or Caddy state. Treat all recovered data and
temporary extraction directories as sensitive until they are securely removed.
