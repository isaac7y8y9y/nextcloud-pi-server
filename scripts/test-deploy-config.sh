#!/usr/bin/env bash
set -euo pipefail
readonly DEPLOYER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/deploy-config.sh"
bash -n "$DEPLOYER"
for text in deploy-approval-v2 transaction_id bundle_manifest_sha256 active-record\ prepare active-record\ rollback active-record\ commit 'service restart' root-code; do grep -Fq "$text" "$DEPLOYER"; done
! grep -Eq 'sudo -n (systemctl|install|cp|mv|rm|mkdir|rmdir|cat|awk|sha256sum)' "$DEPLOYER"
grep -Fq 'atomic_replace_preserve' "$DEPLOYER"
printf 'configuration deployment boundary tests passed\n'
