"""Deterministic W01 action and cleanup receipts. No process, window or input actions."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import contract_document as doc


class Clock:
    def __init__(self):
        self.now = 0

    def sleep(self, seconds):
        self.now += seconds


class DocumentTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.kit = Path(temporary.name).resolve()
        self.instance = {"pid": 27, "birth": 123450000, "launch": 4.1, "hash": "code"}
        self.workspace = SimpleNamespace(kit=self.kit, display="screen", host={"pid": 28, "codeHash": "host"}, hid=[])
        self.calls = []
        self.receipt = SimpleNamespace(attempts=[], log=Mock(), write=Mock())
        self.clock = Clock()
        for name, fn in (("monotonic", lambda: self.clock.now), ("sleep", self.clock.sleep)):
            p = patch.object(doc.time, name, fn)
            p.start()
            self.addCleanup(p.stop)

    def simulate(self, reply, process, close_error=None):
        def helper(workspace, folder, desktop, mode, **kwargs):
            self.calls.append(mode)
            if mode == "open":
                path = folder/"instance.json"
                path.write_text(json.dumps(self.instance))
                path.chmod(0o600)
                return self.instance
            if mode == "sample":
                empty = hashlib.sha256(b"").hexdigest()
                return {"front": True, "numbers": [31, 32], "focused": 31, "main": 31, "hashes": [empty, empty]}
            if mode == "press":
                if isinstance(reply, Exception):
                    raise reply
                return reply
            if mode == "close":
                if close_error:
                    raise doc.ScopeError(close_error)
                return {"quitRequested": True}
            self.fail("unadmitted input: " + mode)

        with patch.object(doc, "document_action", side_effect=helper), patch.object(doc, "kernel_state", side_effect=process):
            outcome = doc.run(self.workspace, self.receipt, 47)
        self.receipt.write.assert_called_once_with("W01-system-documents.json", outcome)
        self.assertEqual(outcome["attempts"], self.receipt.attempts)
        self.assertEqual(self.calls.count("press"), 1)
        self.assertEqual(self.calls.count("close"), 1)
        self.assertNotIn("marker", self.calls)
        return outcome

    def test_refused_press_then_close_ax_error_and_later_kernel_exit(self):
        observations = iter([{"state": "ALIVE"}, {"state": "ABSENT"}])
        def process(kit, pid, birth, timeout):
            self.assertEqual((kit, pid, birth), (self.kit, self.instance["pid"], self.instance["birth"]))
            return next(observations)
        result = self.simulate({"issued": False, "exitCode": 2, "reason": "no unique enabled document control"},
                               process, "TextEdit has not exposed exactly two enrolled document windows")
        self.assertEqual((result["status"], result["operationStatus"], result["issued"]), ("BLOCKED", "BLOCKED", 0))
        self.assertEqual(result["reason"], "no unique enabled document control")
        a = result["attempts"][0]
        self.assertEqual((a["axIssued"], a["pressDisposition"], a["inputAcknowledged"]), (False, "REFUSED", None))
        self.assertEqual(a["reason"], result["reason"])
        cleanup = result["cleanup"]
        self.assertEqual((cleanup["status"], cleanup["terminated"], cleanup["kernelChecks"]), ("PASS", True, 2))
        self.assertIn("two enrolled", cleanup["closeError"])
        events = [c.args[0] for c in self.receipt.log.call_args_list]
        self.assertLess(events.index("W01-installed-sidebar-press"), events.index("W01-system-document-cleanup"))

    def test_lost_press_reply_and_live_generation_do_not_replace_original_reason(self):
        result = self.simulate(subprocess.TimeoutExpired("test-only", 13), lambda *a, **kw: {"state": "ALIVE"},
                               "AX owner inventory unavailable")
        self.assertEqual((result["status"], result["operationStatus"], result["issued"]), ("FAIL", "UNKNOWN", 0))
        self.assertIn("timed out", result["reason"])
        self.assertEqual(result["cleanup"]["status"], "FAIL")
        self.assertIs(result["cleanup"]["terminated"], False)
        self.assertEqual(result["cleanup"]["elapsedSeconds"], 4)
        self.assertIsNone(result["attempts"][0]["axIssued"])

    def test_confirmed_ax_call_and_negative_ack_survive_unreadable_cleanup(self):
        result = self.simulate({"issued": True, "axError": -25204, "control": "current-desktop-window:27:32", "exitCode": 0},
                               lambda *a, **kw: {"state": "UNKNOWN", "exitCode": 3})
        self.assertEqual((result["status"], result["operationStatus"], result["issued"]), ("FAIL", "FAIL", 1))
        self.assertIn("-25204", result["reason"])
        self.assertEqual(result["cleanup"]["status"], "UNKNOWN")
        self.assertIsNone(result["cleanup"]["terminated"])
        a = result["attempts"][0]
        self.assertEqual((a["pressDisposition"], a["axIssued"], a["inputAcknowledged"]), ("ISSUED", True, False))

    def test_issued_and_acknowledged_requires_the_exact_target_control(self):
        def helper(mode, **kwargs):
            return {"exitCode": 0, "control": "current-desktop-window:27:32", "axError": 0, "issued": True}
        reply = doc.press_once(helper, 1, "current-desktop-window:27:32")
        self.assertEqual((reply["pressDisposition"], reply["axIssued"], reply["inputAcknowledged"]), ("ISSUED", True, True))
        wrong = doc.press_once(helper, 0, "current-desktop-window:27:31")
        self.assertIsNone(wrong["inputAcknowledged"])
        self.assertIs(wrong["axIssued"], True)

    def test_ten_acknowledged_placements_and_replaced_pid_confirm_separate_outcomes(self):
        numbers, text, focused = [31, 32], ["", ""], 0
        def helper(workspace, folder, desktop, mode, **kwargs):
            nonlocal focused
            self.calls.append(mode)
            if mode == "open":
                path = folder/"instance.json"
                path.write_text(json.dumps(self.instance))
                path.chmod(0o600)
                return self.instance
            if mode == "sample":
                marker = kwargs.get("marker")
                return {"numbers": numbers, "focused": numbers[focused], "main": numbers[focused], "front": True,
                        "hashes": [hashlib.sha256(t.encode()).hexdigest() for t in text],
                        "markerCounts": [t.count(marker) if marker else 0 for t in text]}
            if mode == "press":
                focused = kwargs["index"]
                return {"issued": True, "exitCode": 0, "axError": 0, "control": f"current-desktop-window:27:{numbers[focused]}"}
            if mode == "marker":
                self.assertEqual(focused, kwargs["index"])
                text[focused] += kwargs["marker"]
                return {"issued": True}
            self.assertEqual(mode, "close")
            return {"quitRequested": True}
        with patch.object(doc, "document_action", side_effect=helper), patch.object(doc, "kernel_state", return_value={
                "state": "REPLACED", "observedBirth": self.instance["birth"] + 1}):
            result = doc.run(self.workspace, self.receipt, 47)
        self.assertEqual((result["status"], result["operationStatus"], result["passes"]), ("PASS", "PASS", 10))
        self.assertEqual(result["pressCounts"], {"ISSUED": 10, "REFUSED": 0, "UNKNOWN": 0})
        self.assertEqual([r["target"] for r in result["attempts"]], [32, 31] * 5)
        self.assertTrue(result["cleanup"]["terminated"])
        self.assertEqual(self.calls.count("close"), 1)

    def test_kernel_witness_accepts_only_the_enrolled_pid_and_valid_generation(self):
        def sample(payload):
            cmd = subprocess.CompletedProcess([], 0, stdout=json.dumps(payload))
            with patch.object(doc.subprocess, "run", return_value=cmd):
                return doc.kernel_state(self.kit, 27, self.instance["birth"], timeout=.1)["state"]
        self.assertEqual(sample({"pid": 27, "birth": self.instance["birth"]}), "ALIVE")
        self.assertEqual(sample({"pid": 27, "birth": self.instance["birth"] + 1}), "REPLACED")
        self.assertEqual(sample({"pid": 27, "absent": True}), "ABSENT")
        for value in ([], {"pid": 99, "absent": True}, {"pid": 27, "birth": True}, {"pid": 27},
                      {"pid": 27, "absent": True, "birth": 57}):
            self.assertEqual(sample(value), "UNKNOWN")

    def test_unknown_or_missing_durable_identity_never_issues_close(self):
        folder = self.kit/"fixture"
        folder.mkdir()
        action = Mock()
        self.assertEqual(doc.cleanup_document(self.kit, folder, None, action)["status"], "NOT_RUN")
        receipt = folder/"instance.json"
        receipt.write_text(json.dumps({**self.instance, "pid": 28}))
        receipt.chmod(0o600)
        bad = doc.cleanup_document(self.kit, folder, self.instance, action)
        self.assertEqual(bad["status"], "UNKNOWN")
        self.assertIsNone(bad["terminated"])
        action.assert_not_called()

    def test_helper_exit_envelope_distinguishes_guard_from_unknown(self):
        record = subprocess.CompletedProcess([], 2, stdout='{"issued":false,"reason":"guard refused"}')
        with patch.object(doc.subprocess, "run", return_value=record):
            reply = doc.document_action(self.workspace, self.kit, 47, "press", index=0)
        self.assertEqual((reply["issued"], reply["exitCode"], reply["reason"]), (False, 2, "guard refused"))
        for payload in ({"exitCode": -9, "issued": False}, {"exitCode": 2, "issued": None}):
            state = doc.press_once(Mock(return_value=payload), 0, "target")
            self.assertEqual(state["pressDisposition"], "UNKNOWN")
            self.assertIsNone(state["axIssued"])


if __name__ == "__main__":
    unittest.main()
