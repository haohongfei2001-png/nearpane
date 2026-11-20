"""Isolated marker attribution. All product and fixture events are mocked or held in memory."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

import acceptance as ac
from field_marker_witness import MarkerWatch


class MarkerWitnessTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name).resolve()
        self.marker = "NP123456789a"
        self.watch = MarkerWatch(self.folder, str(uuid.uuid4()), str(uuid.uuid4()), 71, 900, [321,322], 322, self.marker, "1"*40)

    def test_only_enrolled_digest_and_scoped_numbers_export(self):
        w = self.watch
        event = dict(step="editorKeyDown", clock=13.1, active=True, key=322, main=322, marked=[False,False],
                     responders=[True,True], markerMatches=True, eventWindow=322, receiver=322,eventClock=13.)
        valid = {**w.identity, "status":"ARMED","events":[event],"truncated":False}
        self.assertEqual(w.validate(valid), valid)
        for change in ({"intent":str(uuid.uuid4())}, {"raw":"private"}, {"events":[dict(event, value="private")]},
                       {"events":[dict(event, eventWindow=1024)]}, {"events":[dict(event, marked=[True])]},{"events":[event]*65}):
            self.assertIsNone(w.validate({**valid,**change}))
        w.command("arm")
        wire = (self.folder/"marker-watch-command.json").read_text()
        self.assertNotIn(self.marker, wire)
        self.assertEqual(os.stat(self.folder/"marker-watch-command.json").st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(wire)["grant"]["target"], 322)

    def test_seal_cannot_assert_delivery_without_matching_reader_and_receiver_proof(self):
        w = self.watch
        w.submitted()
        self.assertEqual(w.sender["status"],"REPLY_UNKNOWN")
        raw = dict(issued=True, tagged=True, targetedOnly=True, axFocusedWindow=322, markerDigest=w.identity["digest"], beforePost=1,afterPost=2)
        for change in ({"markerDigest":"bad"},{"axFocusedWindow":321},{"tagged":False}):
            self.assertFalse(w.dispatched({**raw,**change}))
        self.assertTrue(w.dispatched(raw))
        with patch.object(w,"wait",return_value=None):
            result=w.seal()
        self.assertFalse(result["closureConfirmed"])
        self.assertEqual((result["status"],result["sender"]["status"],result["events"]),("NO_ACK","TAGGED_POST",[]))

    def exercise_standard(self, enabled, armed=True):
        rec=Mock(); rec.attempts=[]; rec.summary={}
        observer=self.folder/"observe"; host={"pid":41,"codeHash":"hash"}
        base=dict(observerAX=True,displays=[1],scopes=[{"current":1,"scope":"Main","records":[{"id":1,"type":0}]}],
                  host=host,frontmostPID=11,focusedNumber=88)
        frozen=dict(signatureValid=True,loadedMatchesInstalled=True,source="fixed")
        proc=Mock(pid=71,returncode=0)
        outcomes=[{"session":"test","pid":71,"birth":900,"numbers":[321,322]}, {"pid":71,"key":321}, {"sha256":["a","b"]},
                  {"pid":71,"key":322}, {}]
        calls=[]
        def checked(cmd, **kwargs):
            if len(cmd)==1:
                front=11 if not any(x[0]=="marker" for x in calls) or any(x[0]=="marker" and x[1]=="322" for x in calls) else 71
                return json.dumps({**base,"frontmostPID":front})
            if cmd[1]=="absence":
                return '{"allGone":true}'
            mode=cmd[1]; target=cmd[5]; env=kwargs.get("env",{})
            calls.append((mode,target,env.get("NP_TRIAL_MARKER_TAG"),env.get("NP_TRIAL_MARKER")))
            if mode=="marker" and env.get("NP_TRIAL_MARKER_TAG"):
                import hashlib
                return json.dumps(dict(issued=True,tagged=True,targetedOnly=True,axFocusedWindow=int(target),
                                       markerDigest=hashlib.sha256(env["NP_TRIAL_MARKER"].encode()).hexdigest(),beforePost=1,afterPost=2))
            return '{"issued":true,"axError":0}'
        with patch.dict(os.environ, {"NP_W01_MARKER_WITNESS":"1" if enabled else "0","NP_TRIAL_MARKER_TAG":"unbound"}), \
             patch.object(ac,"identity",return_value={"CDHash":"fixture"}), patch.object(ac.subprocess,"Popen",return_value=proc), \
             patch.object(ac,"checked",side_effect=checked), patch.object(ac,"wait_state",side_effect=outcomes), \
             patch.object(ac.time,"sleep"),patch.object(ac,"selection_logs",return_value=[]), \
             patch.object(MarkerWatch,"arm",return_value=armed),patch.object(MarkerWatch,"seal",return_value=dict(status="SEALED",closureConfirmed=True,events=[])):
            reason=ac.controlled_window(observer,base,frozen,rec,2)
        return reason,calls,rec

    def test_two_normal_marker_submissions_preserve_the_second_fail_through_the_ordinary_entry(self):
        for enabled in [False,True]:
            with self.subTest(enabled=enabled):
                reason,calls,receipt=self.exercise_standard(enabled)
                self.assertIn("discrepancy",reason)
                self.assertEqual([(m,n) for m,n,*_ in calls],[("press","321"),("marker","321"),("press","322"),("marker","322")])
                markers=[c for c in calls if c[0]=="marker"]
                self.assertNotEqual(markers[0][3],markers[1][3])
                self.assertEqual([bool(c[2]) for c in markers],[enabled,enabled])
                self.assertEqual([a["status"] for a in receipt.attempts],["PASS","FAIL"])
                self.assertEqual(receipt.write.call_count,2 if enabled else 0)

    def test_unarmed_witness_sends_nothing(self):
        reason,calls,rec=self.exercise_standard(True,armed=False)
        self.assertIn("did not arm",reason)
        self.assertEqual((calls,rec.attempts),([],[]))

    def test_in_memory_quartz_tag_and_digest(self):
        root=Path(__file__).resolve().parent
        binary=self.folder/"pure-marker"
        subprocess.run(["xcrun","swiftc",root/"field-marker-witness.swift",root/"test_field_marker_tag.swift","-o",binary],check=True,timeout=45)
        subprocess.run([binary],check=True,timeout=5)


if __name__ == "__main__":
    unittest.main()
