import io
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from contextlib import ExitStack
from types import SimpleNamespace
from unittest.mock import Mock, patch

import space_menu_smoke as smoke

D = "00000000-0000-0000-0000-000000000001"
A = "00000000-0000-0000-0000-000000000002"
B = "00000000-0000-0000-0000-000000000003"
S = {"scope": D, "records": [dict(id=7, type=0, uuid=A), dict(id=8, type=4, uuid=B)], "current": 7}
T = smoke.expected_topology(S)


def rows():
    return [dict(id=f"native-space-row:{D}:{n}", role="AXStaticText", enabled=None,
                 actionsRead=True, canPress=False, labelMatches=True) for n in (7, 8)]


class DirectorySmokeTests(unittest.TestCase):
    def test_rows_require_independent_order_numbers_current_label_and_nonactionable_controls(self):
        cases = [list(reversed(rows())), rows()[:1], rows() + rows()[:1]]
        for update in (dict(labelMatches=False), dict(role="AXUnknown"), dict(actionsRead=False), dict(canPress=None),
                       dict(role="AXButton", enabled=True, canPress=True), dict(id="native-space-row:unrelated:7")):
            sample = rows()
            sample[0].update(update)
            cases.append(sample)
        for items in cases:
            with self.subTest(items=items), self.assertRaises(ValueError):
                smoke.review(T, dict(rows=items, quarantineText=True))
        with self.assertRaisesRegex(ValueError, "Explanation"):
            smoke.review(T, dict(rows=rows(), quarantineText=False))
        self.assertEqual(smoke.review(T, dict(rows=rows(), quarantineText=True)), rows())

    def replay(self, *, failure=None):
        # Pipes are replayed from synthetic metadata; no AX objects, applications or Spaces are opened.
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            temp = Path(tmp).resolve()
            home = temp / "home"
            home.mkdir(mode=0o700)
            profile = home / smoke.PROFILE
            generation = profile / "generations" / B
            generation.mkdir(parents=True)
            (profile / "profile-index.json").write_text(json.dumps(dict(active=B)))
            app = temp / "app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
                NearpaneSourceState="clean", NearpaneSourceRevision="fixture", CFBundleVersion="90")))
            ws = SimpleNamespace(host=dict(pid=11, codeHash="digest"), boot="boot", host_birth=20, hid=[1]*5,
                                 read=lambda: {}, check=lambda _: S, hardware=Mock(return_value=[1]*5))
            if failure == "newInput":
                ws.hardware.side_effect = [[1]*5, [2]*5, [2]*5]
            proof = [dict(phase="bind", ok=True), dict(phase="status", ok=True), dict(phase="directory", ok=True)]
            if failure == "existing":
                proof[1] = dict(phase="status", ok=False, statusAttempted=False, reason="preexistingMenuOrDirectory")
            items = rows()
            if failure == "actionable":
                items[0].update(role="AXButton", enabled=True, canPress=True)
            proof.extend([dict(phase="read", ok=True, rows=[], quarantineText=False, uptime=1),
                          dict(phase="read", ok=True, rows=items, quarantineText=True, uptime=2)])
            if failure != "actionable":
                proof.append(dict(phase="read", ok=True, rows=items, quarantineText=True, uptime=3))
            proof += [dict(phase="close", ok=True, method="AXPress"),
                      dict(phase="verify", ok=True, topology=T, closedReadbacks=2)]
            class Input(io.BytesIO):
                def close(self):
                    self.sent = self.getvalue().splitlines()
                    super().close()
            outbound = Input()
            child = Mock(stdin=outbound, stdout=io.BytesIO(b"".join(json.dumps(r).encode()+b"\n" for r in proof)))
            def substitute(obj, attr, *args, **kwargs):
                return stack.enter_context(patch.object(obj, attr, *args, **kwargs))
            substitute(smoke, "APP", app)
            for name in ("private_binary", "validate_home", "owns_profile", "fresh_ordinary_reader", "empty_system_desktop"):
                substitute(smoke, name, return_value=True)
            substitute(smoke, "identity", return_value=dict(CDHash="digest", TeamIdentifier=smoke.TEAM, Identifier="com.holdsnow.nearpane.alpha"))
            substitute(smoke, "installed_pid", return_value=11)
            substitute(smoke.driver, "lease_for", return_value=(None, A))
            substitute(smoke.driver, "login_env", return_value={})
            substitute(smoke.subprocess, "check_output", return_value="boot")
            substitute(smoke.subprocess, "Popen", return_value=child)
            substitute(smoke.select, "select", return_value=([1], [], []))
            substitute(smoke.time, "sleep")
            stack.enter_context(patch.dict(os.environ, NEARPANE_TEST_HOME=str(home), NEARPANE_TEST_GENERATION=str(generation)))
            result = smoke.run("smoke", ws, 7, {}, "stage", temp/"report")
            self.assertEqual(json.loads((temp/"report/result.json").read_text()), result)
            self.assertEqual(result["rowActionsIssued"], 0)
            return result, [s.decode() for s in outbound.sent[1:]]

    def test_complete_qualified_open_read_and_close(self):
        result, commands = self.replay()
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(commands, ["status", "directory", "read", "read", "read", "close", "verify"])
        self.assertEqual(result["readback"]["clocks"], [2, 3])

    def test_visible_enabled_button_is_failure_without_testing_its_action(self):
        result, commands = self.replay(failure="actionable")
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["cleanup"]["status"], "PASS")
        self.assertEqual(commands, ["status", "directory", "read", "read", "close", "verify"])

    def test_preexisting_presentation_is_preserved(self):
        result, commands = self.replay(failure="existing")
        self.assertEqual(result["status"], "BLOCKED")
        self.assertEqual(result["cleanup"]["status"], "NOT_NEEDED")
        self.assertEqual(commands, ["status"])

    def test_new_physical_input_suppresses_opener_and_cleanup_actions(self):
        result, commands = self.replay(failure="newInput")
        self.assertEqual(result["status"], "BLOCKED")
        self.assertEqual(result["cleanup"]["status"], "UNKNOWN")
        self.assertEqual(commands, ["status"])
