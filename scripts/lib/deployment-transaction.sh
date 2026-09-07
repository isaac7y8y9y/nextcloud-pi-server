#!/usr/bin/env bash

# Retained for the existing isolated regression harness. Production deployment
# no longer supplies root-code safety operations to this transaction.
deployment_run_safety_transaction() {
  deployment_safety_validate || return 1
  if deployment_safety_install && deployment_daemon_reload; then return 0; fi
  deployment_safety_restore || return 2
  deployment_daemon_reload || return 2
  return 1
}

deployment_run_application_transaction() {
  local rollback_failed=0
  if ! declare -F deployment_active_prepare >/dev/null; then
    if deployment_application_install && deployment_restart && deployment_health; then return 0; fi
    deployment_application_restore || return 2
    deployment_daemon_reload || return 2
    deployment_restart || return 2
    deployment_rollback_health || return 2
    return 1
  fi
  deployment_active_prepare || return 1
  if deployment_active_apply && deployment_application_install && deployment_restart && deployment_health; then
    deployment_active_commit || return 2
    return 0
  fi
  deployment_application_restore || rollback_failed=1
  deployment_active_rollback || rollback_failed=1
  deployment_restart || rollback_failed=1
  deployment_rollback_health || rollback_failed=1
  (( rollback_failed == 0 )) || return 2
  deployment_active_commit || return 2
  return 1
}
