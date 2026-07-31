# Backup and rollback

Configuration backups and runtime backups have different security properties.
Configuration backups can contain rendered deployment identifiers and a
credential-bearing Compose environment; runtime backups additionally contain
user data, database dumps, certificates, and private keys.

Keep every backup outside Git, encrypted where available, and readable only by
the operator. Verify a backup with the repository verification scripts before
using it for recovery.

Before a configuration change:

1. Run the read-only preflight with the local deployment environment.
2. Create and verify the appropriate backup.
3. Render and validate the intended configuration in a protected temporary
   directory.
4. Obtain explicit approval before restarting any service.

Rollback restores only from a verified backup to the configured deployment
target. Do not publish backup manifests or raw command output.
