"""Read-only dispatch gates. A synthetic proof is never used as installed-Host acceptance."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from pair_pointer import PairPointerRun, scope_probe_gate
from p2_documents import Superseded, TrialStop


def proof():
    return dict(status="CONFIRMED", reason="bothWindowScopesConfirmed", issued=False, actualAXWrites=0,
                hostPID=41, windows=[dict(pid=88,birth=1234,number=n,state="confirmed",findings=[]) for n in (37,52)])


class ScopePreflightTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        output = self.output = Path(temp.name).resolve()
        self.rec = Mock(output=output, attempts=[],scenarios={},summary={})
        self.rec.write.side_effect = lambda name, value: (output/name).write_text(json.dumps(value))
        initial = {"host":{"pid":41,"codeHash":"hh"},"scopes":[{"scope":"D","current":99}],"frontmostPID":88}
        with patch.dict(os.environ,NP_P2_FOCUS_SCOPE_PREFLIGHT="1"):
            self.run = PairPointerRun(output/"observe",initial,self.rec,None)
        self.run.binding.update(pid=88,birth=1234,numbers=[37,52])
        self.run.focus_only = True
        self.order = []
        self.run.prepare_front = Mock(side_effect=lambda _: self.order.append("prepared") or 37)
        self.run.selection_trials = Mock(side_effect=lambda *_: self.order.append("selection"))
        self.run.packet = Mock(side_effect=AssertionError("No system input allowed"))
        self.run.geometry = Mock(side_effect=AssertionError("No layout allowed"))

    def inspector(self, returned, persisted=None):
        def inspect(binding, folder, output):
            self.order.append("probe")
            self.assertEqual(binding["numbers"], [37,52])
            self.assertEqual(folder,self.run.folder)
            self.assertEqual(output,self.output)
            raw = output/"focus-scope-probe.json"
            raw.write_text(json.dumps(returned if persisted is None else persisted))
            raw.chmod(0o600)
            return returned
        return patch.dict("sys.modules",{"focus_scope_probe":Mock(inspect_pair=inspect)})

    def test_only_persisted_confirmed_pair_reaches_selection_after_foreground_prepare(self):
        with self.inspector(proof()):
            self.run.pointer_trials("reader")
        self.assertEqual(self.order, ["prepared","probe","selection"])
        receipt = json.loads((self.output/"focus-scope-preflight.json").read_text())
        self.assertEqual(receipt["status"], "CONFIRMED")
        self.assertTrue(receipt["rawReceiptVerified"])
        self.assertFalse(receipt["pointerOrLayoutIssued"])

    def test_named_blocker_reaches_machine_receipt_with_zero_downstream_actions(self):
        p = proof()
        p.update(status="BLOCKED",reason="windowMembershipChanged")
        finding = {"point":"opening", "reason":"forwardMembership", "state":"changed", "observed":0}
        p["windows"][1].update(state="changed",findings=[finding])
        self.run.drag_only = True
        with self.inspector(p), self.assertRaises(TrialStop) as refused:
            self.run.pointer_trials("reader")
        self.assertEqual((refused.exception.status,refused.exception.reason),("BLOCKED","windowMembershipChanged"))
        self.assertEqual(self.order,["prepared","probe"])
        gate = json.loads((self.output/"focus-scope-preflight.json").read_text())
        self.assertEqual(json.loads((self.output/gate["probeFile"]).read_text())["windows"][1]["findings"], [finding])
        self.assertEqual(gate["windowCauses"], [{"number":52,"point":"opening","reason":"forwardMembership","state":"changed"}])
        self.run.packet.assert_not_called()
        self.run.geometry.assert_not_called()

    def test_each_window_must_affirm_same_generation_and_real_distinct_target_in_order(self):
        for edit in (lambda p:p["windows"].pop(), lambda p:p["windows"].reverse(),
                     lambda p:p["windows"][1].update(number=37), lambda p:p["windows"][0].update(pid=30),
                     lambda p:p["windows"][1].update(birth=9), lambda p:p.update(hostPID=99),
                     lambda p:p["windows"][0].update(state="fullRosterRequired"),
                     lambda p:p.update(issued=True), lambda p:p.update(actualAXWrites=False)):
            value=proof()
            edit(value)
            self.assertEqual(scope_probe_gate(value,self.run.binding)[0], "UNKNOWN")

    def test_output_mismatch_and_missing_probe_both_refuse_before_selection(self):
        with self.inspector(proof(), {"status":"UNKNOWN"}), self.assertRaises(TrialStop) as refused:
            self.run.pointer_trials("reader")
        self.assertEqual(refused.exception.reason,"focusScopeProbePersistedResultMismatch")
        with patch.dict("sys.modules",{"focus_scope_probe":None}), self.assertRaises(TrialStop) as unavailable:
            self.run.pointer_trials("reader")
        self.assertEqual(unavailable.exception.reason,"focusScopeProbeUnavailable")
        self.run.selection_trials.assert_not_called()

    def test_superseded_probe_saves_decision_and_stops_as_hardware_interruption(self):
        value = proof()
        value.update(status="BLOCKED", reason="userSuperseded")
        with self.inspector(value), self.assertRaises(Superseded):
            self.run.pointer_trials("reader")
        gate = json.loads((self.output/"focus-scope-preflight.json").read_text())
        self.assertEqual(gate["reason"], "userSuperseded")
        self.run.selection_trials.assert_not_called()

    def test_ordinary_baseline_never_calls_or_requires_probe(self):
        self.run.focus_scope_preflight=False
        with patch.dict("sys.modules",{"focus_scope_probe":None}):
            self.run.pointer_trials("reader")
        self.assertEqual(self.order,["prepared","selection"])
        self.assertFalse((self.output/"focus-scope-preflight.json").exists())

    def test_supervisor_explicitly_scopes_option_and_clears_ambient_flag_for_other_runs(self):
        spec = importlib.util.spec_from_file_location("scope_probe_supervisor",Path(__file__).with_name("private-installed-trials.py"))
        supervisor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(supervisor)
        class BeforeLaunch(Exception):
            pass
        def capture(_here, _record, _out, _chain, child):
            captured.append(dict(child))
            raise BeforeLaunch
        context = {"NP_P2_FOCUS_SCOPE_PREFLIGHT":"unexpected"}
        captured = []
        with patch.object(supervisor.spaces_trials,"focus_command",side_effect=capture):
            for scenario, enabled in (("pair-focus",True),("pair-pointer",False),("pair-cross",False)):
                rec = {"output":self.output, "candidate":{"source":"fixture"}, "focusScenario":scenario,
                       "focusScopePreflight":enabled}
                with self.assertRaises(BeforeLaunch):
                    supervisor.Mac.trial(None,"P2",rec,context,None)
            self.assertEqual([c.get("NP_P2_FOCUS_SCOPE_PREFLIGHT") for c in captured],["1",None,None])
            self.assertEqual(context["NP_P2_FOCUS_SCOPE_PREFLIGHT"], "unexpected")

    def test_publish_preserves_not_run_when_fixture_cannot_be_enrolled(self):
        self.run.out.update(operationStatus="NOT_RUN",reason="foregroundLaunchEditorUnconfirmed")
        self.run.publish()
        gate = json.loads((self.output/"focus-scope-preflight.json").read_text())
        self.assertEqual(gate["status"], "NOT_RUN")
        self.assertFalse(gate["pointerOrLayoutIssued"])
        self.assertEqual(self.rec.summary["pairPointer"]["runScope"], "DIAGNOSTIC_WITH_FOCUS_SCOPE_PREFLIGHT")
        self.assertEqual(self.rec.summary["pairPointer"]["focusScopePreflight"], gate)
        self.assertIn("focus-scope-pair-diagnostic", self.rec.scenarios)
        self.assertNotIn("ordinary-pair-pointer", self.rec.scenarios)


if __name__ == "__main__":
    unittest.main()
