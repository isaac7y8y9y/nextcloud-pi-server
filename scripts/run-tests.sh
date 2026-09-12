#!/usr/bin/env bash
# Runs the fixed, pull-request-safe repository test tier; live operator drills
# intentionally have no aggregate runner.
set -euo pipefail

usage() {
  printf 'Usage:\n  %s pr\n  %s --list pr\n  %s --help\n' "$0" "$0" "$0"
}

readonly REPOSITORY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly -a PR_COMMANDS=(
  'bash -n scripts/*.sh scripts/lib/*.sh privileged/nextcloud-pi-ops privileged/nextcloud-pi-bundle-installer systemd/nextcloud-pi-validate-active-images'
  'bash scripts/test-privileged-helper.sh'
  'bash scripts/test-privileged-installer.sh'
  'bash scripts/test-privileged-locks.sh'
  'bash scripts/test-privileged-sudoers.sh'
  'bash scripts/check-privileged-sudo-calls.sh'
  'bash scripts/test-deployment-config.sh'
  'bash scripts/test-compose-env-references.sh'
  'bash scripts/test-image-lock.sh'
  'bash scripts/test-active-images.sh'
  'bash scripts/test-compose-launcher.sh'
  'bash scripts/test-atomic-transaction.sh'
  'bash scripts/test-image-import.sh'
  'bash scripts/test-image-import-transaction.sh'
  'bash scripts/test-image-import-interruption.sh'
  'bash scripts/test-image-recovery-attestation.sh'
  'bash scripts/test-image-readiness-lifecycle.sh'
  'bash scripts/test-runtime-recovery-regression.sh'
  'bash scripts/test-ssh-keepalive.sh'
  'bash scripts/test-deploy-config.sh'
  'bash scripts/test-health-check.sh'
  'bash scripts/test-preflight.sh'
  'python3 scripts/test-documentation-links.py'
  'python3 scripts/check-documentation-links.py'
  'python3 scripts/test-operational-documentation.py'
  'python3 scripts/test-public-safety.py'
  'python3 scripts/check-public-safety.py'
  'python3 scripts/check-public-safety.py --history'
  'bash scripts/test-public-config.sh'
)

main() {
  local command
  case "$#:$*" in
    1:--help) usage; return 0 ;;
    1:pr) ;;
    2:--list\ pr)
      printf '%s\n' "${PR_COMMANDS[@]}"
      return 0
      ;;
    *) usage >&2; return 2 ;;
  esac

  cd "$REPOSITORY_ROOT"
  for command in "${PR_COMMANDS[@]}"; do
    printf '+ %s\n' "$command"
    bash -c "$command"
  done
}

main "$@"
