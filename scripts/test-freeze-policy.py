#!/usr/bin/env python3
"""Exercise the installed parser itself, including immutable publication failures."""
import copy
from contextlib import nullcontext
import json
import os
from pathlib import Path
import tempfile
import types
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / 'privileged/nextcloud-pi-ops').read_text()
BODY = SOURCE.split('# BEGIN FREEZE POLICY\n')[1].split('# END FREEZE POLICY')[0]
MODULE = types.ModuleType('freeze_policy')
exec(compile(BODY, 'installed-freeze-policy', 'exec'), MODULE.__dict__)
RAW = (ROOT / 'scripts/fixtures/upgrade-freeze-table.json').read_bytes()

def portable_publication():
    if sys.platform == 'linux':
        return nullcontext()
    # Only the Linux syscall is substituted on macOS; Linux integration tests
    # execute the native exclusive rename through the installed dispatcher.
    def rename(source, target):
        if os.path.lexists(target):
            raise FileExistsError(target)
        os.rename(source, target)
    return patch.object(MODULE, 'rename_exclusive', side_effect=rename)

class PolicyTests(unittest.TestCase):
    def test_reboot_metadata_preserves_policy_but_changes_raw_authority(self):
        changed = json.loads(RAW)
        changed['nftables'][0]['metainfo']['version'] = '1.2.0'
        for entry in changed['nftables'][1:]:
            next(iter(entry.values()))['handle'] += 10
        changed['nftables'][3]['rule']['expr'][2]['match']['right']['set'].reverse()
        encoded = json.dumps(changed).encode()
        self.assertNotEqual(MODULE.digest(RAW), MODULE.digest(encoded))
        self.assertEqual(MODULE.policy(RAW), MODULE.policy(encoded))

    def test_policy_tampering_is_rejected(self):
        base = json.loads(RAW)
        mutations = [
            lambda d: d['nftables'].append(copy.deepcopy(d['nftables'][3])),
            lambda d: d['nftables'].pop(),
            lambda d: d['nftables'][1]['table'].update(family='ip'),
            lambda d: d['nftables'][1]['table'].update(name='other'),
            lambda d: d['nftables'][1]['table'].update(handle=True),
            lambda d: d['nftables'][2]['chain'].update(prio=-299),
            lambda d: d['nftables'][2]['chain'].update(policy='drop'),
            lambda d: d['nftables'][2]['chain'].update(hook='input'),
            lambda d: d['nftables'][3]['rule'].update(comment='unexpected'),
            lambda d: d['nftables'][3]['rule']['expr'].append({'counter': None}),
            lambda d: d['nftables'][3]['rule']['expr'].reverse(),
            lambda d: d['nftables'][3]['rule']['expr'][0]['match'].update(op='=='),
            lambda d: d['nftables'][3]['rule']['expr'][1]['match']['left']['fib'].update(flags=[]),
            lambda d: d['nftables'][3]['rule']['expr'][2]['match']['right'].update(set=[80, 443, 22]),
            lambda d: d['nftables'][3]['rule']['expr'][2]['match']['left']['payload'].update(protocol='udp'),
            lambda d: d['nftables'][3]['rule']['expr'][3].update(accept=None),
            lambda d: d['nftables'][0]['metainfo'].update(json_schema_version=True),
        ]
        for change in mutations:
            with self.subTest(change=mutations.index(change)):
                data = copy.deepcopy(base)
                change(data)
                with self.assertRaises((ValueError, KeyError, TypeError)):
                    MODULE.policy(json.dumps(data).encode())
        for raw in (b'{"nftables":[],"nftables":[]}', b'{}', RAW + b'x', b' ' * 65537):
            with self.assertRaises(ValueError):
                MODULE.policy(raw)

    def test_legacy_requires_original_bytes_and_current_raw_binding(self):
        changed = RAW.replace(b'"handle":7', b'"handle":4')
        authority = MODULE.digest(RAW)
        with tempfile.TemporaryDirectory() as root, patch.object(MODULE, 'current_table', return_value=changed):
            with self.assertRaises(ValueError):
                MODULE.main(['identity', root, '20260910T000000Z-1', authority])
            # A matching live policy alone cannot replace the original authority.
            with patch.object(MODULE.os, 'fdopen') as stream:
                stream.return_value.__enter__.return_value.read.return_value = changed
                with self.assertRaises(ValueError):
                    MODULE.main(['verify', root, '20260910T000000Z-1', authority, MODULE.digest(changed), str(len(changed))])

    def test_adoption_and_identity_use_original_authority(self):
        changed = RAW.replace(b'"handle":7', b'"handle":4')
        authority = MODULE.digest(RAW)
        with tempfile.TemporaryDirectory() as root, patch.object(MODULE, 'current_table', return_value=changed), patch.object(MODULE.os, 'fdopen') as stream, patch.object(MODULE, 'publish') as publish:
            stream.return_value.__enter__.return_value.read.return_value = RAW
            MODULE.main(['verify', root, '20260910T000000Z-1', authority, MODULE.digest(changed), str(len(RAW))])
            publish.assert_not_called()
            MODULE.main(['adopt', root, '20260910T000000Z-1', authority, MODULE.digest(changed), str(len(RAW))])
            publish.assert_called_once_with(os.path.join(root, 'table-20260910T000000Z-1.json'), RAW)
            with self.assertRaises(ValueError):
                MODULE.main(['adopt', root, '20260910T000000Z-1', authority, '0'*64, str(len(RAW))])

    def test_publication_is_exclusive_durable_and_preserves_existing_bytes(self):
        with tempfile.TemporaryDirectory() as root, patch.object(MODULE, 'protected_parents'), portable_publication():
            path = os.path.join(root, 'snapshot')
            MODULE.publish(path, RAW)
            self.assertEqual(Path(path).read_bytes(), RAW)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(os.stat(path).st_nlink, 1)
            with patch.object(MODULE, 'read_snapshot', return_value=RAW):
                MODULE.publish(path, RAW)
                with self.assertRaises(ValueError):
                    MODULE.publish(path, b'different')
            self.assertEqual(Path(path).read_bytes(), RAW)
            os.unlink(path)
            with patch.object(MODULE.os, 'fsync', side_effect=OSError('disk failure')):
                with self.assertRaises(OSError):
                    MODULE.publish(path, RAW)
            self.assertFalse(os.path.lexists(path))
            self.assertEqual(list(Path(root).iterdir()), [])
            # Failure after the atomic rename leaves a complete one-link file;
            # an identical retry can validate it without replacing authority.
            with patch.object(MODULE.os, 'fsync', side_effect=[None, OSError('directory sync interrupted')]):
                with self.assertRaises(OSError):
                    MODULE.publish(path, RAW)
            self.assertEqual(Path(path).read_bytes(), RAW)
            self.assertEqual(os.stat(path).st_nlink, 1)
            with patch.object(MODULE, 'read_snapshot', return_value=RAW), patch.object(MODULE, 'sync_parent', wraps=MODULE.sync_parent) as sync:
                MODULE.publish(path, RAW)
                sync.assert_called_once_with(path)
            self.assertEqual([item.name for item in Path(root).iterdir()], ['snapshot'])

    @unittest.skipUnless(sys.platform == 'linux', 'native Linux exclusive publication')
    def test_native_publication_never_overwrites_and_has_one_link(self):
        with tempfile.TemporaryDirectory() as root:
            source, target = Path(root) / 'temporary', Path(root) / 'published'
            source.write_bytes(RAW)
            MODULE.rename_exclusive(str(source), str(target))
            self.assertFalse(source.exists())
            self.assertEqual(target.stat().st_nlink, 1)
            source.write_bytes(b'changed')
            with self.assertRaises(FileExistsError):
                MODULE.rename_exclusive(str(source), str(target))
            self.assertEqual(target.read_bytes(), RAW)
            self.assertEqual(source.read_bytes(), b'changed')

    def test_unsafe_snapshot_link_and_mode_rejected(self):
        with tempfile.TemporaryDirectory() as root, patch.object(MODULE, 'protected_parents'):
            path = Path(root) / 'snapshot'
            path.write_bytes(RAW)
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                MODULE.read_snapshot(str(path))
            path.unlink()
            path.symlink_to('/dev/null')
            with self.assertRaises(OSError):
                MODULE.read_snapshot(str(path))

if __name__ == '__main__':
    unittest.main()
