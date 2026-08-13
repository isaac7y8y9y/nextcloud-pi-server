#!/usr/bin/env bash

# Production transaction policy. Callers provide the named operations; tests
# inject failures into these same branches instead of modeling another flow.

deployment_run_safety_transaction() {
  if ! deployment_safety_validate; then
    return 1
  fi
  if deployment_safety_install && deployment_daemon_reload; then
    return 0
  fi
  deployment_safety_restore || return 2
  deployment_daemon_reload || return 2
  return 1
}

deployment_run_application_transaction() {
  if deployment_application_install && deployment_restart && deployment_health; then
    return 0
  fi
  deployment_application_restore || return 2
  deployment_daemon_reload || return 2
  deployment_restart || return 2
  deployment_rollback_health || return 2
  return 1
}
