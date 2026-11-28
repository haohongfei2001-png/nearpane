import importlib
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

window_content = importlib.import_module("window-content")
sample_census = window_content.sample_census


def sidebar(count):
    row = dict(ready=True, windowCards=count, matchedFixtureCards=count, expectedCards=count, expectedIDsMatch=True,
               otherWindowCards=0, pid=12, signature="hash", hostBirth=123, space=7, display="fixture", number=51,
               crop=[0, 0, 100, 60], explicitGroups=0, placeholderLabels=[], rosterRegions=1, spaceRows=0, desktopCount=1)
    if count:
        row["documentBirth"] = 730
    return row


class SidebarProofTests(unittest.TestCase):
    def sample(self, plan, budget):
        clock = [0.0]
        replies = iter(plan)

        def advance(seconds):
            clock[0] += seconds

        def observe(timeout):
            self.assertGreaterEqual(timeout, .3)
            seconds, value = next(replies)
            advance(seconds)
            if isinstance(value, Exception):
                raise value
            return value

        return window_content.sample_sidebar(observe, budget, clock=lambda: clock[0], sleep=advance)

    def test_short_remaining_budget_preserves_actual_unready_sidebar(self):
        actual = dict(sidebar(2), ready=False, expectedCards=0)
        result = self.sample([(.77, dict(actual, privateWindowTitle="must not be recorded"))], 1.0)
        self.assertEqual(result["proof"], actual)
        self.assertEqual(len(result["proofSamples"]), 1)
        self.assertNotIn("privateWindowTitle", result["proofSamples"][0]["proof"])
        self.assertFalse(result["proofConfirmed"])

    def test_timeout_preserves_last_real_value_and_breaks_a_pair(self):
        state = sidebar(0)
        timeout = subprocess.TimeoutExpired("observer", 8)
        result = self.sample([(.05, state), (.1, timeout), (.1, state)], 1.3)
        self.assertEqual(result["proof"], state)
        self.assertEqual(result["proofReadErrors"], ["TimeoutExpired"])
        self.assertEqual([r.get("error") for r in result["proofSamples"]], [None, "TimeoutExpired", None])
        self.assertFalse(result["proofConfirmed"])
        result = self.sample([(.05, state), (.1, timeout), (.1, state), (.1, state)], 2)
        self.assertTrue(result["proofConfirmed"])

    def test_deadline_and_incomplete_observer_replies_cannot_confirm(self):
        state = sidebar(2)
        for plan in [[(.1, state), (.72, state)], [(.1, {"ready": True}), (.3, {"ready": True})]]:
            self.assertFalse(self.sample(plan, 1.05)["proofConfirmed"])

    def test_one_camera_excludes_background_frames_during_all_three_phases(self):
        camera = threading.Lock()
        recording = Mock(camera=camera)
        recording.witness.side_effect = lambda _: self.assertFalse(camera.locked())
        fixture_counts = iter([2, 0, 2, 0])
        witnesses = []
        fixture_numbers = [81, 82]

        def document(path, validate, _deadline):
            count = next(fixture_counts)
            state = dict(session=path.parent.name, bundle="net.example.spaces-document", pid=73, birth=730,
                         numbers=fixture_numbers[:count], visible=[True] * count)
            self.assertTrue(validate(state))
            return state

        def read(args, **_):
            if args[1] == "absence":
                return {"allGone": True}
            self.assertTrue(camera.locked())
            if args[1] == "roster-content":
                return sidebar(len(args) - 4)
            if args[1] == "compare-roster":
                count = len(args) - 5
                witnesses.append(count)
                i = len(witnesses)
                return dict(pid=12, hostBirth=123, signature="hash", display="fixture", space=7, panelNumber=51,
                            fixturePID=73, fixtureBirth=730, observerPID=100 + i, observerBirth=1000 + i, observedUptime=100 + i,
                            status="PASS" if count else "INCONCLUSIVE", cards=count, provenVisibleStandard=count,
                            duplicateControls=0, missingProvenVisible=0, knownWrongCards=0, unconfirmedCards=0,
                            coverageComplete=True, expectedVisibleSetMatches=True, expectedCardSetMatches=True)
            args[-1].touch()
            row = sidebar(len(args) - 6)
            return dict(row, isolatedProfile=True, wallpaperIncluded=True) if args[2] == "roster-panel" else row

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "Contents").mkdir()
            (root / "Contents/Info.plist").write_bytes(plistlib.dumps({"NearpaneSourceRevision": "sample", "CFBundleVersion": "90"}))
            fixture = root / "Field Notes.app/Contents/MacOS/FieldNotes"
            fixture.parent.mkdir(parents=True)
            fixture.touch()
            with patch.multiple(window_content, APP=root, installed_pid=Mock(return_value=12), owns_profile=Mock(return_value=True),
                                identity=Mock(return_value={"CDHash": "hash"}), wait_state=Mock(side_effect=document),
                                RosterRecording=Mock(return_value=recording), read=Mock(side_effect=read)):
                with patch.dict(window_content.os.environ, NEARPANE_TEST_HOME=temp), patch.object(
                        window_content.subprocess, "Popen", return_value=Mock(pid=73)):
                    self.assertEqual(window_content.run(root, root / "result", True, film=True), 0)
        self.assertEqual(witnesses, [0, 0, 2, 2, 0, 0])
        self.assertEqual(recording.witness.call_count, 3)


