# Issue 26: clean MariaDB cutover design

Design checkpoint: September 26, 2026, against PR #37 implementation head
`d29ea6f`. This supplements the [upgrade plan](issue-26-upgrade-plan.md) for
the initial MariaDB 11.8-to-11.4 transition. It describes implementation work;
it is not evidence of a Pi cutover or authorization to run one.

Plan-review checkpoint: September 27, 2026 — `plan_review` returned **READY**
with no material findings or required changes, after inspecting issue #26,
the parent plan, and the relevant implementation. This verdict covers only
design readiness for the initial clean cutover, not implementation, Pi
rehearsal, or rollout approval.

## Decision and boundaries

Keep the canonical database bind path `<storage>/nextcloud_db`. Initialize and
verify the approved 11.4 image in a new, isolated directory on the same ext4
mount. With the stack stopped and its old container objects removed, preserve
the original directory and rename the verified directory into the canonical
path. Then recreate the stack with the approved candidate image record and
Compose. Nextcloud remains at its current approved 30.x image throughout.

This preserves the path contract already used by Compose, preflight, backups,
and full-runtime restoration. A permanent second database path would require
those consumers and every later baseline to change. Directory promotion still
needs its own recorded safety boundary: two renames are not one transaction.

MariaDB [does not officially support major-version downgrades](https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/downgrading-between-major-versions-of-mariadb).
This design imports only application schema/data into freshly initialized
11.4 system tables. It never starts 11.4 against 11.8 files. The original cold
11.8 directory and the complete held backup remain recovery evidence.

Retain the DB activation refusal in `activate-image-upgrade.py` and the root
dispatcher until the specialized workflow and recovery tests pass. The later
11.4-to-11.8 forward upgrade is a separate stage after Nextcloud 33; this
design does not enable the generic DB restart path or declare item 4 complete.

## Reuse and proposed interface

Extend `activate-image-upgrade.py` and the existing `upgrade-stage` root journal
with a closed `db-clean-import` operation kind. Reuse candidate verification,
digest-only fetch, held backups, private approvals, active-record transactions,
maintenance-off, health checks, acceptance, and separate freeze release.
Do not create a second image-lock or backup system.

Proposed modes for the database operation are `--plan-prepare-db`,
`--prepare-db`, and `--resume-prepare-db`, followed by the existing
`--plan`/`--apply`, `--maintenance-off`, and acceptance modes. Add
`--resume-db` for an interrupted cutover and an approval-bound pre-boundary
abort. Paths are derived on the Pi from policy and stage ID, never accepted
as arbitrary root-command arguments. Existing app/Caddy modes retain their
contracts.

Preparation and cutover have separate 15-minute, single-use approvals. Starting
a long import within its approval window does not require it to finish within
15 minutes. An already consumed, root-confirmed fetch is durable evidence of
the exact downloaded image; its original fetch deadline must not also expire
a later preparation or activation. Recheck image identity at every use and
issue a fresh cutover approval after preparation. Recovery freshness limits
still apply when the live cutover starts.

Bind both approvals and the root journal to host, mount UUID, stage/freeze ID
and firewall hash, source and candidate configuration/record hashes, exact
source and target image identities, effective credential hash, held runtime
and SQL hashes, configuration/image-recovery hashes, and actions/exclusions.
Preparation additionally binds the source database inventory; cutover binds
the completed preparation attestation and the exact source container IDs.
Resume verifies the consumed approval and root phase rather than minting new
authority or replaying an expired unused approval.

## Prepare and attest the clean database

1. Require measured ingress protection, maintenance on, paused jobs, verified
   drain, and a fresh complete held runtime snapshot. Confirm Nextcloud 30 and
   source DB versions against the approved stage. Recheck unchanged source
   configuration and image IDs, mount identity, free space, and absence of
   other containers mounting the source or staging database paths. Reserve
   room for the original directory, imported DB, full recovery staging, and
   failed-state retention; do not infer this from compressed SQL size alone.
2. Capture a private source inventory while the same freeze remains held:
   application schema/table list, exact per-table row counts, columns and
   indexes/constraints, character sets/collations, engines/row formats, and
   routines/triggers/events. Derive the Nextcloud table prefix from its bound
   configuration. Link the inventory hash to the held SQL/manifest and freeze
   in the preparation record; compare it again before cutover. Reject enabled
   event scheduling or unaccounted DB writers. This is a cutover sidecar, not
   a silent relaxation of the closed runtime-backup schema.
3. Create a root-owned staging parent `<storage>/.db-cutover-<id>` and a new
   empty `data` child. Record filesystem/device and directory identities. Run
   only the already verified target image with `--pull=never`, no published
   ports, `--network none`, `--restart=no`, and a stage label. Record its exact
   container ID. It mounts only the new data directory and private inputs.
