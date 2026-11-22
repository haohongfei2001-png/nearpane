import importlib.util
import json
from pathlib import Path
from contextlib import nullcontext
import tempfile
import shutil
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("interactive_pair", Path(__file__).with_name("interactive-pair.py"))
pair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pair)


class InstalledPairTests(unittest.TestCase):
    def test_only_pinned_clean_522_90_installed_identity_can_launch(self):
        rev, digest = "1" * 40, "a" * 40
        image = dict(Identifier="com.holdsnow.nearpane.alpha", TeamIdentifier=pair.fixture.TEAM,
                     sourceState="clean", multipleInstancesProhibited=True, version="5.22", build="90",
                     engineABI=1, source=rev, CDHash=digest)
        self.assertTrue(pair.signed_image(image, rev, digest))
        for key, wrong in dict(Identifier="com.holdsnow.nearpane.host", sourceState="dirty",
                               multipleInstancesProhibited=False, version="5.23", build="91", engineABI=0,
                               source="2"*40, CDHash="b"*40, TeamIdentifier="other").items():
            self.assertFalse(pair.signed_image({**image, key: wrong}, rev, digest))

    def test_ambiguous_launch_or_missing_window_cleanup_keeps_nonce_for_recovery(self):
        self.assertTrue(pair.may_remove(dict(launchRequested=False)))
        self.assertFalse(pair.may_remove(dict(launchRequested=None)))
        self.assertFalse(pair.may_remove(dict(launchRequested=True, hostExit={"status":"UNKNOWN"})))
        anchor = dict(launchRequested=True, hostExit={"status":"PASS"})
        self.assertTrue(pair.may_remove({**anchor, "pair":{"fixtureLaunchRequested":False}}))
        cleanup = dict(fixtureExited=True, exactWindowsGone=True, ownCloseAcknowledged=True)
        self.assertTrue(pair.may_remove({**anchor, "pair":{"cleanup":cleanup}}))
        for field in cleanup:
            self.assertFalse(pair.may_remove({**anchor, "pair":{"cleanup":{**cleanup,field:False}}}))

    def test_existing_host_stops_before_fixture_preparation_or_launch(self):
        image = dict(Identifier="com.holdsnow.nearpane.alpha", TeamIdentifier=pair.fixture.TEAM, sourceState="clean",
                     multipleInstancesProhibited=True, version="5.22", build="90", engineABI=1,
                     source="1"*40, CDHash="a"*40)
        with tempfile.TemporaryDirectory() as temp, patch.object(pair.scope,"identity",return_value=image), \
             patch.object(pair.scope,"exclusive",return_value=nullcontext()), \
             patch.object(pair.scope,"build_launcher",return_value="offline-launcher"), \
             patch.object(pair.scope,"command",return_value=json.dumps({"complete":True,"pids":[99],"session":{"qualified":True}})) as command, \
             patch.object(pair.fixture,"prepare") as prepare:
            args = SimpleNamespace(output=Path(temp)/"receipt",kit=Path(temp),revision=image["source"],cdhash=image["CDHash"],preflight_only=False)
            result = pair.run(args)
            self.assertEqual((result["status"],result["launchRequested"],result["reason"]),
                             ("BLOCKED",False,"existingHostOrUnqualifiedConsole"))
            self.assertTrue((args.output/"result.json").exists())
            command.assert_called_once_with("offline-launcher", pair.scope.DAILY, "--roster")
            prepare.assert_not_called()

    def test_preopen_census_veto_requires_correlated_empty_close_and_both_process_exits_for_cleanup(self):
        nonce, digest = "abcdef", "a" * 40
        subject = {"pid":72, "birth":614, "cdhash":"b"*40}
        owner = {"pid":84, "birth":739, "cdhash":digest, "identifier":pair.fixture.IDENTIFIER}
        observed = dict(fixtureLaunchRequested=True,openRequestAttempted=False,fixturePID=84,fixtureBirth=739,
                        fixtureCDHash=digest,cleanup={"fixtureExited":True})
        close = dict(schema=1,challenge=nonce,op="close",seq=1,reason="hostDisconnected",ownWindowsCreated=0,
                     ownWindowsClosed=True,beforeClose=[],owner=owner,host=subject)
        self.assertTrue(pair.unopened_exit(close,observed,subject,nonce))
        for key, value in {"seq":2, "op":"open", "beforeClose":[{}], "ownWindowsCreated":2, "unfinished":{},
                           "host":{**subject, "birth":613}, "owner":{**owner, "cdhash":"c"*40}}.items():
            self.assertFalse(pair.unopened_exit({**close,key:value},observed,subject,nonce))
        result = dict(launchRequested=True,verifiedUnopenedFixtureExit=True,pair=observed,hostExit={"status":"PASS"})
        self.assertTrue(pair.may_remove(result))
        self.assertFalse(pair.may_remove({**result,"hostExit":{"status":"UNKNOWN"}}))
        self.assertFalse(pair.may_remove({**result,"pair":{**observed,"openRequestAttempted":True}}))

    def test_corrupt_launch_reply_aborts_only_this_nonce_and_censuses_even_without_a_pid(self):
        image = dict(Identifier="com.holdsnow.nearpane.alpha", TeamIdentifier=pair.fixture.TEAM, sourceState="clean",
                     multipleInstancesProhibited=True, version="5.22", build="90", engineABI=1,
                     source="1"*40, CDHash="a"*40)
        invoked = []
        def command(*args):
            if args[-1] == "--roster": return json.dumps({"complete":True,"pids":[],"session":{"qualified":True}})
            if args[-1] == "--interactive-window-pair":
                invoked.append(args[-2])
                return "{"
            return {"-productVersion":"27.0", "-buildVersion":"26A428",
                    "status":"System Integrity Protection status: enabled."}[args[-1]]
        def observed_exit(_launcher, _app, reply):
            self.assertEqual(reply,{})
            self.assertEqual(len(invoked),1)
            self.assertTrue((Path("/private/tmp")/("nearpane-host-scope."+invoked[0])/"abort").is_file())
            return {"status":"PASS","sameIdentifierRunning":0}
        signature = dict(identifier=pair.fixture.IDENTIFIER, team=pair.fixture.TEAM, strictDeveloperIDVerification=True, cdhash="c"*40)
        with tempfile.TemporaryDirectory() as temp, patch.object(pair.scope,"identity",return_value=image), \
             patch.object(pair.scope,"exclusive",return_value=nullcontext()), patch.object(pair.scope,"build_launcher",return_value="offline"), \
             patch.object(pair.scope,"command",side_effect=command), patch.object(pair.scope,"await_exit",side_effect=observed_exit) as census, \
             patch.object(pair.fixture,"prepare",return_value={"signature":signature}), patch.object(pair.os,"uname",return_value=SimpleNamespace(machine="arm64")):
            try:
                args = SimpleNamespace(output=Path(temp)/"receipt",kit=Path(temp),revision=image["source"],cdhash=image["CDHash"],preflight_only=False)
                row = pair.run(args)
                self.assertEqual(row["status"],"UNKNOWN")
                self.assertIsNone(row["launchRequested"])
                self.assertIs(row["abortPublished"],True)
                self.assertEqual(len(row["retainedNonceDirectories"]),2)
                census.assert_called_once()
            finally:
                for nonce in invoked:
                    for prefix in ("nearpane-host-scope.","nearpane-membership."):
                        path = Path("/private/tmp")/(prefix+nonce)
                        if path.is_dir():
                            shutil.rmtree(path)


if __name__ == "__main__":
    unittest.main()
