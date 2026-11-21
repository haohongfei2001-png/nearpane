import importlib
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import shutil
import unittest
from unittest.mock import Mock,patch

from paired_preview_audit import PairedWindowAudit

paired=importlib.import_module("paired-preview")


class PairedScope(unittest.TestCase):
    @unittest.skipUnless(sys.platform=="darwin" and shutil.which("swift"),"requires macOS Foundation")
    def test_native_numeric_crop_crosses_swift_any_without_an_unrelated_cast(self):
        source=Path(__file__).with_name("observe.swift").read_text()
        declaration=next(line for line in source.splitlines() if line.startswith("func windowReceiptRect("))
        self.assertIn("let coordinates = windowReceiptRect(crop)",source)
        swift="import AppKit\n"+declaration+"""
let r=CGRect(x:12.5,y:13,width:4,height:4)
let old:[String:Any]=["crop":[r.minX,r.minY,r.width,r.height]]
let corrected:[String:Any]=["crop":windowReceiptRect(r)]
precondition(old["crop"] is [CGFloat] && !(old["crop"] is [Double]))
precondition(corrected["crop"] as? [Double]==[12.5,13,4,4])
"""
        subprocess.run(["swift","-e",swift],check=True,timeout=15)

    def test_exact_card_identity_is_independent_of_source_picture_geometry(self):
        ws=importlib.import_module("preview-workspace")
        fixture=dict(numbers=[52350,52351],fixtureBirth=101,hostBirth=90)
        row=dict(fixture,space=5092,panel=52326,hostCardCount=2,sourceProven=True,cardIdentityProven=True,
                 present=[True,True],ready=False,reason="boundPictureGeometryUnavailable")
        self.assertTrue(ws.exact_source_cards([row,row],5092,fixture))
        for update in (dict(numbers=[52351,52350]),dict(hostBirth=91),dict(panel=7),dict(cardIdentityProven=False)):
            self.assertFalse(ws.exact_source_cards([row,dict(row,**update)],5092,fixture))

    def test_missing_visual_keeps_separate_catalog_surface_and_system_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);before=dict(hostPID=7,hostBirth=8,hostHash="hash",display="d",space=5,panel=1)
            binding=dict(before,ready=False,reason="missingFixturePictures",sourceProven=True,windowCensus={"admitted":True})
            result={};cross=Mock(return_value={"status":"FAIL","returnedA":True,"oldCardObservationsOnVerifiedEmptyB":2})
            with patch.object(paired,"read",return_value=binding),patch.object(paired,"owns_profile",return_value=True), \
                    patch.object(paired,"surface_checkpoint",return_value={"status":"PASS"}) as surface,patch.object(paired,"collect") as capture:
                paired.casework(d,d,d,[],7,"hash",d,before,True,True,cross,result,lambda:None,None)
            capture.assert_not_called();surface.assert_called_once();cross.assert_called_once_with(binding)
            self.assertEqual([result[k]["status"] for k in ("sampler","overview","hiddenBudget","twoCardSurface","systemDesktopSwitch")],
                             ["BLOCKED","BLOCKED","BLOCKED","PASS","FAIL"])

    def test_unknown_foreign_owner_refuses_system_mutations(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);before=dict(hostPID=7,hostBirth=8,hostHash="hash",display="d",space=5,panel=1)
            binding=dict(before,ready=False,reason="missingFixturePictures",sourceProven=True,windowCensus={"admitted":False})
            result={};cross=Mock()
            with patch.object(paired,"read",return_value=binding),patch.object(paired,"owns_profile",return_value=True):
                paired.casework(d,d,d,[],7,"hash",d,before,False,False,cross,result,lambda:None,None)
            cross.assert_not_called();self.assertEqual(result["systemDesktopSwitch"]["status"],"BLOCKED")
            self.assertIn("UnverifiedOwners", result["systemDesktopSwitch"]["reason"])

    def test_hidden_only_verdict_comes_from_restored_streams(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);before=dict(hostPID=7,hostBirth=8,hostHash="hash",display="d",space=5,panel=1)
            binding=dict(before,ready=True,sourceProven=True,cardIdentityProven=True,windowCensus={"admitted":True})
            for verdict in ("PASS","FAIL","BLOCKED"):
                result={}
                with patch.object(paired,"read",return_value=binding),patch.object(paired,"owns_profile",return_value=True), \
                        patch.object(paired,"with_current_streams",return_value={"status":verdict}) as hidden, \
                        patch.object(paired,"collect") as capture:
                    paired.casework(d,d,d,[],7,"hash",d,before,False,False,None,result,lambda:None,None,budget_only=True)
                hidden.assert_called_once()
                capture.assert_not_called()
                self.assertEqual(result["status"],verdict)

    def test_host_audit_accepts_only_two_distinct_enrolled_windows_of_one_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp).resolve();audit=PairedWindowAudit.__new__(PairedWindowAudit)
            audit.home=d;audit.output=d;audit.request=d/"manifest.json"
            identity=dict(pid=11,birth=123,hash="fixture",identifier="net.example.spaces-document",executable="/kit/FieldNotes")
            for observed,ids in [(dict(identity,birth=124),[1,2]),(identity,[1,1]),(identity,[1,2,3])]:
                with self.assertRaises(ValueError):audit.bind(observed,identity,ids)
            audit.bind(identity,identity,[1,2])
            manifest=json.loads(audit.request.read_bytes());self.assertEqual(manifest["targets"],[dict(number=n,pid=11,birth=123) for n in [1,2]])
            self.assertEqual(audit.request.stat().st_mode & 0o777,0o600)
            with self.assertRaises(FileExistsError):audit.bind(identity,identity,[1,2])

if __name__=="__main__":unittest.main()
