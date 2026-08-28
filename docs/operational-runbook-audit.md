# Operational runbook documentation audit

## Scope

This audit evaluates every tracked Markdown document against the executable
interfaces under `scripts/`. It identifies where a human operator needs an
ordered, copyable procedure and where conceptual or policy documentation should
remain free of duplicated commands.

The audit covers documentation and command discoverability. It does not
authorize a deployment, backup, recovery, restart, image import, or other live
mutation.

## Implementation status

The plan was implemented on this branch on 2026-08-28. The evaluation matrix
below records the audited `origin/main` baseline; the resulting runbooks now
contain the prescribed procedures. Implementation also added the guarded
isolated-Docker lifecycle helper, its regression test, the operational
documentation contract test, CI coverage, and canonical cross-links. The
aggregate local-validation helper considered in follow-up item 7 remains
deliberately out of scope.

## Runbook decision rule

A document needs a step-by-step procedure when a human-facing workflow has one
or more of these properties:

- it reads from or mutates the configured Pi;
- it produces an artifact consumed by a later command;
- it separates read-only `--check` or `--plan` from mutating `--apply`;
- it consumes a short-lived or single-use approval;
- interruption can require an explicit cleanup or recovery command; or
- the operator must verify a target, output, or postcondition before continuing.

Every such procedure should state its prerequisites, working directory, exact
commands, expected safe output, artifact-path handoff, approval boundary,
postconditions, and failure or cleanup branch. Commands that reveal private
values or encourage storing private output in Git must not be included.

Reference documents should link to one canonical runbook instead of copying
the same operational sequence. This prevents safety controls, argument order,
and expiry limits from drifting between documents.

## Executive result

Three existing documents require full operator runbooks:

1. `docs/deployment.md` for the complete production configuration deployment.
2. `docs/backup-and-rollback.md` for configuration and runtime backup creation,
   verification, and backup failure recovery.
3. `docs/recovery.md` for runtime recovery drills and offline image recovery,
   attestation, and import.

`docs/operations.md` requires a shorter command-oriented index for routine
read-only checks, health validation, public-safety validation, and links to the
three mutation-sensitive runbooks. The README, configuration model, and code
review standard need only short links or mode clarifications after those
canonical procedures exist.

The remaining documents are architectural, policy, risk, historical, legal, or
already procedural. Adding project-script sequences to them would duplicate
the canonical runbooks without helping an operator make a distinct decision.

## Documentation evaluation

| Document | Current purpose | Step-by-step evaluation | Required action |
| --- | --- | --- | --- |
| `README.md` | Project overview and navigation | Keep concise; it should not duplicate deployment commands. Its claim that `docs/deployment.md` contains the complete procedure is currently premature. | Retain the five-step summary and link to the completed deployment, backup, recovery, and operations runbooks. |
| `AGENTS.md` | Repository workflow and engineering policy | The worktree create/cleanup sequence is already adequate. It is not an operator deployment guide. | No new project-script runbook. Keep its links aligned with the canonical operational documents. |
| `CHANGELOG.md` | Historical release record | Historical documentation should not become an executable guide. | No action. |
| `docs/architecture.md` | System design and configuration relationships | Declarative by design. Rendering is appropriately mentioned to explain architecture, not to operate production. | Link to deployment only if more operational detail is needed; do not duplicate commands. |
| `docs/backup-and-rollback.md` | Backup policy and rollback boundaries | **Full runbook required.** It currently names no backup or verification script and provides no artifact handoff, approval point, recovery drill, or failure branch. | Add separate configuration-backup and runtime-backup procedures, verification commands, runtime recovery-drill commands, and maintenance-mode recovery guidance. |
| `docs/client-access.md` | macOS and Windows client enrollment and rollback | Already contains ordered platform-specific steps. No repository script implements client enrollment. | No project-script runbook. A future certificate-export helper would require a separate update, but none exists now. |
| `docs/code-review.md` | Canonical engineering review policy | Its six-step review process and output contract are already sufficient. Exact local validation commands belong in one contributor-validation procedure, not in the review standard. | Link its validation section to the command index in `docs/operations.md` or a future dedicated validation guide. |
| `docs/current-configuration.md` | Private/local/live configuration model | Does not need a full runbook, but `scripts/preflight.sh` has two modes that are not explained here. | Link to the operations preflight procedure and distinguish `--readiness` from `--conformance`. |
| `docs/deployment.md` | Deployment controls and safety model | **Full runbook required.** It gives policy and one render example but omits the production command sequence and the required argument handoffs. | Add the guarded production procedure described below. |
| `docs/known-risks.md` | Stable baseline risk register | A risk register should state controls and point to procedures, not duplicate them. | Link “run preflight and verify a backup” to the canonical runbooks. |
| `docs/operations.md` | Operational entry point | **Command index required.** It currently names only preflight and public-safety checks and does not show modes or commands. | Add routine read-only procedures, contributor validation, and links to mutation-sensitive runbooks. |
| `docs/recovery.md` | Runtime and image recovery safety model | **Full runbook required.** It names image tools but gives no arguments, approval handoff, isolated-Docker lifecycle, runtime drill, or cleanup procedure. | Add the guarded recovery procedures described below and explicitly state the limit of live runtime recovery automation. |
| `docs/security-boundaries.md` | Publication and sensitive-data policy | Declarative policy should remain the source of truth. | Link to validation commands in operations; do not add operational sequences. |
| `docs/startup.md` | Boot ownership and image/mount invariants | Architectural behavior, not a manual startup procedure. The scripts intentionally own these transitions. | No step-by-step instructions unless a separate, tested startup troubleshooting workflow is introduced. |
| `docs/storage.md` | Storage model and exclusions | Architectural behavior with no supported manual storage mutation script. | No step-by-step instructions unless a guarded storage migration or repair tool is introduced. |

