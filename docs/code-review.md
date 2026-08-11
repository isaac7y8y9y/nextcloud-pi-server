# Code Review Standard

This is the canonical engineering-review policy for pull requests, branch
diffs, commits, and uncommitted changes. Review as an owner of this sanitized
Nextcloud operations repository: prioritize correct behavior, data safety,
privacy, recovery, and future maintenance over style preferences.

## Review roles

`code_review` applies this standard to answer whether an implementation is good
engineering for this repository. It does not decide whether work matches an
implementation plan.

`review_my_pr` first compares a PR with its provided implementation-plan
reference, then applies this standard. Plan alignment is additional PR context;
it never weakens the engineering requirements below. The plan identifies what
the PR intended to build, while this document defines whether the resulting
implementation is acceptable.

## Review process

1. Read applicable `AGENTS.md` files, the relevant task or PR description, and
   repository documentation governing the changed behavior.
2. Determine the intended base and diff scope from PR metadata. If unavailable,
   compare the current branch with `origin/main` from their merge base and
   disclose when the local reference may be stale.
3. Inspect the complete diff and only the targeted surrounding implementation,
   configuration, tests, documentation, and workflows needed to evaluate it.
4. For material interfaces, trace relevant producers and consumers rather than
   only adjacent lines. This includes service names, Compose identifiers, ports,
   environment variables, paths, mount points, configuration keys, Caddy proxy
   targets, systemd assumptions, CLI contracts, backup paths, health endpoints,
   and rendered configuration.
5. Run relevant safe, read-only checks when practical. Do not edit files,
   alter Git state, deploy, mutate a target, approve, request changes, or post
   comments as part of a review.
6. Report each root cause once at the narrowest useful changed location.

## Finding threshold

Report a finding only when all of these are true:

- The change introduces the issue, worsens it, makes it newly reachable, or
  leaves a material planned/new execution path incomplete.
- The trigger and impact are concrete and realistic.
- The finding has evidence in the diff or directly related code, configuration,
  documentation, or validation.
- A specific safe correction or engineering decision is available.

Verify tooling and configuration compatibility claims against authoritative
documentation or direct runtime evidence. Suppress formatting preferences,
speculative redesigns, harmless repetition, theoretical failures without a
realistic trigger, and requests for tests that do not name a concrete behavior
or failure mode.

## Review dimensions

### Correctness, behavior, and compatibility

- Verify stated behavior and existing contracts are preserved, including input
  validation, output correctness, exit status, ordering, command construction,
  shell quoting, paths, environment variables, errors, retries, idempotence,
  cleanup, stale state, and realistic races.
- For material behavior, reason through inputs, preconditions, state
  transition, observable outputs and side effects, failure state, and recovery.
  A command merely completing is not enough evidence for an operational
  behavior.
- Verify expected observable results as applicable: generated configuration,
  process or container state, proxy routing, database connectivity, mount
  state, service health, and value-safe diagnostics.
- For changed execution paths, consider realistic boundaries such as failed
  commands, early shell exits, interrupted SSH, unavailable Docker or Compose,
  unhealthy containers, unavailable database or storage, partial replacement,
  failed restart, and failed rollback. Do not invent exotic failures solely to
  create a finding.

### Configuration and integration contracts

- When configuration changes, check the applicable Compose templates and
  `.env` contract, sanitized examples, Caddy, systemd, deployment/preflight,
  backup and recovery scripts, storage configuration, health checks, tests, and
  documentation for stale names, paths, ports, commands, or assumptions.
- Preserve the stable `nextcloud-docker` project-directory basename and its
  Compose-derived service/container/volume naming unless a deliberate,
  documented migration updates every relevant consumer.
- Keep rendered Compose and Caddy co-located as the renderer expects; systemd
  and fstab remain separate rendered review/install inputs.
- Treat configuration propagation, integration changes, and documentation as
  part of the behavior, not optional follow-up work.

### Security and privacy

Apply [`security-boundaries.md`](security-boundaries.md) as the source of
truth. Reject committed or exposed credentials, tokens, cookies, private keys,
certificates, database or uploaded data, raw/generated live configuration,
backup archives, runtime volumes, and deployment-identifying infrastructure or
personal details. Review shell/command injection, unsafe interpolation, secret
output in diagnostics or logs, permissive files, exposed network services, and
TLS, trust, or authentication regressions.

