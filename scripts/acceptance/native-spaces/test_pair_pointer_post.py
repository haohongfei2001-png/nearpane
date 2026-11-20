"""Read-only post-drop polling, including a temporarily absent sidebar and late helper."""
import copy
import unittest
from unittest.mock import Mock, patch
import pair_pointer as p
from test_pair_pointer import geometry


class Time:
    def __init__(self): self.now=100.
    def read(self): return self.now
    def sleep(self,seconds): self.now+=seconds


class PostDropTests(unittest.TestCase):
    def setUp(self):
        self.run=p.PairPointerRun.__new__(p.PairPointerRun)
        self.run.binding={"numbers":[317,409]}
        self.run.phase_monitor=None
        self.rec={"phaseStart":99.9,"events":[{"afterPost":100.0}],"hostRouting":{"status":"HOST_PANEL"}}
        self.anchor=geometry()
        self.expected=[[600,24,610,850],[0,24,600,850]]
        self.time=Time()
        self.seen=[]
        self.run.packet=Mock(side_effect=AssertionError("no input during post-read"))
        self.run.geometry=Mock(side_effect=AssertionError("full card admission is not a system read"))

    def sample(self, exact, cards=(1,1)):
        pair=self.expected if exact else self.anchor["cg"]
        g=dict(clock=self.time.now,members=[317,409],cg=pair,ax=pair,displayUUID="D",visible=self.anchor["visible"],
               verifiedOriginalPanelID=51,leaseState="BOUND")
        return {"status":"READ","geometry":g,"leaseState":"BOUND","frontKind":"other",
                "sidebar":{"panelVisible":False,"cards":[{"count":c} for c in cards],"publishedManagementReasons":[]}}

    def exercise(self, fn):
        def read(*args):
            self.seen.append(self.time.now)
            self.time.sleep(.12)
            return fn(len(self.seen))
        self.run.post_sample=Mock(side_effect=read)
        with patch.object(p.time,"monotonic",self.time.read),patch.object(p.time,"sleep",self.time.sleep):
            self.run.wait_for_drop("right",self.rec,["a","b"],self.anchor,self.expected,self.anchor)

    def test_missing_cards_and_read_error_do_not_end_an_accepted_gesture(self):
        def observations(n):
            if n==1: return self.sample(False)
            if n==3:return {"status":"BLOCKED","reason":"postReadWindowCoordinatesUnconfirmed"}
            return self.sample(True,(0,0))
        self.exercise(observations)
        self.assertEqual(self.rec["status"],"PASS")
        self.assertEqual(len(self.seen),5)
        self.assertEqual(self.rec["postReads"][1]["sidebar"]["cards"],[{"count":0}]*2)
        self.assertLess(self.time.now,103.5)
        self.run.packet.assert_not_called()

    def test_actual_late_bounds_use_read_only_worker_tail_and_mark_original_deadline(self):
        self.exercise(lambda _:self.sample(self.time.now>104.2,(0,1)))
        self.assertEqual(self.rec["status"],"PASS")
        self.assertFalse(self.rec["withinPrimary"])
        self.assertEqual(self.rec["readOnlyTail"]["inputActions"],0)
        self.assertLess(self.time.now,108)

    def test_stopped_accepted_worker_is_unknown_and_all_missing_samples_stay_unknown(self):
        self.run.phase_monitor=Mock(phases=[{"phase":"pairResolving","readAt":100.2}])
        with self.assertRaises(p.TrialStop) as x:
            self.exercise(lambda _:{"status":"BLOCKED","reason":"noRead"})
        self.assertEqual(x.exception.status,"UNKNOWN")
        self.assertGreaterEqual(self.time.now,108)
        self.assertLess(self.time.now,108.2)

    def test_genuine_input_stops_readback_immediately(self):
        def stop(_): raise p.Superseded()
        with self.assertRaises(p.Superseded):self.exercise(stop)
        self.assertEqual(len(self.seen),1)
        self.run.packet.assert_not_called()

    def test_other_display_and_mismatching_observer_data_never_confirm_a_layout(self):
        self.assertFalse(p.post_bound({**self.sample(True)["geometry"],"displayUUID":"other"},self.anchor,[317,409]))
        g=copy.deepcopy(self.sample(True)["geometry"])
        g["ax"][0]=[555,392,320,193]
        self.assertFalse(p.post_frames(g,self.expected))


if __name__=="__main__": unittest.main()
