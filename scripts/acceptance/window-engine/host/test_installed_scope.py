import copy
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


membership = module("scope_membership_tests", "sample-membership.py")
reader = membership.scope_reader
nonce = str(uuid.UUID(int=13))
revision, digest = "a" * 40, "b" * 40
image = dict(Identifier="com.holdsnow.nearpane.alpha", TeamIdentifier="ZB9D4T66QB", source=revision,
             CDHash=digest, version="5.22", build="90", sourceState="clean", engineABI=1, multipleInstancesProhibited=True)
sip = "System Integrity Protection status: enabled."
path = str(reader.DAILY / "Contents/MacOS/NearpaneHost")
session = dict(qualified=True, securitySessionID=27)
launch = dict(launched=True, exactLaunchPath=True, pid=412, birth=59, kernelExecutable=path,
              prelaunch=dict(complete=True, pids=[], session=session), postlaunch=dict(complete=True, pids=[412], session=session))


def raw():
    sample = dict(hostPID=412, hostBirth=59, session=session, display=dict(topologyConfirmed=True, activeCGCount=1))
    return dict(schema=2, abi=1, challenge=nonce,
                subject=dict(pid=412, birth=59, identifier=image["Identifier"], cdhash=digest, teamIdentifier=image["TeamIdentifier"],
                             version="5.22", build="90", source=revision, sourceState="clean", atDailyInstallPath=True, kernelExecutable=path),
                system=dict(version=[27, 0, 0], build="26A428", sip=dict(status="OBSERVED", returnCode=0, bits=0, enabled=True,
                                                                         source="Host/csr_get_active_config")),
                permissionSource="Host/self nonprompt preflight", permissions={k: True for k in reader.CHECKS},
                spaceScope=dict(readOnly=True, spaceWrites=0, windowWrites=0, samples=[copy.deepcopy(sample), copy.deepcopy(sample)],
                                scope=dict(status="PASS", nativeID=6, displayUUID=str(uuid.UUID(int=15)), spaceUUID=str(uuid.UUID(int=17)))))


def correlated(value, opened=launch):
    reader.validate(value, nonce, image, opened, reader.DAILY, "26A428", "27.0", sip)


