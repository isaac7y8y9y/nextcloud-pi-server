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
Use the [focused local validation](operations.md#focused-local-validation)
before publication and the canonical GitHub workflow for the full regression
and history gates.

## Least-privilege Pi operations

Routine Mac-to-Pi automation has one passwordless entry point:
`sudo -n /usr/local/libexec/nextcloud-pi-ops`. The root-owned dispatcher reads
only `/etc/nextcloud-pi/privileged-policy.conf`, accepts fixed commands and
logical names, and keeps lifecycle state beneath its root-owned state root.
Dispatcher and installer mutations serialize on non-truncating lock files
beneath root:root mode-`0700` `/run/nextcloud-pi-locks`; neither opens a lock
from the world-writable `/run/lock` namespace.
The root-owned Compose launcher and upgrade-stage consumption also serialize
on a separate protected startup-selection lock through Compose `up`. It is
separate from the dispatcher operations lock so a privileged service start
cannot deadlock waiting for its launcher.
Routine deployment cannot replace the helper, sudoers policy, validator,
launcher, systemd files, or root policy.

Installing, upgrading, rolling back, revoking, or removing this interface uses
`scripts/manage-pi-privileged-interface.sh` and interactive administrator
authentication. The deployment account retains existing live-Docker access;
that residual authority is intentionally unchanged. Isolated image readiness
uses its own dispatcher-generated socket and readiness-ID-bound containerd
image and plugin namespaces. It never accesses the live Docker socket or the
live daemon's default containerd namespaces.

Normal bundle installation and rollback refuse a held upgrade freeze. The
separate administrator `repair-held-freeze` action requires Docker, Nextcloud
and background jobs to be inactive or failed, no stack processes, the approved
installed manifest, and the original firewall bytes matching the protected
freeze hash. It replaces only the helper and manifest; policy, sudoers, units
and launchers must be unchanged. Its approval includes the original snapshot,
current raw firewall hash and freeze ID. It does not accept or release a stage.

New freezes retain a root-owned mode-`0600` original table snapshot. Policy
comparison ignores only validated nft metadata and kernel handles, and accepts
either ordering of the exact HTTP/HTTPS port set. All other table, chain and
rule fields must match the fixed policy. The original raw snapshot hash remains
the identity used by existing backup and stage records. Legacy adoption accepts
bounded original bytes only when their hash matches that existing authority
and their policy matches the exact current table; it never replaces authority.

Removal is fail-closed. In addition to prior revocation and service migration,
the installer requires every active-record, runtime-recovery, image-readiness,
socket, storage, and deployment-drill lifecycle namespace to be absent or
empty and refuses removal while an isolated readiness daemon is still running.
