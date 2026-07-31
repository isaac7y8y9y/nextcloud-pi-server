# Known risks

- Nextcloud must not start before its configured storage mount is available.
  Otherwise the host can create unintended local directories.
- Runtime backups contain private user data, database material, and TLS state;
  they require stricter handling than configuration backups.
- Compose image tags are version families rather than immutable digests.
- Deployment identity and credentials must stay in ignored local files, never
  in Git history, issues, pull requests, or generated reports.

Run preflight and verify a backup before operational changes.
