from copy import deepcopy
import importlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import overview_admission as gate

stage = importlib.import_module("run-installed-stage")
sample = importlib.import_module("sample-membership")

IMAGE = {"source": "b" * 40, "cdhash": "a" * 40}


def receipt():
    rect = [64, 8, 80, 46]
    hit = {"axError": 0, "object": 1, "tile": 1}
    rect_list = [0, 0, 900, 70]
    listed = dict(list=0,attributes=[dict(attribute=name,axError=0,objects=[1]) for name in ("AXChildren","AXVisibleChildren")])
    grid = dict(completeGrid=True, inputInterrupted=False, rootDisagreement=False, targetPoints=1, pointsRead=1,displayFrame=[0,0,900,600],
                rootTimeoutErrors=dict(dock=0, systemWide=0), hits=[dict(point=[90, 28], dock=hit, systemWide=hit)],
                startUptime=10,endUptime=11,stripAttributes=[listed],parentReads=[dict(object=1,axError=0,parent=0)],
                objects=[dict(pid=23,role="AXList",identifier="mc.spaces.list",frame=rect_list),
                         dict(pid=23,role="AXButton",identifier=None,frame=rect,errors=dict(pid=0,role=0,position=0,size=0))])
    f = dict(pid=8, birth=25, cgWindowID=41, sameOriginalAX=True)
    m = dict(status="PASS", stage="beforeWindowWrites", scopeType=0, currentSpaceID=4, inputEventsPosted=0, windowWrites=0, spaceWrites=0, restored=True,
             stableHitLayout=True, inputUninterrupted=True, nativeInventoryRestored=True, presentations=1, dismissals=1,
             expectedCount=1, managedIDsBefore=[4], managedIDsAfter=[4], tileCounts=[1, 1], hidBefore=[0]*14, hidAfter=[0]*14,
             hitTestSamples=[deepcopy(grid), dict(deepcopy(grid),startUptime=12,endUptime=13)], originalFocus=dict(pid=8, birth=25, window=41),
             originalFocusConfirmedReads=2, focusBefore=[f, f], focusAfter=[dict(f, overviewClosed=True)]*2)
    names = ["before","presented","dismissed","terminal"]
    phases = [dict(pid=9, phase=name, endUptime=100+i, missionControlPresented=int(i == 1),
                   missionControlObservation="signedDockMCIdentifier" if i == 1 else "signedDockAXListWithoutMC") for i,name in enumerate(names)]
    return dict(schema=1,stage="physicalP0BeforeWrites",status="PASS",build="26A428",systemVersion="27.0",sip="System Integrity Protection status: enabled.",
                scope={"status":"PASS","nativeID":4},scopeImmediatelyBeforeOverview={"status":"PASS","nativeID":4},
                windowWrites=0,spaceWrites=0,launchedHosts=0,observerAXTrusted=True,sameHostAtEnd=True,hostSequenceConfirmed=True,
                host=dict(IMAGE,pid=9,birth=20,path="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost"),hostTelemetry=phases,measurement=m)


