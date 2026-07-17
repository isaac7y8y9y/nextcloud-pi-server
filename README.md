# Nextcloud Pi Server

This repository documents and preserves the configuration for an existing working Nextcloud server running on a Raspberry Pi.

The MacBook is the source of truth for documentation, sanitized configuration, and future deployment scripts. A private GitHub repository can later be used for backup and version history of this configuration. The Raspberry Pi remains the live deployment target and host for Nextcloud runtime data.

This Git repository is not a backup of uploaded Nextcloud files, the Nextcloud data directory, or the MariaDB database. Those live data sets require separate backup and restore planning.

Current working URL:

```text
https://cloud.example.invalid
```

Start with:

- `docs/architecture.md` for the overall system shape.
- `docs/current-configuration.md` for confirmed live settings.
- `docs/security-boundaries.md` before adding any new files.
- `docs/known-risks.md` before making improvements.

