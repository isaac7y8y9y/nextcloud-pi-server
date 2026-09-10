# Known risks

- Nextcloud must not start before its configured storage mount is available.
  Otherwise the host can create unintended local directories.
- Runtime backups contain private user data, database material, and TLS state;
  they require stricter handling than configuration backups.
- Compose image tags are version families rather than immutable digests. Normal
  starts validate the source multi-platform index lock; offline archive recovery
  validates its separate attested platform-manifest identity. Docker 29 can
  expose both identities for the same tag, so record mode determines which
  identity is authoritative.
- Image restore-readiness starts a second privileged Docker daemon with isolated
  paths and ID-bound containerd image and plugin namespaces, with networking
  controls disabled. Separate paths alone do not isolate Docker 29's containerd
  image metadata. Use only the guarded lifecycle helper, preserve its printed ID
  until cleanup succeeds, and never substitute a live Docker socket.
- Deployment identity and credentials must stay in ignored local files, never
  in Git history, issues, pull requests, or generated reports.
- The deployment account retains its pre-existing live Docker-daemon access.
  The dispatcher narrows sudo authority but cannot remove that separate Docker
  authority; isolate and audit access to that account accordingly.

Run the [read-only preflight](operations.md#read-only-pi-checks) and follow the
[backup verification procedures](backup-and-rollback.md) before operational
changes. Neither action authorizes mutation.
