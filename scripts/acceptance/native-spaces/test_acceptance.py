import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from acceptance import Receipt, catalog_match, host_current_permissions
from roster import evaluate, same_scale


class EvidenceTests(unittest.TestCase):
    @staticmethod
    def fixture_roster():
        sizes = [[540, 213], [240, 383]]
        return sizes, [dict(observed=True, cardY=y, cardHeight=43, spaceRows=0, window=i,
                            value=desc, axSize=size, cgSize=size)
                       for i, (size, desc, y) in enumerate(zip(sizes, ["窗口轮廓，预览 54 × 21 pt", "窗口轮廓，预览 24 × 38 pt"], [42, 85]))]

    def test_installed_roster_accepts_actual_distinct_relative_sizes(self):
        sizes, cards = self.fixture_roster()
        self.assertEqual("PASS", evaluate(sizes, cards)["status"])

    def test_presentation_rectangle_used_as_the_window_is_a_failure(self):
        sizes, cards = self.fixture_roster()
        cards[0].update(cgSize=[150, 139], value="窗口轮廓，预览 15 × 14 pt")
        self.assertEqual("FAIL", evaluate(sizes, cards)["status"])
        cards[0].update(value="窗口尺寸待核对")
        result = evaluate(sizes, cards)
        self.assertEqual("BLOCKED", result["status"])
        self.assertTrue(result["windowGeometry"][0]["presentationMismatchSafelyWithheld"])

    def test_unknown_size_or_skipped_card_cannot_prove_safe_rejection(self):
        sizes, cards = self.fixture_roster()
        cards[0].update(cgSize=None, value="窗口尺寸待核对")
        self.assertFalse(evaluate(sizes, cards)["windowGeometry"][0]["presentationMismatchSafelyWithheld"])
        cards[0]["observed"] = False
        self.assertEqual("BLOCKED", evaluate(sizes, cards)["status"])

    def test_correct_sizes_overlapping_or_with_desktop_rows_still_fail(self):
        sizes, cards = self.fixture_roster()
        cards[0]["spaceRows"] = 1
        self.assertEqual("FAIL", evaluate(sizes, cards)["status"])
        cards[0].update(spaceRows=0, cardY=cards[1]["cardY"])
        self.assertEqual("FAIL", evaluate(sizes, cards)["status"])

    def test_same_scale_requires_relative_size_and_shape(self):
        source = [[540, 208], [240, 378]]
        self.assertTrue(same_scale(source, [[54, 21], [24, 38]]))
        self.assertFalse(same_scale(source, [[54, 21], [54, 21]]))
        self.assertFalse(same_scale(source, [[54, 21], [48, 76]]))
        self.assertFalse(same_scale(source, [[54, 21], [24, 30]]))

    def test_current_permissions_only_accept_matched_request(self):
        nonce = "481A400A-1079-46FB-A048-3918F2B91FC4"
        current = f"Permission check {nonce} screen=true accessibility=false postEvent=false"
        stale = current.replace("481A", "881A")
        host = {"pid": 123, "launch": 1}
        for record in (stale, "", current + "\n" + current):
            with self.subTest(record=record), patch("acceptance.checked", side_effect=[nonce, record]):
                self.assertIsNone(host_current_permissions(host, Path("metrics")))
        with patch("acceptance.checked", side_effect=[nonce, current]):
            result = host_current_permissions(host, Path("metrics"))
            self.assertTrue(result["screen"])
            self.assertFalse(result["accessibility"])

    def test_highlight_and_inventory_are_independent(self):
        scopes = [{"scope": "display", "current": 7, "records": [{"id": 2, "type": 0}, {"id": 7, "type": 0}]}]
        rows = [{"identifier": f"native-space-row:display:{n}", "matches": 1, "selected": n == 2} for n in (2, 7)]
        data = {"scopes": scopes, "sidebar": {"rows": rows}}
        self.assertTrue(catalog_match(data)["rowIdentitiesMatch"])
        self.assertFalse(catalog_match(data)["highlightMatchesSystem"])
        rows[0]["matches"] = 2
        self.assertFalse(catalog_match(data)["rowIdentitiesMatch"])

    def test_unobserved_is_never_pass(self):
        self.assertFalse(catalog_match({})["rowIdentitiesMatch"])
        with tempfile.TemporaryDirectory() as tmp:
            report = Receipt(Path(tmp) / "new")
            report.attempts.append({"id": "interrupted", "status": "UNKNOWN"})
            report.log("window-intent", intent="interrupted")
            report.finish()
            results = json.loads((report.output / "results.json").read_text())
            self.assertEqual(1, results["unknownAttempts"])
            self.assertFalse(results["allRequiredPassed"])
            with self.assertRaises(FileExistsError):
                Receipt(report.output)


if __name__ == "__main__":
    unittest.main()
