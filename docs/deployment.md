# Deployment

`scripts/deploy-config.sh` is the only supported production configuration
deployment interface. Its plan is Pi-read-only and binds the rendered candidate,
verified recovery artifacts, live Pi pre-state, and both UTC clocks into a
protected approval artifact. Apply consumes that exact artifact before any
remote mutation and cannot replay it.

This procedure does not authorize image import or runtime recovery. Follow it
from the repository root in a clean linked worktree containing the exact
reviewed candidate.

## 1. Prepare the private deployment environment

For a new operator checkout, copy the sanitized example into the ignored local
file, protect it, and replace every placeholder locally:

```sh
cp config/deployment.env.example config/deployment.env
chmod 600 config/deployment.env
```

Do not print or commit the resulting file. Shell-provided `NEXTCLOUD_*` values
may override it for one-off automation. `NEXTCLOUD_REMOTE_PROJECT_DIR` must end
in `nextcloud-docker`; operational scripts depend on that stable Compose project
name.

Confirm the worktree has no unintended changes before operating production:

```sh
git status --short --branch
```

## 2. Render and inspect the candidate

Choose a new or empty absolute protected directory outside Git:

```sh
RENDERED_CONFIG=/absolute/private/rendered-nextcloud-candidate
scripts/render-deployment-config.sh --output-dir "$RENDERED_CONFIG"
```

Inspect `docker-compose.yml` beside `caddy/Caddyfile`, plus the separate
`systemd/`, `launcher/`, `active-images/`, and `storage/` review inputs. The
renderer does not contact the Pi. Never commit or publish its output.

Run deployment-readiness preflight:

```sh
scripts/preflight.sh --readiness
```

Readiness may report the reviewed transition from the current baseline as
warnings. Any hard failure blocks deployment. Preflight is read-only and is not
authorization to copy files or restart services.

## 3. Prepare the Pi-only Compose environment when required

Database credentials remain only in the Pi project's untracked mode-`0600`
`.env`. Check its state without changing the Pi:

```sh
scripts/prepare-env-migration.sh --check
```

Exit status `0` means the protected file already has the required schema. Exit
status `2` with `Pi-only .env is absent` identifies the supported one-time
migration path. Any malformed or unexpected existing file is a hard failure.