## Script-to-runbook ownership

### Production deployment

`docs/deployment.md` should own the ordered use of:

| Script | Required instruction level |
| --- | --- |
| `scripts/render-deployment-config.sh` | Show creation of a new absolute protected output directory, inspection scope, and safe removal expectations. |
| `scripts/preflight.sh` | Show `--readiness` before deployment and explain what warnings are expected versus blocking failures. |
| `scripts/prepare-env-migration.sh` | Show `--check`, explain its exit status when `.env` is absent, and show the separately approved one-time `--apply <verified-config-backup>` branch. |
| `scripts/test-deploy-transaction.sh` | Show `--check`, the approval boundary, then the disposable `--apply` drill and its expected cleanup result. |
| `scripts/deploy-config.sh` | Show exact `--plan <config-backup> <runtime-backup> <image-recovery>` and `--apply <approval> <config-backup> <runtime-backup> <image-recovery>` commands using unchanged artifact variables. |
| `scripts/health-check.sh` | Explain that apply runs it automatically and show the standalone read-only post-deployment invocation. The rollback-only `--caddyfile` form is an internal deployment transaction interface, not a routine operator command. |

The runbook must link to backup and recovery procedures for artifact creation
rather than restating them. Immediately before `--plan`, it must require all
four freshness inputs checked by the deployment script: configuration manifest,
runtime manifest, image manifest, and image restore attestation. Each can be at
most one hour old. The runbook must also state that the generated deployment
approval expires after 15 minutes and is consumed even if a later staging or
apply step fails.

The production sequence should use explicit path variables such as
`CONFIG_BACKUP`, `RUNTIME_BACKUP`, `IMAGE_RECOVERY`, and
`APPROVAL_ARTIFACT`. Operators should set them from the protected paths printed
by the scripts; the guide must not suggest parsing private manifests or placing
those values in a tracked file.

### Backup and rollback

`docs/backup-and-rollback.md` should own:

| Script | Required instruction level |
| --- | --- |
| `scripts/backup-config.sh` | Show protected output-root setup, read-only capture, printed artifact path, and separate verification. |
| `scripts/verify-config-backup.sh` | Show offline verification of the exact produced directory and explain that verification does not authorize restore or deployment. |
| `scripts/backup-runtime-state.sh` | Show read-only `--check`, explicit approval, `--apply`, automatic verification, and sensitive artifact handling. |
| `scripts/verify-runtime-backup.sh` | Show repeatable offline verification of the completed artifact. |
| `scripts/backup-runtime-state.sh --maintenance-off` | Document only as the explicit failure-recovery action when an interrupted backup reports that maintenance mode may remain enabled. |
| `scripts/test-runtime-recovery.sh` | Link to the canonical recovery drill in `docs/recovery.md`; do not duplicate the full procedure here. |

The document must distinguish three facts that are easy to conflate:

- configuration backup creation is Pi-read-only but still produces private
  local material;
- runtime backup `--apply` temporarily mutates Nextcloud maintenance mode; and
- a verified backup is recovery evidence, not authority to restore or deploy.

### Recovery

`docs/recovery.md` should own:

| Script | Required instruction level |
| --- | --- |
| `scripts/test-runtime-recovery.sh` | Show `--check <runtime-backup>`, explicit approval, disposable `--apply <runtime-backup>`, expected cleanup, and `--cleanup <recovery-test-id>` after an interrupted or failed drill. |
| `scripts/export-image-recovery.sh` | Show optional protected output root, produced archive directory, and the fact that export does not authorize import. |
| `scripts/verify-image-recovery.sh` | Show verification before and after attestation, including when `--require-attestation` is required. |
| `scripts/run-image-restore-readiness.sh` | Show read-only `--check`, the human approval pause, isolated-daemon `--apply`, and retryable `--cleanup <readiness-id>`. |
| `scripts/test-image-restore-readiness.sh` | Show the isolated Unix-socket requirement, attestation result, and cleanup of the isolated daemon and data root. |
| `scripts/restore-image-recovery.sh` | Show exact `--plan <recovery-directory>` and `--apply <approval-artifact> <recovery-directory>` commands, the 15-minute approval window, review points, automatic rollback behavior, and consumed-approval outcome. |
| `scripts/health-check.sh` | Explain that image import performs health validation and rollback automatically. |

