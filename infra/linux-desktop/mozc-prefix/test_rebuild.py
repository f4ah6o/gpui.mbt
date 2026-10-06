import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('mozc_prefix_rebuild', HERE / 'rebuild.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecipeSafetyTests(unittest.TestCase):
    def test_offline_cache_is_hash_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archives = root / 'archives'
            cache = root / 'cache'
            archives.mkdir()
            cache.mkdir()
            payload = b'exact official archive bytes'
            (cache / 'source.tar.xz').write_bytes(payload)
            record = {'filename': 'source.tar.xz', 'size': len(payload),
                      'sha256': hashlib.sha256(payload).hexdigest(),
                      'url': 'https://deb.debian.org/debian/pool/main/m/mozc/source.tar.xz'}
            with patch.object(module, 'run', side_effect=AssertionError('No network/process expected')):
                dest = module.fetch(record, archives, [cache], True)
            self.assertEqual(dest.read_bytes(), payload)
            dest.write_bytes(b'changed')
            with self.assertRaisesRegex(RuntimeError, 'lock mismatch'):
                module.fetch(record, archives, [cache], True)

    def test_missing_offline_archive_stops(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = {'filename': 'missing.deb', 'size': 1, 'sha256': '0' * 64,
                      'url': 'https://deb.debian.org/debian/missing.deb'}
            with patch.object(module, 'run', side_effect=AssertionError('No network expected')):
                with self.assertRaisesRegex(RuntimeError, 'Missing verified offline'):
                    module.fetch(record, root, [], True)

    def test_nonofficial_download_origin_stops(self):
        with tempfile.TemporaryDirectory() as directory:
            record = {'filename': 'missing.deb', 'size': 1, 'sha256': '0' * 64,
                      'url': 'https://example.invalid/package.deb'}
            with patch.object(module, 'run', side_effect=AssertionError('No network expected')):
                with self.assertRaisesRegex(RuntimeError, 'Unapproved archive origin'):
                    module.fetch(record, Path(directory), [], False)

    def test_source_archive_traversal_stops(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'unsafe.tar'
            with tarfile.open(archive, 'w') as target:
                target.addfile(tarfile.TarInfo('../escape'))
            with self.assertRaisesRegex(RuntimeError, 'Unsafe source archive entry'):
                module.validate_tar(archive)

    def test_source_archive_link_escape_stops(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'unsafe.tar'
            with tarfile.open(archive, 'w') as target:
                member = tarfile.TarInfo('source/link')
                member.type = tarfile.SYMTYPE
                member.linkname = '/etc/passwd'
                target.addfile(member)
            with self.assertRaisesRegex(RuntimeError, 'Unsafe source archive link'):
                module.validate_tar(archive)

    def test_locked_scope_and_budget(self):
        lock = json.loads((HERE / 'build.lock.json').read_text())
        self.assertEqual(lock['source_version'], '2.29.5160.102+dfsg-1.4')
        self.assertEqual(lock['build_contract']['target'], 'ibus_mozc')
        self.assertEqual(lock['build_contract']['jobs'], 4)
        self.assertFalse(lock['build_contract']['renderer_built'])
        self.assertLess(sum(p['size'] for p in lock['sources']) +
                        sum(int(p['Size']) for p in lock['extra_build_packages']), 100_000_000)
        self.assertEqual(module.sha256(HERE / '0001-scope-gyp-to-ibus.patch'),
                         lock['generator_scope_patch_sha256'])
        patch_text = (HERE / '0001-scope-gyp-to-ibus.patch').read_text()
        self.assertIn('unix/ibus/*.gyp', patch_text)
        self.assertNotIn('ipc_path_manager', patch_text)
        self.assertNotIn('system_util', patch_text)


if __name__ == '__main__':
    unittest.main()
