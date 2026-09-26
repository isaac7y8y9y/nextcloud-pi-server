# Recovery

Recover only from a verified protected artifact bound to the configured target.
Begin with the read-only validation mode and stop at every stated human approval
pause. A human approval pause is not a generated approval artifact: deployment,
image import, and the draft live-runtime restore and activation drivers generate expiring,
single-use authorization files for their separate operations.

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

This drill remains the only *live-tested* runtime restore automation. Draft PR
#37 also contains a planned, single-use approved live-restore driver described
below. That driver is not yet a production operator procedure: its failure
paths have local tests, but it and the ingress freeze have not been proved on
the Pi's actual network path or passed the required code/PR reviews. A passed
disposable drill alone does not authorize a live restore.

The helper derives every disposable recovery path from that ID beneath the
policy-bound storage mount. It validates the mount and UUID again before each
creation, restoration, or recursive cleanup; never substitute a path manually.

## Draft full-runtime restore after an upgrade boundary

The separate draft `scripts/activate-image-upgrade.py` stages exactly one
fetched, verified image under the active ingress freeze. It accepts the same
candidate, source-rendered baseline, configuration backup, held runtime
backup, and prior image-recovery directories as the restore driver. Its
`--plan`/`--apply` modes additionally require the consumed `--fetch-approval`;
`--apply` additionally requires the fresh private `--approval` printed by the
plan. It verifies the protected completed-fetch marker, loaded digest and
source runtime, then tags the candidate, installs its active record and Compose,
records the root boundary, and restarts the stack. A successful stage stops
with maintenance mode and ingress freeze held. It does not migrate, accept,
release the freeze, prune images, or alter the repository source lock.

After separate application/migration and health review, `--plan-accept` and
`--accept` use `--stage-approval` (the consumed stage artifact) and the same
five directories; `--accept` also requires its newly printed `--approval`.
Acceptance rechecks the protected stage and candidate image IDs, maintenance
off, no app host port, and loopback health; it marks the stage accepted and
commits the active-record transaction. The freeze still requires a separate
release. If staging fails before the root boundary, the driver attempts only
the approved pre-start configuration rollback and verifies it. At or after an
ambiguous boundary, never use config-only rollback: preserve the freeze and
use the full-runtime restore below or a separately approved forward repair.
This driver is item-4 code under local test, **not a live Pi upgrade procedure**.
The real ingress/drain path, disposable rehearsal, reviews, and item-5 approval
remain outstanding.

`scripts/restore-live-runtime.py` is an item-4 implementation under test, not
yet an item-5 production instruction. It requires a root-owned upgrade stage
already at `runtime-may-have-changed`, its still-applied active-record
transaction, an active ingress freeze, a matching `runtime-backup-v2` held at
that freeze, verified prior image recovery, a source-rendered baseline, and a
verified one-image candidate. The source configuration backup must include a
protected `.env` matching the unchanged live project file. Planning is
read-only on the Pi and creates a private, 15-minute approval artifact outside
Git; applying consumes it before the first mutation.

The draft interface is:

```sh
scripts/restore-live-runtime.py --plan "$STAGE_ID" "$CANDIDATE" \
  "$SOURCE_RENDERED" "$CONFIG_BACKUP" "$HELD_RUNTIME_BACKUP" "$PRIOR_IMAGE_RECOVERY"
scripts/restore-live-runtime.py --apply "$STAGE_ID" "$CANDIDATE" \
  "$SOURCE_RENDERED" "$CONFIG_BACKUP" "$HELD_RUNTIME_BACKUP" "$PRIOR_IMAGE_RECOVERY" \
  --approval "$RESTORE_APPROVAL"
```

`--plan` is only available after the root-owned runtime boundary and while
the active-record transaction remains applied. It does not create the held
backup or freeze; it requires that backup to predate the stage by no more than
24 hours. Review the private approval record's exact stage, hashes,
actions, exclusions, and expiry before any future approved apply; the plan
command alone is not approval.

The approved apply restores three archives into the protected staging root,
loads and verifies prior image IDs if needed, imports the held SQL into an
isolated MariaDB bind directory, checks application tables and all databases,
and stops that temporary container. It then stops the stack, preserves failed
Nextcloud/MariaDB/Caddy state under transaction-specific names, promotes the
staged state, restores prior Compose/Caddy and the protected active record,
starts the prior images, turns off restored maintenance mode, and checks
loopback health before marking the stage recovered. It never releases the
ingress freeze; that requires a separate approved gate.

On any interruption, preserve the stage ID, root recovery state, failed-state
directories, and ingress freeze. Do not retry the consumed artifact, remove
staging paths, or reopen LAN access. Diagnose the exact phase and obtain a new
reviewed recovery decision. This workflow must not be used on the production
Pi until its operator tests, live ingress/drain proof, reviews, and bundle
installation gates have passed.

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
iptables management, IP forwarding, masquerading, and userland proxy; uses
readiness-ID-bound containerd image and plugin namespaces; and is never
connected to the live Docker socket. Both containerd namespaces are part of the
recorded process identity, so status and stop reject a daemon missing either
isolation flag.

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
must be no more than 24 hours old when `deploy-config.sh --plan` runs. Their
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

For approved Pi integration evidence of the rollback path without leaving the
deployment in recovered-image mode, create a distinct plan instead:

```sh
scripts/restore-image-recovery.sh --plan-rollback-test "$IMAGE_RECOVERY"
```

This artifact binds `force-health-failure` into its action list. Its apply loads
and activates the recovered mappings, then deliberately takes the same branch
as a failed health decision, restores the captured tags and active record,
restarts the prior deployment, verifies rollback health, and removes the remote
stage. It does not simulate an unhealthy service or weaken the health check.
Review and explicitly approve this rollback-test artifact independently; a
normal import approval cannot enable the forced branch.

### 4. Apply the approved image import

Within the 15-minute approval window, use the unchanged approval and recovery
paths:

```sh
scripts/restore-image-recovery.sh --apply \
  "$IMAGE_IMPORT_APPROVAL" \
  "$IMAGE_RECOVERY"
```

Apply recaptures the live pre-state before atomically consuming the single-use
approval. After loading, it proves each attested platform manifest exists and
explicitly retags it. Docker may retain a multi-platform index as the tag's
default identity, so recovered-record validation resolves the record's bound
platform rather than comparing that index with the attested platform manifest.
If transfer, loading, mapping, activation, restart,
interruption, or health checks fail, the transaction attempts to restore the
prior tags, containers, and active-image record. A consumed approval cannot be
replayed; create a new plan after any failed attempt. The importer runs
`scripts/health-check.sh` automatically after restart and again after rollback
when recovery is required.

Once remote apply begins, Mac-side HUP, INT, TERM, and unexpected exit handling
remain armed until verified rollback or commit. Cleanup retries the fixed remote
rollback, restores service, runs rollback health, commits resolved root state,
and removes only the exact transaction stage. If any recovery step cannot be
verified, the command preserves and prints the transaction ID and remote stage;
inspect those exact values instead of deleting a broader project path.

Applying a `--plan-rollback-test` artifact uses the same `--apply` command. Its
successful terminal message is `Image import forced health-failure rollback
passed with consumed approval`. Confirm source-mode image state and standalone
health afterward.

Normal shutdown is different from import: systemd uses `docker compose stop`
so existing container objects retain their image identities. Approved import
uses `docker compose down` so no retained container can keep an old identity
while archive tags are loaded.
