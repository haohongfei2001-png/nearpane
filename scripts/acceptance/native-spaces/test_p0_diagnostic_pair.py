from contextlib import ExitStack
import hashlib
import importlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
from uuid import uuid4

from p0_diagnostic_pair import BookedPair, confirmed_members, endpoints
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
        r.confirm=Mock(return_value={"17":[],"18":[]});r.read=Mock(side_effect=ValueError("unknown delivery"))
        with self.assertRaisesRegex(ValueError,"unknown delivery"):r.setup(Mock())
        self.assertTrue(r.setup_attempted)
        with self.assertRaises(ScopeError):r.setup(Mock())
        r.read.assert_called_once_with(17,"system-shortcut","leased-setup-arrow",expected_members={"17":[],"18":[]})

    def test_equal_counts_cannot_hide_changed_or_recycled_windows(self):
        fixture=dict(number=41,pid=10,birth=123,layer=0,kind="fixture",windowGeneration=str(uuid4()).upper())
        dock=dict(number=117,pid=14,birth=90,layer=-1,kind="appleDock")
        counts={"2":dict(fixture=1,inactiveStage=[],systemOrHost=1,unresolved=0),
                "3":dict(fixture=0,inactiveStage=[],systemOrHost=0,unresolved=0)}
        proof=dict(counts=counts,members={"2":[fixture,dock],"3":[]},uptime=1)
        pair=BookedPair.__new__(BookedPair)
        pair.source,pair.target,pair.documents,pair.setup_attempted=2,3,{2:fixture},False
        with patch("p0_diagnostic_pair.time.sleep"):
            for rows in ([fixture,dict(dock,number=118)],[fixture,dict(dock,birth=91)],
                         [dict(fixture,windowGeneration=str(uuid4()).upper()),dock]):
                pair.read=Mock(side_effect=[proof,dict(proof,uptime=2,members={"2":rows,"3":[]})])
                with self.assertRaisesRegex(ScopeError,"identities changed"):pair.setup(Mock(side_effect=AssertionError))
                self.assertEqual(pair.read.call_count,2)
                self.assertFalse(pair.setup_attempted)
            pair.read=Mock(side_effect=[proof,dict(proof,uptime=2)])
            self.assertEqual(pair.confirm(2,"read-only"),proof["members"])
        for invalid in (dict(proof,members={"2":[fixture],"3":[]}),dict(proof,members={"2":[fixture,dock],"3":[dock]}),
                        dict(proof,members={"2":[dict(fixture,windowGeneration=None),dock],"3":[]}),
                        dict(proof,members={"2":[fixture,dict(dock,kind="unknown")],"3":[]}),
                        dict(proof,members={"2":[fixture,dict(dock,layer=0)],"3":[]})):
            with self.assertRaises(ValueError):confirmed_members(invalid)

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

    def test_census_only_uses_first_document_and_cleans_up_without_any_navigation(self):
        # Exercise the real run/exception/finally route; all operating-system entry points are replaced.
        window=dict(number=41,pid=13,birth=45)
        space=17
        top=dict(current=space,display=str(uuid4()).upper(),records=[dict(id=n,uuid=str(uuid4()).upper(),type=0) for n in (17,18)])
        state=dict(hid=[0]*8,topology=top,observerAX=True,frontPID=13,focusedNumber=41,systemFocus={"pid":13})
        for rejected,new_selection in ((False,False),(True,False),(False,True)):
            with self.subTest(rejected=rejected,new_selection=new_selection),tempfile.TemporaryDirectory() as folder,ExitStack() as stack:
                base=Path(folder)
                def replace(target,**kwargs):
                    module,attribute=target.rsplit(".",1)
                    return stack.enter_context(patch.object(importlib.import_module(module),attribute,**kwargs))
                args=SimpleNamespace(output=base/"out",kit=base,through="diagnostic",route="ordinary",diagnostic_key=base/"issuer",
                                     drift_kit=None,preflight_only=False,stage_workspace=base,booked_census_only=True)
                stack.enter_context(patch.dict(os.environ,NEARPANE_TEST_HOME=str(base),NP_P0_DYNAMIC_MARKER="1"))
                replace("p0-cards.freeze",return_value=(dict(pid=90,birth=30,hash="test"),base))
                reader=replace("p0-cards.cmd",return_value=state)
                focus=replace("p0-focus.OriginalFocus").return_value
                focus.reply.return_value=dict(held=True,pid=13,number=41,hid=state["hid"],topology=top)
                focus.finish.return_value={"issued":False}
                issuer=replace("p0_diagnostic_issuer.Issuer").return_value
                issuer.capabilities.return_value=dict(ready=True,canSwitch=False)
                loan=replace("p0_diagnostic_stage.StageLoan").return_value
                loan.restore.return_value={"status":"PASS"}
                pair=replace("p0_diagnostic_pair.BookedPair").return_value
                pair.source,pair.target,pair.workspace,pair.documents,pair.generations=space,18,SimpleNamespace(),{},{}
                pair.confirm.side_effect=[{},ValueError("unregisteredOrdinaryOwner") if rejected else {"17":[],"18":[]}]
                documents=replace("p0-cards.Documents")
                docs=documents.return_value
                docs.processes=[];docs.close.return_value=[];docs.launch.return_value={"windows":[window]}
                if new_selection:
                    def closed():
                        reader.return_value=dict(state,frontPID=478,focusedNumber=99,systemFocus={"pid":478})
                        return []
                    docs.close.side_effect=closed
                    pair.recoverable_front.return_value=False
                keeper=replace("p0-cards.OwnedKeeper").return_value
                replies={"windows":{"windows":[dict(standard=True,forward=True,reverse=[space])]},
                         "enroll":dict(enrolled=True,ownerGeneration=str(uuid4()).upper())}
                keeper.call.side_effect=lambda method,*args,**kwargs:replies[method]
                audit=replace("p0-cards.InstalledWindowAudit").return_value
                audit.targets=[];audit.baselineLines=0
                audit.read.return_value=([(1,dict(stage="history-original-applied",current=True,window=window),0)],0)
                cards_seen=replace("p0-cards.confirmed_current_cards")
                self.assertEqual(cards.run(args),2 if rejected else 0)
                outcome=json.loads((args.output/"results.json").read_bytes())
                self.assertEqual(outcome["bookedCensusAdmission"]["status"],"BLOCKED" if rejected else "CONFIRMED")
                self.assertFalse(outcome["bookedCensusAdmission"]["hostSwitchIssued"])
                self.assertFalse(outcome["bookedCensusAdmission"]["setupShortcutIssued"])
                self.assertFalse(outcome["dynamicFixtureMarkerEnabled"])
                self.assertEqual(outcome["diagnosticOutcome"],"NOT_RUN")
                self.assertTrue(all(s["status"]=="NOT_RUN" for s in outcome["stages"].values()))
                self.assertEqual(outcome["cleanup"]["status"],"PASS")
                self.assertEqual(outcome["cleanup"]["preservedNewerState"],new_selection)
                self.assertFalse(focus.finish.call_args.args[0])
                cards_seen.assert_called_once()
                docs.launch.assert_called_once_with("Field Notes")
                self.assertFalse(documents.call_args.kwargs["animate"])
                pair.setup.assert_not_called();issuer.submit.assert_not_called()
                docs.close.assert_called_once();loan.restore.assert_called_once()

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
            def window(n,p):
                return dict(number=n,pid=p)
            stage,doc=window(45,12),window(49,15)
            data.update(stageSurfaces=[dict(space=21,ownerBirth=9,bounds=[0,0,2,2],**stage)],fixtureVerified=True,
                        documents=[dict(space=21,window=dict(**doc,birth=1,executable="fixture",identifier="fixture",hash="test"))])
            data["ordinary"]=[doc,stage]
            self.assertEqual(run()["stageWindowIDs"],[45])
            foreign=window(88,77)
            for added,why,rejected in [
                    ([stage],"duplicateEnrolledStageWindowID",stage),
                    ([doc],"duplicateOrdinaryWindowID",doc),
                    ([foreign,foreign],"duplicateOrdinaryWindowID",foreign),
                    ([window(51,15)],"unregisteredWindowOfEnrolledFixture",window(51,15)),
                    ([window(53,12)],"unregisteredWindowWithEnrolledStagePID",window(53,12)),
                    ([foreign],"unregisteredOrdinaryOwner",foreign)]:
                data["ordinary"]=[doc,stage,*added]
                actual=run()
                self.assertEqual(actual,dict(issued=False,ready=False,error=f"ordinary census: {why} on endpoint 21",
                                             category=why,endpoint=21,windowNumber=rejected["number"],ownerPID=rejected["pid"],pixels=0))
            data["ordinary"]=[doc,stage,window(51,15)];data["fixtureVerified"]=False
            self.assertEqual(run()["category"],"enrolledFixturePIDIdentityUnconfirmed")
            evidence={"status":"offlineCallback","ownerPID":15,"windowNumber":51,"endpoint":21}
            data.update(fixtureVerified=True,testFixtureDescription=True)
            self.assertEqual((run()["category"],run()["fixtureEvidence"]),("unregisteredWindowOfEnrolledFixture",evidence))
            data["ordinary"]=[doc,stage,foreign]
            self.assertNotIn("fixtureEvidence",run())
            for rows,why in (([doc,window(45,16)],"enrolledStageWindowOwnerMismatch"),
                             ([window(49,81),stage],"enrolledDocumentOwnerMismatch"),
                             ([stage],"enrolledDocumentMissing"),([doc,stage,{"pid":77}],"malformedOrdinaryMember")):
                data["ordinary"]=rows
                self.assertEqual(run()["category"],why)
            data["target"]=20;data["fixtureVerified"]=True;data["ordinary"]=[doc]
            self.assertEqual((run()["category"],run()["endpoint"]),("enrolledDocumentOnWrongEndpoint",20))
            data.pop("ordinary")
            known=dict(number=74,pid=10,birth=12,kind="fixture",layer=0,windowGeneration=str(uuid4()).upper())
            data.update(observedMembers={"20":[known],"21":[]},expectedMembers={"20":[known],"21":[]})
            self.assertTrue(run()["matchedExpectedMembers"])
            for changed in (dict(known,number=75),dict(known,birth=13),dict(known,windowGeneration=str(uuid4()).upper())):
                data["expectedMembers"]={"20":[changed],"21":[]}
                self.assertIn("changed since the two",run()["error"])
            original=leases[0]["digest"];leases[0]["digest"]="00"*32
            self.assertIn("digest",run()["error"])
            leases[0]["digest"]=original;Path(leases[0]["receipt"]).with_name("removed.json").touch()
            self.assertIn("removed",run()["error"])