class WindowCensusTests(unittest.TestCase):
    binding = dict(pid=12, hostBirth=1000, signature="test-cdhash", display="fixture-display",
                   space=7, panelNumber=21, fixturePID=36, fixtureBirth=3000)

    def valid(self, count):
        return dict(self.binding, status="PASS" if count else "INCONCLUSIVE", cards=count,
                    provenVisibleStandard=count, coverageComplete=True, expectedVisibleSetMatches=True,
                    expectedCardSetMatches=True, missingProvenVisible=0, knownWrongCards=0,
                    duplicateControls=0, unconfirmedCards=0)

    def sample(self, sequence, count=2):
        responses = [dict({"observerPID": 80 + i, "observerBirth": 200 + i, "observedUptime": 300 + i}, **row)
                     if isinstance(row, dict) else row for i, row in enumerate(sequence)]
        observe = Mock(side_effect=responses)
        outcome = sample_census(observe, self.binding, count, limit=len(sequence), interval=0)
        self.assertLessEqual(observe.call_count, len(sequence))
        return outcome

    def test_two_consecutive_matches_after_unreadable_or_incomplete_sample(self):
        complete = self.valid(2)
        empty = dict(self.binding, status="INCONCLUSIVE", sourceCounts={"cgRows": 0})
        timeout = subprocess.TimeoutExpired(["fixture-observer"], 1)
        samples, confirmed, _ = self.sample([empty, complete, timeout, complete, complete])
        self.assertTrue(confirmed)
        self.assertEqual([row["status"] for row in samples[:2]], ["INCONCLUSIVE", "PASS"])
        self.assertEqual(samples[2]["reason"], "TimeoutExpired")
        self.assertEqual(len(samples), 5)

    def test_single_positive_and_old_unconfirmed_double_card_are_blocked(self):
        incomplete = dict(self.binding, status="INCONCLUSIVE", classifiedCards={"unconfirmed": 2},
                          unconfirmedEvidence={}, systemExcluded={}, cards=2, provenVisibleStandard=0)
        self.assertFalse(self.sample([incomplete, self.valid(2)])[1])
        self.assertFalse(self.sample([incomplete, incomplete])[1])
        stale = dict(self.valid(2), observerPID=81, observerBirth=205, observedUptime=333)
        self.assertFalse(self.sample([stale, stale])[1])

    def test_same_count_requires_the_two_exact_independent_sets(self):
        for key in ("coverageComplete", "expectedVisibleSetMatches", "expectedCardSetMatches"):
            with self.subTest(key=key):
                ambiguous = dict(self.valid(2), **{key: False})
                self.assertFalse(self.sample([ambiguous, ambiguous])[1])

    def test_unknown_empty_global_sources_cannot_prove_an_empty_roster(self):
        incomplete = dict(self.binding, status="INCONCLUSIVE", cards=0, provenVisibleStandard=0,
                          sourceCounts={"cgRows": None, "publicCurrent": None, "publicOrdered": 0})
        self.assertFalse(self.sample([incomplete, incomplete], count=0)[1])
        self.assertTrue(self.sample([self.valid(0), self.valid(0)], count=0)[1])

    def test_generation_change_or_confirmed_discrepancy_ends_this_checkpoint(self):
        complete = self.valid(2)
        failures = [dict(complete, **{key: value}) for key, value in
                    (("pid", 13), ("hostBirth", 4000), ("fixtureBirth", 5000), ("space", 8),
                     ("panelNumber", 44), ("generationChanged", True), ("status", "FAIL"))]
        for failure in failures:
            samples, confirmed, _ = self.sample([complete, failure, complete, complete])
            self.assertFalse(confirmed)
            self.assertEqual(len(samples), 2)
            self.assertTrue(all(samples[-1][key] == value for key, value in failure.items()))


if __name__ == "__main__":
    unittest.main()
