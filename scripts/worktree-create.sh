#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/worktree-create.sh <branch>

Create a new local branch from the latest origin/main and check it out in a
sibling worktree. Example:

  ./scripts/worktree-create.sh feat/add-backups
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -eq 1 ]] || {
  usage >&2
  exit 2
}

BRANCH="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
REPO_NAME="$(basename -- "$REPO_ROOT")"
WORKTREE_ROOT="$(dirname -- "$REPO_ROOT")"
WORKTREE_NAME="${REPO_NAME}-${BRANCH//\//-}"
WORKTREE_PATH="$WORKTREE_ROOT/$WORKTREE_NAME"

[[ -d "$REPO_ROOT/.git" ]] || die "run this helper from the permanent checkout, not a linked worktree"
[[ "$(git -C "$REPO_ROOT" branch --show-current)" == "main" ]] || die "the permanent checkout must be on main"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "invalid branch name: $BRANCH"
[[ "$BRANCH" != "main" ]] || die "main cannot be used as a task branch"
[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)" ]] || die "the permanent checkout must be clean"

printf 'Fetching origin/main...\n'
git -C "$REPO_ROOT" fetch origin '+refs/heads/main:refs/remotes/origin/main'

if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  die "local branch already exists: $BRANCH"
fi

if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  die "remote branch already exists: origin/$BRANCH"
fi

[[ ! -e "$WORKTREE_PATH" ]] || die "worktree path already exists: $WORKTREE_PATH"

git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WORKTREE_PATH" origin/main

printf '\nCreated worktree for %s at:\n%s\n\nEnter it with:\ncd %q\n' \
  "$BRANCH" "$WORKTREE_PATH" "$WORKTREE_PATH"