For the absent-file case, first create and verify a fresh configuration backup
using [the configuration backup procedure](backup-and-rollback.md#configuration-backup).
Then stop for explicit human approval of the one-time `.env` creation. No
approval artifact is generated for this migration.

After approval, use the exact verified backup path:

```sh
scripts/prepare-env-migration.sh --apply "$CONFIG_BACKUP"
scripts/prepare-env-migration.sh --check
```

Migration copies the running database container's existing values into a new
protected Pi-only `.env`; it refuses to overwrite a file and does not replace
Compose configuration or restart services.

## 4. Prove the deployment transaction mechanics

Check the disposable drill prerequisites:

```sh
scripts/test-deploy-transaction.sh --check
```

Stop until the operator approves the harmless remote test units and disposable
`/tmp` targets. This is a human approval pause, not an approval artifact. Then
run:

```sh
scripts/test-deploy-transaction.sh --apply
```

The drill forces a disposable dependency failure, proves atomic rollback,
approval no-replay, and the storage gate, then removes every test target. It
does not access live Nextcloud configuration, Docker objects, images, volumes,
mounts, runtime data, or `.env`.

## 5. Create the recovery inputs

Create and verify these three protected artifacts under their separately
approved procedures:

1. [`CONFIG_BACKUP`](backup-and-rollback.md#configuration-backup)
2. [`RUNTIME_BACKUP`](backup-and-rollback.md#runtime-backup)
3. [`IMAGE_RECOVERY`](recovery.md#image-recovery-and-restore-readiness), including
   its isolated restore-readiness attestation

Set the exact paths printed by those procedures:

```sh
CONFIG_BACKUP=/absolute/private/nextcloud-backups/config-backup-YYYYMMDDTHHMMSSZ
RUNTIME_BACKUP=/absolute/private/nextcloud-backups/runtime-backup-YYYYMMDDTHHMMSSZ
IMAGE_RECOVERY=/absolute/private/nextcloud-image-recovery/image-recovery-YYYYMMDDTHHMMSSZ
```

Reverify all three without contacting or changing the Pi:

```sh
scripts/verify-config-backup.sh "$CONFIG_BACKUP"
scripts/verify-runtime-backup.sh "$RUNTIME_BACKUP"
scripts/verify-image-recovery.sh --require-attestation "$IMAGE_RECOVERY"
```

At plan time the configuration manifest, runtime manifest, image manifest, and
image restore attestation must each be no more than one hour old. The deployer
also requires the configuration backup's Compose and Caddy files to match the
current live pre-state. Recreate any stale or mismatched artifact; do not edit a
manifest or backup.

## 6. Create and review the deployment plan

Create the exact redacted plan:

```sh
scripts/deploy-config.sh --plan \
  "$CONFIG_BACKUP" \
  "$RUNTIME_BACKUP" \
  "$IMAGE_RECOVERY"
```

The command validates the target, source-locked images, Pi-only `.env`, rendered
Compose and Caddy configuration, mount gates, launcher, recovery artifacts,
clock skew, and live pre-state. It prints a redacted file-hash transition and a
protected approval artifact path.

Set the printed path explicitly:

```sh
APPROVAL_ARTIFACT=/absolute/private/deploy-approvals/approval-SHA256-EPOCH.tsv
```

Before approval, review all of the following:

- the target hostname and candidate fingerprint;
- every live-to-candidate file hash;
- source-locked image tags and lock hash;
- actions: safety baseline, Compose/Caddy replacement, daemon reload, restart,
  health check, and configuration rollback; and
- exclusions: `.env`, runtime data, volumes, images, pulls, pruning, image
  removal, and runtime recovery.

The generated file records the exact authority but is not human approval by
itself. Stop until the operator approves that target, candidate, restart,
configuration rollback, and those exact actions and exclusions.

## 7. Apply within 15 minutes

The approval expires 15 minutes after planning. With no candidate, artifact,
argument, or live pre-state changes, apply it once:

```sh
scripts/deploy-config.sh --apply \
  "$APPROVAL_ARTIFACT" \
  "$CONFIG_BACKUP" \
  "$RUNTIME_BACKUP" \
  "$IMAGE_RECOVERY"
```

Apply recaptures and compares the bound state, then atomically marks the
approval consumed before staging or remote mutation. A staging or apply failure
after consumption requires a new plan and approval.

The transaction installs the safety baseline first. It then replaces only the
tracked Compose and Caddy application configuration, reloads systemd, restarts
`nextcloud.service`, and runs the full health check. It never copies `.env` or
runtime data and never pulls, prunes, removes, or imports images.

## 8. Confirm the outcome

Successful apply prints `Deployment applied with consumed approval artifact`.
Run the standalone read-only health check once more for the operational record:

```sh
scripts/health-check.sh
scripts/preflight.sh --conformance
```

Health validation covers target identity, storage, active-image identity,
containers, MariaDB, Nextcloud installation and maintenance state, direct app
port policy, Caddy configuration, and HTTPS.

If safety-baseline installation fails, the transaction restores the previous
safety files. If application installation, restart, or health validation fails,
it restores the verified Compose and Caddy pre-state and checks rollback health.
Follow the exact terminal message:

- `application change rolled back` means live configuration was restored; make
  a new plan before retrying;
- `preserve remote recovery stage` means automatic rollback or cleanup did not
  finish and manual inspection is required; and
- a consumed artifact is never reusable, even when no live change remains.

Configuration rollback does not authorize runtime recovery or image import.
Those remain separate procedures and approvals.

## 9. Dispose of the rendered candidate

Keep the protected rendered candidate until successful deployment or completed
rollback has been confirmed and any required diagnosis is finished. It contains
deployment-identifying configuration and should not remain on disk afterward.

Before removal, reset the variable to the exact path chosen in step 2 and
validate that it is an owned, non-symlink directory outside a Git worktree. The
literal comparison is an intentional deletion guard; replace both occurrences
when choosing a different private path:

```sh
RENDERED_CONFIG=/absolute/private/rendered-nextcloud-candidate
test "$RENDERED_CONFIG" = /absolute/private/rendered-nextcloud-candidate
test -d "$RENDERED_CONFIG" && test ! -L "$RENDERED_CONFIG" && test -O "$RENDERED_CONFIG"
if git -C "$RENDERED_CONFIG" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'Refusing to remove a directory inside a Git worktree\n' >&2
  exit 1
fi
find "$RENDERED_CONFIG" -depth -delete
test ! -e "$RENDERED_CONFIG" && test ! -L "$RENDERED_CONFIG"
unset RENDERED_CONFIG
```

Never reuse a rendered directory for a later deployment. Create a new empty
protected directory so stale files cannot enter a future review.
