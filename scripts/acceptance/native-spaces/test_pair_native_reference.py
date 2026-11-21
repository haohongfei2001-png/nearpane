"""Exercise the registered runner's normal entry point with file receipts and no GUI."""
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch
import uuid

from acceptance import Receipt
from p2_documents import Superseded, TrialStop
from pair_pointer import PairPointerRun


class PassiveCheckpointTests(unittest.TestCase):
    def setUp(self):
        tmp=TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.rec=Receipt(Path(tmp.name)/"receipts")
        self.addCleanup(self.rec.stream.close)
        initial={"scopes":[{"scope":str(uuid.uuid4()),"current":27,"records":[]}],"host":{"pid":11,"codeHash":"f"*40},
                 "frontmostPID":21}
        with patch.dict(os.environ,NP_NATIVE_REFERENCE_PROBE="1"):
            self.run=PairPointerRun(Path(tmp.name)/"observe",initial,self.rec,None)
        self.run.focus_only=True
        self.run.binding.update(hostBirth=111,pid=21,birth=222,numbers=[71,72],hash="a"*40,
                                session=self.run.folder.name,spaceUUID=str(uuid.uuid4()))
        self.run.baseline=[7,9]
        self.order=[]
        self.run.prepare_front=Mock(side_effect=lambda hashes:self.order.append("prepare") or 71)
        self.run.selection_trials=Mock(side_effect=lambda *args:self.order.append("selection"))
        b=self.run.binding
        self.scene={k:b[k] for k in ("hostPID","hostBirth","hostHash","display","space","spaceUUID","session","numbers")}
        self.scene.update(fixturePID=21,fixtureBirth=222,fixtureHash="a"*40,bounds=[0,0,800,600],modePixels=[1600,1200],
                          frames=[[10,10,300,300],[20,30,300,300]],reduceMotion=False,stageManager=False,
                          otherOrdinaryAppWindows=0,boot=str(uuid.uuid4()),osBuild="26A428",refreshHz=60)
        self.base={"issued":False,"retainedPixelBytes":0,"presentationSamples":0,"interval":[10,10.1]}
        self.env={**self.base,"status":"ENVIRONMENT_OBSERVED","environment":self.scene,"privateTitle":"neverStored"}
        self.absent={**self.base,"status":"BLOCKED","reason":"twoStableSystemLinksAndHitTestsUnavailable","observations":[
            {"displayContainers":0,"buttons":0,"firstLinks":0,"secondLinks":0,"privateTitle":"neverStored"}]*2}

    def replies(self,*values):
        pending=iter(values)
        def answer(mode,extra):
            self.order.append(mode)
            self.assertEqual(set(extra),{"digests"})
            self.assertEqual(len(extra["digests"]),2)
            for s in extra["digests"]: self.assertRegex(s,r"^[0-9a-f]{64}$")
            return next(pending)
        self.run.call=Mock(side_effect=answer)

    def test_ordinary_desktop_saves_environment_and_absence_before_normal_selection(self):
        self.replies(self.env,self.absent)
        self.run.pointer_trials("reader")
        self.assertEqual(self.order,["prepare","focus-reference-environment","apple-focus-reference","selection"])
        summary=self.run.out["nativeReferenceProbe"]
        self.assertEqual(summary["environment"]["status"],"ENVIRONMENT_OBSERVED")
        self.assertEqual(summary["applePicker"]["systemView"],"noMatchingSystemDisplayContainerObserved")
        for part in summary.values():
            text=(self.rec.output/part["file"]).read_text()
            self.assertNotIn("neverStored",text)
            d=json.loads(text)
            self.assertFalse(d["issued"])
            self.assertEqual(d["physicalLatencySamples"],0)
            self.assertRegex(part["sha256"],r"^[a-f0-9]{64}$")

    def test_off_skips_both_probes(self):
        self.run.native_reference_probe=False
        self.replies()
        self.run.pointer_trials("reader")
        self.assertEqual(self.order,["prepare","selection"])
        self.assertFalse((self.rec.output/"apple-focus-reference.json").exists())

    def test_bound_visible_system_targets_stop_product_input_and_save_each_read(self):
        signed={"pid":10,"birth":12,"bundle":"com.apple.dock","cdHash":"b"*40}
        visible={**self.env,**self.scene,"status":"LINKS_OBSERVED","owner":signed,
                 "targets":[{"number":n,"rect":[i*120,5,100,100]} for i,n in enumerate(self.scene["numbers"])],
                 "observations":[{"displayContainers":1,"buttons":2,"firstLinks":1,"secondLinks":1}]*2}
        self.replies(self.env,visible)
        with self.assertRaisesRegex(TrialStop,"nativePickerCurrentlyOwnsBothFixtureTargets"):
            self.run.pointer_trials("reader")
        self.run.selection_trials.assert_not_called()
        self.assertEqual(json.loads((self.rec.output/"apple-focus-reference.json").read_text())["status"],"LINKS_OBSERVED")

    def test_superseded_user_input_saves_first_refusal_and_never_runs_second_read(self):
        self.replies({"status":"BLOCKED","reason":"userSuperseded"})
        with self.assertRaises(Superseded): self.run.pointer_trials("reader")
        self.assertEqual(self.order,["prepare","focus-reference-environment"])
        self.assertEqual(self.run.out["nativeReferenceProbe"]["applePicker"]["status"],"NOT_RUN")
        self.assertTrue((self.rec.output/"apple-focus-reference.json").is_file())

    def test_foreign_generation_and_unrecognized_diagnostics_cannot_enter_receipt(self):
        self.replies({**self.env,"environment":{**self.scene,"fixtureBirth":1}},{"status":"BLOCKED","reason":"privateString"})
        with self.assertRaisesRegex(TrialStop,"enrolledScopeChangedDuringPassiveReference"):
            self.run.pointer_trials("reader")
        self.run.selection_trials.assert_not_called()
        summary=self.run.out["nativeReferenceProbe"]
        self.assertEqual(summary["environment"]["reason"],"observedFixtureOrLeaseMismatch")
        self.assertEqual(summary["applePicker"]["reason"],"observerRefused")


if __name__ == "__main__":
    unittest.main()
