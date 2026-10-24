#!/usr/bin/env python3
"""Manager approval checks use disposable packages and inert SSH/SCP programs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        repo = self.root / 'repo'
        files = ['scripts/manage-pi-privileged-interface.sh', 'scripts/lib/deployment-config.sh',
                 'scripts/lib/image-lock.sh', 'config/image-lock.env', 'privileged/bundle-manifest.tsv',
                 'privileged/privileged-policy.conf.example', 'privileged/nextcloud-pi-automation.sudoers.in',
                 'privileged/nextcloud-pi-bundle-installer']
        files += [line.split('\t')[2] for line in (ROOT / 'privileged/bundle-manifest.tsv').read_text().splitlines() if line.startswith('file\t')]
        for name in files:
            target = repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        config = repo / 'config/deployment.env'
        config.write_text('NEXTCLOUD_PI_HOST=pi.test.invalid\nNEXTCLOUD_PI_SYSTEM_HOSTNAME=pi-test\nNEXTCLOUD_PI_USER=test-user\nNEXTCLOUD_REMOTE_PROJECT_DIR=/srv/repair-fixture/nextcloud-docker\nNEXTCLOUD_STORAGE_MOUNT=/mnt/test-nextcloud\nNEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111\nNEXTCLOUD_PUBLIC_HOSTNAME=nextcloud.test.invalid\n')
        config.chmod(0o600)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.events = self.root / 'events'
        for name in ('ssh', 'scp'):
            script = self.bin / name
            script.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >>"$REPAIR_TEST_EVENTS"\ncase "$*" in *"ops version"*) printf "version\\t1\\nmanifest_sha256\\t%s\\n" "' + '1' * 64 + '";; esac\n')
            script.chmod(0o700)
        self.env = {**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
                    'NEXTCLOUD_PRIVILEGED_APPROVAL_ROOT': str(self.root / 'approvals'),
                    'NEXTCLOUD_DEPLOYMENT_ENV_FILE': str(config), 'REPAIR_TEST_EVENTS': str(self.events)}
        for key in tuple(self.env):
            if key.startswith('NEXTCLOUD_') and key not in ('NEXTCLOUD_PRIVILEGED_APPROVAL_ROOT', 'NEXTCLOUD_DEPLOYMENT_ENV_FILE'):
                del self.env[key]
        self.manager = repo / 'scripts/manage-pi-privileged-interface.sh'
        self.snapshot = self.root / 'original.json'
        shutil.copyfile(ROOT / 'scripts/fixtures/upgrade-freeze-table.json', self.snapshot)
        self.snapshot.chmod(0o600)

    def run_manager(self, *args, success=True):
        result = subprocess.run(['bash', str(self.manager), *map(str, args)], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def plan(self):
        result = self.run_manager('--plan-held-freeze-repair', self.snapshot, '20260910T000000Z-100', '2' * 64)
        return Path(result.stdout.split('Approval artifact: ')[1].strip())

    def test_apply_repair_consumes_once_and_dispatches_only_repair(self):
        artifact = self.plan()
        self.run_manager('--apply-held-freeze-repair', artifact)
        self.assertIn('state\tconsumed', artifact.read_text())
        self.assertIn('repair-held-freeze', self.events.read_text())
        before = self.events.read_text()
        self.run_manager('--apply-held-freeze-repair', artifact, success=False)
        self.assertEqual(self.events.read_text(), before)

    def test_modes_cannot_exchange_authority(self):
        artifact = self.plan()
        self.run_manager('--apply', artifact, success=False)
        result = self.run_manager('--plan')
        normal = Path(result.stdout.split('Approval artifact: ')[1].strip())
        self.run_manager('--apply-held-freeze-repair', normal, success=False)
        self.assertNotIn('sudo /bin/bash', self.events.read_text())

    def test_changed_snapshot_source_binding_and_closed_schema_rejected(self):
        for mutation in ('snapshot', 'source', 'binding', 'schema', 'expiry'):
            with self.subTest(mutation=mutation):
                artifact = self.plan()
                original_artifact = artifact.read_text()
                package = Path(dict(line.split('\t', 1) for line in original_artifact.splitlines())['package'])
                source = self.manager.parent.parent / 'privileged/nextcloud-pi-bundle-installer'
                original_source = source.read_bytes()
                if mutation == 'snapshot':
                    with (package / 'original-freeze.json').open('ab') as stream:
                        stream.write(b' ')
                elif mutation == 'source':
                    source.write_bytes(original_source + b'\n# changed\n')
                elif mutation == 'binding':
                    artifact.write_text(original_artifact.replace('current_raw_sha256\t' + '2' * 64, 'current_raw_sha256\t' + '3' * 64))
                elif mutation == 'schema':
                    artifact.write_text(original_artifact + 'mode\trepair-held-freeze\n')
                else:
                    fields = dict(line.split('\t', 1) for line in original_artifact.splitlines())
                    artifact.write_text(original_artifact.replace(fields['created'], str(int(fields['created']) - 1000)).replace(fields['expires'], str(int(fields['expires']) - 1000)))
                before = self.events.read_text()
                self.run_manager('--apply-held-freeze-repair', artifact, success=False)
                self.assertEqual(self.events.read_text(), before)
                source.write_bytes(original_source)

if __name__ == '__main__':
    unittest.main()