Tracked templates must remain sanitized. Deployment identity is loaded from the
ignored, regular mode-`0600` local deployment environment; the Pi-only Compose
`.env` is a separate mode-`0600` credential file. The review output must not
repeat sensitive values.

### Operational and data safety

Apply [`deployment.md`](deployment.md),
[`backup-and-rollback.md`](backup-and-rollback.md),
[`recovery.md`](recovery.md), and [`storage.md`](storage.md) when relevant.

- Deployment is currently blocked: the repository has no approved apply
  procedure. No PR may treat rendering, preflight, backup, or migration
  preparation as authorization to copy files to the Pi or restart services.
- A future deploy/apply path must validate target identity and rendered
  configuration without printing private values; create and verify the
  appropriate protected backup/recovery point; present a redacted dry-run/live
  comparison; obtain explicit approval immediately before replacement or
  restart; perform meaningful Docker, MariaDB, Nextcloud, HTTPS, storage-mount,
  and maintenance-mode health checks; and roll back from verified protected
  state when apply or health checks fail.
- Never synchronize, overwrite, clean up, or delete live uploaded files,
  database storage, Caddy runtime TLS state, or the Pi-only `.env` from
  repository state. A backup that succeeds does not justify an unsafe apply.
- Preflight and diagnostics must stay read-only unless a separately named
  operation has explicit user approval. Migration, recovery, and rollback must
  bind to the configured target and protect live state, including on failure or
  interruption.
- Nextcloud must not start until the configured storage mount is present;
  otherwise host-local directories can be created. Check this invariant on
  successful, failure, and recovery paths when a change can affect it.

`docs/known-risks.md` is baseline context. Report a listed risk only when the
change introduces it, worsens it, or makes it newly reachable.

### Simplicity and maintainability

Apply the engineering conventions in `AGENTS.md`. Prefer the smallest direct
implementation that satisfies the requirement, reuse existing guarded
mechanisms where appropriate, and keep one clear source of truth for policy,
configuration, and operational behavior. Report redundancy only when it causes
concrete competing behavior, drift, unclear ownership, mutation, security
exposure, or meaningful maintenance risk.

### Validation and documentation

Trace important behavior from requirement to implementation to validation
evidence. Require validation proportional to impact, including material failure
paths. Prefer deterministic checks in scripts or CI over instructions to test
manually. Validation must exercise the behavioral contract, not merely show
that a command exited successfully.

Verify executable configuration, sanitized examples, tests, and documentation
remain aligned. State checks not run and the resulting residual risk. A
validation finding must name the behavior, the realistic regression it could
miss, and the smallest suitable improvement.

## Severity and verdict

- `P0`: catastrophic data loss, broad compromise, or system-wide outage risk.
- `P1`: merge-blocking correctness, security, data, or operational defect.
- `P2`: actionable, non-blocking maintainability, validation, or residual
  engineering risk.
- Do not report `P3` or style-only feedback by default.

Use these PR verdicts:

- `Request changes` when any `P0` or `P1` finding exists.
- `Comment` when only `P2` findings, material questions, or residual validation
  risks remain.
- `Approve` when there are no actionable findings and validation is adequate.

## Deployment readiness

Assess deployment readiness separately from the PR verdict as `Ready`, `Ready
after listed pre-deployment checks`, `Not ready`, or `Not assessable from
available evidence`. Approval means the change is acceptable to merge; it does
not prove that the live Raspberry Pi was tested or authorize deployment.

For changes that would deploy or restart services, the current documented
deployment block normally makes readiness `Not ready` until an approved apply
procedure exists. Otherwise disclose any environment-dependent checks needed
before production use. Readiness requires applicable planned functionality,
repository invariants, integration contracts, realistic failure/recovery
behavior, validation, and sensitive-state protection to be adequately covered.

## Output format

List findings first, ordered by severity and then file location:

```text
[P1] Concise actionable title — path/to/file:line
Triggering condition, concrete impact, and simplest safe correction.
```

Keep findings concise and direct. If there are none, write `No actionable
findings`. Then provide:

```text
Verdict
...

Deployment readiness
...

Validation
...
```

Add `Residual risk` only when material. `review_my_pr` additionally puts a
concise `Plan alignment` section before findings; ordinary `code_review` does
not.
