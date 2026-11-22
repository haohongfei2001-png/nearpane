from copy import deepcopy
import json
from pathlib import Path
import unittest
from visible_strip import replay


class PhysicalStripReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[4]
        raw = root / "engineering/verification/window-engine/p0-p1-admission-26A428/07-ordinary-position-and-focus.json"
        cls.measurement = json.loads(raw.read_bytes())["measurement"]

    def test_windowmanager_returned_four_individually_hittable_buttons_twice(self):
        verdict = replay(self.measurement)
        self.assertEqual(verdict["status"], "PASS")
        self.assertEqual([r["count"] for r in verdict["samples"]], [4,4])
        self.assertEqual(verdict["samples"][0], verdict["samples"][1])
        self.assertEqual(self.measurement["status"], "UNKNOWN")
        self.assertEqual(self.measurement["originalFocusConfirmedReads"], 0)

    def test_count_alone_or_changed_parent_cannot_prove_the_visible_strip(self):
        for corrupt in (
            lambda g:g["stripAttributes"][0]["attributes"][1]["objects"].pop(),
            lambda g:g["parentReads"].clear(),
            lambda g:[p["systemWide"].update(object=0) for p in g["hits"]],
            lambda g:g.update(inputInterrupted=True),
        ):
            measurement = deepcopy(self.measurement)
            corrupt(measurement["hitTestSamples"][1])
            self.assertEqual(replay(measurement)["status"],"UNKNOWN")
