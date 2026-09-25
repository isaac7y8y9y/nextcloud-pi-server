# Image upgrade candidate preparation

This is the first, read-only part of [issue #26's upgrade plan](issue-26-upgrade-plan.md).
It does not authorize a pull, container replacement, database migration, or a
Pi change. The active production Compose and image lock remain unchanged.

`scripts/resolve-image-upgrade.py` reads registry metadata for an exact patch
tag using `docker buildx imagetools inspect --raw`. It selects exactly one
`linux/arm64/v8` manifest, checks the manifest's bytes against the index, and
reports the index, platform-manifest, and image-config digests. The image-config
digest is the expected loaded Docker image ID; the index digest is not. Pass
`--expected-index` when a previously reviewed index digest must be enforced.
The command reads metadata only; it does not pull the image.

`scripts/prepare-image-upgrade.py` accepts that TSV record, the current tracked
image lock, and a **private** baseline rendered by `render-deployment-config.sh`.
It verifies source-lock, Compose, and active-record agreement, then creates a
new private directory containing one-image candidate versions of those files.
It refuses a Git destination and publishes `candidate-manifest.tsv` last. It
never modifies the tracked baseline or the Pi.

`scripts/verify-image-upgrade.py` checks the closed candidate directory,
private permissions, all payload hashes, source-lock/active-record agreement,
Compose mappings, and exact patch-tag grammar. Pass both `--source-lock` and
`--source-rendered` to prove that every candidate byte is exactly the
one-image transition from the supplied source baseline. Without those two
options, verification is self-consistency only and is insufficient for an
upgrade approval. This check does not re-query the registry or assert that a
running Pi uses the candidate.

The metadata record is not an approval artifact. Before a live image update, a
separate transaction must bind a refreshed registry identity to the actual Pi
pre-state and fresh recovery point, verify the loaded ID after the approved
pull, and prove the ingress freeze and full-runtime recovery gates. Until that
transaction is implemented and reviewed, these candidate files are for
offline preparation and tests only.

`scripts/fetch-image-upgrade.sh` is an in-progress, narrower transaction for
retrieving **one** image without activating it. Its `--plan` validates the
source-bound candidate, refreshes registry metadata, checks a fresh config
backup, a held runtime backup, attested prior-image recovery, the Pi's active
freeze, source images, running containers, Compose, Caddyfile, and clock. It
creates a private, 15-minute, single-use approval artifact. Its `--apply`
rechecks those bindings, consumes the artifact before any pull, pulls only the
approved index digest for ARM64, and proves the loaded image ID. The
root-owned dispatcher also records the fetch ID once, so a copied local
approval cannot be replayed; a pending or failed fetch prevents freeze release
until recovery is resolved. It does not
retag an image, replace Compose, start a target container, change the protected
record, or release the freeze. A failed pull retains the freeze and fetched
image for diagnosis. This is **not** an operational upgrade procedure until
activation, phase-aware full-runtime recovery, ingress/drain proof, isolated
database rehearsal, and integration tests are completed and reviewed.

## In-progress protected backup boundary

The root-owned dispatcher has a transaction-ID-bound `upgrade-freeze`
check/status/activate/release lifecycle. Its nftables `inet` prerouting rule
is intended to block host-directed Caddy traffic before Docker destination
NAT while retaining loopback checks. Activation pauses the background-job
timer and enables maintenance mode; interruption leaves that state for an
operator to resolve. Release requires maintenance mode to be off and restores
the timer's prior active state. The dispatcher fixture tests its basic state
transitions and replay denial, but a separate LAN-client test on the deployed
network backend is still required to prove both IPv4/IPv6 and old/new-flow
denial. No live Pi firewall change has been made for this implementation.

`backup-runtime-state.sh --check-held <id>` and `--apply-held <id>` require
that protected freeze. The apply mode writes a `runtime-backup-v2` manifest
bound to the freeze ID and firewall hash, and it deliberately leaves the
freeze, maintenance mode, and timer unchanged even when capture fails. The
existing ordinary backup remains `runtime-backup-v1` and still reopens service
after its capture. The held mode is not yet a complete approved upgrade
transaction: in-flight-write drain, external denial proof, stage approval,
image activation, and full-runtime restore remain hard gates. Do not use it
as a live upgrade procedure until those gates are implemented and reviewed.

## Isolated MariaDB rehearsal

`scripts/rehearse-mariadb-upgrade.py` is a **local, database-only** rehearsal.
Its `--plan` verifies an existing private runtime backup, checks current
registry metadata for exact `mariadb:11.4.13` and `mariadb:11.8.9` ARM64
images, and writes a private, 15-minute approval record outside Git. Its
`--apply` consumes that record once, pulls only the bound digest references
into the local ARM64 Docker daemon, and uses a new bind directory and
unpublished containers with `--network none`. It imports the backup's SQL
into clean 11.4 system tables, checks application table/column/collation and
file-cache counts plus `mariadb-check`, then starts 11.8 against **that
disposable 11.4 directory**, runs `mariadb-upgrade`, and repeats the checks.
Successful runs remove their exact containers and private data. Failures stop
the named containers and retain private state for diagnosis. A failed approval
cannot be replayed; generate a fresh plan after fixing the cause. The helper
never connects to the Pi or opens a host port.

This proves only the database import and forward-file-format path for the
backup used. It does **not** prove `occ status`, Nextcloud 30→31, file
operations, a fresh final snapshot, or live cutover and restoration. A
September backup cannot substitute for a new quiesced item-5 recovery point.
Those are still hard rollout gates.
