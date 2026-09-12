# Testing

`scripts/run-tests.sh pr` is the canonical repository test command for local
development and pull-request CI. It uses one fixed, fail-fast order and runs
only repository-safe checks; it never contacts the configured Pi, consumes a
private archive, or runs an approved mutation flow.

From the repository root, run:

```sh
scripts/run-tests.sh pr
```

Inspect the exact command list without executing it:

```sh
scripts/run-tests.sh --list pr
```

The local prerequisites are Bash, Python 3, Git, ripgrep, and Docker with
Compose. macOS and other non-Actions environments run the portable subsets of
the guarded Linux/root tests; GitHub Actions runs their disposable privileged
fixture branches. Docker is required for the final rendered Compose/Caddy
validation. Gitleaks remains a separate workflow-owned security gate because it
is installed externally rather than tracked as a repository test script.

Failures identify the boundary that needs attention: syntax failures prevent
the suite from starting; unit/regression failures identify a repository
contract; documentation failures identify stale command or inventory metadata;
publication-safety failures block unsafe material; Docker configuration failures
identify invalid rendered Compose/Caddy; and privileged-fixture cleanup failures
must be resolved before trusting a Linux integration result.

<!-- test-inventory:start -->
| Script | Coverage and requirements | Effects and cleanup | Approximate runtime | Current PR execution | Final tier |
| --- | --- | --- | ---: | --- | --- |
| `scripts/check-compose-env-references.sh` | Validates matching `${MYSQL_*}` references in a supplied Compose file; Bash and `awk` | Read-only | `<0.1s` | Transitive through `test-compose-env-references.sh` | PR-transitive |
| `scripts/check-documentation-links.py` | Validates tracked/untracked Markdown paths and heading fragments; Python and Git | Read-only | `0.03s` | Direct | PR-direct |
| `scripts/check-privileged-sudo-calls.sh` | Rejects non-dispatcher passwordless sudo calls in non-test shell scripts; Bash and ripgrep | Read-only | `0.01s` | Direct | PR-direct |
| `scripts/check-public-safety.py` | Detects forbidden files, deployment identity, and secret-like material in the tree or reachable history; Python and Git | Read-only; output is redacted | `0.10s` tree; `4.23s` history locally | Direct in both modes | PR-direct |
| `scripts/test-active-images.sh` | Exercises active-image record schema, modes, binding, ownership contract, and symlink rejection | Disposable local fixture removed by trap | `0.03s` | Direct | PR-direct |
| `scripts/test-atomic-transaction.sh` | Fault-injects the shared deployment transaction and verifies rollback ordering/state | Disposable local fixture and fake sudo; trap cleanup | `0.23s` | Direct | PR-direct |
| `scripts/test-compose-env-references.sh` | Exercises the Compose checker against valid and invalid synthetic templates | Disposable Compose fixture removed by trap | `0.02s` | Direct | PR-direct |
| `scripts/test-compose-launcher.sh` | Exercises rendered launcher image/service validation with fake Docker | Disposable rendered tree and fake commands; trap cleanup | `1.31s` | Direct | PR-direct |
| `scripts/test-deploy-config.sh` | Static guard for deployment approval, freshness, atomic apply, and rollback contracts | Read-only | `0.02s` | Direct | PR-direct |
| `scripts/test-deploy-transaction.sh` | Checks or performs the disposable Pi deployment rollback drill; deployment identity, SSH, helper, systemd, and explicit apply approval | Check is Pi-read-only; apply creates then removes disposable remote state; trap reports cleanup ID | `<1 min` expected on healthy LAN; not run in audit | Syntax only | Operator-only |
| `scripts/test-deployment-config.sh` | Exercises renderer placeholders, substitutions, permissions, output contents, and overwrite rejection | Disposable rendered tree removed by trap | `0.15s` | Direct | PR-direct |
| `scripts/test-documentation-links.py` | Unit-tests Markdown-link and heading parsing | Python temporary directories | `0.07s` | Direct | PR-direct |
| `scripts/test-health-check.sh` | Exercises retry bounds and rendered health/rollback policy with fake remote calls | Disposable fixture removed by trap | `0.06s` | Direct | PR-direct |
| `scripts/test-image-import-interruption.sh` | Fault-injects local image-import lifecycle interruption and recovery handling | Disposable state and fake Docker removed by trap | `0.01s` | Direct | PR-direct |
| `scripts/test-image-import-transaction.sh` | Exercises image-load/apply/rollback failures with fake transport, Docker, and systemd behavior | Disposable tags/state/fixtures removed by cleanup trap | `1.18s` | Direct | PR-direct |
| `scripts/test-image-import.sh` | Static import/attestation/approval contract guard plus clock-skew behavior | Read-only plus disposable extracted function | `0.06s` | Direct | PR-direct |
| `scripts/test-image-lock.sh` | Exercises locked tag/ID parsing and lookup | Read-only | `<0.01s` | Direct | PR-direct |
| `scripts/test-image-readiness-lifecycle.sh` | Static contract guard that the Mac lifecycle wrapper uses the privileged dispatcher, isolated namespaces, and no live Docker socket | Read-only; does not execute lifecycle modes | `0.02s` | Direct | PR-direct |
| `scripts/test-image-recovery-attestation.sh` | Exercises archive/attestation binding, hashes, platforms, tags, malformed data, and modes | Protected disposable archive fixture removed by trap | `0.52s` | Direct | PR-direct |
| `scripts/test-image-restore-readiness.sh` | Loads a verified private archive into an explicitly isolated Docker daemon and publishes attestation | Mutates isolated daemon and recovery directory; parent lifecycle owns daemon cleanup | Several minutes, archive-size dependent | Syntax plus static assertions in related tests | Operator-only |
| `scripts/test-operational-documentation.py` | Enforces operator command/runbook contracts and executable promises | Read-only | `0.01s` | Direct | PR-direct |
| `scripts/test-preflight.sh` | Static guard that preflight reads protected state only through the dispatcher | Read-only | `<0.01s` | Direct | PR-direct |
| `scripts/test-privileged-helper.sh` | Exercises helper parsing/archive safety portably and the installed dispatcher lifecycle on an ephemeral Linux runner; Bash, Python 3, tar, a C compiler, and Actions sudo | Local temp data; in Actions, root-owned fixtures, fake services, sockets, and units removed by trap | `0.31s` portable subset; CI portion to be measured | Direct | PR-direct |
| `scripts/test-privileged-installer.sh` | Exercises bundle install, upgrade, rollback, interruption, revocation, removal refusal, and cleanup; Bash, coreutils, and Actions sudo | In Actions only, disposable root-owned install tree and fake tools removed by trap | `<0.1s` portable subset; CI portion to be measured | Direct | PR-direct |
| `scripts/test-privileged-locks.sh` | Exercises helper/installer lock-root and lock-file symlink protections and modes; Bash and Actions sudo | In Actions only, disposable root-owned lock fixtures removed by trap | `<0.1s` portable subset; CI portion to be measured | Direct | PR-direct |
| `scripts/test-privileged-sudoers.sh` | Exercises exact sudoers authorization and denial surface; Bash, sudo, `visudo`, and `useradd` on Actions Linux | In Actions only, temporary system user and fixed-path fixture removed/restored by trap | `<0.1s` portable subset; CI portion to be measured | Direct | PR-direct |
| `scripts/test-public-config.sh` | Renders synthetic deployment config and validates Compose plus Caddy; Docker, Compose, network/cache for `caddy:2` | Local temp tree and `--rm` container; image may be pulled/cached | `6s` in audited Actions run | Direct separate step | PR-direct |
| `scripts/test-public-safety.py` | Unit-tests publication-safety detectors using value-safe fixtures | Disposable Git/environment fixtures | `0.13s` | Direct | PR-direct |
| `scripts/test-runtime-recovery-regression.sh` | Static guard that the live recovery drill uses dispatcher actions and no broad direct sudo | Read-only; does not restore data | `0.01s` | Direct | PR-direct |
| `scripts/test-runtime-recovery.sh` | Restores a verified private runtime backup into disposable Pi paths and a disposable MariaDB container | Check is Pi-read-only; apply mutates disposable storage/container state and owns cleanup/retry ID | Minutes to tens of minutes, backup-size dependent | Syntax plus static wrapper assertions and helper integration | Operator-only |
| `scripts/test-ssh-keepalive.sh` | Enforces keepalive options on long image/runtime SSH and SCP streams | Read-only | `0.02s` | Direct | PR-direct |
<!-- test-inventory:end -->

