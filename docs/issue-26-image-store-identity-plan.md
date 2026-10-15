# Issue 26: bind upgrade candidates to the target image store

## Problem and scope

Item 5 stopped before ingress freeze: Docker's containerd image store exposes
an index ID for an image pulled by its multi-platform index, whereas the upgrade
builder assumes every Docker ID is its registry config digest. Fetch consumes
its authorization before that incorrect comparison fails. Keep the upgrade
roadmap, existing dispatcher interfaces, exact digest checks, and recovery
boundaries. Correct only the operator tooling's candidate identity contract.

## Implementation

1. Extend `scripts/prepare-image-upgrade.py` with required `--image-store`
   (`containerd` or `classic`). Include a private, manifest-hashed
   `image-identity.tsv` with closed fields `format`, `image_store`, `expected_id`.
   Derive the single expected unqualified Docker/container image ID from the
   registry index for containerd and config digest for classic. Preserve the
   seven-field registry metadata unchanged. Reject old candidates missing this
   contract; regenerate them rather than interpreting legacy assumptions.
2. Extend `verify-image-upgrade.py` to validate that contract and reconstruct
   the exact one-image transition with the same store. Expose its checked store
   and expected ID to activation and restore tooling. Do not change active-image
   record/source-lock schemas: they already store exact runtime IDs, and the
   privileged dispatcher already compares those IDs without assuming a config
   digest.
3. In `fetch-image-upgrade.sh`, validate remote `docker info` DriverStatus and
   require it matches the candidate before local/root approval consumption.
   Use `io.containerd.snapshotter.v1` for containerd; recognize only explicit
   classic drivers, rejecting unknown drivers. Bind store and expected ID into
   the fetch authority/fingerprint with a new fetch artifact format. Keep the
   original config digest as a separate bound registry fact. Pull only the
   approved index, then demand the one expected unqualified ID. For containerd,
   also prove platform-qualified ID equals the approved ARM64 manifest before
   protected completion. Source identity checks remain exact.
4. In `activate-image-upgrade.py`, consume the checked contract, enforce live
   store matching before each applicable plan/apply/resume/acceptance, validate
   the new fetch authority, and use its expected ID for fetched image, tag,
   preparation, container, and stage bindings. In `restore-live-runtime.py`,
   compare the stage with that checked expected ID and reject changed store.
   Keep the prior-image archive's separate platform identity and restoration
   behavior intact. Trace acceptance/release/source-mode validators to confirm
   they use the bound source lock/active record rather than registry config.
5. Add focused tests for both store derivations, missing/unknown/tampered
   identity contracts, wrong/changed store before consumption, exact manifest
   mismatch, fetch replay, activation/preparation and restore bindings. Update
   existing fixtures and sanitized upgrade/testing documentation. Run affected
   tests and the complete PR-safe suite; obtain required code and plan-conformance
   reviews, publish a draft PR with this plan as its reference, and verify CI.

## Runtime verification and production continuation

Before production freeze, use already fetched digest-bound images on the local
containerd-backed ARM64 daemon to prove default inspect ID, platform inspect ID,
index-based tag identity, container `.Image`, ID-based clean MariaDB startup,
and isolated save/load recovery identity. Test the missing/changed prior-tag
fallback against the exact source-lock IDs required by the existing full-runtime
restore driver; a matching platform attestation alone does not satisfy that
check. If a platform-only archive cannot reconstruct the source ID, record a
live-cutover blocker and revise/review the recovery plan before that affected
stage. Do not accept alternative source IDs or silently substitute recovered
mode. The unchanged-source freeze-only proof remains independently bounded.
Remove only named disposable resources;
retain evidence privately. Reuse the completed fresh SQL/schema/core rehearsals
unless new image/data/time evidence invalidates them. Exercise the real guarded
interfaces on disposable equivalent-store infrastructure where feasible and
state remaining proof limits explicitly. If privileged bundle changes prove
necessary, revise/review the plan before installing; no bundle change is
anticipated because its interfaces already accept exact index IDs.

Regenerate the private candidate and all approvals after the correction. Refresh
health and time-limited recovery evidence, review the corrected operational plan,
and resume the roadmap's freeze/drain/held-backup step. This repair does not merge
its PR or authorize proceeding into the separate live MariaDB cutover stage.
For freeze proof alone, release the unchanged source with the existing guarded
release after the held backup is verified; retain the snapshot and evidence.
Do not fetch or prepare a production candidate in that bounded freeze-only run.
A later live stage requires its own freshly held snapshot.
