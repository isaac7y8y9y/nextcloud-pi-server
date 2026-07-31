# Storage

The deployment environment defines the storage mount and device UUID. The
rendered fstab entry mounts it before Nextcloud starts.

The application directory, uploaded-data directory, and MariaDB directory are
derived beneath that local mount and are intentionally excluded from Git.
Database dumps and Caddy runtime volumes are backup material, not repository
content.
