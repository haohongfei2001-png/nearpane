import json
import unittest
from pair_pointer_timing import correlate, pair_phase, parse


class HostCallbackTests(unittest.TestCase):
    def setUp(self):
        self.op = "43002097-d880-4f78-9c49-f5a03fee4c7d"
        self.row = dict(processID=51,category="WindowFocusLatency",subsystem="com.holdsnow.nearpane.alpha",
                        eventMessage=f"operation={self.op} phase=click route=sidebar action=none uptime=42.089000")

    def test_only_enrolled_pid_and_fixed_content_free_message_are_admitted(self):
        self.assertEqual(parse(json.dumps(self.row),51)["operation"],self.op)
        for change in (dict(processID=50), dict(eventMessage=self.row["eventMessage"]+" unrelated content"),
                       dict(category="WindowSelection")):
            self.assertIsNone(parse(json.dumps({**self.row,**change}),51))

    def test_stale_ambiguous_and_unavailable_never_prove_a_callback(self):
        click = parse(json.dumps(self.row),51)
        for records,status,expect in (([click],"OBSERVED","OBSERVED"),([click,click],"OBSERVED","AMBIGUOUS"),
                ([{**click,"uptime":41}],"OBSERVED","NOT_OBSERVED"),([click],"UNAVAILABLE","UNAVAILABLE")):
            attempt = {"pointerObservationRange":[42,44]}
            correlate([attempt],records,status)
            self.assertEqual(attempt["hostButton"]["status"],expect)

    def test_drag_does_not_generate_a_click_record(self):
        attempt = {"kind":"right"}
        correlate([attempt],[parse(json.dumps(self.row),51)],"OBSERVED")
        self.assertNotIn("hostButton",attempt)

    def test_pair_refusal_has_only_checked_stage_and_reason_from_enrolled_host(self):
        row = {**self.row,"category":"SidebarPointer"}
        message = "phase=pairTransactionRefused stage=verifyRightBeforeWrite reason=stale"
        def read(msg, pid=51):
            return pair_phase(json.dumps({**row,"eventMessage":msg}),pid)
        self.assertEqual(read(message),{"phase":"pairTransactionRefused","stage":"verifyRightBeforeWrite","reason":"stale"})
        self.assertEqual(read("phase=pairBoundEvidenceRevoked reason=membershipChanged"),
                         {"phase":"pairBoundEvidenceRevoked","reason":"membershipChanged"})
        self.assertEqual(read("phase=pairUsingBoundWindows"),{"phase":"pairUsingBoundWindows"})
        for invalid in (message+" extra",message.replace("stale","arbitrary"),message.replace("verifyRightBeforeWrite","arbitrary"),
                        "phase=pairBoundEvidenceRevoked reason=arbitrary","pairUsingBoundWindows"):
            self.assertIsNone(read(invalid))
        self.assertIsNone(read(message,52))
