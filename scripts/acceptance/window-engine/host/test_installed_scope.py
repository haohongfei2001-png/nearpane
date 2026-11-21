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
