import hashlib
import importlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from preview_support import copy_checked, surface_checkpoint

w=importlib.import_module("preview-workspace")


class PreviewWorkspaceTests(unittest.TestCase):
    def test_preference_setup_is_one_existing_known_boolean_and_runtime_is_independent(self):
        with tempfile.TemporaryDirectory() as d:
            ws=Mock();ws.display="D";ws.host={"pid":7,"codeHash":"signed"}
            stage=w.PreferenceStage(Path("/kit"),Path(d),ws,3)
            with patch.object(w,"states",return_value=[{"state":True}]*2),patch.object(w.subprocess,"check_output",return_value="Type is boolean"),patch.object(w.subprocess,"run",return_value=Mock(returncode=0)) as write,patch.object(stage,"runtime",return_value={"status":"BLOCKED","reason":"notReflectedByHost"}):
                with self.assertRaisesRegex(ValueError,"notReflectedByHost"):stage.toggle("stage-off",True,False)
                self.assertEqual(write.call_args.args[0],["/usr/bin/defaults","write","com.apple.WindowManager","GloballyEnabled","-bool","false"])
                self.assertFalse(json.loads((Path(d)/"stage-off-preference-intent.json").read_bytes())["countsAsAppleUIAcceptance"])

    def test_preference_comparison_and_prior_authorized_loan_are_required(self):
        with tempfile.TemporaryDirectory() as d:
            ws=Mock();ws.host={"pid":8,"codeHash":"signed"}
            stage=w.PreferenceStage(Path("/kit"),Path(d).resolve(),ws,3)
            with patch.object(w,"states",return_value=[{"state":False}]*2),patch.object(w.subprocess,"run") as write:
                with self.assertRaisesRegex(ValueError,"CompareBeforeWrite"):stage.toggle("stage-off",True,False)
                with self.assertRaises(ValueError):stage.restore(True)
                write.assert_not_called()
            self.assertEqual(w.stage_media(None,None,None,None,None)["status"],"NOT_RUN")

    def test_restore_requires_this_runs_exact_press_intent(self):
        transaction=w.StageTransaction(Path("/x"),Path("/x"),None,12)
        with patch.object(transaction,"events",return_value=[]),patch.object(w,"states",return_value=[{"state":False}]*2),patch.object(transaction,"switch") as press:
            with self.assertRaisesRegex(ValueError,"WithoutThisRuns"):transaction.restore(True)
            press.assert_not_called()
        with patch.object(transaction,"events",return_value=[{"event":"press-intent"}]),patch.object(w,"states",return_value=[{"state":False}]*2),patch.object(transaction,"switch",return_value={"status":"PASS"}) as press:
            self.assertTrue(transaction.restore(True)["restorationPress"])
            press.assert_called_once_with("stage-restore",False,True)

    def test_restored_or_initially_off_state_does_not_toggle(self):
        t=w.StageTransaction(Path("/no"),Path("/no"),None,99)
        for state in (True,False):
            with patch.object(t,"events",return_value=[]),patch.object(w,"states",return_value=[{"state":state}]*2),patch.object(t,"switch") as press:
                self.assertFalse(t.restore(state)["restorationPress"]);press.assert_not_called()

    def test_empty_requires_consecutive_complete_membership(self):
        ws=Mock();ws.check.side_effect=lambda o:o["s"]
        def reading(t,ordinary):
            return dict(uptime=t,s=dict(current=7,records=[dict(id=7,uuid="A",type=0)]),
                        scopedMembers={"7":{"ordinary":ordinary,"otherMembers":0,"unresolved":0}})
        ws.read.side_effect=[reading(1,[]),reading(2,None),reading(3,[]),reading(4,[])]
        with patch.object(w,"lease_for",return_value=(Path("/fixture"),"A")),patch.object(w.time,"sleep"):
            self.assertEqual(w.empty(ws,7)["uptimes"],[3,4])

    def test_raw_witness_forbids_even_one_private_pixel_and_preserves_exact_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            d=Path(temp).resolve();dest=d/"output";file=d/"preview-00001.rgba"
            raw=bytearray(bytes.fromhex("2222aaff")*256)
            for modified in (True,False):
                raw[5]=48 if modified else 34;file.write_bytes(raw);file.chmod(0o600)
                if modified:
                    with self.assertRaisesRegex(ValueError,"uniform opaque"):copy_checked(d,dest,file.name,hashlib.sha256(raw).hexdigest(),1024)
                    self.assertFalse(dest.exists())
                else:
                    copy_checked(d,dest,file.name,hashlib.sha256(raw).hexdigest(),1024)
                    self.assertEqual((dest/file.name).read_bytes(),bytes(raw))

    def test_zero_tools_guard_retains_transient_old_cards(self):
        def surface(cards):
            return dict(available=True,hostPID=4,hostHash="x",hostBirth=11,space=8,stageManager=False,windowCards=cards,
                        duplicatedCards=0,bareSpaceRows=0,legacyCards=0,placeholderLabels=[],panels=[5],
                        controls={"tray-content":1,"voice-capture-toggle":1,"desktop-reserved-region":1})
        rows=[json.dumps(r) for cards in [2,0,0] for r in [surface(cards),{"stageManagerOwnsDispatch":0}]]
        with patch("preview_support.subprocess.check_output",side_effect=rows),patch("preview_support.time.sleep"):
            result=surface_checkpoint(Path("/x"),{"pid":4,"codeHash":"x"},8,False,0)
        self.assertEqual(result["status"],"PASS")
        self.assertEqual([r["surface"]["windowCards"] for r in result["observations"]],[2,0,0])

    def test_system_ax_action_needs_independent_arrival_and_overview_dismissal(self):
        ws=w.PreviewWorkspace.__new__(w.PreviewWorkspace)
        ws.kit=Path("/x");ws.display="D";ws.host={"pid":4,"codeHash":"x"};ws.host_birth=8;ws.cleanup_current=1
        top={"current":1,"records":[{"id":1,"type":0},{"id":2,"type":0}]}
        ws.read=Mock(return_value={"frontmostPID":3,"focusedNumber":4});ws.check=Mock(return_value=top)
        ws.ids=Mock(return_value=[2]);ws.hardware=Mock(return_value=[0]*5);ws.record=Mock();ws.settled=Mock(return_value="arrived")
        for reached in (False,True):
            reply=dict(issued=True,acknowledged=True,action="AXPress",targetConfirmedBeforeOwnedOverviewClosed=reached,overviewDismissed=True)
            with patch.object(w.subprocess,"run",return_value=Mock(returncode=0,stdout=json.dumps(reply))) as issued:
                if reached:self.assertEqual(ws.select(2),"arrived")
                else:
                    with self.assertRaisesRegex(ValueError,"IndependentlyConfirmed"):ws.select(2)
                issued.assert_called_once()

if __name__=="__main__":unittest.main()
