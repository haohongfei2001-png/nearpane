import hashlib
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from package import AUTOMATION_FILES, package, workspace_tools


class CandidatePackageTests(unittest.TestCase):
    def test_old_or_modified_donor_is_not_relabelled_or_copied(self):
        revision = "a" * 40
        for built, state in (("b" * 40, "clean"), (revision, "modified"), (revision, None)):
            with self.subTest(built=built, state=state), tempfile.TemporaryDirectory() as folder:
                root = Path(folder).resolve()
                source, target = root / "Source.app", root / "Candidate.app"
                (source / "Contents").mkdir(parents=True)
                (source / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "NearpaneStageEngineSourceRevision": built,
                    **({"NearpaneStageEngineSourceState": state} if state is not None else {}),
                }))
                with patch("package.subprocess.run") as command:
                    with self.assertRaisesRegex(ValueError, "clean source revision"):
                        package(source, target, revision)
                    command.assert_not_called()
                self.assertFalse(target.exists())

    def test_existing_runtime_requires_exact_untampered_seal(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder).resolve() / "Candidate.app"
            metadata = self.sealed_runtime(app)
            with patch("package.subprocess.run") as command:
                self.assertEqual(workspace_tools(app, metadata), metadata)
                command.assert_not_called()
                (app / "Contents" / AUTOMATION_FILES[-1]).write_bytes(b"changed")
                with self.assertRaisesRegex(ValueError, "integrity mismatch"):
                    workspace_tools(app, metadata)

    def test_sealed_runtime_cannot_resolve_outside_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder).resolve() / "Candidate.app"
            metadata = self.sealed_runtime(app)
            helper = app / "Contents/Helpers"
            outside = Path(folder).resolve() / "ExternalHelpers"
            helper.rename(outside)
            helper.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "integrity mismatch"):
                workspace_tools(app, metadata)

    @staticmethod
    def sealed_runtime(app):
        seals = {}
        for relative in AUTOMATION_FILES:
            path = app / "Contents" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(relative.encode())
            seals[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
        return {"NearpaneAutomationSHA256": seals}


if __name__ == "__main__":
    unittest.main()
