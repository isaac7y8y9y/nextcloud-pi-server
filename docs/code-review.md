# Code Review Standard

Use this guide for pull requests, branch diffs, commits, and uncommitted-change
reviews. Review as an owner of the system: prioritize behavior, safety, and
future maintenance over style preferences.

## Review process

1. Read the applicable `AGENTS.md` files and the pull-request description when
   available.
2. Determine the intended base from pull-request metadata. When metadata is not
   available, review the current branch against `origin/main` from their merge
   base and disclose if the local ref may be stale.
3. Inspect the complete diff and only the surrounding implementation,
   configuration, tests, and documentation needed to evaluate it.
4. Run relevant read-only checks when practical. Never edit files, commit,
   push, approve, request changes, or post comments while reviewing.
5. Report each root cause once at the narrowest useful changed location.

## Finding threshold

Report a finding only when all of these are true:

- The change introduces the issue, worsens it, or makes it newly reachable.
- The impact is concrete and can occur under realistic conditions.
- The finding identifies evidence in the diff or directly related code.
- A specific safe correction or decision is available.

Verify tooling and configuration compatibility claims against current
authoritative documentation or direct runtime evidence.

Suppress formatting preferences, speculative refactors, harmless repetition,
and requests for tests that do not name a concrete behavior or failure mode.

## Review dimensions

### Correctness and compatibility

- Verify the change satisfies its stated behavior without breaking existing
  behavior, configuration shape, or operational assumptions.
- Trace validation, errors, exit statuses, partial failures, retries,
  idempotence, ordering, and cleanup where relevant.
- Check shell quoting, path handling, environment-variable behavior, command
  construction, and assumptions about installed tools.
- Consider race conditions or stale state only when the changed behavior can
  realistically encounter them.

### Security and privacy

- Reject committed secrets, credentials, private keys, session material,
  database contents, user data, raw live configuration, or logs that expose
  them. Apply `docs/security-boundaries.md` as the source of truth.
- Check for shell or command injection, unsafe interpolation, accidental secret
  output, overly broad permissions, and newly exposed network surfaces.
- Preserve the intended TLS, trust, and authentication boundaries.

### Operational and data safety

- Apply `docs/deployment.md` before accepting deployment behavior. Deployment
  must retain backup, environment preparation, validation, dry-run, rollback,
  explicit restart approval, and post-deployment health checks.
- Never permit Git synchronization, overwrite, cleanup, or deletion of live
  Nextcloud files, uploaded data, database files, or Caddy runtime TLS state.
- Keep preflight and diagnostic operations read-only unless a separately named
  operation and explicit user approval authorize mutation.
- Preserve documented compatibility constraints, including Compose project
  naming and proxy target assumptions, unless the change performs and
  documents a deliberate migration.

### Simplicity and maintainability

- Apply the engineering conventions in `AGENTS.md` to the changed
  implementation.
- Report a deviation only when it creates a concrete maintenance risk, and
  recommend the smallest correction that keeps behavior obvious.

### Validation and documentation

- Require validation proportional to the changed behavior and its failure
  impact, including failure paths when they carry material risk.
- Prefer deterministic checks in scripts or CI over review instructions.
- Verify documentation, sanitized examples, and executable configuration stay
  aligned.
- State checks that were not run and any resulting residual risk.

## Severity and verdict

- `P0`: catastrophic data loss, broad compromise, or system-wide outage risk.
- `P1`: merge-blocking correctness, security, data, or operational defect.
- `P2`: actionable, non-blocking maintainability or validation risk.
- Do not report `P3` or style-only feedback by default.

Use these verdicts:

- `Request changes` when any `P0` or `P1` finding exists.
- `Comment` when only `P2` findings, material questions, or residual validation
  risks remain.
- `Approve` when there are no actionable findings and validation is adequate.

## Output format

List findings first, ordered by severity and then by file location:

```text
[P1] Concise actionable title — path/to/file:line
Explain the triggering condition, concrete impact, and simplest safe correction.
```

Keep each finding concise and direct. After the findings, provide `Verdict` and
`Validation` sections. If there are no findings, write `No actionable findings`
before those sections.