4. Resolve the approved Compose environment into a protected snapshot and
   pass only the required database/root/user/password settings. Do not feed
   arbitrary extra `.env` keys into the temporary image. Preserve the actual
   application credentials and database charset/collation; verify the
   application user's authentication and schema grants. Do not import 11.8
   `mysql` system tables, credential hashes, or privilege-table files. The
   [official image entrypoint](https://github.com/MariaDB/mariadb-docker/blob/master/docker-entrypoint.sh)
   initializes system tables and the application account on a fresh directory;
   verify that behavior for the pinned image during rehearsal.
5. Stream the exact held application SQL, fail on any import error, and retain
   the original SQL unchanged. Compare the imported inventory to the frozen
   source using version-independent schema fields and exact row counts, then
   run `mariadb-check`. Do not treat positive table/column counts or a count of
   distinct collations as equivalence. Any required SQL transformation needs
   a revised reviewed design and a new attestation.
6. Shut the temporary DB down cleanly; reject a forced/uncertain shutdown as
   ready for promotion. Remove its exact container after identity checks and
   prove no remaining container references the staging path. Record a private
   checksum manifest of the stopped DB files, directory identities, image ID,
   SQL and inventory hashes, credential/configuration hashes, and successful
   verification. Protect and atomically publish this attestation as
   `db_phase=prepared`. Recheck it immediately before directory promotion.

On interruption during preparation, `--resume-prepare-db` checks the same
consumed approval and journal, stops/removes only its verified temporary
container, and discards/recreates only its isolated staging data. Invalidate
all incomplete attestations and repeat import/verification. Journal creation,
partial directory creation, partial SQL streaming, and loss of the completion
response must each have a defined retry. Source data is untouched in these
phases. A pre-boundary abort verifies source state, removes only disposable
staging, marks the stage aborted, and leaves freeze release separate.

## Cutover and restart ordering

The root dispatcher owns the state transitions under its existing operation
lock. Journal writes and rename outcomes must be flushed to storage before
the next dependent operation; startup must detect missing, malformed, or
contradictory state. Record intent before each irreversible operation and
recognize its completed result on retry.

| DB phase | Permitted state and next action |
| --- | --- |
| `preparing` / `prepared` | Source directory/configuration remain authoritative; only isolated import work may run. |
| `detaching` | Keep source configuration and canonical directory unchanged. Disable restart on the recorded stack container IDs, stop cleanly, and remove those exact stopped objects without volumes. Resume repeats verified missing/completed removals. |
| `detached` | Prove all three old stack objects and the temporary DB object are absent and no other container mounts these data paths. Persist that fact before any path/configuration switch. |
| `switching` | Record the generic `runtime-may-have-changed` boundary before the first directory move. Preserve the old DB, promote the attested DB, and install candidate Compose/active record. Normal stack startup is denied. |
| `candidate-ready` | Canonical directory identity is the imported directory, preserved source exists, candidate configuration and record agree, and old objects are absent. Only now permit candidate creation. |
| `starting` / `running` | Record intent before first create/start; recheck actual image IDs, mount source and canonical directory identity. Never compare mutable DB contents to the pre-start checksum after target start. |
| `accepted` | DB/application health and separate acceptance pass. Preserve original/failed data and require the existing separately approved release. |

Use `<storage>/.nextcloud-db-before-<id>` for preserved original data, distinct
from the existing full-restore `.nextcloud-db-failed-<id>` namespace. The two
promotion renames remain within the verified filesystem. On retry, identify
each directory by the recorded device/inode and protected attestation, not
merely by whether a path exists. Reject symlinks, nested mounts, unexpected
destinations, replaced directories, and unknown consumers.

The existing candidate builder can keep its DB-image-only Compose change,
because the verified clean directory is promoted to the canonical bind path
before any target start. Root activation must additionally require this
operation kind and attestation; removing the current blanket DB refusal is
not sufficient. Preserve READ-COMMITTED/ROW settings and all app/Caddy image
identities. Normal startup remains no-pull.

Docker's [`always` policy restarts a manually stopped container after daemon
restart](https://docs.docker.com/engine/containers/start-containers-automatically/).
Consequently, `service stop` alone is not the cutover barrier. Add a journal
check to the root Compose launcher and service dispatch so neither can start
the stack during `detaching`, `detached`, or `switching`.

Make reboot recovery possible without a circular dependency on Docker:
before `detached`, only the unchanged source directory/configuration may
exist; from `detached` through `switching`, the durable removal checkpoint
proves no old stack container can auto-restart. The Docker boot guard can
therefore restore the freeze and permit the daemon for inspection/resume,
while the Compose startup gate stays closed. At `candidate-ready` and later,
verify the stable candidate path/configuration binding before permitting
startup. The boot guard must not call the Docker API before Docker starts.
Unknown states fail closed. Test daemon restart at every boundary; do not
solve a blocked daemon by deleting the journal or bypassing the guard.

## Acceptance and full recovery

Before acceptance, prove exact target version/image and canonical mount,
database integrity and application-user login, preserved source directory,
Nextcloud 30 status with no pending DB upgrade, maintenance-off through the
stage-bound primitive, loopback HTTPS, and no direct app host port. Validate
candidate-aware conformance against the approved private candidate; normal
source-based preflight will otherwise report the intentional image drift.
Exercise synthetic upload/download in disposable rehearsal; after the
separately approved production reopening, perform the planned LAN checks.

Before `switching`, an abort may recreate the original stack with its original
restart policies/configuration after verifying no canonical data move or
candidate start occurred. From `switching` onward, take the conservative
full-runtime recovery boundary even if target start was not observed. Resume
the same cutover or use a separately approved full restore; do not just switch
the image back or reopen the preserved original DB by itself.

Extend `restore-live-runtime.py` and the root promotion workflow for DB stages:

- Bind the cutover journal and accept only the explicitly recorded combinations
  of source/candidate configuration and directory locations. Current restore
  evidence assumes candidate configuration is already completely installed;
  it cannot cover an interrupted DB switch unchanged.
- If the first rename completed but the second did not, finish only the
  identity-checked directory placement under the freeze and closed startup
  gate, without starting a container. This supplies a known canonical
  failed/candidate path for full restoration while retaining the original.
- Prepare all four datasets from the same held snapshot with the prior DB
  image. Before promotion, disable restart and remove the exact current stack
  containers, then durably record a recovery-detached checkpoint. Extend the
  boot and launcher gates to allow Docker for inspection while denying stack
  startup during this known container-free recovery. Preserve existing gates
  for unrelated recovery stages.
- Promote the full prior runtime, restore the prior Compose/active record, and
  establish a verified `source-ready` checkpoint before starting the original
  images. Mark recovered only after health. Every ambiguous rename, partial
  configuration restore, interrupted import, and lost response must resume
  through the same bound journal. Keep original and failed directories.
- Mark accepted/recovered operational journals resolved atomically before a
  later stage becomes eligible; retain evidence separately. Subsequent stages
  must not be checked against an obsolete resolved stage's image hashes.

Do not automatically delete the preserved original DB. Cleanup of disposable
preparation state must refuse any promoted directory; old/failed runtime
retention has a later explicit, exact-target cleanup decision. No pre-open
snapshot may overwrite user writes accepted after reopening.

## Implementation slices and evidence

1. Extend `privileged/nextcloud-pi-ops` stage schemas and status/resume/abort
   transitions, startup gates in `systemd/nextcloud-pi-compose-start` and the
   Docker guard, then refresh `privileged/bundle-manifest.tsv`. Keep actual DB
   activation disabled until the integration is complete.
2. Extend `scripts/activate-image-upgrade.py` with the separate preparation
   approval, isolated import attestation, new activation approval, and guarded
   cutover. Adjust completed-fetch age handling without weakening unused
   approval expiry. Share only concrete common import/verification logic with
   the existing rehearsal/restore code.
3. Extend `scripts/restore-live-runtime.py`, protected runtime promotion, and
   candidate-aware conformance for the partial DB states above. Update the
   recovery, candidate, startup, storage, testing, and handoff documentation.
4. Fault-inject interruption before/after approval consumption, container
   stop/removal, each rename, journal/config/active-record replacement, target
   creation, health, acceptance, and recovery. Test wrong ID/mount, SQL error,
   mismatched inventory/credentials, stale evidence, insufficient space,
   restart-policy drift, partial staging, and cleanup after promotion. Prove
   retries and denial behavior, not just command order.
5. Use disposable Linux filesystem/container fixtures to show the original
   directory remains intact, the target mounts the imported directory, and
   daemon restart never runs an old image against the new directory. Include
   actual systemd/startup integration and each rename interruption. Use
   synthetic data and credentials; retain failed fixtures only for diagnosis.
6. Run the local PR tier and Linux privileged CI, then the required engineering
   and PR reviews on the implementation. Before live use, refresh the dated
   rehearsal evidence, prove the Pi/LAN ingress and drain gates, install the
   reviewed bundle, and rehearse disposable Pi restoration under the existing
   operational procedure.

The source/target versions and image digests remain dated inputs from the
parent plan and must be resolved again before rollout. No live inventory or
private backup contents were read for this design. Completion of this design
pass is not completion of implementation, review, or operational proof.
