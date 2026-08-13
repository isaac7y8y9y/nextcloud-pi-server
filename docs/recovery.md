# Recovery

Recover only from a verified backup that is bound to the configured deployment
target and project directory. Begin with the read-only validation mode, then
obtain explicit approval before restoring data or restarting services.

The runtime recovery drill targets disposable paths and containers; it must not
write to live Nextcloud, MariaDB, or Caddy state. Treat all recovered data and
temporary extraction directories as sensitive until they are securely removed.

`export-image-recovery.sh` saves the three locked tags from the Pi to a
protected local archive. Verify it offline, then use
`test-image-restore-readiness.sh` against an explicitly isolated Docker socket.
The test records the archive-specific post-load tag IDs in a protected
attestation; it does not assume `docker load` preserves the live source IDs.
`restore-image-recovery.sh --plan/--apply` is the separately approved import
transaction. Its protected, expiring plan shows and binds the archive and
attestation hashes, active-record hash, current tag pointers, container IDs and
images, recovered mappings, target, and exact actions. Apply recaptures that
state before atomically consuming the single-use approval. It preserves prior
tag pointers, switches the protected active-image record only after
verification, and retags/restores the previous state if loading, mapping,
activation, restart, interruption, or health checks fail. Image recovery,
runtime recovery, and configuration deployment are separate approvals.

Normal system shutdown retains container objects with `docker compose stop`.
Image import is intentionally different: after stopping `nextcloud.service`,
the approved recovery transaction explicitly runs `docker compose down` so no
container can retain an old image identity while archive tags are loaded.