The implementation will add `scripts/run-image-restore-readiness.sh` as the
guarded lifecycle owner around `test-image-restore-readiness.sh`. It will start
a second Docker daemon on the configured Pi with separate data, execution,
PID, and Unix-socket paths; disable its bridge, forwarding, masquerading, and
iptables management; forward only that isolated socket to a protected local
`/tmp` socket; run the existing readiness test; and stop and remove every
disposable target. Its read-only `--check`, explicitly approved `--apply`, and
retryable `--cleanup <readiness-id>` modes will be documented and regression
tested. It must never connect the readiness test to the live Docker socket.

There is also no script that restores a runtime backup into live Nextcloud,
MariaDB, and Caddy state. `scripts/test-runtime-recovery.sh` proves restoration
only in disposable targets. The recovery guide must say this explicitly and
must not imply that a tested live runtime restore command exists.

### Routine operations and contributor validation

`docs/operations.md` should be the short command index for:

| Workflow | Script coverage |
| --- | --- |
| Deployment readiness comparison | `scripts/preflight.sh --readiness` |
| Hardened live-state comparison | `scripts/preflight.sh --conformance` |
| Read-only service validation | `scripts/health-check.sh` |
| Documentation link validation | `scripts/test-documentation-links.py`, then `scripts/check-documentation-links.py` |
| Publication-safety validation | `scripts/test-public-safety.py`, `scripts/check-public-safety.py`, and the separately identified `--history` check |
| Sanitized configuration validation | `scripts/test-public-config.sh`, with its Docker prerequisite stated |
| Full regression validation | The repository test sequence currently encoded in `.github/workflows/public-safety.yml` |

The full regression list should have one canonical owner. Copying the workflow's
individual commands into multiple documents will drift. Until an aggregate
test runner exists, operations may show the sequence once or link directly to
the workflow and explain how to reproduce it locally.

### Scripts that do not need individual operator runbooks

The following are support libraries, focused regression tests, or internal
validators. They should be covered by the contributor-validation sequence, not
presented as independent production operations:

- `scripts/check-compose-env-references.sh`;
- `scripts/test-active-images.sh`;
- `scripts/test-atomic-transaction.sh`;
- `scripts/test-compose-env-references.sh`;
- `scripts/test-compose-launcher.sh`;
- `scripts/test-deploy-config.sh`;
- `scripts/test-deployment-config.sh`;
- `scripts/test-health-check.sh`;
- `scripts/test-image-import-transaction.sh`;
- `scripts/test-image-import.sh`;
- `scripts/test-image-lock.sh`;
- `scripts/test-image-recovery-attestation.sh`;
- `scripts/test-image-readiness-lifecycle.sh`;
- `scripts/test-preflight.sh`;
- `scripts/test-runtime-recovery-regression.sh`; and
- every file under `scripts/lib/`.

`scripts/worktree-create.sh` and `scripts/worktree-cleanup.sh` are already
documented adequately in `AGENTS.md`. They should not be repeated in the live
operations runbooks.

## Priority order

### Critical: make live operations executable

1. Expand `docs/backup-and-rollback.md` so configuration and runtime backups can
   be created and verified without reading script source.
2. Expand `docs/recovery.md` so the image-recovery input can be created and
   attested, including the isolated-Docker gap and the absence of automated
   live runtime restoration.
3. Expand `docs/deployment.md` with the exact artifact handoff, plan, approval,
   apply, post-check, and failure branches.

These changes should be designed together because deployment consumes artifacts
owned by the other two guides.

### High: establish one operational entry point

4. Expand `docs/operations.md` into a concise command index and validation
   procedure.
5. Update `README.md`, `docs/current-configuration.md`,
   `docs/known-risks.md`, `docs/security-boundaries.md`, and
   `docs/code-review.md` to link to their canonical procedure without copying
   it.

### Follow-up: prevent documentation drift

6. Add documentation tests that assert every human-facing script is named by
   its canonical runbook and that the documented argument order matches its
   usage contract. Add the new test to the explicit public-safety CI command
   list.
7. An aggregate local-validation script is outside this implementation. CI
   remains the canonical full regression list, while operations links to it and
   documents the focused local checks.
8. Add and test the isolated-Docker lifecycle helper specified in the recovery
   section before publishing the image-attestation procedure.

## Completion criteria for the documentation rewrite

The rewrite is complete when a clean-clone operator can determine, without
opening a script:

- which commands are read-only and which require explicit approval;
- which approvals are operator-controlled pauses and which are generated,
  expiring, single-use artifacts;
- which artifact path from each command is passed to the next command;
- which operations have one-hour or 15-minute freshness windows;
- what must be reviewed before `--apply`;
- which approval artifacts are single-use;
- what success looks like;
- what automatic rollback covers;
- which cleanup or recovery command applies after interruption; and
- which live recovery capability is deliberately not automated.

All command examples must continue to use placeholders, keep protected outputs
outside Git, avoid private values and raw reports, and pass documentation-link
and publication-safety validation.

All listed completion criteria are covered by the implemented runbooks and the
operational documentation contract test. No live deployment, backup, recovery,
restart, or Pi mutation was performed to validate this documentation change.
