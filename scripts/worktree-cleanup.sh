#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/worktree-cleanup.sh <branch>

After a pull request has merged into main, remove its clean local worktree and
local branch. The remote branch is not deleted. Example:

  ./scripts/worktree-cleanup.sh feat/add-backups
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
EXPECTED_WORKTREE_PATH="$WORKTREE_ROOT/$WORKTREE_NAME"

[[ -d "$REPO_ROOT/.git" ]] || die "run this helper from the permanent checkout, not a linked worktree"
[[ "$(git -C "$REPO_ROOT" branch --show-current)" == "main" ]] || die "the permanent checkout must be on main"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "invalid branch name: $BRANCH"
[[ "$BRANCH" != "main" ]] || die "main cannot be removed"

if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  if [[ -e "$EXPECTED_WORKTREE_PATH" ]]; then
    die "the local branch is absent but its expected worktree path still exists: $EXPECTED_WORKTREE_PATH"
  fi

  printf 'Nothing to clean: local branch %s and its expected worktree are absent.\n' "$BRANCH"
  exit 0
fi

BRANCH_HEAD="$(git -C "$REPO_ROOT" rev-parse "refs/heads/$BRANCH")"
WORKTREE_PATH=""
CURRENT_WORKTREE_PATH=""

while IFS= read -r -d '' FIELD; do
  case "$FIELD" in
    "worktree "*) CURRENT_WORKTREE_PATH="${FIELD#worktree }" ;;
    "branch refs/heads/$BRANCH") WORKTREE_PATH="$CURRENT_WORKTREE_PATH" ;;
  esac
done < <(git -C "$REPO_ROOT" worktree list --porcelain -z)

if [[ -n "$WORKTREE_PATH" ]]; then
  [[ "$WORKTREE_PATH" == "$EXPECTED_WORKTREE_PATH" ]] || \
    die "branch is checked out at an unexpected path: $WORKTREE_PATH"
  [[ -z "$(git -C "$WORKTREE_PATH" status --porcelain --untracked-files=all)" ]] || \
    die "worktree has tracked or untracked changes: $WORKTREE_PATH"
elif [[ -e "$EXPECTED_WORKTREE_PATH" ]]; then
  die "expected path exists but is not a registered worktree: $EXPECTED_WORKTREE_PATH"
fi

command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required to verify the merged pull request"

printf 'Verifying the merged GitHub pull request for %s...\n' "$BRANCH"
if ! PR_DATA="$(
  cd -- "$REPO_ROOT"
  gh pr view "$BRANCH" \
    --json state,mergedAt,headRefOid,baseRefName,number,url \
    --jq '[.state, (.mergedAt // ""), .headRefOid, .baseRefName, (.number | tostring), .url] | @tsv'
)"; then
  die "unable to find or verify a GitHub pull request for $BRANCH"
fi

IFS=$'\t' read -r PR_STATE PR_MERGED_AT PR_HEAD PR_BASE PR_NUMBER PR_URL <<<"$PR_DATA"

[[ "$PR_STATE" == "MERGED" && -n "$PR_MERGED_AT" ]] || die "pull request #${PR_NUMBER:-unknown} is not merged"
[[ "$PR_BASE" == "main" ]] || die "pull request #$PR_NUMBER targets $PR_BASE, not main"
[[ "$PR_HEAD" == "$BRANCH_HEAD" ]] || \
  die "pull request #$PR_NUMBER head $PR_HEAD does not match local branch head $BRANCH_HEAD"

if [[ -n "$WORKTREE_PATH" ]]; then
  git -C "$REPO_ROOT" worktree remove "$WORKTREE_PATH"
  printf 'Removed worktree: %s\n' "$WORKTREE_PATH"
fi

# The PR verification above makes force deletion safe for squash and rebase merges,
# whose feature branch tips are not ancestors of main.
git -C "$REPO_ROOT" branch -D -- "$BRANCH"

printf 'Deleted local branch: %s\nVerified merged pull request: %s\nRemote branch left unchanged.\n' \
  "$BRANCH" "$PR_URL"
