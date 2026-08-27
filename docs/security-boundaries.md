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

CI checks both the proposed worktree and all reachable history with
`scripts/check-public-safety.py`. Gitleaks independently scans full history for
secret-like material. Both history gates must pass before publication; a
finding is a security-remediation blocker, not a reason to weaken either rule.
