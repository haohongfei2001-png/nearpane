#!/usr/bin/env python3
"""Regression checks for the frozen icon/source contract; no GUI or application launch."""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("app_icon", Path(__file__).with_name("prepare-app-icon.py"))
icon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icon)


class AppIconTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nearpane-icon-contract-")
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Nearpane.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundleName="Nearpane")))
        self.report = icon.embed(self.app)

    def test_frozen_source_and_all_resolutions_roundtrip(self):
        self.assertEqual(icon.verify(self.app), self.report)
        self.assertEqual(self.report["representations"], 10)
        self.assertEqual(self.report["revision"], "2026-11-15-v2")

    def test_absent_bundle_icon_does_not_get_generic_fallback_pass(self):
        plist = self.app / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        del info["CFBundleIconFile"]
        plist.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "metadata"):
            icon.verify(self.app)

    def test_changed_packaged_icon_is_rejected(self):
        target = self.app / "Contents/Resources/Nearpane.icns"
        data = bytearray(target.read_bytes())
        data[-1] ^= 1
        target.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "fingerprint"):
            icon.verify(self.app)

    def test_wrong_resolution_is_rejected_even_with_container_hash(self):
        data = bytearray(icon.ICON.read_bytes())
        data[32:36] = (20).to_bytes(4, "big")  # First PNG's IHDR width.
        expected = copy.deepcopy(icon.provenance()["packagedIcon"])
        expected["sha256"] = icon.digest(data)
        with self.assertRaisesRegex(ValueError, "dimensions"):
            icon.validate_icon(data, expected)

    def test_provenance_cannot_claim_a_different_original(self):
        target = self.app / "Contents/Resources/AppIconSource.json"
        evidence = json.loads(target.read_text())
        evidence["originalBrandSHA256"] = "0" * 64
        target.write_text(json.dumps(evidence))
        with self.assertRaisesRegex(ValueError, "provenance"):
            icon.verify(self.app)


if __name__ == "__main__":
    unittest.main()
