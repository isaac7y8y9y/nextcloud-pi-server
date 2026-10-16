#!/usr/bin/env python3
"""Exercise exact archive producer/consumer boundaries with disposable fake transports."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
BAD = 'sha256:' + 'a' * 64


class ExactRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('export-image-recovery.sh', 'verify-image-recovery.sh',
                     'test-image-restore-readiness.sh', 'restore-image-recovery.sh',
                     'lib/deployment-config.sh', 'lib/image-lock.sh', 'lib/image_identity.py',
                     'lib/image-import-approval.sh', 'lib/image-import-transfer.sh',
                     'lib/image-import-lifecycle.sh'):
            dest = self.repo / 'scripts' / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(HERE / name, dest)
        (self.repo / 'config').mkdir()
        shutil.copy2(HERE.parent / 'config/image-lock.env', self.repo / 'config/image-lock.env')
        lock = dict(line.split('=', 1) for line in (self.repo / 'config/image-lock.env').read_text().splitlines() if line.startswith('NEXTCLOUD_'))
        self.ids = {lock[f'NEXTCLOUD_IMAGE_{key}_TAG']: lock[f'NEXTCLOUD_IMAGE_{key}_ID'] for key in ('APP', 'DB', 'CADDY')}
        (self.root / 'ids.json').write_text(json.dumps(self.ids))
        config = self.root / 'deployment.env'
        config.write_text('NEXTCLOUD_PI_HOST=test.example.invalid\nNEXTCLOUD_PI_SYSTEM_HOSTNAME=test-pi\nNEXTCLOUD_PI_USER=tester\nNEXTCLOUD_REMOTE_PROJECT_DIR=/srv/test/nextcloud-docker\nNEXTCLOUD_STORAGE_MOUNT=/srv/test/storage\nNEXTCLOUD_STORAGE_UUID=11111111-1111-1111-1111-111111111111\nNEXTCLOUD_PUBLIC_HOSTNAME=cloud.example.invalid\n')
        config.chmod(0o600)
        self.env = dict(os.environ, NEXTCLOUD_DEPLOYMENT_ENV_FILE=str(config),
                        EXACT_FIXTURE=str(self.root), PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        # Clear operator overrides so this fixture never depends on private identity.
        for key in tuple(self.env):
            if key.startswith('NEXTCLOUD_') and key != 'NEXTCLOUD_DEPLOYMENT_ENV_FILE':
                del self.env[key]
        transport = '''#!/usr/bin/env python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['EXACT_FIXTURE'])
args=sys.argv[1:]
command=args[-1] if pathlib.Path(sys.argv[0]).name == 'ssh' else ' '.join(args)
with (root/'calls').open('a') as f: f.write(command+'\\n')
ids=json.loads((root/'ids.json').read_text())
fault=os.environ.get('EXACT_FAULT','')
store='classic' if fault == 'store' else 'containerd'
if 'docker info' in command or ' info' in command:
    print(json.dumps({'driver':'overlay2','status':[]} if store == 'classic' else {'driver':'overlayfs','status':[['driver-type','io.containerd.snapshotter.v1']]}))
elif 'image inspect' in command:
    tag=next(tag for tag in ids if tag in command)
    if 'platform' in command:
        print(('linux amd64 ' if fault == 'platform' else 'linux arm64 ')+'sha256:'+'b'*64)
    else:
        count=(root/'calls').read_text().count('image inspect')
        print('sha256:'+'a'*64 if fault == 'identity' or (fault == 'drift' and count > 3) else ids[tag])
elif 'image save' in command:
    sys.stdout.buffer.write(b'opaque archive fixture')
    if fault == 'save': sys.exit(1)
elif 'image ls -aq' in command:
    if fault == 'image-list': sys.exit(1)
    if fault == 'images': print('unexpected-image')
elif ' ps -aq' in command:
    if fault == 'container-list': sys.exit(1)
    if fault == 'containers': print('unexpected-container')
elif ' load ' in command: pass
elif 'hostname' in command and 'id -un' in command: pass
else: sys.exit('Unexpected transport: '+command)
'''
        for name in ('ssh', 'docker'):
            path = self.bin / name
            path.write_text(transport)
            path.chmod(0o755)

    def run_script(self, name, *args, ok=True):
        result = subprocess.run(['bash', str(self.repo / 'scripts' / name), *map(str, args)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def export(self, exact=True):
        output = self.root / 'archives'
        self.run_script('export-image-recovery.sh', '--output-root', output,
                        *(['--exact-source'] if exact else []))
        return next(output.glob('image-recovery-*'))

    def readiness(self, archive, ok=True):
        return self.run_script('test-image-restore-readiness.sh', '--docker-host',
                               'unix:///tmp/exact-test.sock', archive, ok=ok)

    def test_exact_export_readiness_and_platform_identity_are_distinct(self):
        archive = self.export()
        self.assertNotIn('image save --platform', (self.root / 'calls').read_text())
        self.readiness(archive)
        self.run_script('verify-image-recovery.sh', '--require-exact-source', archive)
        proof = (archive / 'restore-attestation.tsv').read_text()
        self.assertIn('platform_image\tnextcloud:31.0.14-apache\tsha256:' + 'b'*64, proof)
        self.assertIn('image\tnextcloud:31.0.14-apache\t' + self.ids['nextcloud:31.0.14-apache'], proof)

    def test_legacy_export_still_filters_and_is_ineligible_for_cutover(self):
        archive = self.export(False)
        self.assertIn('image save --platform', (self.root / 'calls').read_text())
        self.readiness(archive)
        self.run_script('verify-image-recovery.sh', '--require-attestation', archive)
        self.run_script('verify-image-recovery.sh', '--require-exact-source', archive, ok=False)

    def test_failed_or_drifting_export_never_publishes(self):
        for fault in ('save', 'identity', 'drift'):
            with self.subTest(fault=fault):
                self.env['EXACT_FAULT'] = fault
                output = self.root / fault
                (self.root / 'calls').unlink(missing_ok=True)
                self.run_script('export-image-recovery.sh', '--exact-source', '--output-root', output, ok=False)
                self.assertEqual(list(output.iterdir()), [])

    def test_readiness_failure_never_publishes_attestation(self):
        archive = self.export()
        for fault in ('store', 'identity', 'platform', 'containers', 'images', 'image-list', 'container-list'):
            with self.subTest(fault=fault):
                self.env['EXACT_FAULT'] = fault
                self.readiness(archive, ok=False)
                self.assertEqual(sorted(p.name for p in archive.iterdir()), ['images.tar', 'manifest.tsv'])

    def test_v2_schema_and_binding_fail_closed(self):
        archive = self.export()
        self.readiness(archive)
        originals = {p: p.read_bytes() for p in archive.iterdir()}
        manifest = archive / 'manifest.tsv'
        proof = archive / 'restore-attestation.tsv'
        changes = [(manifest, b'unknown\tx\n'), (manifest, b'image_store\tcontainerd\n'),
                   (proof, b'platform_image\tnextcloud:31.0.14-apache\t' + BAD.encode() + b'\n'),
                   (proof, b'image_store\tclassic\n')]
        for path, extra in changes:
            with self.subTest(extra=extra):
                path.write_bytes(originals[path] + extra)
                self.run_script('verify-image-recovery.sh', '--require-exact-source', archive, ok=False)
                path.write_bytes(originals[path])
        proof.write_text(proof.read_text().replace('image\tnextcloud:31.0.14-apache\t' + self.ids['nextcloud:31.0.14-apache'] + '\n', 'image\tnextcloud:31.0.14-apache\t' + BAD + '\n'))
        self.run_script('verify-image-recovery.sh', '--require-exact-source', archive, ok=False)
        proof.write_bytes(originals[proof])
        (archive / 'images.tar').write_bytes(b'changed archive')
        self.run_script('verify-image-recovery.sh', '--require-exact-source', archive, ok=False)

    def test_platform_import_rejects_v2_before_remote_prestate(self):
        archive = self.export()
        self.readiness(archive)
        (self.root / 'calls').write_text('')
        result = self.run_script('restore-image-recovery.sh', '--plan', archive, ok=False)
        self.assertIn('exact source archives belong to full-runtime restoration', result.stderr)
        self.assertEqual((self.root / 'calls').read_text(), '')


if __name__ == '__main__':
    unittest.main()
