#!/usr/bin/env bash
set -euo pipefail
readonly DEPLOYER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/deploy-config.sh"
bash -n "$DEPLOYER"
for text in deploy-approval-v2 transaction_id bundle_manifest_sha256 active-record\ prepare active-record\ rollback active-record\ commit 'service restart' root-code; do grep -Fq "$text" "$DEPLOYER"; done
grep -Fq 'readonly RECOVERY_ARTIFACT_MAX_AGE_SECONDS=86400' "$DEPLOYER"
grep -Fq 'backup is older than 24 hours' "$DEPLOYER"
grep -Fq 'application_paths_replaceable' "$DEPLOYER"
grep -Fq 'deployment_uid=\$(id -u)' "$DEPLOYER"
grep -Fq 'test -w \"\$directory\"' "$DEPLOYER"
grep -Fq "stat -c '%u'" "$DEPLOYER"
grep -Fq 'live application configuration is not safely replaceable by the deployment user' "$DEPLOYER"
! grep -Eq 'sudo -n (systemctl|install|cp|mv|rm|mkdir|rmdir|cat|awk|sha256sum)' "$DEPLOYER"
grep -Fq 'atomic_replace_preserve' "$DEPLOYER"
grep -Fq 'ROLLBACK_ARMED=1' "$DEPLOYER"
grep -Fq 'Deployment interruption cleanup is incomplete' "$DEPLOYER"
grep -Fq 'deployment_application_restore || rollback_failed=1' "$DEPLOYER"
grep -Fq 'deployment_active_rollback || rollback_failed=1' "$DEPLOYER"
grep -Fq 'deployment_rollback_health || rollback_failed=1' "$DEPLOYER"
printf 'configuration deployment boundary tests passed\n'
