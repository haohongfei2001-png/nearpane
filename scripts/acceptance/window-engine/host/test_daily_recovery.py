import hashlib
import importlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

import installed_cycle

recovery = importlib.import_module("daily-recovery")


class DailyRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.profile = self.base / "profile"
        uid = str(uuid.uuid4())
        self.generation = self.profile / "generations" / uid
        self.generation.mkdir(parents=True)
        (self.profile / "profile-index.json").write_text(json.dumps({"active": uid}))

    def read(self):
        return recovery.inspect(self.profile, self.base, self.base / "noSharedLeaseDir", "readonly-observer")

    def test_pending_ordinary_blocks_even_if_no_live_lock_and_frame_matches(self):
        f = self.generation / "WorkRect/ordinary/journal.json"
        f.parent.mkdir(parents=True)
        frame = dict(x=12, y=33, width=1100, height=700)
        entry = dict(id=dict(pid=33, launch=44, number=55), original=frame, confirmed=frame)
        f.write_text(json.dumps(dict(version=1, status="pending", entries=[entry])))
        before = f.read_bytes()
        with patch.object(recovery.subprocess, "check_output", return_value=b"[{},{}]"):
            self.assertFalse(self.read()["quitPermitted"])
        self.assertEqual(before, f.read_bytes())

    def test_stage_owner_and_interrupted_spaces_write_block_quit(self):
        self.assertTrue(self.read()["quitPermitted"])
        ledger = self.generation / "Nearpane/stage-visibility-v1.json"
        ledger.parent.mkdir()
        ledger.write_text(json.dumps(dict(version=1, owned=[], owner={"epoch": 7})))
        self.assertFalse(self.read()["quitPermitted"])
        ledger.write_text(json.dumps(dict(version=1, owned=[])))
        crash = self.base / "Nearpane-Spaces-Verification/active.jsonl"
        crash.parent.mkdir()
        crash.touch()
        self.assertFalse(self.read()["quitPermitted"])

    def test_qualified_roster_and_clear_ownership_are_both_required(self):
        gate = dict(roster=dict(complete=True, session=dict(qualified=True), pids=[59938]),
                    leases=dict(quitPermitted=True))
        self.assertTrue(installed_cycle.admit_daily(gate, 59938))
        self.assertFalse(installed_cycle.admit_daily(gate, 12))
        gate["leases"]["quitPermitted"] = False
        self.assertFalse(installed_cycle.admit_daily(gate, 59938))

    def test_unknown_candidate_or_fixture_blocks_reverse_exchange(self):
        tx = SimpleNamespace(out=self.base, rec={"engineProbeIntended": True, "trials": {"WindowEngine": {}}})
        self.assertFalse(installed_cycle.resources_clear(tx))
        f = self.base / "window-engine.json"
        for clear, expected in ((False, False), (True, True)):
            f.write_text(json.dumps(dict(probeResourcesClear=clear, safeToRollback=clear,
                                         probeResources=dict(clear=clear))))
            tx.rec["trials"]["WindowEngine"]["sha256"] = hashlib.sha256(f.read_bytes()).hexdigest()
            self.assertEqual(expected, installed_cycle.resources_clear(tx))
        f.write_text(f.read_text() + " ")
        self.assertFalse(installed_cycle.resources_clear(tx))
