# Repository Worktree Rulebook

This repository uses a permanent `main` checkout as the control worktree and a
separate linked worktree for every feature or maintenance branch.

## Required workflow

1. Keep the primary checkout on `main`. Do not make task changes or commits in
   the primary checkout.
2. Before starting a task, create an explicitly named branch and worktree from
   the latest `origin/main`:

   ```bash
   ./scripts/worktree-create.sh feat/example-change
   ```

3. Make changes, commit, push, and open the pull request from the new worktree.
4. Keep the worktree while its pull request is open or under review.
5. After GitHub reports that the pull request is merged into `main`, return to
   the primary checkout and clean up the local worktree and branch:

   ```bash
   ./scripts/worktree-cleanup.sh feat/example-change
   ```

## Safety rules

- Never create, modify, or delete `main` through the worktree helpers.
- Never remove a worktree containing tracked or untracked changes.
- Never delete a local branch until its exact head commit is associated with a
  merged GitHub pull request targeting `main`.
- Do not force-remove worktrees or bypass a helper's failed safety check.
- Local cleanup does not delete the remote branch. Remote branch cleanup is
  controlled by the GitHub repository's pull-request settings.
- Keep the permanent checkout and task worktrees together under
  `nextcloud-pi-server-root/`. Name each task worktree
  `nextcloud-pi-server-<branch>`, replacing branch-name slashes with hyphens.
  For example, `feat/example-change` belongs at
  `nextcloud-pi-server-root/nextcloud-pi-server-feat-example-change`.

## Engineering conventions

- Prefer the simplest direct implementation that satisfies the current
  requirement.
- Apply DRY to shared logic, policy, and domain knowledge that could drift. Do
  not add an abstraction solely to remove a few obvious repeated lines.
- Keep comments concise. Explain intent, constraints, or risk rather than
  restating what the code does.
- Keep runtime data, credentials, private keys, and live configuration out of
  Git.
- Keep diagnostics read-only unless the user explicitly requests a mutation.
- Structure operational changes as: validate, back up, dry-run, obtain explicit
  approval, apply, health-check, and roll back when needed.
- Write Bash with strict error handling, quoted expansions, validated inputs,
  clear failures, and safe repeatable behavior.
- Update documentation and sanitized configuration together when behavior or
  operational assumptions change.

## Code Review Rules

- Follow [`docs/code-review.md`](docs/code-review.md) for the shared review
  process, finding threshold, severity levels, and output format.
- Preserve the security and deployment boundaries documented under `docs/`.
- Treat `docs/known-risks.md` as baseline context. Report a known risk only when
  the change introduces it, worsens it, or makes it newly reachable.
- Use the project-scoped `code_review` custom agent for a general engineering
  review of a diff. Launch it with high reasoning and read-only permissions; it
  must not delegate further.
- Use the project-scoped `review_my_pr` custom agent for pull-request review
  when an implementation-plan link or reference is available. It verifies plan
  conformance and then applies the canonical engineering standard; launch it
  with high reasoning and read-only permissions, and do not let it delegate.
- Use the project-scoped `plan_review` custom agent after an implementation plan
  is written and before implementation begins. Provide the original ticket and
  proposed plan; launch it with high reasoning and read-only permissions. It
  must not delegate further, write or revise the plan, implement changes, or
  perform a pull-request review.
