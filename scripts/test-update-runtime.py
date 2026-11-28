#!/usr/bin/env python3
"""Offline regressions for exact updater input verification; no application launch."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('update_runtime', Path(__file__).with_name('prepare-update-runtime.py'))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class UpdateRuntimeTests(unittest.TestCase):
    def test_offline_missing_never_downloads(self):
        with tempfile.TemporaryDirectory() as work, patch.object(runtime, 'CACHE', Path(work)), \
                patch.object(runtime.urllib.request, 'urlopen') as download:
            with self.assertRaisesRegex(ValueError, 'missing in offline mode'):
                runtime.prepare(True)
            download.assert_not_called()

    def test_bad_archive_is_retained_and_rejected(self):
        with tempfile.TemporaryDirectory() as work, patch.object(runtime, 'CACHE', Path(work)), \
                patch.object(runtime.urllib.request, 'urlopen') as download:
            archive = Path(work) / f"Sparkle-{runtime.PIN['version']}.zip"
            archive.write_bytes(b'corrupt source')
            with self.assertRaisesRegex(ValueError, 'archive SHA-256 mismatch'):
                runtime.prepare()
            self.assertEqual(archive.read_bytes(), b'corrupt source')
            download.assert_not_called()

    def test_changed_cached_framework_does_not_fall_back(self):
        with tempfile.TemporaryDirectory() as work, patch.object(runtime, 'CACHE', Path(work)), \
                patch.object(runtime.urllib.request, 'urlopen') as download:
            folder = Path(work)
            archive = folder / f"Sparkle-{runtime.PIN['version']}.zip"
            archive.write_bytes(b'verified fixture archive')
            framework = folder / 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
            framework.mkdir(parents=True)
            code = framework / 'Sparkle'
            code.write_bytes(b'original fixture executable')
            pin = dict(runtime.PIN, sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                       frameworkSHA256=runtime.framework_digest(framework))
            code.write_bytes(b'replaced fixture executable')
            with patch.object(runtime, 'PIN', pin), self.assertRaisesRegex(ValueError, 'framework content mismatch'):
                runtime.prepare(True)
            self.assertEqual(code.read_bytes(), b'replaced fixture executable')
            download.assert_not_called()

    def test_framework_external_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as work:
            folder = Path(work)
            source = folder / 'framework'
            source.mkdir()
            (folder / 'foreign').write_text('foreign')
            (source / 'Sparkle').symlink_to('../foreign')
            with self.assertRaisesRegex(ValueError, 'leaves its framework'):
                runtime.framework_digest(source)


if __name__ == '__main__':
    unittest.main()
