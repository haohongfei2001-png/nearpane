import json
import tempfile
import unittest
from pathlib import Path

from acceptance import Receipt, catalog_match


class EvidenceTests(unittest.TestCase):
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
