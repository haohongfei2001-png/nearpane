import hashlib
import importlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock
from uuid import uuid4

from p0_diagnostic_pair import BookedPair, endpoints
from space_scope import ScopeError

cards=importlib.import_module("p0-cards")


class BorrowedPairTests(unittest.TestCase):
    def test_existing_pair_requires_original_uuid_adjacency_and_an_owned_current(self):
        rows=[dict(id=n,uuid=str(uuid4()),type=0) for n in (1,2,3)]
        top=dict(records=rows,current=3)
        registered={r["id"]:r["uuid"] for r in rows[1:]}
        self.assertEqual(endpoints(top,[2,3],registered),(3,2))
        for invalid in (dict(top,current=1),dict(top,records=[rows[1],rows[0],rows[2]]),
                        dict(top,records=[*rows[:2],dict(rows[2],type=4)]),
                        dict(top,records=[*rows[:2],dict(rows[2],uuid=str(uuid4()))])):
            with self.assertRaises(ScopeError):
                endpoints(invalid,[2,3],registered)

    def test_unknown_setup_delivery_cannot_be_retried(self):
        r=BookedPair.__new__(BookedPair)
        r.source,r.target,r.documents,r.setup_attempted=17,18,{17:{}},False
        r.confirm=Mock();r.read=Mock(side_effect=ValueError("unknown delivery"))
        with self.assertRaisesRegex(ValueError,"unknown delivery"):r.setup(Mock())
        self.assertTrue(r.setup_attempted)
        with self.assertRaises(ScopeError):r.setup(Mock())
        r.read.assert_called_once_with(17,"system-shortcut","leased-setup-arrow")

    def test_mismatched_census_and_new_external_focus_stop_setup(self):
        r=BookedPair.__new__(BookedPair)
        r.read=Mock(side_effect=[dict(uptime=1,counts={"2":0}),dict(uptime=2,counts={"2":1})])
        with self.assertRaisesRegex(ValueError,"stable endpoint"):r.confirm(2,"setup")
        r.binding=dict(hostPID=42);r.documents={2:dict(pid=12,number=40)}
        initial=dict(frontPID=99,focusedNumber=None)
        process=Mock(side_effect=AssertionError)
        self.assertFalse(r.recoverable_front(dict(frontPID=12,focusedNumber=41),initial,process))
        self.assertFalse(r.recoverable_front(dict(frontPID=47,focusedNumber=2),initial,process))
        self.assertTrue(r.recoverable_front(dict(frontPID=12,focusedNumber=40),initial,process))

    def test_unmeasured_visual_is_separate_from_one_diagnostic_and_never_passes_a_product_gate(self):
        trial=dict(status="PASS",navigationStatus="PASS",axIssued=False,hostIssued=True,hostProof={"confirmed":True},scope="DIAGNOSTIC_ONLY",
                   officialGateEligible=False,measurement="continuous-windowserver-drift",pixels=0,visualStatus="NOT_MEASURED",
                   retainedTargetFocus={"status":"PASS"},continuousClassification="settled",blankScreen="UNKNOWN")
        for gate,expected in (("diagnostic","PASS"),("roundTrip","BLOCKED"),("ten","BLOCKED"),("fifty","BLOCKED")):
            stage=dict(samples=[trial])
            cards.evaluate_gate(stage,gate,1)
            self.assertEqual((stage["status"],stage["blankScreen"]),(expected,"UNKNOWN"))
        for change in ({"hostProof":{"confirmed":False}},{"hostIssued":False},{"scope":"ordinary"}):
            stage=dict(samples=[dict(trial,**change)])
            cards.evaluate_gate(stage,"diagnostic",1)
            self.assertEqual(stage["status"],"BLOCKED")
        stage=dict(samples=[dict(trial,continuousClassification="unknown")])
        cards.evaluate_gate(stage,"diagnostic",1)
        self.assertEqual(stage["status"],"UNKNOWN")

    @unittest.skipUnless(os.getenv("NP_P0_BOOKED_TOOL"),"set NP_P0_BOOKED_TOOL to the compiled private reader")
    def test_native_receipts_and_positive_system_owners_without_a_windowserver_query(self):
        exe=os.environ["NP_P0_BOOKED_TOOL"]
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temp:
            display,boot=str(uuid4()).upper(),str(uuid4()).upper()
            records=[dict(id=n,uuid=str(uuid4()).upper(),type=0) for n in (20,21)]
            leases=[]
            for row in records:
                target=str(row["id"])
                path=Path(temp)/"secondary-route-followup"/str(uuid4())/"provision"/"created.json"
                path.parent.mkdir(parents=True,mode=0o700)
                data=json.dumps(dict(target=target,intent=dict(boot=boot,display=display),after=dict(spaceUUIDs={target:row["uuid"]}))).encode()
                path.write_bytes(data);path.chmod(0o600)
                leases.append(dict(space=row["id"],uuid=row["uuid"],receipt=str(path),digest=hashlib.sha256(data).hexdigest()))
            ws=dict(pid=189,layer=24,forward=[21],reverse=[21],code=dict(apple=True,identifier="com.apple.WindowServer"),
                    onscreen=False,visibleQuery=False,installedHost=False)
            dock=dict(ws,layer=-1,code=dict(apple=True,identifier="com.apple.dock"))
            host=dict(ws,pid=101,layer=0,installedHost=True,code=dict(apple=False,identifier="com.holdsnow.nearpane.alpha"))
            rows=[ws,dock,host,dict(ws,onscreen=True),dict(ws,visibleQuery=True),dict(ws,layer=0),dict(ws,reverse=[20,21]),
                  dict(dock,code=dict(apple=False,identifier="com.apple.dock")),dict(host,pid=717)]
            data=dict(topology=dict(current=20,display=display,records=records),target=21,hid=[0]*8,hostPID=101,hostBirth=54,hostHash="abc",
                      boot=boot,leases=leases,documents=[],stageSurfaces=[],otherDetails=rows)
            def run():
                reply=subprocess.run([exe,"leased-artifact-check"],input=json.dumps(data),capture_output=True,text=True,timeout=3)
                return json.loads(reply.stdout)
            self.assertEqual(run(),dict(classifiedOther=[True,True,True,False,False,False,False,False,False],receiptCount=2,pixels=0,issued=False))
            original=leases[0]["digest"];leases[0]["digest"]="00"*32
            self.assertIn("digest",run()["error"])
            leases[0]["digest"]=original;Path(leases[0]["receipt"]).with_name("removed.json").touch()
            self.assertIn("removed",run()["error"])
