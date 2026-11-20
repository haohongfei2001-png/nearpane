"""No process launch, WindowServer input, or access to any user's windows."""
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

import pair_pointer as p
import private_spaces_trials


def geometry(pair=None, clock=42):
    frames = pair or [[90,60,340,260],[130,110,372,300]]
    return dict(members=[317,409],panelID=51,displayUUID="D",clock=clock,ax=frames,cg=frames,
                visible=[0,24,1457,850],panel=[1213,34,238,810])


def click_receipt():
    return dict(status="FOCUSED",issued=True,
                events=[dict(type=1,beforePost=4.00,afterPost=4.001),dict(type=2,beforePost=4.04,afterPost=4.041)],
                focus=dict(lastNegativeSampleStarted=4.047,firstPositiveStart=4.056,firstPositiveEnd=4.059,
                           secondPositiveEnd=4.070,reads=3))


class PointerTests(unittest.TestCase):
    def setUp(self):
        initial={"scopes":[{"scope":"Main","current":9,"records":[]}],"host":{"pid":41,"codeHash":"d"},
                 "frontmostPID":23}
        self.rec = Mock(attempts=[],scenarios={},summary={})
        self.run = p.PairPointerRun(Path("/private/tmp/example/observe"),initial,self.rec,None)
        self.run.binding.update(pid=45,numbers=[317,409])
        self.run.call = Mock(side_effect=AssertionError("an offline test must never contact an application"))
        self.root = geometry()

    def test_work_area_uses_real_usable_and_panel_not_the_layout_result(self):
        policy = p.reservation({"edge":"right","displays":{}},"D")
        self.assertEqual(p.work_rect(self.root, policy),[0,24,1213,850])
        self.assertEqual(p.halves([0,24,1213,850]),[[0,24,607,850],[607,24,606,850]])
        self.root["cg"] = [[19,40,80,80]]*2
        self.assertEqual(p.work_rect(self.root, policy),[0,24,1213,850])

    def test_left_sidebar_independent_reservation_percent_and_rounding(self):
        self.root["visible"]=[.25,24.25,1457,849.75]
        self.root["panel"]=[9,30,242,834]
        cfg={"edge":"right","displays":{"d":{"edge":"left","measures":["reservedWidth",{"unit":"%","value":20}]}}}
        self.assertEqual(p.work_rect(self.root,p.reservation(cfg,"D")),[292,25,1165,849])
        cfg["displays"]["d"]["measures"][1]["value"]=1
        with self.assertRaisesRegex(p.TrialStop,"Conflicts"):p.work_rect(self.root,p.reservation(cfg,"D"))

    def test_reject_moved_panel_other_window_and_single_instrument_success(self):
        frames=self.root["cg"]
        self.assertTrue(p.geometry_agrees(self.root,frames,self.root,[317,409]))
        for changed in (dict(panelID=52),dict(members=[317,412]),dict(displayUUID="another"),
                        dict(cg=[frames[1],frames[0]]),dict(ax=[frames[1],frames[0]]),dict(visible=[0,24,1200,600])):
            self.assertFalse(p.geometry_agrees({**self.root,**changed}, frames,self.root,[317,409]))

    def test_clock_bounds_do_not_claim_appkit_or_render_timestamp(self):
        raw=click_receipt()
        t=p.click_timing(raw)
        self.assertAlmostEqual(t["downToFocusUpperMs"],59)
        self.assertAlmostEqual(t["upToFocusUpperMs"],19)
        self.assertAlmostEqual(t["upToFocusLowerMs"],6)
        raw["focus"]["lastNegativeSampleStarted"]=4.04
        self.assertEqual(p.click_timing(raw)["upToFocusLowerMs"],0)
        raw["focus"]["firstPositiveEnd"]=4.01
        with self.assertRaisesRegex(p.TrialStop,"ClockOrder"):p.click_timing(raw)

    def test_mouse_click_requires_one_down_up_and_two_real_observations(self):
        for altered in ({"status":"DISPATCHED"},{"events":[{"type":1}]},{"events":[{"type":1},{"type":6},{"type":2}]},
                        {"events":[],"issued":True,"axError":0}):
            with self.assertRaises(p.TrialStop):p.click_timing({**click_receipt(),**altered})
        self.assertEqual(p.summary(list(range(1,11))),{"n":10,"p50":5.5,"p95":10,"max":10})
        self.assertEqual(p.summary([]),{"n":0})

    def test_focus_only_runs_identical_initial_selection_and_no_drag(self):
        self.run.focus_only=True
        self.run.prepare_front=Mock(return_value=409)
        self.run.selection_trials=Mock()
        self.run.drag=Mock(side_effect=AssertionError("group placement in focus-only"))
        self.run.trials("reader")
        self.assertEqual(self.run.selection_trials.call_args.args[-1],409)
        self.run.drag.assert_not_called()
        self.assertEqual(self.run.out["selection"]["status"],"PASS")
        self.assertEqual([r["status"] for r in self.run.out["drags"].values()],["NOT_RUN"]*3)

    def test_full_order_self_right_left_and_no_extra_selection(self):
        order=[]
        self.run.prepare_front=Mock(return_value=409)
        self.run.selection_trials=Mock(side_effect=lambda *a:order.append("selection"))
        self.run.read_until=Mock(return_value={"focused":317})
        self.run.geometry=Mock(return_value=self.root)
        self.run.profile_policy=Mock(return_value={"edge":"right","explicit":None})
        def checked(kind,hashes,anchor,expected,before):
            order.append(kind)
            if kind=="self":self.assertEqual(expected,self.root["cg"])
            if kind=="right":self.assertGreater(expected[0][0],expected[1][0])
            if kind=="left":self.assertEqual(expected[0],before[1])
            self.run.out["drags"][kind]["status"]="PASS"
        self.run.drag=Mock(side_effect=checked)
        self.run.capture_pair=Mock()
        self.run.trials("reader")
        self.run.capture_pair.assert_called_once()
        self.assertEqual(order,["selection","self","right","left"])
        self.assertEqual(self.run.out["status"],"PASS")

    def test_supersession_and_failed_release_do_not_allow_next_gesture(self):
        for error in (p.Superseded(),p.TrialStop("mouseUpTargetOrScopeChanged","UNKNOWN")):
            self.run.prepare_front=Mock(return_value=409)
            self.run.selection_trials=Mock(side_effect=error)
            self.run.geometry=Mock()
            self.run.drag=Mock()
            with self.assertRaises(p.TrialStop):self.run.trials("reader")
            self.run.geometry.assert_not_called()
            self.run.drag.assert_not_called()

    def test_self_drag_requires_real_motion_with_unchanged_enrolled_frames(self):
        events=[{"type":1,"point":[0,0]}]+[{"type":6,"point":[t,0]} for t in (4,9,14,7,0)]+[{"type":2,"point":[0,0]}]
        bad=[[92,60,340,260],self.root["cg"][1]]
        for during,reason in (([{"cg":self.root["cg"]}]*4,"ReadIncomplete"),
                               ([{"cg":self.root["cg"]}]*4+[{"cg":bad}],"windowMoved")):
            self.run.geometry=Mock(return_value=self.root)
            self.run.packet=Mock(return_value=dict(status="DISPATCHED",issued=True,geometry=self.root,events=events,duringSelfDrag=during))
            with self.assertRaisesRegex(p.TrialStop,reason):
                self.run.drag("self",["a","b"],self.root,self.root["cg"],self.root["cg"])
            self.assertEqual(self.run.packet.call_count,1)

    def test_process_scoped_receipt_distinguishes_post_only_panel_and_other_window(self):
        old = click_receipt()
        self.assertEqual(p.host_route(old)["receiver"],"NOT_IN_THIS_TOOL")
        old["events"][0].update(point=[7,8],eventTimestampNS=600)
        old["events"][1].update(point=[7,8],eventTimestampNS=1900)
        seen = [dict(type=r["type"], timestampNS=r["eventTimestampNS"], point=[7,8], destination="bound", source="bound",
                     acceptingPointer="boundPanel", underPointer="boundPanel") for r in old["events"]]
        old["hostRouting"] = dict(status="OBSERVED",events=seen)
        self.assertEqual(p.host_route(old)["status"],"HOST_PANEL")
        seen[0]["acceptingPointer"]="different"
        self.assertEqual(p.host_route(old)["status"],"HOST_OTHER_WINDOW")
        seen[0]["source"]="different"
        self.assertEqual(p.host_route(old)["status"],"UNCONFIRMED")

    def test_unreceived_click_timeout_is_unknown_and_does_not_repeat(self):
        reply = dict(status="BLOCKED",issued=True,reason="systemFocusReadbackTimedOut",events=[])
        self.run.packet=Mock(return_value=reply)
        self.run.terminal_focus_reads=Mock(return_value=[dict(status="READ")]*2)
        attempt={}
        with self.assertRaises(p.TrialStop) as denied:
            self.run.select_document({"target":409,"digests":["a","b"]},"intent",attempt)
        self.assertEqual(denied.exception.status,"UNKNOWN")
        self.assertEqual(self.run.packet.call_count,1)
        self.assertEqual(len(attempt["terminalFocusReads"]),2)

    def test_drag_only_prepares_a_fresh_bound_pair_and_sends_no_click_or_marker(self):
        self.run.drag_only=True
        self.run.prepare_front=Mock(return_value=409)
        self.run.selection_trials=Mock(side_effect=AssertionError("input in drag-only"))
        self.run.read_until=Mock(return_value={"focused":409})
        self.run.geometry=Mock(return_value=self.root)
        self.run.profile_policy=Mock(return_value={"edge":"right","explicit":None})
        def checked(kind,*_):
            self.run.out["drags"][kind].update(status="PASS",issued=True)
        self.run.drag=Mock(side_effect=checked)
        self.run.capture_pair=Mock()
        self.run.trials("reader")
        self.run.selection_trials.assert_not_called()
        self.assertEqual([c.args[0] for c in self.run.drag.call_args_list],["self","right","left"])
        self.assertEqual(self.run.out["selection"]["status"],"NOT_RUN")

    def test_direct_display_samples_stay_independent_of_ax_and_save_the_complete_sidecar(self):
        visual=dict(status="OBSERVED", frames=[{"ticks":132}], downToVisibleMS={"lower":9,"upper":27},
                    upToVisibleMS={"lower":-1,"upper":19},targetFrameObserved=True,retainedPixelBytes=0)
        self.run.attempt={}
        self.run.trial=1
        self.run.call=Mock(return_value={"presentation":visual,"issued":True})
        self.run.packet("click",409,["a","b"])
        self.rec.write.assert_called_once_with("window-presentation-01.json",visual)
        item=self.run.attempt["presentation"]
        self.assertNotIn("frames",item)
        self.assertEqual(item["file"],"window-presentation-01.json")
        self.run.out["operationStatus"]="UNKNOWN"
        self.run.out["attempts"]=[self.run.attempt,{"presentation":{"status":"UNKNOWN","reason":"obscuredOrUncertainCrop"}}]
        self.run.publish()
        result=self.run.out["measurement"]
        self.assertEqual(result["displayPresentation"],"PARTIAL")
        self.assertEqual(result["presentationCounts"],{"attempts":2,"sampled":2,"observed":1})
        self.assertEqual(result["statistics"]["downToVisibleMSUpper"]["p50"],27)
        self.assertEqual(result["statistics"]["upToVisibleMSLower"]["p50"],-1)

    def test_protected_transaction_optional_scenario_leaves_enrolled_lease_intact(self):
        lease=dict(documentKit="/private/old",workspace="w",expectedSpace=99,originalCheckout="c",originArchive="a")
        record=dict(focusLease=lease,kit="/kit",focusScenario="pair-focus",pairKit="/private/pointer")
        env={}
        args=private_spaces_trials.focus_command(Path("/scripts"),record,Path("/out"),Path("/chain"),env)
        self.assertEqual(args[-2:],["--scenario","pair-focus"])
        self.assertEqual(env["NP_P2_DOCUMENT_KIT"],"/private/pointer")
        self.assertEqual(lease["documentKit"],"/private/old")
        record.pop("focusScenario");record.pop("pairKit")
        self.assertEqual(private_spaces_trials.focus_command(Path("/s"),record,Path("/o"),Path("/c"),env)[-1],"controlled-window")


if __name__ == "__main__":
    unittest.main()
