# Issue 26: preserve exact source IDs in cutover recovery archives

## Problem and boundary

The live source record stores containerd index IDs. The existing exporter uses
`docker image save --platform`, which reloads as platform-manifest IDs. The
full-runtime restore correctly demands the original source IDs and fails when
prior tags are missing or wrong. Preserve that exact check, source record,
configuration hashes, approval boundaries and separate platform-recovery flow.
The user authorizes this correction and its verification, then a pause before
cutover. No production freeze, target pull, DB preparation, migration, service
restart, privileged bundle installation or PR merge is part of this task.

## Changes

1. Add explicit `--exact-source` to `scripts/export-image-recovery.sh`, keeping
   legacy platform export as the default. Exact mode saves the three locked
   images without platform filtering so their source indexes remain available.
   Publish `image-recovery-v2` with an explicit detected `image_store`, existing
   target/platform/archive hash/size and exact tag-to-ID rows. Reuse
   `scripts/lib/image_identity.py` for store classification; add its print-store
   CLI mode rather than duplicating policy. Check source IDs/store before and
   after export. Keep every archive protected, outside Git, and atomic.
2. Extend `verify-image-recovery.sh` for a closed v2 manifest/attestation contract.
   V2 binds store and retains the existing target, ARM64, hash/size and three
   source-ID checks. V1 remains supported for legacy platform recovery.
   `--require-exact-source` also requires attestation and rejects v1 or any
   substituted loaded ID. Exact attestation's `image` IDs must equal its
   `source_image`/manifest IDs for all three tags. A separate `platform_image`
   row records each verified selected-platform identity; do not conflate it
   with source/default IDs. Reject unknown/duplicate/missing fields, wrong
   targets/stores/platforms, changed archive bytes or mismatched attestation.
3. In `test-image-restore-readiness.sh`, recognize v2, require the explicitly
   isolated empty daemon's store to match, load the unchanged archive, and
   prove all three default IDs equal the source lock plus ARM64 selection.
   Publish v2 attestation only after every check and no-container result passes.
   Retain the existing wrapper's ID-bound daemon/socket lifecycle and cleanup;
   legacy readiness behavior stays intact. No privileged bundle changes.
4. Gate `fetch-image-upgrade.sh` and `restore-live-runtime.py::verify_local` on
   exact-source attestation, with archive/candidate store agreement before
   authorization consumption. Activation/preparation/resume/acceptance already
   use verify_local and inherit the gate. Existing fingerprints bind archive
   and attestation hashes; no approval format change or alternative-ID fallback.
   Extract the existing exact prior-image load/check block from restore apply
   into `restore_prior_images`, preserving its behavior, so disposable runtime
   tests exercise the actual fallback used by full restoration.
5. Reject v2 exact-source artifacts in the separate recovered-mode
   `restore-image-recovery.sh` before planning remote pre-state or consuming
   approval. That legacy consumer intentionally retags platform identities and
   cannot safely interpret an index as a recovered platform ID. Keep its v1
   plan/apply/rollback semantics; do not silently change record mode.
6. Extend existing archive/readiness/fetch/restore/import tests, plus scoped
   exporter tests for default versus exact flags, pre/post drift and publication
   failure. Keep the test inventory/runner synchronized. Update sanitized
   backup/recovery/candidate documentation with the two purposes and the exact
   archive requirement before live stages. Run focused tests and the complete
   PR-safe suite; obtain code and plan-conformance reviews, publish a draft PR
   referencing this plan, and verify both exact-head CI checks.

## Operational verification before the requested pause

Read-only export of currently locked production images is authorized. Generate
new protected v2 material; retain the prior platform archive and all backups.
Use the existing guarded Pi isolated-readiness wrapper to load/attest the new
archive, verify exact-source mode and clean up its exact lifecycle. Recheck
production health, freeze absence, scheduler and image/container identities.
This starts no production container and changes no live image tag or dataset.

Use an isolated local ARM64 Docker 29 containerd daemon with the new three-image
archive to call the actual restore_prior_images helper for both missing and
wrong prior tags. Assert exact source/default IDs and source-mode validation,
then create/start disposable no-network/no-restart containers to prove their
`.Image` IDs match those source records. Also exercise a wrong/changed archive
or platform-only load and require rejection before runtime dataset staging.
Remove only named fixture containers/volumes and private temporary archives.
Keep evidence private. Prior clean SQL/core rehearsals need not be repeated for
this image-only correction; no live full-runtime restore is claimed.

Regenerate future approval artifacts around the new archive. Reopening after the
completed freeze proof means any later cutover needs a new held snapshot and
fresh time-limited health/config/recovery checks. Record the correction, proof
limits, PR/review status and remaining pre-cutover prerequisites in the ignored
handoff/roadmap. Then pause with production open, maintenance off and scheduler
active. Do not execute the cutover or initiate its downtime window.