## Coverage tiers

- **PR-direct**: the runner executes the script as a program.
- **PR-transitive**: a directly executed test invokes the script against a
  controlled fixture.
- **Operator-only**: the complete program needs private identity, target
  infrastructure, artifacts, privilege, or explicit approval.

Static checks are not behavioral lifecycle execution. In particular,
`test-image-readiness-lifecycle.sh` checks wrapper and dispatcher contracts but
does not run image-readiness check/apply/failure/cleanup. Linux-only branches
of guarded tests are likewise different from their portable macOS subsets.

## Operator-only procedures

No aggregate operator tier exists: these procedures retain their individual
approval and cleanup boundaries.

- [Deployment rollback drill](deployment.md) documents
  `scripts/test-deploy-transaction.sh --check` and the explicitly approved
  `--apply` flow.
- [Image recovery](recovery.md) documents
  `scripts/run-image-restore-readiness.sh --check`, `--apply`, and `--cleanup`.
  The lifecycle wrapper, not `test-image-restore-readiness.sh`, is the operator
  entry point.
- [Runtime recovery](recovery.md) documents
  `scripts/test-runtime-recovery.sh --check`, `--apply`, and `--cleanup`.

There are no path-filtered or scheduled test tiers. Both unfiltered `push` and
`pull_request` events run because the all-push publication-safety signal is
worth the small duplicate-run cost for internal branches.

The remaining automated coverage gap is tracked by
[#31: Restore hermetic end-to-end image restore-readiness coverage](https://github.com/isaac7y8y9y/nextcloud-pi-server/issues/31).
