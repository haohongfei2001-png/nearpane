"""Run the fixture lifecycle against disposable stand-ins without starting a GUI."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("trial", Path(__file__).with_name("run-current-desktop-selection.py"))
trial = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trial)


class FixtureCleanupTests(unittest.TestCase):
    def lifecycle(self, code):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            unregistered = []
            roots = []

            def process(argv, **options):
                if Path(argv[0]).name == "build-current-desktop-selection.sh":
                    root = argv[2]
                    roots.append(root.parent)
                    for name in trial.APPS:
                        (root / name / "Contents/MacOS").mkdir(parents=True)
                        (root / name / "Contents/MacOS/fake").write_text("owned")
                    (root / "board.json").write_text("{}")
                elif Path(argv[0]).name == "NearpaneHost":
                    options["stdout"].write(b'{"fake":true}')
                    return subprocess.CompletedProcess(argv, code)
                elif Path(argv[0]).name == "lsof":
                    return subprocess.CompletedProcess(argv, 1, b"", b"")
                elif argv[0] == trial.REGISTER:
                    self.assertEqual(argv[1], "-u")
                    unregistered.append(argv[2])
                    return subprocess.CompletedProcess(argv, 0, "")
                else:
                    self.assertEqual(argv[0], "/usr/bin/codesign")
                return subprocess.CompletedProcess(argv, 0)

            with patch.object(trial, "ROOT", project), patch.object(trial.sys, "argv", ["runner"]), \
                    patch.object(trial.subprocess, "run", side_effect=process):
                self.assertEqual(trial.main(), code)
            evidence, = (project / "build/verification").iterdir()
            self.assertEqual(json.loads((evidence / "run.json").read_text())["trialExit"], code)
            self.assertTrue((evidence / "board.json").is_file())
            self.assertTrue((evidence / "result.json").is_file())
            self.assertEqual(unregistered, [roots[0] / "fixtures" / name for name in trial.APPS])
            self.assertFalse(roots[0].exists())

    def test_success_keeps_evidence_only(self):
        self.lifecycle(0)

    def test_failed_trial_removes_bundles_and_keeps_status(self):
        self.lifecycle(3)

    def test_busy_fixture_remains_available_for_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "scratch"
            executable = root / "fixtures/Controller.app/Contents/MacOS/host"
            executable.parent.mkdir(parents=True)
            executable.touch()
            busy = subprocess.CompletedProcess([], 0, b"222", b"")
            with patch.object(trial.subprocess, "run", return_value=busy) as invoke, \
                    patch.object(trial.time, "monotonic", side_effect=[1, 20]):
                with self.assertRaisesRegex(RuntimeError, "confirm fixture processes exited"):
                    trial.cleanup(root, Path(tmp))
                self.assertEqual(invoke.call_count, 1)
            self.assertTrue(executable.is_file())


if __name__ == "__main__":
    unittest.main()
