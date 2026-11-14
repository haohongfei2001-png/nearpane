#!/usr/bin/env python3
"""Pinned-source failures cannot silently download or fall back to installed Python."""
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('runtime_build', Path(__file__).with_name('build-helper-runtime.py'))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class SourceLock(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.cache = Path(self.temporary.name)
        self.archive = self.cache / Path(build.PIN['source']).name
        self.addCleanup(patch.stopall)
        patch.object(build, 'CACHE', self.cache).start()
        self.download = patch.object(build.subprocess, 'run', side_effect=AssertionError('Unexpected network/build')).start()

    def test_offline_missing_source_fails_without_download(self):
        with patch.dict(os.environ, {'NEARPANE_OFFLINE': '1'}):
            with self.assertRaisesRegex(ValueError, 'Offline build'):
                build.source_archive()
        self.download.assert_not_called()

    def test_invalid_cached_source_is_preserved_and_rejected(self):
        raw = b'synthetic damaged archive'
        self.archive.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, 'failed SHA-256'):
            build.source_archive()
        self.assertEqual(self.archive.read_bytes(), raw)
        self.download.assert_not_called()

    def test_verified_offline_source_is_reused(self):
        raw = b'synthetic verified fixture'
        self.archive.write_bytes(raw)
        with patch.dict(os.environ, {'NEARPANE_OFFLINE': '1'}), patch.dict(build.PIN, {'sha256': hashlib.sha256(raw).hexdigest()}):
            self.assertEqual(build.source_archive(), self.archive)
        self.download.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
