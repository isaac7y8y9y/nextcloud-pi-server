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
Compose mappings, and exact patch-tag grammar. It does not re-query the
registry or assert that a running Pi uses the candidate.

The metadata record is not an approval artifact. Before a live image update, a
separate transaction must bind a refreshed registry identity to the actual Pi
pre-state and fresh recovery point, verify the loaded ID after the approved
pull, and prove the ingress freeze and full-runtime recovery gates. Until that
transaction is implemented and reviewed, these candidate files are for
offline preparation and tests only.

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
