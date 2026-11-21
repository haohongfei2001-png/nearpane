import fcntl
import importlib
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid
from unittest.mock import patch

recovery = importlib.import_module("p4-wordbook-recovery")


class SeededWordRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.active = self.root / "generations" / str(uuid.uuid4())
        self.support = self.active / "Nearpane"
        self.support.mkdir(parents=True)
        (self.root/"profile-index.json").write_text(json.dumps({"format":1,"active":self.active.name}))
        (self.active/"profile.version").write_bytes(b"Nearpane P5.3\n")
        (self.root/"writer.lock").touch(mode=0o600)

    def test_exclusive_new_wordbook_cannot_replace_an_existing_or_symlinked_file(self):
        path = self.support/recovery.NOTE
        recovery.seed_unused(self.root,self.active,b"first")
        self.assertEqual(recovery.plain(path),b"first")
        with self.assertRaises(FileExistsError): recovery.seed_unused(self.root,self.active,b"wrong")
        self.assertEqual(path.read_bytes(),b"first")
        path.unlink()
        sentinel = self.root/"must-remain"
        sentinel.write_bytes(b"original")
        path.symlink_to(sentinel)
        with self.assertRaises(FileExistsError): recovery.seed_unused(self.root,self.active,b"another")
        self.assertEqual(sentinel.read_bytes(),b"original")
        self.assertTrue(path.is_symlink())

    def test_busy_lock_stale_index_transaction_and_old_generation_prevent_seeding(self):
        with (self.root/"writer.lock").open("rb") as lease:
            fcntl.flock(lease,fcntl.LOCK_EX)
            with self.assertRaises(BlockingIOError): recovery.seed_unused(self.root,self.active,b"wrong")
        for change in ({"previous":str(uuid.uuid4())},{"active":str(uuid.uuid4())},{"format":2}):
            (self.root/"profile-index.json").write_text(json.dumps({"active":self.active.name,"format":1,**change}))
            with self.assertRaises(ValueError): recovery.seed_unused(self.root,self.active,b"wrong")
        (self.root/"profile-index.json").write_text(json.dumps({"active":self.active.name,"format":1}))
        (self.root/"transaction.json").touch()
        with self.assertRaises(ValueError): recovery.seed_unused(self.root,self.active,b"wrong")
        self.assertFalse(os.path.lexists(self.support/recovery.NOTE))

    def test_two_host_readback_requires_exact_pid_request_answer_and_launch_time(self):
        seed = {"requestID": str(uuid.uuid4()).upper(),"answerSHA256":recovery.digest("自行车".encode())}
        def row(pid=24,kind="wordReopened",hashval=None,clock=107,ident=None):
            return json.dumps({"processID":pid,"eventMessage":(
                f'toolStage id={ident or seed["requestID"]} stage={kind} hash={hashval or seed["answerSHA256"]} uptime={clock}')})
        def state(text): return recovery.qualified_reopen(text,24,seed,103,110)["status"]
        self.assertEqual(state(row()),"PASS")
        for proof in (row(pid=25),row(clock=99),row(clock=123),row(hashval="a"*64),row(ident=str(uuid.uuid4()).upper()),
                      row()+"\n"+row(kind="serviceCallback"),row()+"\n"+row(kind="translated")):
            self.assertEqual(state(proof),"UNKNOWN")

    def test_a_different_or_unregistered_home_stops_before_launch_or_termination(self):
        with patch.dict(os.environ, {"NEARPANE_TEST_HOME":str(self.root),"NEARPANE_TEST_GENERATION":str(self.active)}), \
                patch.object(recovery,"quit_host") as quit_host, patch.object(recovery,"launch_isolated") as launch:
            receipt = recovery.run(self.root,self.root/"result","a"*40)
        self.assertEqual(receipt["status"],"BLOCKED")
        self.assertEqual(receipt["seedStatus"],"NOT_RUN")
        self.assertEqual(receipt["serviceRequests"],0)
        quit_host.assert_not_called()
        launch.assert_not_called()
