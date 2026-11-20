import importlib
import subprocess
import unittest
from unittest.mock import Mock

sample_census = importlib.import_module("window-content").sample_census


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
