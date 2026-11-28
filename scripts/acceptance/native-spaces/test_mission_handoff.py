import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from mission_handoff import cleared_pair, run


def closed():
    return SimpleNamespace(binding={"numbers": [31, 32]}, out={"superseded": False, "cleanup": {
        "status": "PASS", "signal": "close", "ownedSessionRemoved": True,
        "readback": {"status": "EXITED", "generationGone": True, "windowsGone": True}}})


class MissionHandoffTests(unittest.TestCase):
    def test_only_the_enrolled_pair_can_admit_a_lifecycle(self):
        self.assertTrue(cleared_pair(closed()))
        for key, value in (("numbers", [31]), ("numbers", [31, 31])):
            pair = closed()
            pair.binding[key] = value
            self.assertFalse(cleared_pair(pair))
        for key in ("generationGone", "windowsGone"):
            pair = closed()
            pair.out["cleanup"]["readback"][key] = False
            self.assertFalse(cleared_pair(pair))
        pair = closed()
        pair.out["superseded"] = True
        self.assertFalse(cleared_pair(pair))

    def test_refusal_retains_receipt_without_launching_or_calling_a_system_reader(self):
        workspace = Mock()
        pair = closed()
        pair.out["cleanup"]["status"] = "UNKNOWN"
        with tempfile.TemporaryDirectory() as td, patch("mission_handoff.subprocess.Popen") as popen:
            out = Path(td) / "mission"
            result = run(Path(td), out, workspace, 123, "uuid", {}, pair, {"status": "PASS"})
            self.assertEqual(result["status"], "BLOCKED")
            self.assertEqual(result["cleanup"], "NOT_NEEDED")
            self.assertFalse(result["launched"])
            self.assertTrue((out / "receipt.json").is_file())
            self.assertFalse((out / "events.jsonl").exists())
            popen.assert_not_called()
            self.assertFalse(workspace.mock_calls)

    def test_unverified_zero_cards_cannot_trigger_a_system_action(self):
        with tempfile.TemporaryDirectory() as td, patch("mission_handoff.signed_tool") as sign:
            result = run(Path(td), Path(td)/"mission", Mock(), 123, "uuid", {}, closed(), {"status":"UNKNOWN"})
            self.assertEqual(result["reason"], "emptyInstalledWindowAreaOrLeasedSpaceUnconfirmed")
            self.assertEqual(result["spaceOrWindowSelections"], 0)
            sign.assert_not_called()


if __name__ == "__main__":
    unittest.main()
