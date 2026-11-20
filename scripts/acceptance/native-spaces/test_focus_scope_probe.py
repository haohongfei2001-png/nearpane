import json
import unittest

from focus_scope_probe import REQUIRED, matching_rows


class EnrolledFocusReadTests(unittest.TestCase):
    bind = {"pid": 17, "birth": 711, "hostPID": 25, "numbers": [54391, 54393]}

    def row(self, number=54393):
        return {"probe": "NONCE", "stage": "enrolled-current-focus", "mode": "readOnlyFocusScope", "writerPID": 25,
                "workerPID": 30, "actualAXWrites": 0, "state": "confirmed", "window": {"pid": 17, "birth": 711, "number": number},
                "findings": [{"point": p, "reason": r, "state": "confirmed"} for p, r in sorted(REQUIRED)]}

    def read(self, rows):
        return matching_rows([json.dumps(r) for r in rows], self.bind, "NONCE")

    def test_read_uses_original_pair_order_and_discards_unrelated_nonce(self):
        stale = {**self.row(), "probe": "OLD"}
        rows = self.read([self.row(), stale, self.row(54391)])
        self.assertEqual([r["number"] for r in rows], self.bind["numbers"])
        self.assertTrue(all(r["state"] == "confirmed" for r in rows))

    def test_no_confirmed_record_from_unread_unknown_or_missing_scope(self):
        for bad in ({"actualAXWrites": 1}, {"mode":"ordinary"}, {"writerPID": 19}, {"workerPID": 25}, {"findings": []},
                    {"window": {"pid": 17, "birth": 712, "number": 54393}},
                    {"findings": [{"point":"surface","reason":"surfaceOwner","state":"changed"}]}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.read([{**self.row(), **bad}])
        with self.assertRaises(ValueError):
            self.read([self.row(), self.row()])

    def test_refusals_preserve_categorical_details_without_granting_any_action(self):
        row = self.row()
        row["state"] = "changed"
        row["findings"] = [{"point":"opening","reason":"usableFrame","state":"changed","expected":0,"observed":10}]
        self.assertEqual(self.read([row])[0]["findings"], row["findings"])
        with self.assertRaises(ValueError):
            self.read([{**row, "findings":[{**row["findings"][0], "windowTitle":"forbidden"}]}])
