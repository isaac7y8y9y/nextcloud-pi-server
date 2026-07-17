# Recovery

High-level recovery order:

1. Install Debian and Docker prerequisites.
2. Restore the `/mnt/example-storage` storage mount.
3. Restore the Nextcloud files under `/mnt/example-storage/nextcloud`.
4. Restore MariaDB data under `/mnt/example-storage/nextcloud_db`.
5. Restore or recreate required secrets.
6. Deploy the sanitized repository configuration to the Pi deployment directory.
7. Start the Docker Compose stack through `nextcloud.service`.
8. Restore Caddy trust on client devices, including the Mac.
9. Verify login, file upload, and file download.

Detailed backup and restore automation is future work. This repository currently documents the live architecture and stores sanitized configuration; it does not by itself restore uploaded files or the database.

