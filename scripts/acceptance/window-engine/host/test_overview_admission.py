from copy import deepcopy
from contextlib import ExitStack
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
             originalFocusConfirmedReads=2, focusBefore=[f, f], focusAfter=[dict(f, overviewClosed=True)]*2,
             terminalFocus=dict(f, overviewClosed=True, uptime=103.01), terminalReadbackUptime=103.02)
    names = ["before","presented","dismissed","terminal"]
    phases = [dict(pid=9, phase=name, endUptime=100+i, missionControlPresented=int(i == 1),
                   missionControlObservation="signedDockMCIdentifier" if i == 1 else "signedDockAXListWithoutMC") for i,name in enumerate(names)]
    for phase in phases:
        end = phase["endUptime"]
        phase["startUptime"] = end - 0.4
        phase["attempts"] = [dict(pid=9, targetPID=9, targetBirth=20, uptime=end-0.3, endUptime=end-0.1,
                                  missionControlSample="requested", missionControlReadStartUptime=end-0.24,
                                  missionControlReadEndUptime=end-0.18,
                                  status="observed", exit=0, source="installedHostPreviewMetrics",
                                  missionControlPresented=phase["missionControlPresented"],
                                  missionControlObservation=phase["missionControlObservation"])]
    return dict(schema=1,stage="physicalP0BeforeWrites",status="PASS",build="26A428",systemVersion="27.0",sip="System Integrity Protection status: enabled.",
                scope={"status":"PASS","nativeID":4},scopeImmediatelyBeforeOverview={"status":"PASS","nativeID":4},
                windowWrites=0,spaceWrites=0,launchedHosts=0,observerAXTrusted=True,sameHostAtEnd=True,hostSequenceConfirmed=True,
                host=dict(IMAGE,pid=9,birth=20,path="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost"),hostTelemetry=phases,measurement=m)


