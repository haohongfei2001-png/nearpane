#!/usr/bin/env python3
"""Exercise installed entry points without external interpreters or developer tools."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ARGS = None
SANDBOX = '(version 1)(allow default)(deny network*)(deny file-read* file-write* (subpath "/Library/Developer") (subpath "/Applications/Xcode.app") (subpath "/opt/homebrew") (subpath "/usr/local") (literal "/usr/bin/python3"))'


class BundledAutomation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nearpane-automation-')
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name).resolve()
        self.helper = ARGS.app.resolve() / 'Contents/Helpers/NearpaneAutomation'
        self.env = dict(PATH='/nonexistent', PYTHONPATH=str(self.work), PYTHONHOME='/nonexistent', PYTHONUSERBASE=str(self.work))

    def run_helper(self, *args, **kwargs):
        return subprocess.run(['/usr/bin/sandbox-exec', '-p', SANDBOX, str(self.helper), *map(str, args)],
                              cwd=self.work, env=self.env, text=True, capture_output=True, timeout=15, **kwargs)

    def test_isolated_runtime_ignores_external_module_paths(self):
        (self.work / 'json.py').write_text('raise RuntimeError("foreign module executed")')
        (self.work / 'sitecustomize.py').write_text('raise RuntimeError("foreign site executed")')
        p = self.run_helper('--self-check')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)['python'], '3.14.10')

    def test_only_named_entry_points_are_accepted(self):
        for args in (('-c', 'raise SystemExit(0)'), ('/tmp/foreign.py',), ('profile',), ('workrect',), ('--self-check', 'extra')):
            with self.subTest(args=args):
                self.assertEqual(self.run_helper(*args).returncode, 2)

    def test_window_supervisor_starts_off_and_quits_without_grants(self):
        (self.work / 'profile.version').write_text('Nearpane P5.3\n')
        p = self.run_helper('workrect', self.work, input='quit\n')
        self.assertEqual(p.returncode, 0, p.stderr)
        states = [json.loads(line) for line in p.stdout.splitlines()]
        self.assertTrue(states)
        self.assertTrue(all(s['mode'] == 'off' and s['members'] == 0 and s['windows'] == [] for s in states))
        self.assertFalse(any(p.name in ('run.json', 'grant.json') for p in self.work.rglob('*')))

    def test_profile_status_preserves_invalid_source(self):
        root = self.work / 'Nearpane Alpha Profiles'
        root.mkdir(mode=0o700)
        index = root / 'profile-index.json'
        raw = b'{"format":999}'
        index.write_bytes(raw)
        p = self.run_helper('profile', 'status', '--container', root)
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(json.loads(p.stdout)['ok'])
        self.assertEqual(index.read_bytes(), raw)

    def test_runtime_relocates_with_signed_bundle(self):
        target = self.work / 'different path with spaces' / 'Nearpane.app'
        target.parent.mkdir()
        subprocess.run(['/usr/bin/ditto', '--norsrc', '--noextattr', str(ARGS.app), str(target)], check=True)
        self.helper = target / 'Contents/Helpers/NearpaneAutomation'
        p = self.run_helper('--self-check')
        self.assertEqual(p.returncode, 0, p.stderr)
        host = target / 'Contents/MacOS/NearpaneHost'
        p = subprocess.run(['/usr/bin/sandbox-exec', '-p', SANDBOX, str(host), '--check-helper-runtime'],
                           env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        source = target / 'Contents/Resources/WorkRect/window-management.py'
        original = source.read_bytes()
        source.write_bytes(original + b'\n# synthetic tamper\n')
        p = subprocess.run([str(host), '--check-helper-runtime'], env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(p.returncode, 3, p.stderr + p.stdout)
        source.unlink()
        sibling = self.work / 'identical-script.py'
        sibling.write_bytes(original)
        source.symlink_to(sibling)
        p = subprocess.run([str(host), '--check-helper-runtime'], env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(p.returncode, 3, p.stderr + p.stdout)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    ARGS = parser.parse_args()
    unittest.main(argv=[__file__], verbosity=2)
