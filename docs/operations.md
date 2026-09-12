# Operations

Run operational scripts from the repository root in a clean linked worktree
with a valid ignored mode-`0600` `config/deployment.env`. The scripts use
non-interactive SSH, validate configured identity and input syntax, and avoid
printing credential values. Preserve private reports, paths, backup manifests,
and rendered output outside Git.

Mutation-sensitive procedures have their own approval boundaries:

- [production deployment](deployment.md)
- [backup and rollback](backup-and-rollback.md)
- [runtime and image recovery](recovery.md)

## Read-only Pi checks

Use readiness mode before a candidate deployment. Reviewed candidate drift may
appear as warnings, while hard failures block planning:

```sh
scripts/preflight.sh --readiness
```

Use conformance mode after deployment or during routine operation. Any checked
drift is a failure:

```sh
scripts/preflight.sh --conformance
```

Run the bounded service health check independently at any time:

```sh
scripts/health-check.sh
```

All three commands are Pi-read-only. They do not create an approval artifact
and do not authorize deployment, restart, backup mutation, or recovery.

## Privileged-interface administration

Routine operations use the exact passwordless command
`sudo -n /usr/local/libexec/nextcloud-pi-ops`; no general-purpose sudo command
is supported. Before a first install or reviewed bundle upgrade, create and
review a private plan, then use an administrator-authenticated terminal:

```sh
scripts/manage-pi-privileged-interface.sh --plan
scripts/manage-pi-privileged-interface.sh --apply /absolute/private/approval.tsv
```

The plan and its rendered policy are private. Rollback, revoke, and removal are
separate authenticated actions; removal first requires revocation and a service
migration that no longer references the managed launcher. Removal also refuses
to proceed while active-record, runtime-recovery, image-readiness, isolated
daemon/socket, or disposable deployment-drill state remains. Complete those
lifecycles through their supported cleanup commands before retrying removal.

## Focused local validation

Run the complete pull-request-safe repository test tier without contacting the
Pi or using private deployment material:

```sh
scripts/run-tests.sh pr
```

It requires Bash, Python 3, Git, ripgrep, Docker, and Docker Compose. Inspect
the fixed command order without running it:

```sh
scripts/run-tests.sh --list pr
```

See the [testing guide](testing.md) for the full inventory, environment-specific
Linux/root behavior, Docker validation, failure interpretation, and the three
individual operator-only procedures. The runner includes the current-tree and
full-history publication-safety scans; Gitleaks remains a separate workflow
security gate.

## Full regression validation

The public-safety workflow invokes `scripts/run-tests.sh pr` as its one
repository-test step. It then installs and runs Gitleaks against complete
reachable history. A documentation-link, public-safety, or Gitleaks finding is
a publication blocker; fix the source rather than weakening a rule.

The three Pi/operator drills are intentionally absent from the runner. Use their
individual, approval-gated procedures in the deployment and recovery guides.

## Publication history scan

The runner's history scan is read-only but may take longer. It emits only
redacted finding references and fingerprints:

```sh
python3 scripts/check-public-safety.py --history
```