class AdmissionTests(unittest.TestCase):
    def test_membership_observation_cannot_promote_either_backend(self):
        trial = dict(status="PASS", guardianReadback={"status":"BLOCKED"}, thirdPartyMembershipRoundTrip="PASS",
                     singleWindowHideRestore="NOT_RUN")
        corner = stage.summarize_trial("corner-readback",trial)
        self.assertEqual(corner["membershipReadback"],"PASS")
        self.assertEqual(corner["guardianReadback"]["status"],"BLOCKED")
        self.assertEqual(corner["qualification"],"NOT_RUN")
        self.assertEqual(stage.summarize_trial("spaces",trial)["qualification"],"BLOCKED")

    def test_obsolete_host_never_advertises_interactive_session_or_research_neighbor(self):
        with tempfile.TemporaryDirectory() as folder:
            exe = Path(folder) / "NearpaneHost"
            exe.write_bytes(b"--registered-window")
            self.assertFalse(stage.advertises_interactive_entry(exe, "interactive-roster"))
            exe.write_bytes(b"--interactive-window-pair")
            self.assertTrue(stage.advertises_interactive_entry(exe, "interactive-roster"))
            self.assertFalse(stage.advertises_interactive_entry(exe, "interactive-spaces"))

    def test_passive_read_admits_fixture_readback_only_without_prior_spaces_trial(self):
        r = receipt()
        focus = dict(uptime=100., workspacePID=8, birth=25, cgWindowID=41)
        scope = dict(status="PASS", nativeID=4, displayUUID="screen", spaceUUID="ordinary")
        phase = r["hostTelemetry"][0]
        phase["phase"] = "passive"
        focus["uptime"] = phase["startUptime"] - 0.2
        r.update(status="NOT_RUN", stage="passiveReadOnly", hostTelemetry=[phase], scope=scope, terminalScope=scope.copy(),
                 admission=focus, terminalAdmission=dict(focus, sameOriginalAX=True, uptime=100.05),
                 buttonsBefore=0, buttonsAfter=0, inputAvailableBefore=True, inputAvailableAfter=True,
                 hidBeforePassiveRead=[4]*14, hidAfterPassiveRead=[4]*14, terminalReadbackUptime=100.1)
        self.assertTrue(gate.qualifies_read_only(r,IMAGE,9,20,101))
        self.assertFalse(gate.qualifies(r,IMAGE,9,20,101))
        self.assertFalse(gate.qualifies_read_only(r,IMAGE,9,20,131))
        for edit in (lambda t:t["terminalScope"].update(nativeID=5), lambda t:t["terminalAdmission"].update(sameOriginalAX=False),
                     lambda t:t.update(windowWrites=1), lambda t:t.update(inputAvailableAfter=False), lambda t:t.update(hidAfterPassiveRead=[5]*14)):
            changed = deepcopy(r)
            edit(changed)
            self.assertFalse(gate.qualifies_read_only(changed,IMAGE,9,20,101))

    def test_signed_host_read_must_be_inside_its_actual_overview_phase(self):
        phases = receipt()["hostTelemetry"]
        sample = phases[1]["attempts"][-1]
        self.assertTrue(gate.observed_host_phases(phases, 9, 20))
        sample["missionControlReadStartUptime"] = phases[1]["startUptime"] + 0.01
        self.assertFalse(gate.observed_host_phases(phases, 9, 20))
        sample["missionControlSample"] = "cached"
        self.assertTrue(gate.observed_host_phases(phases, 9, 20))
        sample["missionControlReadStartUptime"] = phases[1]["startUptime"] - 0.01
        self.assertFalse(gate.observed_host_phases(phases, 9, 20))
        del sample["missionControlReadEndUptime"]
        self.assertFalse(gate.observed_host_phases(phases, 9, 20))

    def test_intervening_hardware_input_stops_before_quit_or_returns_the_sole_regular_host(self):
        quiet = dict(counts=[0]*14, pressed=False, secure=False)
        changed = dict(counts=[1]+[0]*13, pressed=False, secure=False)
        rights = dict(status="PASS", installed={"CDHash":IMAGE["cdhash"]}, subject=dict(pid=9,birth=20),
                      permissions={k:True for k in ("accessibility","listenEvent","postEvent","screenCapture")})
        for after_quit in (False,True):
            with self.subTest(after_quit=after_quit), tempfile.TemporaryDirectory() as name, ExitStack() as mocks:
                directory = Path(name)
                (directory/"08-upgrade.json").write_text(json.dumps(dict(status="PASS",stage="running",installed=IMAGE)))
                mac = mocks.enter_context(patch.object(stage.install, "Mac")).return_value
                mac.inspect.return_value = IMAGE
                mac.pid.return_value = 9
                mac.bound.return_value = (9,0,20)
                mac.wait_owner.return_value = (10,0,22)
                mocks.enter_context(patch.object(stage.install,"process_stamp",return_value=(9,0,20)))
                mocks.enter_context(patch.object(gate,"load_receipt",return_value=(receipt(),"abc")))
                mocks.enter_context(patch.object(gate,"qualifies",return_value=True))
                mocks.enter_context(patch.object(gate,"current_hid",side_effect=[quiet,changed] if after_quit else [changed]))
                mocks.enter_context(patch.object(stage.cycle.backup.permissions,"sample",return_value=rights))
                mocks.enter_context(patch.object(stage.cycle,"admit_daily",return_value=True))
                mocks.enter_context(patch.object(stage.cycle,"stamp_is_gone",return_value=True))
                mocks.enter_context(patch.object(stage.upgrade,"recoveries",return_value={"quitPermitted":True}))
                mocks.enter_context(patch.object(stage.upgrade,"census",
                    side_effect=[{"pids":[9]},{"pids":[]},{"pids":[]},{"pids":[10]}]))
                child = mocks.enter_context(patch.object(stage.subprocess,"Popen"))
                events = []
                stage.run(directory,"spaces",lambda key,**row:events.append((key,row)),directory,directory/"p0")
                child.assert_not_called()
                if after_quit:
                    mac.quit.assert_called_once_with((9,0,20))
                    mac.open_daily.assert_called_once()
                    self.assertIn("inputChangedBeforeDiagnosticLaunch", [key for key,row in events])
                    self.assertEqual(events[-1][0],"regularHostRunning")
                else:
                    mac.quit.assert_not_called()
                    self.assertEqual(events[-1][1]["quitRequests"],0)

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
            lambda r:r["hostTelemetry"][1]["attempts"][0].update(exit=3),
            lambda r:r["hostTelemetry"][1]["attempts"][0].update(targetBirth=21),
            lambda r:r["hostTelemetry"][1]["attempts"][0].update(missionControlObservation="unknown"),
            lambda r:r["hostTelemetry"][3]["attempts"][0].update(uptime=900),
            lambda r:r["hostTelemetry"][3]["attempts"].clear(),
            lambda r:r["measurement"].update(terminalReadbackUptime=102.9),
            lambda r:r["measurement"].pop("terminalReadbackUptime"),
            lambda r:r["measurement"].update(terminalReadbackUptime=400),
            lambda r:r["measurement"].pop("terminalFocus"),
            lambda r:r["measurement"]["terminalFocus"].update(cgWindowID=42),
            lambda r:r["measurement"]["terminalFocus"].update(overviewClosed=False),
            lambda r:r["measurement"]["terminalFocus"].update(sameOriginalAX=False),
            lambda r:r["measurement"]["terminalFocus"].update(uptime=102.9),
            lambda r:r["measurement"]["terminalFocus"].update(uptime=103.03),
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
