import importlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

upgrade = importlib.import_module("upgrade-installed")


class SingleVersionTests(unittest.TestCase):
    def test_canonical_only_is_read_only(self):
        app = Path("/Applications/Nearpane.app")
        with patch.object(upgrade, "registered_paths", side_effect=[[app], [app]]), patch.object(upgrade.subprocess, "run") as run:
            self.assertEqual(upgrade.retire_backup_registrations(app)["retired"], 0)
            run.assert_not_called()

    def test_foreign_registration_does_not_receive_an_unregister_request(self):
        app = Path("/Applications/Nearpane.app")
        with tempfile.TemporaryDirectory() as root:
            foreign = Path(root) / app.name
            foreign.mkdir()
            with patch.object(upgrade, "registered_paths", return_value=[app, foreign]), patch.object(upgrade.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "Unrecognized registration"):
                    upgrade.retire_backup_registrations(app)
                run.assert_not_called()

    def test_outstanding_engine_owner_cannot_be_archived_as_an_ordinary_record(self):
        pending = {"kind": "stageGroup", "blocksExchange": True}
        inventory = {"records": [pending], "openSharedLeaseDescriptors": 0, "quitPermitted": False}
        with patch.object(upgrade.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "Unresolved ownership"):
                upgrade.archive_if_needed(Path("/private/tmp"), inventory, None)
            run.assert_not_called()
