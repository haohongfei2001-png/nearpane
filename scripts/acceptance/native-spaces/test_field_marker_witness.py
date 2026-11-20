"""Isolated marker attribution. All product and fixture events are mocked or held in memory."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

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

    def test_ordinary_keys_distinguish_no_app_event_unattributed_partial_and_complete(self):
        w=MarkerWatch(self.folder,str(uuid.uuid4()),str(uuid.uuid4()),71,900,[321,322],322,"012345678912","1"*40,
                      transport="pidNumericKeypad")
        base=dict(mode="pidNumericKeypad",posterBound=True,attributedDown=0,attributedUp=0,
                  unattributedDown=0,unattributedUp=0,sequenceMatches=False,physicalSuperseded=False,overflow=False)
        end=dict(step="end",clock=1,key=322,main=322,active=True,marked=[False,False],responders=[True,True])
        w.sender={"postedDown":1}
        for change,expect in [({},"NO_APPKIT_KEY_SEEN_DURING_REGISTERED_DELIVERY"),({"unattributedDown":1},"APP_SAW_ONLY_UNATTRIBUTED_KEYS"),
                              ({"attributedDown":1},"PARTIAL_REGISTERED_SEQUENCE"),({"posterBound":False},"LIVE_SENDER_ENROLLMENT_UNCONFIRMED"),
                              ({"attributedDown":12,"attributedUp":12,"sequenceMatches":True},"COMPLETE_REGISTERED_SEQUENCE"),
                              ({"physicalSuperseded":True},"SUPERSEDED")]:
            valid={**w.identity,"status":"SEALED","events":[end],"truncated":False,"keyDelivery":base|change}
            self.assertEqual(w.validate(valid),valid)
            with patch.object(w,"wait",return_value=valid):
                self.assertEqual(w.seal()["receiverDisposition"],expect)
            self.assertIsNone(w.validate(valid|{"keyDelivery":dict(base,rawText="unexpected")}))

    def test_real_quartz_key_construction_without_posting(self):
        src=Path(__file__).resolve().parent
        binary=self.folder/"pure-keypad"
        subprocess.run(["xcrun","swiftc",src/"p2-keypad.swift",src/"test_p2_keypad.swift","-o",binary],check=True,timeout=45)
        result=json.loads(subprocess.check_output([binary],timeout=5))
        self.assertTrue(result["sequenceMatches"])
        self.assertEqual((result["attributedDown"],result["attributedUp"],result["unattributedDown"]),(12,12,1))

    def test_in_memory_quartz_tag_and_digest(self):
        root=Path(__file__).resolve().parent
        binary=self.folder/"pure-marker"
        subprocess.run(["xcrun","swiftc",root/"field-marker-witness.swift",root/"test_field_marker_tag.swift","-o",binary],check=True,timeout=45)
        wire=json.loads(subprocess.check_output([binary],timeout=5))
        enrolled=MarkerWatch(self.folder,wire["session"],wire["intent"],21,89,[45,46],46,self.marker,"1"*40)
        self.assertEqual(enrolled.validate(wire),wire)
        self.assertIsNone(enrolled.validate({**wire,"readerHash":"2"*40}))


if __name__ == "__main__":
    unittest.main()
