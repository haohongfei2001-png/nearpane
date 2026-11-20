import importlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock,patch

from paired_preview_audit import PairedWindowAudit

paired=importlib.import_module("paired-preview")


class PairedScope(unittest.TestCase):
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
