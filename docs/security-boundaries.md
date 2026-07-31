# Security boundaries

Never track or publish:

- database credentials, Nextcloud secrets, API tokens, or cookies;
- uploaded files, database files or dumps, certificates, private keys, or Caddy
  runtime volumes;
- deployment usernames, hostnames, IP addresses, project paths, storage device
  identifiers, or personal email addresses;
- raw reports, generated configuration, backup archives, or local environment
  files.

The tracked templates require the ignored deployment environment at render time.
The Pi-only Compose environment remains a separate mode-`0600` credential
file. GitHub noreply addresses, explicit placeholders, and documentation IP
ranges are allowed in public-safe material.

During the pre-rewrite remediation phase, CI enforces the proposed worktree and
Gitleaks scans reachable history. The stricter
`scripts/check-public-safety.py --history` gate remains intentionally disabled
until the coordinated history rewrite removes known legacy identifiers from
every retained ref; it must be enabled and pass before remediation is complete.
