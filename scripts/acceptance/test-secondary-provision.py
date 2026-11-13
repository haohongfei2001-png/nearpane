import runpy
import unittest
from pathlib import Path

verify = runpy.run_path(str(Path(__file__).with_name("verify-secondary-provision.py")))["verify"]
PRIMARY, SECONDARY = "C3538AA7-A42B-4D47-B25F-BF1B305F90EF", "7F437AAC-5DC5-49C9-AB60-AFEB68FD3B9A"


def pair(first, records, ordinary, *, current="10"):
    def snapshot(i):
        def display(id_, x, width):
            frame = dict(x=x, y=0, width=width, height=1000)
            return dict(id=id_, frame=frame, usable=frame, backingScale=2, rotationDegrees=0)

        def scope(id_, order, active):
            return dict(id="scope-" + id_, displayID=id_, records=[dict(id=r, isCurrent=r == active) for r in order])

        return dict(source="macos-window-server", freshness="fresh", topologyConsistent=True, separateSpaces=True,
                    sessionID="EDC498FF-12EF-496B-9EFF-EFEE1631CB7B", revision=i, sampledFrom=1000+i,
                    sampledTo=1000+i+0.04, sourceBuild="test-build", topologyFingerprint="test-hash", windows=[],
                    native=dict(beganUptime=100+i, endedUptime=100+i+0.04, population="markedFixture", rows=[],
                                spaces="observed", windowLimitReached=False),
                    displays=[display(PRIMARY, 0, 1600), display(SECONDARY, -800, 800)],
                    scopes=[scope(PRIMARY, ["1", "2"], "2"), scope(SECONDARY, records, current)],
                    ordinaryRecordsByDisplay={PRIMARY: ["1", "2"], SECONDARY: list(ordinary)})
    return [snapshot(first), snapshot(first + 1)]


class Provision(unittest.TestCase):
    def setUp(self):
        self.before = pair(1, ["10", "12"], ["10"])
        self.after = pair(3, ["10", "11", "12"], ["10", "11"])

    def test_exact_addition_and_return(self):
        receipt = verify(PRIMARY, SECONDARY, self.before, self.after, pair(5, ["10", "12"], ["10"]))
        self.assertEqual((receipt["source"], receipt["target"], receipt["direction"]), ("10", "11", "right"))
        self.assertTrue(receipt["originalScopesRestored"])
        for k in ("creatorProven", "emptyDesktopProven", "deletionAuthorized"):
            self.assertFalse(receipt[k])
        left = pair(3, ["11", "10", "12"], ["11", "10"])
        self.assertEqual(verify(PRIMARY, SECONDARY, self.before, left)["direction"], "left")

    def test_fullscreen_missing_nonadjacent_multiple_and_changed_current(self):
        for after in (pair(3, ["10", "11", "12"], ["10"]), pair(3, ["10", "12"], ["10"]),
                      pair(3, ["10", "12", "11"], ["10", "11"]), pair(3, ["10", "11", "12", "13"], ["10", "11", "13"]),
                      pair(3, ["10", "11"], ["10", "11"]), pair(3, ["10", "11", "12"], ["10", "11", "12"]),
                      pair(3, ["10", "11", "12"], ["10", "11"], current="11")):
            with self.subTest(after=after[0]["scopes"][1]), self.assertRaises(ValueError):
                verify(PRIMARY, SECONDARY, self.before, after)

    def test_protected_current_and_geometry(self):
        for changed in ("primary-current", "primary-frame", "secondary-scale", "build", "nonordinary-primary"):
            after = pair(3, ["10", "11", "12"], ["10", "11"])
            for s in after:
                if changed == "primary-current":
                    for row in s["scopes"][0]["records"]:
                        row["isCurrent"] = not row["isCurrent"]
                elif changed == "primary-frame":
                    s["displays"][0]["frame"]["width"] -= 1
                elif changed == "secondary-scale":
                    s["displays"][1]["backingScale"] = 1
                elif changed == "build":
                    s["sourceBuild"] = "other-build"
                else:
                    s["ordinaryRecordsByDisplay"][PRIMARY].pop()
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                verify(PRIMARY, SECONDARY, self.before, after)

    def test_replay_unstable_and_mismatched_restore(self):
        for before, after, restored in ((self.before[:1] * 2, self.after, None),
                                        (self.before, [self.before[-1], self.after[-1]], None),
                                        (self.before, [self.after[0], pair(4, ["10"], ["10"])[0]], None),
                                        (self.before, self.after, pair(5, ["10"], ["10"])),
                                        (self.before, self.after, self.before)):
            with self.subTest(), self.assertRaises(ValueError):
                verify(PRIMARY, SECONDARY, before, after, restored)

    def test_sole_display_only_appends_and_removes_its_own_last_target(self):
        def samples(start, order):
            result = pair(start, order, order)
            for row in result:
                row["displays"] = row["displays"][1:]
                row["displays"][0]["frame"]["x"] = 0
                row["scopes"] = row["scopes"][1:]
                del row["ordinaryRecordsByDisplay"][PRIMARY]
            return result
        before = samples(1, ["9","10"])
        added = samples(3, ["9","10","11"])
        restore = samples(5, ["9","10"])
        self.assertTrue(verify(None,SECONDARY,before,added,restore,current_display=True)["originalScopesRestored"])
        for after in (samples(3, ["9","11","10"]), samples(3, ["10","11"]), samples(3, ["10","9","11"])):
            with self.assertRaises(ValueError):
                verify(None,SECONDARY,before,after,current_display=True)
        with self.assertRaises(ValueError):
            verify(PRIMARY,SECONDARY,before,added)

    def test_swapped_display_and_duplicate_global_record(self):
        with self.assertRaises(ValueError):
            verify(SECONDARY, PRIMARY, self.before, self.after)
        with self.assertRaises(ValueError):
            verify(PRIMARY, SECONDARY, self.before, pair(3, ["10", "1", "12"], ["10", "1"]))


if __name__ == "__main__":
    unittest.main()
