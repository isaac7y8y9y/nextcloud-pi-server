# Recovery

Recover only from a verified protected artifact bound to the configured target.
Begin with the read-only validation mode and stop at every stated human approval
pause. A human approval pause is not a generated approval artifact: deployment
and image import are the only workflows here that generate expiring, single-use
authorization files.

Treat all backups, image archives, attestations, disposable extraction paths,
and command output as sensitive. Keep them outside Git and do not publish them.

## Runtime recovery drill

The runtime recovery drill proves a verified backup against disposable Pi paths
and a disposable MariaDB container. It never writes to live Nextcloud, MariaDB,
or Caddy state.

Set the exact path printed by the runtime backup procedure, then run the
read-only check:

```sh
RUNTIME_BACKUP=/absolute/private/nextcloud-backups/runtime-backup-YYYYMMDDTHHMMSSZ
scripts/verify-runtime-backup.sh "$RUNTIME_BACKUP"
scripts/test-runtime-recovery.sh --check "$RUNTIME_BACKUP"
```

Review the target binding, tool checks, image identity, and required free space.
No approval artifact is created. Stop until the operator explicitly approves
creation and removal of the disposable restore paths and container.

After that human approval pause, run:

```sh
scripts/test-runtime-recovery.sh --apply "$RUNTIME_BACKUP"
```

The drill restores and compares the Nextcloud and Caddy archives, imports the
database dump into a disposable MariaDB container, runs `mariadb-check`, and
removes all disposable targets. Success ends with `Controlled runtime recovery
drill passed`.

The apply command prints a recovery-test ID before creating targets. If it
reports failed or incomplete cleanup, retain that ID, obtain approval for the
cleanup mutation, and run:

```sh
RECOVERY_TEST_ID=20260828T120000Z-1234
scripts/test-runtime-recovery.sh --cleanup "$RECOVERY_TEST_ID"
```

Success prints that the disposable recovery-test targets are absent. Never
construct a different path or remove recovery targets manually.

This drill is the repository's only runtime restore automation. There is no
script that restores a runtime backup into live Nextcloud, MariaDB, and Caddy
state. A passed drill is recovery evidence, not authority or tooling for a live
runtime restore.

## Image recovery and restore-readiness

Image recovery has four distinct stages: export, offline verification,
isolated restore-readiness, and an independently approved import. Export and
attestation do not authorize import or restart.

### 1. Export the locked images

Choose an absolute protected root outside Git and export the three source-locked
images from the configured Pi:

```sh
export NEXTCLOUD_IMAGE_RECOVERY_ROOT=/absolute/private/nextcloud-image-recovery
scripts/export-image-recovery.sh --output-root "$NEXTCLOUD_IMAGE_RECOVERY_ROOT"
```

The command validates target identity and source image IDs, starts no container,
and prints an `image-recovery-<UTC timestamp>` directory. Set and verify that
exact path:

```sh
IMAGE_RECOVERY=/absolute/private/nextcloud-image-recovery/image-recovery-YYYYMMDDTHHMMSSZ
scripts/verify-image-recovery.sh "$IMAGE_RECOVERY"
```

Continue only after `Image recovery verified`.

### 2. Check isolated-daemon readiness

The lifecycle helper uses a second Docker daemon on the configured Pi. It has
separate data, execution, PID, and Unix-socket paths; disables its bridge,
iptables management, IP forwarding, masquerading, and userland proxy; and is
never connected to the live Docker socket.

Its check mode validates the unattested archive, Pi identity, storage mount,
`dockerd` prerequisites, disposable paths, and free space without changing the
Pi:

```sh
scripts/run-image-restore-readiness.sh --check "$IMAGE_RECOVERY"
```

Stop until the operator explicitly approves the disposable daemon, SSH Unix-
socket forwarding, archive load, attestation write, and cleanup. This is a
human approval pause; no approval artifact is generated.

After approval, run:

```sh
scripts/run-image-restore-readiness.sh --apply "$IMAGE_RECOVERY"
```

The helper prints a readiness ID, starts the isolated daemon, forwards only its
socket to a protected local `/tmp` socket, invokes
`test-image-restore-readiness.sh`, writes `restore-attestation.tsv`, and removes
the tunnel, daemon, socket, and isolated data root. Success ends with `all
disposable targets were removed`.

If cleanup fails or the command is interrupted, retain the printed ID. Obtain
approval for cleanup and run:

```sh
IMAGE_READINESS_ID=20260828T120000Z-1234
scripts/run-image-restore-readiness.sh --cleanup "$IMAGE_READINESS_ID"
```

Do not substitute `/var/run/docker.sock`, the Docker Desktop socket, or any
other live daemon. After successful cleanup, require the archive-specific
attestation:

```sh
scripts/verify-image-recovery.sh --require-attestation "$IMAGE_RECOVERY"
```

For configuration deployment, both the image manifest and restore attestation
must be no more than one hour old when `deploy-config.sh --plan` runs. Their
timestamps are independent; recreate the archive and attestation if either is
stale.

### 3. Plan an image import

Image import is recovery, not normal deployment. It stops the service, runs
Compose `down`, loads the archive without pulling or pruning, verifies and
retags the recovered mappings, installs a recovered active-image record, and
restarts the service.

Create a read-only import plan:

```sh
scripts/restore-image-recovery.sh --plan "$IMAGE_RECOVERY"
```

The plan prints a protected import approval path, fingerprint, current active-
record hash, archive and attestation hashes, current and recovered image IDs,
container identities, exact actions, and expiry. Set the printed path explicitly:

```sh
IMAGE_IMPORT_APPROVAL=/absolute/private/image-import-approvals/import-SHA256-EPOCH.tsv
```

Review that the target, hashes, image mappings, running container pre-state, and
actions match the intended recovery. The file is not human approval by itself.
Stop until the operator explicitly approves this exact import and restart.

### 4. Apply the approved image import

Within the 15-minute approval window, use the unchanged approval and recovery
paths:

```sh
scripts/restore-image-recovery.sh --apply \
  "$IMAGE_IMPORT_APPROVAL" \
  "$IMAGE_RECOVERY"
```

Apply recaptures the live pre-state before atomically consuming the single-use
approval. If transfer, loading, mapping, activation, restart, interruption, or
health checks fail, the transaction attempts to restore the prior tags,
containers, and active-image record. A consumed approval cannot be replayed;
create a new plan after any failed attempt. The importer runs
`scripts/health-check.sh` automatically after restart and again after rollback
when recovery is required.

Normal shutdown is different from import: systemd uses `docker compose stop`
so existing container objects retain their image identities. Approved import
uses `docker compose down` so no retained container can keep an old identity
while archive tags are loaded.
