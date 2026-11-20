"""Pure-memory regressions for file-model scoring and unknown propagation."""
import unittest
from unittest.mock import patch

import p4_apple_file as probe


class FileAccuracyTests(unittest.TestCase):
    def test_six_cases_use_the_physical_contracts_first_repetition(self):
        rows = probe.scheduled()
        self.assertEqual(len({r["case"] for r in rows}), 6)
        self.assertEqual({r["expected"] for r in rows}, set(probe.cold.PHRASES))
        self.assertEqual([r["seed"] for r in rows], [None, 2, None, 4, None, 6])

    def test_first_character_and_levenshtein_do_not_depend_on_punctuation(self):
        for heard, first, distance in [(" 今，天！", True, 0), ("天", False, 1), ("今月", True, 1),
                                      ("刚今天", False, 1), ("", False, 2)]:
            with self.subTest(heard=heard):
                result = probe.score("今天", heard)
                self.assertEqual(result["firstCharacterCorrect"], first)
                self.assertEqual(result["edits"], distance)
                self.assertEqual(result["cer"], distance / 2)
        # The archived recorder replaces each non-fixture glyph with one square.
        self.assertEqual(probe.score("今天", "叮叮天"), probe.score("今天", "□□天"))

    def test_missing_final_is_unscored_but_real_empty_final_is_a_deletion(self):
        base = {"exitCode": 0, "timedOut": False}
        missing, empty = probe.scheduled()[:2]
        probe.assessed(missing, dict(base, events=[{"stage": "analysis-finished", "finalCount": 0, "finalText": ""}]))
        probe.assessed(empty, dict(base, events=[{"stage": "analysis-finished", "finalCount": 1, "finalText": ""}]))
        self.assertEqual((missing["status"], empty["status"]), ("UNKNOWN", "FAIL"))
        a = probe.aggregate([missing, empty])
        self.assertEqual((a["scoredFinals"], a["unscored"], a["firstCharacterRate"], a["microCER"]), (1, 1, 0, 1))
        self.assertIsNone(probe.aggregate([missing])["microCER"])

    def test_timeout_or_nonzero_exit_cannot_promote_partial_events(self):
        for timed_out, code in ((True, None), (False, 8)):
            row = probe.scheduled()[0]
            probe.assessed(row, {"timedOut": timed_out, "exitCode": code, "events": [
                {"stage": "analysis-finished", "finalText": row["expected"], "finalCount": 1}]})
            self.assertEqual(row["status"], "UNKNOWN")
            self.assertIsNone(row["score"])

    def test_self_hosted_mac_cannot_prepare_the_model(self):
        with patch.dict("os.environ", {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted",
                                      "RUNNER_OS": "macOS", "GITHUB_REPOSITORY": probe.REPO}, clear=True):
            self.assertFalse(probe.hosted())


if __name__ == "__main__":
    unittest.main()
