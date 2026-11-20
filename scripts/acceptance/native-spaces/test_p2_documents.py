"""Offline W01 behavior, including negative readbacks and relinquishing a newer foreground."""
import importlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import acceptance
import p2_documents as p2


class DocumentsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name).resolve()
        self.r = Mock(attempts=[], summary={})
        self.initial = {"scopes": [{"scope":"Main","current":9,"records":[{"id":9,"type":0}]}],
                        "host":{"pid":41,"codeHash":"code"}, "frontmostPID":23, "observerAX":True,"displays":[1]}
        self.run = p2.RegisteredRun(self.folder/"observe", self.initial, self.r, None)
        self.run.folder = self.folder
        self.numbers = [317,409]
        self.run.binding.update(pid=91, birth=1300, numbers=self.numbers)
        self.run.baseline = [0]*13

    def test_launch_enrolls_two_private_distinct_files_via_launch_services(self):
        app=self.folder/"Field Notes.app"
        with patch.object(subprocess,"Popen") as spawn:
            self.assertIs(p2.open_documents(app,self.folder),spawn.return_value)
        argv=spawn.call_args.args[0]
        self.assertEqual(argv[:6],["/usr/bin/open","-n","-g","-W","-a",str(app)])
        self.assertEqual(argv[-3:],["--args",str(self.folder),"2"])
        self.assertIn("CFFIXED_USER_HOME="+str(self.folder/"home"),argv)
        self.assertEqual(len({p2.private_file(self.folder/(s+".txt")) for s in "AB"}),2)
        self.assertEqual((self.folder/"home").stat().st_mode & 0o777,0o700)

    def test_unleased_invocation_refuses_before_launch_signing_or_input(self):
        self.r.scenarios={}
        with patch.object(p2,"static_part") as signing,patch.object(p2,"open_documents") as launch:
            self.assertEqual(self.run.run(),"verifiedExistingOrdinarySpaceLeaseRequired")
        signing.assert_not_called()
        launch.assert_not_called()
        self.assertEqual(self.r.scenarios["W01"]["status"],"BLOCKED")

    def test_positive_control_requires_independent_window_editor_and_two_file_digests(self):
        q={"status":"READ","registration":{"pid":91,"birth":1300},"numbers":self.numbers,
           "axSHA256":["a","b"],"focused":409,"main":409,"editorFocused":True}
        own=dict(pid=91,birth=1300,numbers=self.numbers,filesSaved=[True,True],sha256=["a","b"],key=409,main=409,editorsFocused=[False,True])
        def match(proof,state,disk=None):
            return p2.classify_read(proof,state,disk or ["a","b"],409,["a","b"],True)
        self.assertTrue(match(q,own))
        for bad in [dict(focused=317),dict(main=317),dict(editorFocused=False),dict(axSHA256=["x","b"])]:
            self.assertFalse(match(q|bad,own))
        for bad in [dict(pid=9),dict(birth=9),dict(numbers=self.numbers[::-1]),dict(key=317),dict(main=317),
                    dict(sha256=["x","b"]),dict(filesSaved=[True,False]),dict(editorsFocused=[True,False])]:
            self.assertFalse(match(q,own|bad))
        self.assertFalse(match(q,own,["x","b"]))

    def test_formal_entry_uses_registered_flow_and_lease_hid(self):
        with patch.object(p2.RegisteredRun,"run",autospec=True,return_value="verified") as registered, patch.object(subprocess,"Popen") as spawn:
            actual = acceptance.controlled_window(self.folder/"observe",self.initial,
                       dict(signatureValid=True, loadedMatchesInstalled=True, source="test"),self.r,2,lease_hid=[5]*5)
        self.assertEqual(actual,"verified")
        self.assertEqual(registered.call_args.args[0].lease_hid,[5]*5)
        spawn.assert_not_called()

    def simulate(self, *, drop=None, user_after=None, armed=True):
        numbers=self.numbers
        docs=[f"Field Notes {s} {self.folder.name}\n" for s in "AB"]
        calls=[]; markers=[]; focused=None
        self.seen_actions=calls; self.markers=markers
        def proof(target,hashes,stage,**kwargs):
            if [p2.digest(v.encode()) for v in docs]!=hashes or kwargs.get("focus") and focused!=target:
                raise p2.TrialStop("independent"+stage+"Unconfirmed","FAIL")
            return dict(focused=focused,cards=[True,True])
        def dispatch(mode,target,env=None,timeout=None):
            nonlocal focused
            trial=self.run.trial
            calls.append((mode,target["target"]))
            if mode=="press":
                focused=target["target"]
                reply=dict(issued=True,axError=0)
            else:
                marker=env["NP_TRIAL_MARKER"]
                markers.append(marker)
                if drop!=trial:
                    docs[numbers.index(focused)]+=marker
                reply=dict(issued=True,complete=True,tagged=True,markerDigest=p2.digest(marker.encode()),axFocusedWindow=focused)
            if user_after==(mode,trial):
                reply["userSuperseded"]=True
            return reply
        def watch(*args,**kwargs):
            item=Mock()
            item.identity={"intent":args[2]}
            item.grant={"tag":411, "expires":float("inf")}
            item.arm.return_value=armed
            item.dispatched.return_value=True
            item.seal.return_value=dict(status="SEALED",closureConfirmed=True,truncated=False,events=[],receiverDisposition="COMPLETE_REGISTERED_SEQUENCE")
            return item
        with patch.object(p2,"MarkerWatch",side_effect=watch),patch.object(self.run,"call",side_effect=dispatch),patch.object(self.run,"read_until",side_effect=proof):
            self.run.trials("f"*40)

    def test_ten_unique_single_posts_alternate_using_two_file_outcomes(self):
        self.simulate()
        self.assertEqual(self.run.out["passes"],10)
        self.assertEqual([n for op,n in self.seen_actions if op=="marker"],self.numbers*5)
        self.assertEqual([op for op,n in self.seen_actions],["press","marker"]*10)
        self.assertEqual(len(set(self.markers)),10)

    def test_first_wrong_input_receipt_preserves_previous_pass_and_stops(self):
        with self.assertRaisesRegex(p2.TrialStop,"independentInputUnconfirmed"): self.simulate(drop=2)
        self.assertEqual(self.run.out["passes"],1)
        self.assertEqual(self.seen_actions,[("press",317),("marker",317),("press",409),("marker",409)])
        self.assertEqual(len(set(self.markers)),2)

    def test_supersession_after_a_press_or_a_post_never_replays_it(self):
        for stage,expected in [("press",["press"]),("marker",["press","marker"])]:
            with self.subTest(stage=stage):
                with self.assertRaises(p2.Superseded): self.simulate(user_after=(stage,1))
                self.assertEqual([op for op,n in self.seen_actions],expected)

    def test_unarmed_receiver_has_no_actions(self):
        with self.assertRaisesRegex(p2.TrialStop,"postReceiverEnrollmentUnavailable"): self.simulate(armed=False)
        self.assertEqual(self.seen_actions,[])

    def test_interruption_checks_counter_even_if_native_refusal_has_a_different_cause(self):
        with self.assertRaises(p2.Superseded):
            p2.check_hid(dict(reason="scopeChanged",hidAfter=[0]*12+[1]),[0]*13)
        with self.assertRaises(p2.Superseded):
            p2.check_hid(dict(issued=True,userSuperseded=True),[0]*13)

    def test_cleanup_when_user_owns_fixture_front_never_closes_or_reselects(self):
        self.run.launcher=Mock()
        self.run.out["superseded"]=True
        with patch.object(self.run,"call",return_value={"status":"UNCONFIRMED","frontIsFixture":True}) as query:
            self.run.cleanup()
        self.assertTrue((self.folder/"close-when-inactive").exists())
        self.assertFalse((self.folder/"close").exists())
        self.assertEqual(self.run.out["cleanup"]["status"],"DEFERRED_UNTIL_INACTIVE")
        self.assertEqual(query.call_args.args,("exit",))
        self.run.launcher.terminate.assert_not_called()

    def test_no_repost_when_first_normal_pair_has_no_receiver(self):
        numbers=self.numbers
        replies=[dict(issued=True,axError=0),dict(issued=True,complete=False,reason="receiverPairUnconfirmed",
                                                postedDown=1,postedUp=1)]
        w=Mock(identity={"intent":"i"},grant={"tag":1,"expires":float("inf")})
        w.arm.return_value=True
        w.seal.return_value=dict(status="SEALED",closureConfirmed=True,events=[],receiverDisposition="NO_APPKIT_KEY_SEEN_DURING_REGISTERED_DELIVERY")
        with patch.object(p2,"MarkerWatch",return_value=w),patch.object(self.run,"read_until",return_value={"focused":None}), \
             patch.object(self.run,"call",side_effect=replies) as calls,patch.object(self.run,"partial_readback",return_value="FAIL"):
            with self.assertRaisesRegex(p2.TrialStop,"receiverPairUnconfirmed"):self.run.trials("f"*40)
        self.assertEqual([c.args[0] for c in calls.call_args_list],["press","marker"])
        self.assertEqual(self.r.attempts[0]["receiverDisposition"],"NO_APPKIT_KEY_SEEN_DURING_REGISTERED_DELIVERY")

    def test_single_source_screenshot_only_retained_after_exact_readback(self):
        self.initial["observerScreenRead"]=True
        files=[p2.digest(v.encode()) for v in "AB"]
        for c in "AB":
            f=self.folder/(c+".txt");f.write_text(c);f.chmod(0o600)
        state={"session":self.folder.name,"pid":91,"birth":1300,"numbers":self.numbers,"filesSaved":[True,True],"sha256":files,
               "key":317,"main":317,"editorsFocused":[True,False]}
        f=self.folder/"windows.json";f.write_text(json.dumps(state));f.chmod(0o600)
        self.r.output=self.folder
        q=dict(status="READ",screenRead=True,registration={"pid":91,"birth":1300},hostBirth=11,clock=1,hid=[0]*13,
               axSHA256=files,focused=317,main=317,editorFocused=True,numbers=self.numbers)
        import struct,zlib
        def chunk(kind,data):
            return struct.pack(">I",len(data))+kind+data+struct.pack(">I",zlib.crc32(kind+data))
        image=(b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">II5B",320,160,8,0,0,0,0))+
               chunk(b"IDAT",zlib.compress(bytes(321*160)))+chunk(b"IEND",b""))
        with self.assertRaises(ValueError):p2.capture_dimensions(image[:-4])
        def capture(argv,**_):
            self.assertEqual(argv[:-1],["/usr/sbin/screencapture","-x","-o","-t","png","-l317"])
            Path(argv[-1]).write_bytes(image)
            return Mock(returncode=0)
        with patch.object(self.run,"call",side_effect=[q,q|{"hid":[1]+[0]*12}]),patch.object(subprocess,"run",side_effect=capture):
            with self.assertRaises(p2.Superseded):self.run.capture_first(317,files)
        self.assertFalse((self.folder/"first-registered-document.png").exists())
        with patch.object(self.run,"call",side_effect=[q,q|{"clock":2}]),patch.object(subprocess,"run",side_effect=capture):
            self.run.capture_first(317,files)
        self.assertEqual(self.run.out["firstDocumentCapture"]["status"],"CAPTURED")

    def test_stale_count_or_one_error_cannot_satisfy_two_consecutive_disk_and_ax_reads(self):
        q={"status":"READ","registration":{"pid":91,"birth":1300},"numbers":self.numbers,
           "axSHA256":[p2.digest(b"A"),p2.digest(b"B")],"focused":409,"main":409,"editorFocused":True}
        own=dict(session=self.folder.name,pid=91,birth=1300,numbers=self.numbers,filesSaved=[True,True],
                 sha256=q["axSHA256"],key=409,main=409,editorsFocused=[False,True])
        for name in "AB":
            f=self.folder/(name+".txt");f.write_bytes(name.encode());f.chmod(0o600)
        f=self.folder/"windows.json";f.write_text(json.dumps(own));f.chmod(0o600)
        with patch.object(self.run,"call",side_effect=[q,dict(status="BLOCKED",reason="LSRegularAppIdentityUnavailable"),q,q]) as check:
            actual=self.run.read_until(409,q["axSHA256"],"Focus",focus=True)
        self.assertEqual(actual,q)
        self.assertEqual(check.call_count,4)
        self.assertEqual(self.run.out["registration"]["pid"],91)

    def test_new_input_during_initial_enrollment_does_not_wait_for_publication(self):
        self.run.launcher=Mock()
        with patch.object(self.run,"call",return_value={"reason":"userSuperseded"}),self.assertRaises(p2.Superseded):
            self.run.opened()
        self.run.launcher.poll.assert_not_called()

    def test_daily_guard_releases_anchor_without_reading_or_restoring_focus(self):
        guard=importlib.import_module("p0-focus").DailyFocus.__new__(importlib.import_module("p0-focus").DailyFocus)
        holder=Mock()
        guard.anchors={"original":(holder,{})}; guard.info={}; guard.file=self.folder/"focus.json"
        with patch.object(guard,"state",side_effect=AssertionError("no foreground read after supersession")):
            guard.finish(True,preserve_new_input=True)
        self.assertEqual(json.loads(guard.file.read_text())["status"],"NEWER_INPUT_PRESERVED")
        holder.finish.assert_called_once_with(False)


if __name__=="__main__":
    unittest.main()
