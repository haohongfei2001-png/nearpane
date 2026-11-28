import copy
import importlib
import json
from pathlib import Path
import unittest

from p0_system_events import SEND, typed_row

replay=importlib.import_module("p0-run18-system")
receipt=replay.P0/"post-reassessment"/"run18-system.json"


class SystemAttribution(unittest.TestCase):
    def test_real_chain_replays_and_each_link_is_required(self):
        known=json.loads(receipt.read_bytes())["rootMechanisms"]
        rows=known["events"]
        self.assertEqual(replay.replay(rows)["rootMechanisms"],known)
        for i in range(len(rows)):
            with self.subTest(missing=i):
                self.assertEqual(replay.replay(rows[:i]+rows[i+1:])["rootMechanisms"]["status"],"UNKNOWN")
        for index,key in [(2,"returnID"),(3,"previousPID"),(4,"asnLow"),(4,"window"),(5,"space")]:
            altered=copy.deepcopy(rows);altered[index][key]+=1
            self.assertEqual(replay.replay(altered)["rootMechanisms"]["status"],"UNKNOWN")
        for alternate in [dict(rows[1],pid=49),dict(rows[4],boot="OTHER")]:
            altered=list(rows)
            if "asnLow" in alternate:altered[4]=alternate
            else:altered.append(alternate)
            self.assertEqual(replay.replay(altered)["rootMechanisms"]["status"],"UNKNOWN")

    def test_filters_keep_non_activation_content_out_of_evidence(self):
        base=dict(formatString=SEND,subsystem="com.apple.appleevents",processImagePath="/usr/bin/osascript",
                  timestamp="2026-11-20 13:02:56.645975+0000",pid=4,processID=4,bootUUID="12345678-1234-1234-1234-123456789abc",machTimestamp=19)
        raw=dict(base,eventMessage="AESendMessage(misc,actv {misc,actv target='psn '[private] returnID=-4}...")
        row=typed_row(raw)
        self.assertTrue(row["systemOSAScript"])
        self.assertNotIn("private",json.dumps(row))
        self.assertIsNone(typed_row(dict(raw,eventMessage="AESendMessage(core,setd secret)")))