class InstalledScopeTests(unittest.TestCase):
    def test_survival_cleanup_requires_a_terminal_helper_when_a_fixture_started(self):
        record = {"hostObservationStarted": True, "hostLaunchRequested": True, "hostExit": {"status": "PASS"},
                  "fixtureLaunchRequested": True, "ownerClosed": True, "ownedProcessExited": True,
                  "requestedGuardianSurvival": True, "requestedSpacesCycle": False}
        self.assertFalse(membership.resources(record)["clear"])
        self.assertFalse(membership.resources({**record, "postExitGuardian": {"status": "PASS", "readerExited": False}})["clear"])
        self.assertTrue(membership.resources({**record, "postExitGuardian": {"status": "UNKNOWN", "readerExited": True}})["clear"])
        self.assertTrue(membership.resources({**record, "fixtureLaunchRequested": False})["clear"])

    def test_guardian_continuation_binds_the_kernel_exit_original_object_and_both_geometry_readers(self):
        frame = [40, 60, 220, 143]
        rect = dict(zip(("x", "y", "width", "height"), frame))
        a = {"pid": 8, "birth": 102, "cdhash": digest}
        b = {"pid": 12, "birth": 109, "cdhash": revision}
        scope = {"window": {"pid": 21, "birth": 99, "number": 14}, "fixtureHash": "3"*40,
                 "nativeID": 4, "display": str(uuid.uuid4()), "space": str(uuid.uuid4())}
        subject = dict(scope, host=a, guardian=b, challenge=nonce, ended=160,
                       samples=[dict(cg=rect, ax=rect)]*2, matchesHostRegisteredGeometry=True)
        raw = {"subject": a, "guardianIndependent": dict(postExitWatchArmed=True, mayPark=False, evidence=subject)}
        exited = dict(status="PASS", pid=8, birth=102)
        row = dict(scope, schema=1, challenge=nonce, hostPID=8, hostBirth=102, hostHash=digest,
                   childPID=12, childBirth=109, childHash=revision, mayPark=False, windowWrites=0, spaceWrites=0,
                   scope="readOnlyOriginalObjectAcrossHostExit", kernelExit=True, postExitAXTrusted=True,
                   exactOriginalRetained=True, geometryReturned=True, inputStable=True, originalReleased=True,
                   status="PASS", sampleCode=0, firstPostReadNS=208, secondPostReadNS=332,
                   originalAX=frame, originalCG=frame, postAX=frame, postCG=frame)
        verdict = lambda value: reader.guardian_survival_result(value, raw, nonce, exited)
        self.assertEqual(verdict(row), "PASS")
        for key in ("kernelExit", "postExitAXTrusted", "exactOriginalRetained", "inputStable", "originalReleased", "geometryReturned"):
            self.assertEqual(verdict({**row, key: False}), "UNKNOWN")
        for delta in ({"childBirth": 12}, {"challenge": str(uuid.uuid4())}, {"sampleCode": 19}, {"firstPostReadNS": 155},
                      {"nativeID": 5}, {"postAX": [41, 60, 220, 143]}, {"originalCG": []}, {"mayPark": True}):
            self.assertEqual(verdict({**row, **delta}), "UNKNOWN")
        self.assertEqual(reader.guardian_survival_result(row, raw, nonce, dict(exited, status="UNKNOWN")), "UNKNOWN")

    def test_own_canary_receipt_requires_exact_operations_original_scope_and_no_external_write(self):
        ops = ("create", "hide", "return", "destroy")
        panel = dict(owner="installedHostPrivateNonactivatingPanel", pid=412, window=8, originalSpace=6, parkingID=7,
                     observedRegistration=True, restored=True, closed=True, parkingGone=True, dispatchAttempts=dict.fromkeys(ops, 1))
        checks = dict.fromkeys(("installedHostSignatureAndPath", "exact26A428AndSIP", "existingHostAccessibility",
                               "sameConsoleAndDisplay", "externalFocusAndHIDRecorded", "durableOneUseClaim"), True)
        row = dict(status="PASS", trial="ownPanelOnly", phase="completed", challenge=nonce, admission=checks, canary=panel,
                   fixture=dict(status="NOT_RUN", dispatchAttempts=dict.fromkeys(ops, 0)), heldSpaces=0, heldWindows=0,
                   endInventoryAndFocusReads=2, canaryUnresolved=False, safeToRollback=True)
        host = dict(raw(), installedSpacesCanary=row)
        host["spaceScope"]["scope"]["spaceUUID"] = nonce
        host["spaceScope"]["workspace"] = {"notificationsObserved": 0}
        entries = [dict(id64=i, managedID=i, type=t, malformed=False, uuid=str(uuid.UUID(int=i))) for i,t in [(5,4),(6,0)]]
        for read in host["spaceScope"]["samples"]:
            read.update(directCurrent=6, directCurrentAfter=6, managedRows=[dict(rosterCount=2,orderedDesktops=entries)])
        host["postCanarySpaceScope"] = copy.deepcopy(host["spaceScope"])
        correlated(host)
        sample = dict(status="PASS", subject=host["subject"], hostExit=dict(status="PASS"), **reader.public_observation(host))
        self.assertNotIn(nonce, json.dumps(sample["spaceScope"]))
        self.assertEqual(sample["installedSpacesCanary"]["challenge"], nonce)
        self.assertEqual(membership.panel_verdict(sample, nonce), "PASS")
        for key in ("installedSpacesCanary", "installedSpacesFixtureCycle"):
            other = dict(raw(), **{key: dict(row, challenge=str(uuid.uuid4()))})
            with self.assertRaises(ValueError):
                reader.public_observation(other)
        for path, value in [(("fixture", "dispatchAttempts", "hide"), 1), (("canary", "dispatchAttempts", "create"), True),
                            (("canary", "closed"), False), (("canary", "originalSpace"), 9),
                            (("canary", "parkingID"), None), (("canary", "parkingID"), 6),
                            (("admission", "durableOneUseClaim"), False), (("heldSpaces",), 1)]:
            changed = copy.deepcopy(sample)
            item = changed["installedSpacesCanary"]
            for field in path[:-1]: item = item[field]
            item[path[-1]] = value
            self.assertEqual(membership.panel_verdict(changed, nonce), "UNKNOWN", path)
        self.assertEqual(membership.panel_verdict(dict(sample, status="BLOCKED"), nonce), "BLOCKED")

        # Replay through the same public projection and archive verifier as the formal runner.
        log = [["willOpenCanary",0,0,0], ["openedCanaryResponse",8,0,1],
               ["willCreateSpace",0,0,0], ["createdSpaceResponse",0,7,1],
               ["willHideWindow",8,7,0], ["hideResponse",8,7,1], ["twoMembershipReads",8,7,1],
               ["willReturnWindow",8,6,0], ["returnResponse",8,6,1], ["twoMembershipReads",8,6,0],
               ["willCloseCanary",8,0,0], ["closedCanaryResponse",8,0,1], ["willDestroySpace",0,7,0],
               ["destroyResponse",0,7,1], ["canaryFullyRecovered",8,7,1], ["terminalClean",0,0,1]]
        boot = str(uuid.uuid4())
        journal = dict(status="ARCHIVED_CLEAN", scopeOfTrial="ownPanelOnly", boot=boot, challenge=nonce,
                       hostPID=412, hostBirth=59, fixturePID=0, fixtureBirth=0, fixtureWindow=0,
                       originalSpace=6, originalFrame=None, startUptime=49.0, initialSpaceInventory=[5,5,6],
                       managedDesktopIDs=[5,6], knownActions=[dict(event=e, window=w, space=s, response=r,
                       owner="installedHostCanary", uptime=50+i*.01) for i,(e,w,s,r) in enumerate(log)])
        def verify(archive):
            with patch.object(membership.journal, "inspect", return_value=copy.deepcopy(archive)) as read, \
                    patch.object(reader, "command", return_value=boot):
                result = membership.panel_archive(sample, nonce)
                read.assert_called_once_with(uuid.UUID(nonce))
                self.assertNotIn(boot, json.dumps(result))
                return result["status"]
        self.assertEqual(verify(journal), "PASS")
        for change in ("addedDesktop", "reorderedDesktops", "differentSession", "missingPostRead"):
            altered = copy.deepcopy(sample)
            after = altered["postCanarySpaceScope"]["samples"][1]
            if change == "addedDesktop": after["managedRows"][0]["orderedDesktops"].append(dict(entries[0],id64=11,managedID=11))
            if change == "reorderedDesktops": after["managedRows"][0]["orderedDesktops"].reverse()
            if change == "differentSession": after["session"]["securitySessionID"] += 1
            if change == "missingPostRead": del altered["postCanarySpaceScope"]
            self.assertIsNone(membership.confirmed_desktops(altered), change)
        for key, value in (("hostBirth", 60), ("boot", str(uuid.uuid4())), ("status", "PENDING_RECONCILIATION"),
                           ("fixtureWindow", False), ("scopeOfTrial", "ownPanelAndEnrolledWindow"),
                           ("initialSpaceInventory", [6,7]), ("managedDesktopIDs", [5,6,6]),
                           ("knownActions", journal["knownActions"][:-1]), ("startUptime", float("nan"))):
            self.assertEqual(verify(dict(journal, **{key:value})), "UNKNOWN", key)
        for i, key, value in ((6,"window",9), (9,"space",7), (15,"response",True), (10,"uptime",0),
                              (4,"owner","signedOrdinaryFixture"), (5,"response",-1), (7,"event","willDestroySpace")):
            broken = copy.deepcopy(journal)
            broken["knownActions"][i][key] = value
            self.assertEqual(verify(broken), "UNKNOWN", (i,key))
        with patch.object(membership.journal, "inspect", side_effect=FileNotFoundError):
            self.assertEqual(membership.panel_archive(sample, nonce)["status"], "UNKNOWN")
        with patch.object(membership.journal, "inspect") as untouched:
            self.assertEqual(membership.panel_archive(dict(sample,status="BLOCKED"), nonce)["status"], "BLOCKED")
            untouched.assert_not_called()

    def test_launch_readiness_records_both_conflicts_without_looking_at_daily_windows(self):
        target = dict(os="27.0", build="26A428", architecture="arm64", sip=sip)
        census = dict(complete=True, pids=[], session=session)
        def check(install=image, roster=census, platform=target):
            return membership.launch_readiness(image, install, revision, digest, roster, platform)
        self.assertEqual(check()["status"], "PASS")
        blocked = check(dict(image, engineABI=None, source="d"*40), dict(census, pids=[1234]))
        self.assertEqual(blocked["status"], "BLOCKED")
        self.assertEqual(blocked["blockers"], ["installedHostIsNotPinnedEngineCandidate", "sameProductInstanceRunning"])
        self.assertEqual((blocked["hostLaunches"], blocked["spaceWrites"], blocked["hostPermissions"]), (0, 0, "NOT_RUN"))
        self.assertEqual(check(platform=dict(target, build="26A434"))["status"], "BLOCKED")
        for invalid in [dict(complete=False), dict(pids=None), dict(pids=[True]), dict(session={}),
                        dict(session=dict(session, securitySessionID=0))]:
            self.assertEqual(check(roster=dict(census, **invalid))["status"], "UNKNOWN")

    def test_real_overview_receipt_demands_two_visible_counts_and_restoration(self):
        row = dict(status="PASS", stage="afterCanary", restored=True, inputEventsPosted=0,
                   presentations=1, dismissals=1, tileCounts=[2,2], expectedCount=2)
        self.assertEqual(membership.overview_verdict(row, [3,7]), "PASS")
        for change in (dict(tileCounts=[2]), dict(tileCounts=[2,3]), dict(restored=False),
                       dict(presentations=True), dict(inputEventsPosted=1), dict(dismissals=2)):
            self.assertEqual(membership.overview_verdict(dict(row, **change), [3,7]), "UNKNOWN")
        self.assertEqual(membership.overview_verdict(dict(row,status="FAIL"), [3,7]), "FAIL")
        report = dict(requestedOwnCanary=True, requestedSpacesCycle=False, hostObservationStarted=True,
                      hostLaunchRequested=True, hostExit=dict(status="PASS"), panelJournal=dict(status="PASS"))
        self.assertFalse(membership.resources(report)["clear"])
        self.assertTrue(membership.resources(dict(report,overviewObservation=row))["clear"])
        refused = dict(report, panelJournal=dict(status="BLOCKED"), canary=dict(status="BLOCKED", engineInvoked=False,
                       reason="hostScopeOrRegistrationChanged", safeToRollback=True))
        self.assertTrue(membership.resources(refused)["clear"])
        refused["canary"]["engineInvoked"] = True
        self.assertFalse(membership.resources(refused)["clear"])

    def test_release_of_open_close_only_panel_is_independent_of_qualification(self):
        challenge = str(uuid.uuid4())
        counts = dict(create=0, hide=0, destroy=0, **{"return": 0})
        canary = dict(status="UNKNOWN", challenge=challenge, trial="ownPanelOnly", heldSpaces=0, heldWindows=0,
                      endInventoryAndFocusReads=2, engineInvoked=True, safeToRollback=True, canaryUnresolved=False,
                      canary=dict(dispatchAttempts=counts), fixture=dict(status="NOT_RUN", dispatchAttempts=counts))
        subject = dict(pid=412, birth=59)
        observation = dict(status="PASS", subject=subject, installedSpacesCanary=canary,
                           hostExit=dict(status="PASS", sameIdentifierRunning=0, **subject))
        actions = [("willOpenCanary", 0, 0), ("openedCanaryResponse", 71, 1), ("willCloseCanary", 71, 0),
                   ("closedCanaryResponse", 71, 1), ("terminalClean", 0, 1)]
        archive = dict(challenge=challenge, scopeOfTrial="ownPanelOnly", hostPID=412, hostBirth=59, status="ARCHIVED_CLEAN",
                       managedDesktopIDs=[4,6], startUptime=9, knownActions=[
                           dict(event=e, window=w, space=0, response=r, owner="installedHostCanary", uptime=10+i)
                           for i, (e,w,r) in enumerate(actions)])
        with patch.object(membership, "confirmed_desktops", return_value=[4,6]):
            self.assertTrue(membership.released_before_dispatch(observation, archive, challenge))
            self.assertEqual(membership.panel_verdict(observation, challenge), "UNKNOWN")
            for changed in (dict(hostBirth=60), dict(managedDesktopIDs=[6,4]), dict(knownActions=archive["knownActions"][:-1])):
                self.assertFalse(membership.released_before_dispatch(observation, archive | changed, challenge))
            counts["create"] = 1
            self.assertFalse(membership.released_before_dispatch(observation, archive, challenge))

    def test_external_trial_stops_at_predecessor_without_starting_an_owner(self):
        with tempfile.TemporaryDirectory() as td:
            canonical = Path(td).resolve() / "Applications" / "Nearpane.app"
            canonical.mkdir(parents=True)
            args = membership.argparse.Namespace(host=canonical, expected_source=revision, expected_cdhash=digest,
                out=Path(td)/"run.json", installed=True, preflight_only=False, own_spaces_canary=False, enrolled_spaces_cycle=True,
                p0_receipt=Path(td)/"prior.json", p0_sha256="admitted", independent_reader=Path(td)/"fixture-readback")
            report = dict(osBuild="26A428",requestedSpacesCycle=True)
            with patch.object(membership.overview_admission,"load_receipt",return_value=({"host":{}}, "admitted")), \
                    patch.object(membership.overview_admission,"qualifies",return_value=True), patch.object(membership.subprocess,"run"), \
                    patch.object(reader,"DAILY",canonical), patch.object(reader,"identity",return_value=image), \
                    patch.object(membership,"inspect_launch",return_value=dict(status="PASS")), \
                    patch.object(membership,"own_panel_first",side_effect=lambda a,r: r.update(ownPanelPredecessor=dict(status="UNKNOWN", resourcesClear=False))), \
                    patch.object(membership,"prepare_fixture") as prepare:
                membership.run(args, report)
                prepare.assert_not_called()
            self.assertEqual(report["status"], "UNKNOWN")
            self.assertFalse(membership.resources(report)["clear"])

    def test_installed_binding_and_development_controls(self):
        self.assertTrue(membership.installed_matches(reader.DAILY, image, revision, digest))
        for key, value in (("CDHash","c"*40), ("sourceState","dirty"), ("Identifier","com.holdsnow.nearpane.host"),
                           ("multipleInstancesProhibited",False), ("TeamIdentifier","OTHER"), ("build","91")):
            self.assertFalse(membership.installed_matches(reader.DAILY, dict(image, **{key:value}), revision, digest))
        self.assertFalse(membership.installed_matches(Path("/tmp/Nearpane.app"), image, revision, digest))
        dev = dict(image, Identifier="com.holdsnow.nearpane.host")
        self.assertTrue(membership.legacy_matches(dict(status="PASS", osBuild="26A428", permissions=raw()["permissions"],
                                                      spaceScope=raw()["spaceScope"], subject=dict(source=revision, cdhash=digest,
                                                                                                 identifier=dev["Identifier"])), dev))

    def test_correlation_requires_every_physical_subject_and_nonprompt_field(self):
        correlated(raw())
        for section, field, unexpected in (("subject","pid",411),("subject","birth",36),("subject","kernelExecutable","/tmp/NearpaneHost"),
                                           ("subject","teamIdentifier","OTHER"),("subject","cdhash","a"*40),("system","build","26A000"),
                                           ("system","version",[26,0,0]),("system","sip",{"status":"UNKNOWN"})):
            with self.subTest(field=field):
                changed = raw()
                changed[section][field] = unexpected
                with self.assertRaises(ValueError):
                    correlated(changed)
        for permiss in reader.CHECKS:
            changed = raw()
            del changed["permissions"][permiss]
            with self.assertRaises(ValueError):
                correlated(changed)
        denied = raw()
        denied["permissions"]["screenCapture"] = False
        correlated(denied)  # A correlated negative remains attributable to this Host.

    def test_refuses_preexisting_substitution_second_instance_and_session_change(self):
        for section, key, observed in (("prelaunch","pids",[59938]), ("prelaunch","complete",False),
                                      ("postlaunch","pids",[412,59938]), ("postlaunch","session",dict(session,securitySessionID=28))):
            changed = copy.deepcopy(launch)
            changed[section][key] = observed
            with self.assertRaises(ValueError):
                correlated(raw(), changed)
        changed = raw()
        changed["spaceScope"]["samples"][1]["session"] = dict(session, qualified=False)
        with self.assertRaises(ValueError):
            correlated(changed)

    def test_registration_cannot_follow_changed_display_space_or_authorization(self):
        for key in ("permissions", "system", "spaceScope", "subject"):
            first, final = raw(), raw()
            if key == "spaceScope":
                final[key]["scope"]["nativeID"] = 11
            else:
                final[key]["changed"] = True
            with self.assertRaises(ValueError):
                reader.confirm_continuity(first, final)
        changed = raw()
        changed["spaceScope"]["samples"][1]["display"]["activeCGCount"] = 2
        self.assertFalse(membership.preflight_allows(changed))
        reader.confirm_continuity(raw(), raw())

    def test_wrong_owner_mode_or_link_never_supplies_a_registration(self):
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            reader.publish(folder, "fixture.json", b"abc")
            self.assertEqual(reader.read_private(folder/"fixture.json",3), b"abc")
            (folder/"fixture.json").chmod(0o644)
            with self.assertRaises(ValueError):
                reader.read_private(folder/"fixture.json",3)
            (folder/"link").symlink_to(folder/"fixture.json")
            with self.assertRaises(OSError):
                reader.read_private(folder/"link",3)

    def test_one_ls_launch_brackets_fixture_and_emits_separate_exit(self):
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            calls, order = [], []
            def command(*args):
                if str(args[0]) == "xcrun": return ""
                if str(args[0]).endswith("sw_vers"): return "27.0" if args[1]=="-productVersion" else "26A428"
                if str(args[0]).endswith("csrutil"): return sip
                if args[-1] == "--roster":
                    self.assertIn("ownerClosed", order)
                    return json.dumps(dict(complete=True,pids=[],session=session))
                calls.append(args)
                return json.dumps(launch)
            @contextmanager
            def enroll(pre):
                self.assertEqual(pre["subject"]["birth"], 59)
                order.append("fixtureStart")
                try: yield b'{"window":118}'
                finally: order.append("ownerClosed")
            def respond(where, name, _seconds):
                r=raw()
                if name=="preflight.json":
                    self.assertFalse((where/"fixture.json").exists())
                    order.append("initialHost")
                else:
                    self.assertEqual(reader.read_private(where/"fixture.json",4096), b'{"window":118}')
                    order.append("registeredHost")
                    r["guardianFixture"] = {"status":"UNKNOWN"}
                return r, digest
            with patch.object(reader, "identity", return_value=image), patch.object(reader, "exclusive", return_value=reader.nullcontext()), \
                    patch.object(reader, "command", side_effect=command), patch.object(reader, "response", side_effect=respond):
                out = reader.observe(reader.DAILY, nonce, folder, folder/"result.json", enroll=enroll, expected_image=image)
            self.assertEqual(out["status"], "PASS")
            self.assertEqual(out["hostExit"]["status"], "PASS")
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][-1], "--await-registered-window")
            self.assertEqual(order, ["initialHost", "fixtureStart", "registeredHost", "ownerClosed"])

    def test_preexisting_running_pid_does_not_start_fixture_or_submit(self):
        with tempfile.TemporaryDirectory() as td:
            folder = Path(td)
            refusal = dict(launched=False, exactLaunchPath=False, pid=0, reason="singleInstanceOrLoginUnavailable",
                           prelaunch=dict(complete=True, pids=[59938], session=session))
            def command(*args):
                return json.dumps(refusal) if str(args[0]).endswith("launch-scope") else "test"
            with patch.object(reader, "identity", return_value=image), patch.object(reader, "exclusive", return_value=reader.nullcontext()), \
                    patch.object(reader, "command", side_effect=command):
                out = reader.observe(reader.DAILY, nonce, folder, folder/"result.json", enroll=lambda _:self.fail("fixture ran"))
            self.assertEqual(out["status"], "BLOCKED")
            self.assertEqual(out["launchServices"]["prelaunch"]["pids"], [59938])
            self.assertEqual(out["hostExit"]["status"], "NOT_RUN")
            self.assertFalse((folder/"launched").exists())

    def test_backend_cleanup_is_not_authority_to_release_an_unconfirmed_host_or_window(self):
        res = dict(requestedSpacesCycle=True, fixtureAdmission="registeredSignedBackgroundWindow", fixtureLaunchRequested=True,
                   hostObservationStarted=True, hostLaunchRequested=True, hostExit={"status":"PASS"}, ownerClosed=True,
                   ownedProcessExited=True, backendSafeToRollback=True)
        self.assertTrue(membership.resources(res)["clear"])
        for field, lost in (("hostExit",None), ("ownerClosed",False), ("ownedProcessExited",False),
                            ("backendSafeToRollback",False), ("preexistingSameID",[59938])):
            self.assertFalse(membership.resources(dict(res,**{field:lost}))["clear"])
        untouched = membership.resources(dict(requestedSpacesCycle=True,hostObservationStarted=True,hostLaunchRequested=False))
        self.assertEqual(untouched, dict(candidateExit="NOT_RUN",registeredWindowExit="NOT_RUN",backendCleanup="NOT_RUN",clear=True))


if __name__ == "__main__":
    unittest.main()
