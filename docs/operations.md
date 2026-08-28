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

## Focused local validation

Validate Bash syntax and the documentation tooling without contacting the Pi:

```sh
bash -n scripts/*.sh scripts/lib/*.sh
python3 scripts/test-documentation-links.py
python3 scripts/check-documentation-links.py
python3 scripts/test-operational-documentation.py
python3 scripts/test-public-safety.py
python3 scripts/check-public-safety.py
```

When Docker is available, validate the sanitized rendered Compose and Caddy
configuration:

```sh
bash scripts/test-public-config.sh
```

Before publication, also scan every reachable Git revision:

```sh
python3 scripts/check-public-safety.py --history
```

The history scan is read-only but may take longer. It emits only redacted
finding references and fingerprints.

## Full regression validation

The canonical full test sequence is the `Run repository and publication-safety
tests` step in [the public-safety workflow](../.github/workflows/public-safety.yml).
Run that explicit sequence locally when its Bash, Python, and Docker
prerequisites are available, then confirm the GitHub workflow passes for the
published branch.

The workflow also runs Gitleaks against complete reachable history. A
documentation-link, public-safety, or Gitleaks finding is a publication blocker;
fix the source rather than weakening a rule.
