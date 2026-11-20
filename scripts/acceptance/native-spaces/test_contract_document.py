"""Deterministic W01 action and cleanup receipts. No process, window or input actions."""
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
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
        self.workspace = SimpleNamespace(kit=self.kit, display="screen", host={"pid": 28, "codeHash": "host"}, host_birth=987654321, hid=[])
        self.calls = []
        self.receipt = SimpleNamespace(attempts=[], log=Mock(), write=Mock())
        self.clock = Clock()
        for name, fn in (("monotonic", lambda: self.clock.now), ("sleep", self.clock.sleep)):
            p = patch.object(doc.time, name, fn)
            p.start()
            self.addCleanup(p.stop)

    def ready(self, target, state="ready", panel=90):
        note = dict(state=state, matches=1, regions=1, button=True, enabled=True, enabledAXError=0, actionsAXError=0)
        if state == "ready":
            note["panel"] = panel
        return dict(control=f"current-desktop-window:27:{target}", hostPID=28, hostBirth=self.workspace.host_birth, hostHash="host",
                    documentBirth=self.instance["birth"], numbers=[31, 32], display="screen", space=47, controlRead=note)

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
            if mode == "ready":
                return self.ready(kwargs["target"])
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

    def test_control_wait_resets_on_absence_duplicates_disabling_and_visible_panel_replacement(self):
        expected = self.ready(32)
        expected.pop("controlRead")
        seq = iter([("missing", 0), ("disabled", 0), ("ready", 70), ("duplicate", 0), ("ready", 70), ("ready", 80), ("ready", 80)])
        def action(mode, **kwargs):
            self.assertEqual(mode, "ready")
            self.assertEqual((kwargs["index"], kwargs["target"]), (1, 32))
            state, panel = next(seq)
            proof = self.ready(32, state, panel)
            if state == "missing":
                proof["controlRead"].update(matches=0)
            elif state == "disabled":
                proof["controlRead"].update(enabled=False)
            elif state == "duplicate":
                proof["controlRead"].update(matches=2)
            return proof
        result = doc.wait_for_control(action, 1, 32, expected, 1, self.receipt)
        self.assertEqual((result["status"], result["panel"]), ("READY", 80))
        self.assertEqual([o["state"] for o in result["observations"]], ["missing", "disabled", "ready", "duplicate", "ready", "ready", "ready"])

    def test_unready_sidebar_expires_without_product_attempt_or_marker_and_closes_the_owned_fixture(self):
        def action(workspace, folder, desktop, mode, **kwargs):
            self.calls.append(mode)
            if mode == "open":
                path = folder/"instance.json"
                path.write_text(json.dumps(self.instance))
                path.chmod(0o600)
                return self.instance
            if mode == "sample":
                empty = hashlib.sha256(b"").hexdigest()
                return dict(front=True, numbers=[31, 32], focused=31, main=31, hashes=[empty, empty])
            if mode == "ready":
                proof = self.ready(32, "missing")
                proof["controlRead"] = dict(state="missing", matches=0, regions=1)
                return proof
            self.assertEqual(mode, "close")
            return dict(quitRequested=True)
        with patch.object(doc, "document_action", side_effect=action), patch.object(doc, "kernel_state", return_value=dict(state="ABSENT")):
            result = doc.run(self.workspace, self.receipt, 47)
        self.assertEqual((result["status"], result["operationStage"], result["issued"], result["attempts"]), ("BLOCKED", "control-readiness", 0, []))
        self.assertNotIn("marker", self.calls)
        self.assertNotIn("press", self.calls)
        self.assertEqual(result["cleanup"]["status"], "PASS")
        obs = result["controlReadiness"][0]["observations"]
        self.assertGreater(len(obs), 1)
        self.assertLessEqual(obs[-1]["afterSeconds"], 5)
        self.assertTrue(all(o["matches"] == 0 and o["state"] == "missing" for o in obs))

    def test_one_ready_read_cannot_survive_a_changed_identity_scope_or_lost_proof(self):
        expected = self.ready(32)
        expected.pop("controlRead")
        failures = [({"hostPID": 32}, "readIdentityChanged"), ({"hostBirth": 10}, "readIdentityChanged"),
                    ({"documentBirth": 12}, "readIdentityChanged"), ({"numbers":[31, 33]}, "readIdentityChanged"), ({"control":"other"}, "readIdentityChanged"),
                    ({"space":9}, "readIdentityChanged"), ({"controlRead":{"state":"ready", "matches":1}}, "invalidRead"),
                    (subprocess.TimeoutExpired("readonly", 0.2), "readTimedOut"), (doc.ScopeError("HID changed"), "guardRefused")]
        for change, reason in failures:
            with self.subTest(reason=reason):
                tail = change if isinstance(change, Exception) else {**self.ready(32), **change}
                action = Mock(side_effect=[self.ready(32), tail])
                result = doc.wait_for_control(action, 1, 32, expected, 1, self.receipt)
                self.assertEqual((result["status"], result["observations"][-1]["state"]), ("BLOCKED", reason))
                self.assertEqual([c.args for c in action.call_args_list], [("ready",), ("ready",)])

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
            if mode == "ready":
                return self.ready(kwargs["target"])
            if mode == "press":
                self.assertEqual((kwargs["panel"], kwargs["target"], kwargs["numbers"]), (90, numbers[kwargs["index"]], numbers))
                focused = kwargs["index"]
                return {"issued": True, "exitCode": 0, "axError": 0, "control": f"current-desktop-window:27:{numbers[focused]}"}
            if mode == "marker":
                self.assertEqual((focused, kwargs["target"], kwargs["numbers"]), (kwargs["index"], numbers[focused], numbers))
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
        self.assertEqual(self.calls.count("ready"), 20)
        for i, call in enumerate(self.calls):
            if call == "press":
                self.assertEqual(self.calls[i-2:i], ["ready", "ready"])

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

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS system code signing")
    def test_textedit_signature_and_scoped_focus_without_gui(self):
        source = Path(__file__).resolve().parent
        executable = self.kit / "check-identity"
        subprocess.run(["xcrun", "swiftc", source.parents[2]/"Sources/NearpaneCore/AXWindowList.swift",
                        source/"textedit_window_list.swift", source/"textedit_identity.swift", source/"test_textedit_identity.swift",
                        "-o", executable], check=True, timeout=60)
        system = Path("/System/Applications/TextEdit.app/Contents/MacOS/TextEdit")
        names = subprocess.check_output(["xcrun", "lipo", "-archs", system], text=True).split()
        with system.open("rb") as target:
            header = target.read(4096)
        magic, count = struct.unpack_from(">II", header)
        if magic in (0xCAFEBABE, 0xCAFEBABF):
            self.assertEqual(count, len(names))
            stride = 20 if magic == 0xCAFEBABE else 32
            slices = [struct.unpack_from(">ii", header, 8+i*stride) for i in range(count)]
        else:
            self.assertEqual(len(names), 1)
            self.assertIn(magic, (0xCFFAEDFE, 0xCEFAEDFE, 0xFEEDFACE, 0xFEEDFACF))
            slices = [struct.unpack_from("<ii" if magic in (0xCFFAEDFE, 0xCEFAEDFE) else ">ii", header, 4)]
        cases = []
        for (cpu, subtype), name in zip(slices, names):
            code = subprocess.run(["codesign", "-d", "--verbose=4", "--arch", name, system],
                                  capture_output=True, text=True, check=True)
            digest = re.search(r"^CDHash=([0-9a-f]+)$", code.stderr, re.M).group(1)
            cases.append(f"{cpu}:{subtype}:{digest}")
        subprocess.run([executable, *cases], check=True, timeout=5)

    def test_partial_launch_can_close_only_the_same_reverified_signed_slice_without_launch_date(self):
        folder = self.kit / "launch"
        folder.mkdir()
        def write(name, data):
            path = folder / name
            path.write_text(json.dumps(data))
            path.chmod(0o600)
        intent = {"notBefore": 120}
        write("launch-intent.json", intent)
        action = Mock()
        self.assertEqual(doc.cleanup_document(self.kit, folder, None, action)["status"], "UNKNOWN")
        action.assert_not_called()
        write("launch-callback.json", {**intent, "pid": 27, "birth": 130, "callbackTime": 140})
        signed = {"pid": 27, "birth": 130, "hash": "a"*40, "consoleUID": os.getuid(),
                  "architecture": {"cpu": 16777228, "subtype": -2147483646}}
        def close(mode):
            self.assertEqual(mode, "close")
            write("instance.json", signed)
            return {"quitRequested": True}
        action.side_effect = close
        with patch.object(doc, "kernel_state", return_value={"state": "ABSENT"}):
            result = doc.cleanup_document(self.kit, folder, None, action)
            self.assertTrue(result["recoveredSignedEnrollment"])
            self.assertEqual(result["status"], "PASS")
            self.assertEqual(doc.cleanup_document(self.kit, folder, {**signed, "launch": None}, Mock())["status"], "PASS")
        action.assert_called_once_with("close")
        (folder/"instance.json").unlink()
        refused = Mock(side_effect=doc.ScopeError("TextEdit signedDiskSlice unavailable"))
        self.assertEqual(doc.cleanup_document(self.kit, folder, None, refused)["status"], "UNKNOWN")
        refused.assert_called_once_with("close")

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

    def test_issued_press_and_every_read_refusal_keep_their_own_safe_metadata(self):
        item = dict(phase="initial", start=10.001, end=10.02, rootAXError=0, status="emptyArray",
                    binding="notChecked", valueKind="array", countAXError=0, copyAXError=0, reportedCount=0, copiedCount=0)
        seen = []
        def capture(mode, coverage, rows):
            seen.append((mode, coverage, rows))
        replies = [{"issued": True, "control": "x", "axError": 0, "windowReads": [dict(item, status="twoAXWindows", copiedCount=2, reportedCount=2)]},
                   {"issued": False, "reason": "empty", "windowReads": [item]},
                   {"issued": False, "reason": "copy failed", "windowReads": [dict(item, status="arrayAXError", copyAXError=-25204)]},
                   {"issued": False, "reason": "unavailable", "windowReads": [dict(item, title="private")]}]
        processes = [subprocess.CompletedProcess([], int(i != 0) * 2, stdout=json.dumps(v)) for i, v in enumerate(replies)]
        with patch.object(doc.subprocess, "run", side_effect=processes) as runner:
            action = lambda mode, **kw: doc.document_action(self.workspace, self.kit, 47, mode, record_reads=capture, **kw)
            self.assertEqual(doc.press_once(action, 0, "x")["pressDisposition"], "ISSUED")
            for _ in range(3):
                with self.assertRaises(doc.ScopeError):
                    action("sample")
        self.assertEqual(runner.call_count, 4)
        self.assertEqual([x[0] for x in seen], ["press", "sample", "sample", "sample"])
        self.assertEqual([x[2][0]["status"] for x in seen[:3]], ["twoAXWindows", "emptyArray", "arrayAXError"])
        self.assertEqual(seen[-1][1:], ("INVALID", []))

    def test_lost_replies_and_unusable_diagnostics_never_reissue_an_accepted_press(self):
        malformed = {"phase": "initial", "start": 1, "end": 2, "binding": [], "status": {"unexpected": 1}}
        accepted = subprocess.CompletedProcess([], 0, stdout=json.dumps(
            {"issued": True, "control": "x", "axError": 0, "windowReads": [malformed]}))
        lost = subprocess.CompletedProcess([], 1, stdout="truncated reply")
        tracked = Mock()
        def action(mode, **kwargs):
            return doc.document_action(self.workspace, self.kit, 47, mode, record_reads=tracked, **kwargs)
        with patch.object(doc.subprocess, "run", side_effect=[accepted, lost, subprocess.TimeoutExpired("test-witness", 13)]) as runner:
            self.assertIs(doc.press_once(action, 0, "x")["inputAcknowledged"], True)
            with self.assertRaises(doc.ScopeError):
                action("sample")
            with self.assertRaises(subprocess.TimeoutExpired):
                action("sample")
        self.assertEqual([json.loads(call.kwargs["input"])["mode"] for call in runner.call_args_list], ["press", "sample", "sample"])
        self.assertEqual([call.args for call in tracked.call_args_list],
                         [("press", "INVALID", []), ("sample", "NO_REPLY", []), ("sample", "NO_REPLY", [])])

    def test_helper_exit_envelope_distinguishes_guard_from_unknown(self):
        record = subprocess.CompletedProcess([], 2, stdout='{"issued":false,"reason":"guard refused"}')
        with patch.object(doc.subprocess, "run", return_value=record):
            reply = doc.document_action(self.workspace, self.kit, 47, "press", index=0)
        self.assertEqual((reply["issued"], reply["exitCode"], reply["reason"]), (False, 2, "guard refused"))
        specific = subprocess.CompletedProcess([], 2, stdout='{"issued":false,"stage":"matchingCDHash","reason":"different signed slice"}')
        with patch.object(doc.subprocess, "run", return_value=specific):
            with self.assertRaises(doc.DocumentIdentityError) as refused:
                doc.document_action(self.workspace, self.kit, 47, "open")
            self.assertEqual(refused.exception.stage, "matchingCDHash")
        for payload in ({"exitCode": -9, "issued": False}, {"exitCode": 2, "issued": None}):
            state = doc.press_once(Mock(return_value=payload), 0, "target")
            self.assertEqual(state["pressDisposition"], "UNKNOWN")
            self.assertIsNone(state["axIssued"])


if __name__ == "__main__":
    unittest.main()
