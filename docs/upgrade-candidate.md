# Image upgrade candidate preparation

This is the first, read-only part of [issue #26's upgrade plan](issue-26-upgrade-plan.md).
It does not authorize a pull, container replacement, database migration, or a
Pi change. The active production Compose and image lock remain unchanged.

`scripts/resolve-image-upgrade.py` reads registry metadata for an exact patch
tag using `docker buildx imagetools inspect --raw`. It selects exactly one
`linux/arm64/v8` manifest, checks the manifest's bytes against the index, and
reports the index, platform-manifest, and image-config digests. The image-config
digest is the expected loaded Docker image ID on the Pi's classic Docker image
store; the index digest is not. Docker Desktop's containerd image store can
report the platform-manifest digest as `.Id`, so the isolated rehearsal binds
both reviewed identities plus the exact pulled repo digest and ARM64 platform.
Do not substitute that local behavior for a live Pi image-ID check. Pass
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

The metadata record is not an approval artifact. The draft fetch, activation,
and restore transactions below bind registry identity, Pi pre-state, and a
fresh recovery point, but are not reviewed or proved on the Pi's live network
path. These candidate files remain for offline preparation and tests only.

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
measured ingress/drain proof, disposable integration, and code/PR review are
completed.

The root-owned dispatcher now also has an `upgrade-stage` state marker. It
consumes one completed fetch and a second short-lived stage approval bound to
the freeze, source and candidate record/Compose hashes, target tag, and loaded
ID. `boundary` must be recorded **before** a target container can be started;
afterward, the marker rejects pre-start abort and prevents freeze release
until the candidate is accepted. A draft approval-bound full-restore driver
exists for failures after that boundary, but is not live-proved or reviewed.
`abort` is
limited to the prepared, pre-start phase and requires the original record and
Compose to be back in place. `accept` checks the candidate configuration,
running image IDs, service, and maintenance state while ingress remains
blocked. The root commands are safety primitives; the separate draft
`scripts/activate-image-upgrade.py` driver uses them to tag the exact fetched
image, install the candidate record and Compose, mark the boundary before
restart, and pause for a second health-checked acceptance approval. It leaves
the freeze held and does not release ingress or alter the source lock.

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

The draft `upgrade-freeze quiescence` check fails closed unless established
app/Caddy TCP sockets and active InnoDB transactions are zero in two samples
while the freeze, paused timer, and maintenance mode remain in place. Held
backups now require that protected check. The draft `maintenance-off` action
requires resolved image transactions and repeats quiescence before turning
maintenance off, while keeping ingress blocked. Neither command establishes
that the live LAN rule works; the [ingress proof plan](upgrade-ingress-proof.md)
and a separately approved release still gate production use. The draft
`scripts/release-upgrade-freeze.py` driver now binds live configuration,
container identities, freeze hash, and prior timer state to a private
single-use approval; it has offline tests only. It does not supply LAN proof.

`backup-runtime-state.sh --check-held <id>` and `--apply-held <id>` require
that protected freeze. The apply mode writes a `runtime-backup-v2` manifest
bound to the freeze ID and firewall hash, and it deliberately leaves the
freeze, maintenance mode, and timer unchanged even when capture fails. The
existing ordinary backup remains `runtime-backup-v1` and still reopens service
after its capture. The held mode is not yet a complete approved upgrade
transaction: measured in-flight-write drain, external denial proof, disposable Pi
rehearsal, and reviews remain hard gates. See the
[ingress proof plan](upgrade-ingress-proof.md). Do not use it as a live upgrade
procedure until those gates pass.

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

The database helper proves only the import and forward-file-format path for
the backup used. Application behavior is tested separately below. A September
backup cannot substitute for a new quiesced item-5 recovery point; live
cutover and restoration remain hard gates.

`scripts/rehearse-nextcloud-upgrade.py` adds a separate, single-use approved
application rehearsal. Its plan verifies the private backup and exact ARM64
metadata for MariaDB 11.4.13 and Nextcloud 30.0.17/31.0.14. Apply pulls
those exact digests into the **local** Docker daemon, extracts the backed-up
Nextcloud tree into a new Docker volume, imports SQL into a clean 11.4 bind
directory, and runs the applications on an internal-only Docker network with
no published ports. It rewrites only the disposable `config.php` to use the
isolated database and loopback HTTP. It checks `occ status`, creates a
synthetic user, and uploads/downloads synthetic files through local WebDAV
before and after the official-image 30→31 startup migration. The six known
enabled custom apps are disabled before the core hop, matching the reviewed
plan. A successful run removes its containers, network, volume, and private
database directory; failure stops named containers and retains private state
for diagnosis. Private user data and credentials never enter Git or command
output.

The September 25 rehearsal passed against the September 17 backup. It is
evidence for that backup and those three image digests, **not** a substitute
for a fresh item-5 quiesced recovery point, live mount and ingress proof,
approved activation, or live full-runtime restore. It does not test the later
31→34 hops or custom-app re-enablement.
