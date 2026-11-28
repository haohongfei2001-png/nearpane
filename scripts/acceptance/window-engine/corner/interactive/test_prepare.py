#!/usr/bin/env python3
"""Exercise the shipped kit in a new empty session. This executable never launches an application."""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
from unittest import TestCase, TextTestRunner, defaultTestLoader
import uuid

import build


class PrepareTests(TestCase):
    def setUp(self):
        self.nonce = str(uuid.uuid4())
        self.session = build.TMP / ("nearpane-membership." + self.nonce)
        self.session.mkdir(mode=0o700)

    def tearDown(self):
        if self.session.is_symlink():
            self.session.unlink()
        else:
            build.shutil.rmtree(self.session)

    def test_signed_clone_recognized_by_system_metadata_without_open(self):
        report = build.prepare(KIT, self.nonce)
        app = self.session / build.APP
        self.assertFalse(report["launched"])
        self.assertEqual(report["signature"], build.verify(KIT / build.APP))
        self.assertEqual(set(p.name for p in self.session.iterdir()), {build.APP})
        # NSURLIsApplicationKey is Apple's supported replacement for Launch Services' LSItemInfoIsApplication.
        # Restrict metadata to the staged file URL. Do not register it or call NSWorkspace.open.
        swift = """
import Foundation
import UniformTypeIdentifiers
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let v = try url.resourceValues(forKeys: [.isApplicationKey, .isDirectoryKey, .contentTypeKey])
let info: [String: String] = ["isApplication": String(v.isApplication == true),
  "isDirectory": String(v.isDirectory == true), "type": v.contentType?.identifier ?? "",
  "identifier": Bundle(url: url)?.bundleIdentifier ?? ""]
try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(info))
"""
        read = subprocess.run(["/usr/bin/xcrun", "swift", "-", str(app)], input=swift, capture_output=True, text=True,
                              timeout=45, check=True)
        actual = json.loads(read.stdout)
        self.assertEqual(actual, {"isApplication": "true", "isDirectory": "true", "type": "com.apple.application-bundle",
                                  "identifier": build.IDENTIFIER})
        FACTS["systemFileURLMetadata"] = actual
        FACTS["stagedCDHash"] = report["signature"]["cdhash"]
        FACTS["stagedMatchingMachOSHA256"] = report["signature"]["executableSHA256"]

    def test_three_windows_require_two_different_signed_applications(self):
        a = build.prepare(KIT, self.nonce)
        b = build.prepare(KIT, self.nonce, bystander=True)
        self.assertEqual(b["signature"]["identifier"], build.BYSTANDER_ID)
        self.assertNotEqual(a["signature"]["cdhash"], b["signature"]["cdhash"])
        self.assertNotEqual(a["socket"], b["socket"])
        self.assertEqual(set(p.name for p in self.session.iterdir()), {build.APP, build.BYSTANDER_APP})
        with self.assertRaises(FileExistsError):
            build.prepare(KIT, self.nonce, bystander=True)

    def test_existing_enrollment_is_not_replaced(self):
        existing = self.session / build.APP
        existing.mkdir()
        place = existing / "fixture-placeholder"
        place.write_bytes(b"existing-fixture")
        original = place.stat()
        with self.assertRaises(FileExistsError):
            build.prepare(KIT, self.nonce)
        self.assertEqual(place.stat().st_ino, original.st_ino)
        self.assertEqual(place.read_bytes(), b"existing-fixture")

    def test_world_readable_session_is_rejected_before_writes(self):
        self.session.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "unsafe private fixture directory"):
            build.prepare(KIT, self.nonce)
        self.assertEqual(list(self.session.iterdir()), [])

    def test_symlink_session_is_rejected_without_reading_target(self):
        self.session.rmdir()
        with tempfile.TemporaryDirectory(dir=build.TMP, prefix="nearpane-interactive-test.") as isolated:
            self.session.symlink_to(isolated, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "unsafe private fixture directory"):
                build.prepare(KIT, self.nonce)
            self.assertEqual(list(Path(isolated).iterdir()), [])

    def test_noncanonical_nonce_never_launches(self):
        with self.assertRaisesRegex(ValueError, "canonical existing membership challenge"):
            build.prepare(KIT, self.nonce.upper())
        self.assertEqual(stat.S_IMODE(os.lstat(self.session).st_mode), 0o700)
        self.assertEqual(list(self.session.iterdir()), [])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kit", type=Path)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    KIT, FACTS = args.kit, {}
    suite = defaultTestLoader.loadTestsFromTestCase(PrepareTests)
    result = TextTestRunner(verbosity=2).run(suite)
    if args.receipt:
        build.save(args.receipt, {"schema": 1, "scope": "isolatedSignedClonePreparationAndApplicationMetadata",
            "status": "PASS" if result.wasSuccessful() else "FAIL", "testCount": result.testsRun,
            "testSourceSHA256": build.digest(Path(__file__)), **FACTS, "applicationLaunches": 0,
            "realLaunchServicesOpen": "NOT_RUN", "realInputAndWindowRestoration": "NOT_RUN"})
    raise SystemExit(0 if result.wasSuccessful() else 1)
