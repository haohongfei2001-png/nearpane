import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid


HERE = Path(__file__).resolve().parent


class InstalledJournalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.probe = Path(cls.build.name) / "journal-unit"
        cmd = ["xcrun", "clang", "-fobjc-arc", "-Wall", "-Werror=return-type",
               HERE / "installed-journal-offline.m", "-o", cls.probe]
        for framework in ["AppKit", "QuartzCore", "ApplicationServices", "CoreGraphics", "Security", "Carbon"]:
            cmd.extend(["-framework", framework])
        subprocess.run(cmd, check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        parent = tempfile.TemporaryDirectory()
        self.addCleanup(parent.cleanup)
        self.root = Path(parent.name)
        self.ledger = self.root / "Nearpane-Spaces-Verification"
        self.nonce = str(uuid.uuid4())

    def issue(self, mode, nonce=None):
        return subprocess.run([self.probe, self.root, mode, nonce or self.nonce], check=False).returncode

    def records(self, name):
        return [json.loads(line) for line in (self.ledger / name).read_bytes().splitlines()]

    def test_crash_blocks_an_independent_process_and_a_fresh_nonce(self):
        self.assertEqual(self.issue("crash"), 91)
        self.assertEqual(self.issue("pending", str(uuid.uuid4())), 0)
        self.assertEqual(self.issue("refuse", str(uuid.uuid4())), 0)
        self.assertEqual(self.issue("refuse"), 0)
        first, intent = self.records("active.jsonl")
        self.assertEqual((first["challenge"], first["home"], first["spaceInventory"]), (self.nonce, 6, [6]))
        self.assertEqual((intent["event"], intent["space"]), ("willCreateSpace", 0))

    def test_own_panel_archive_does_not_claim_an_external_window_or_frame(self):
        self.assertEqual(self.issue("panel"), 0)
        first = self.records(self.nonce + ".jsonl")[0]
        self.assertEqual(first["scopeOfTrial"], "ownPanelOnly")
        self.assertEqual([first[k] for k in ("fixturePID", "fixtureBirth", "fixtureWindow")], [0, 0, 0])
        self.assertIsNone(first["fixtureCDHash"])
        self.assertIsNone(first["frame"])

    def test_fullscreen_inventory_corroborates_each_repeated_id_and_preserves_both_entries(self):
        self.assertEqual(self.issue("inventory"), 0)

    def test_unresolved_record_is_retained_and_never_permits_a_second_nonce(self):
        self.assertEqual(self.issue("retain"), 0)
        self.assertEqual(self.issue("refuse", str(uuid.uuid4())), 0)
        self.assertEqual(self.records("active.jsonl")[-1]["event"], "terminalRetained")

    def test_clean_archive_is_durable_and_same_nonce_cannot_run_again(self):
        self.assertEqual(self.issue("clean"), 0)
        self.assertFalse((self.ledger / "active.jsonl").exists())
        archive = self.ledger / f"{self.nonce}.jsonl"
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.records(archive.name)[-1]["event"], "terminalClean")
        self.assertEqual(self.issue("refuse"), 0)
        self.assertEqual(self.issue("clean", str(uuid.uuid4())), 0)

    def test_existing_symlink_is_never_followed_or_removed(self):
        self.ledger.mkdir(mode=0o700)
        saved = self.root / "unrelated"
        saved.write_text("unchanged")
        (self.ledger / "active.jsonl").symlink_to(saved)
        self.assertEqual(self.issue("refuse"), 0)
        self.assertTrue((self.ledger / "active.jsonl").is_symlink())
        self.assertEqual(saved.read_text(), "unchanged")


if __name__ == "__main__":
    unittest.main()
