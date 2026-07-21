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