class AdmissionTests(unittest.TestCase):
    def test_rejects_single_root_partial_or_unbound_p0(self):
        original = receipt()
        self.assertTrue(gate.qualifies(original,IMAGE,9,20,104))
        for mutate in (
            lambda r:r["host"].update(birth=21),
            lambda r:r["measurement"].update(stage="fullscreenPositionDiagnostic"),
            lambda r:r["measurement"]["hidAfter"].__setitem__(6,1),
            lambda r:r["measurement"]["focusAfter"][-1].update(cgWindowID=19),
            lambda r:r["measurement"]["hitTestSamples"][1].update(completeGrid=False),
            lambda r:r["measurement"]["hitTestSamples"][0]["hits"][0].pop("dock"),
            lambda r:r["measurement"]["hitTestSamples"][0]["hits"][0]["systemWide"].update(object=0),
            lambda r:r["hostTelemetry"][1].update(missionControlPresented=0),
        ):
            value = deepcopy(original)
            mutate(value)
            self.assertFalse(gate.qualifies(value,IMAGE,9,20,104))
        self.assertFalse(gate.qualifies(original,IMAGE,9,20,404))
        self.assertFalse(gate.qualifies(original,IMAGE,9,20,102))

    def test_unqualified_p0_cannot_quit_or_start_fixture(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root/"08-upgrade.json").write_text(json.dumps(dict(status="PASS",stage="running",installed=IMAGE)))
            events = []
            with patch.object(stage.install, "Mac") as mac, patch.object(stage, "subprocess") as process:
                stage.run(root,"spaces",lambda label,**r:events.append((label,r)))
                self.assertEqual(events[-1][1]["quitRequests"],0)
                self.assertEqual(events[-1][1]["qualification"],"BLOCKED")
                mac.return_value.quit.assert_not_called()
                process.run.assert_not_called()
        args = sample.argparse.Namespace(installed=True, enrolled_spaces_cycle=True, own_spaces_canary=False)
        evidence = {}
        with patch.object(sample,"own_panel_first") as canary:
            sample.run(args,evidence)
            canary.assert_not_called()
        self.assertEqual(evidence["status"],"BLOCKED")

    def test_fixture_ledger_requires_the_return_read_and_clean_terminal(self):
        nonce = "00000000-0000-4000-b000-000000000037"
        boot = "00000000-0000-4000-b000-000000000035"
        frame = [5,10,40,80]
        owner = dict(pid=90,birth=30,window=61)
        panel = sample.panel_actions(54,4,501)[:-1]
        external = [("willCreateSpace",0,0,0),("createdSpaceResponse",0,502,1),("willHideWindow",61,502,0),
                    ("hideResponse",61,502,1),("twoMembershipReads",61,502,1),("willReturnWindow",61,4,0),
                    ("returnResponse",61,4,1),("twoMembershipReads",61,4,0),("willDestroySpace",0,502,0),
                    ("destroyResponse",0,502,1),("fixtureFullyRecovered",61,502,1)]
        events = ([("installedHostCanary",*e) for e in panel]+[("signedOrdinaryFixture",*e) for e in external]+
                  [("installedHostCanary","terminalClean",0,0,1)])
        actions = [dict(owner=o,event=e,window=w,space=s,response=v,uptime=i+2) for i,(o,e,w,s,v) in enumerate(events)]
        ledger = dict(status="ARCHIVED_CLEAN",scopeOfTrial="ownPanelAndEnrolledWindow",boot=boot,challenge=nonce,
                      hostPID=12,hostBirth=89,fixturePID=90,fixtureBirth=30,fixtureWindow=61,originalFrame=frame,
                      originalSpace=4,initialSpaceInventory=[4,6],managedDesktopIDs=[4,6],knownActions=actions,startUptime=1)
        raw = dict(subject=dict(pid=12,birth=89),installedSpacesFixtureCycle=dict(challenge=nonce,
                   fixture=dict(owner,homeID=4,parkingID=502,originalCGAndAXFrame=frame),canary=dict(window=54,parkingID=501)))
        report = dict(ownerStart=owner,independentBefore=dict(samples=[dict(managedRows=[dict(orderedDesktops=[{"managedID":4},{"managedID":6}])])]))
        def validate(case):
            with patch.object(sample.journal,"inspect",return_value=deepcopy(case)), patch.object(sample.scope_reader,"command",return_value=boot):
                return sample.fixture_archive(raw,nonce,report)["status"]
        self.assertEqual(validate(ledger),"PASS")
        self.assertEqual(validate(dict(ledger,knownActions=actions[:-1])),"UNKNOWN")
        self.assertEqual(validate(dict(ledger,knownActions=[r for r in actions if r["event"] != "returnResponse"])),"UNKNOWN")
        self.assertEqual(validate(dict(ledger,fixtureBirth=31)),"UNKNOWN")

    def test_independent_comparison_rejects_dock_focus_geometry_and_inventory_drift(self):
        row = dict(status="PASS",scope={"status":"PASS"},membership={"status":"PASS"},dock={"orderedSubroles":["AXApplicationDockItem"]},
                   cgFrame=[3,4,90,80],axFrame=[3,4,90,80],samples=[dict(managedRows=[4, 8])]*2,focus=dict(workspacePID=73,birth=7,cgWindowID=12))
        self.assertTrue(sample.independent_pair(row,row))
        for other in (dict(row,dock={}),dict(row,focus=dict(row["focus"],cgWindowID=51)),dict(row,axFrame=[30,4,90,80]),
                      dict(row,samples=[dict(managedRows=[8,4])]*2)):
            self.assertFalse(sample.independent_pair(row,other))
