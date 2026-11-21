"""Replay APFS exchanges in a private directory. The Host and Launch Services are simulated."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
spec = importlib.util.spec_from_file_location("installation_replay",HERE/"private-installed-trials.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class Fixture:
    def __init__(self, base):
        self.root = base/"journal"
        self.canonical = base/"Applications/Nearpane.app"
        self.daily = base/"daily"
        (self.daily).mkdir()
        (self.daily/tool.LOCK_FILE).touch(mode=0o600)
        self.base = base
        self.source = base/"staging/Nearpane.app"
        for path,label in ((self.canonical,"old"),(self.source,"new")):
            (path/tool.HOST).parent.mkdir(parents=True)
            (path/tool.HOST).write_text(label)
        self.config_value = digest("unchanged daily config")
        self.generation = None
        self.next_id = 77
        self.active = (self.next_id,self.daily)
        self.actions = []
        self.before_trial = lambda _:None
        self.foreign = False
        self.ownpid = os.getpid()
        self.publisher_fd = -1

    def config(self):
        return {"index":digest("daily index"),"configuration":self.config_value}

    def inspect(self,path,expected):
        content = (path/tool.HOST).read_text()
        index = {"old":"a","new":"c"}[content]
        cd = {"old":"b","new":"d"}[content]
        if expected != {"source":index*40,"cdhash":cd*40}:
            raise ValueError("Unrecognized signature")
        return dict(expected,version="5.22",build="90",tree=tool.public_tree(path),root=tool.inode(path),host=tool.inode(path/tool.HOST))

    def new_home(self):
        home = Path(tempfile.mkdtemp(dir=self.base))/"home"
        home.mkdir(mode=0o700)
        return home

    def verify_home(self, home):
        tool.owned_dir(home)
        if home.parent.parent != self.base:
            raise ValueError("unexpected home")

    def pid(self):
        return None if self.active is None else self.active[0]

    def bound(self,pid,root,expected):
        if self.foreign or self.active != (pid,root) or tool.inode(self.canonical/tool.HOST) != expected["host"]:
            raise ValueError("Unexpected owner")
        return [pid, pid*10, 7]

    def stage(self,source,slot):
        shutil.copytree(source,slot)

    def quit(self, stamp):
        assert self.active[0] == stamp[0]
        self.actions.append("quit-"+("daily" if self.active[1] == self.daily else "isolated"))
        self.active = None

    def wait_stopped(self,paths):
        if self.active is not None:
            raise RuntimeError("Running process")

    def clear(self,lock,allowed):
        if self.foreign:
            raise ValueError("Foreign lock owner")
        if lock == self.daily/tool.LOCK_FILE:
            with open(lock,"rb") as fd:
                try:
                    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                except BlockingIOError:
                    assert allowed == {self.ownpid}
                else:
                    assert not allowed
        elif self.active is not None and self.active[1] == lock.parent:
            raise ValueError("Isolated fixture still active")

    def isolated(self,home):
        assert self.active is None and (self.canonical/tool.HOST).read_text() == "new"
        root = home/tool.profile.PROFILE
        root.mkdir(parents=True)
        (root/tool.LOCK_FILE).touch(mode=0o600)
        self.generation = root/"generations"/str(uuid.uuid4())
        self.generation.mkdir(parents=True)
        self.next_id += 1
        self.active = self.next_id,root
        self.actions.append("launch-isolated")
        return self.next_id,self.generation

    def verify_generation(self,home,generation):
        assert generation == self.generation and generation.parent.parent == home/tool.profile.PROFILE

    def open_daily(self):
        assert self.active is None and (self.canonical/tool.HOST).read_text() == "old"
        self.clear(self.daily/tool.LOCK_FILE,set())
        self.next_id += 1
        self.active = self.next_id,self.daily
        self.actions.append("launch-daily")

    def wait_launch_resolution(self,root):
        return self.pid()

    def wait_owner(self,root,expected):
        return self.bound(self.pid(),root,expected)

    def permissions(self,stamp,root,expected,metrics):
        assert self.bound(stamp[0],root,expected)==stamp
        self.actions.append("installed-permissions")
        return {"status":"OBSERVED","screen":True,"accessibility":False,"postEvent":True}

    def trial(self,name,rec,env,guard):
        assert self.active[1] == Path(env["NEARPANE_TEST_HOME"])/tool.profile.PROFILE
        assert self.generation == Path(env["NEARPANE_TEST_GENERATION"])
        self.clear(self.daily/tool.LOCK_FILE,{self.ownpid})
        self.actions.append(name)
        self.before_trial(name)
        if name == "P4":
            self.next_id += 1
            self.active = self.next_id,self.active[1]
        return {"status":"BLOCKED" if name == "P3" else "PASS"}


@unittest.skipUnless(sys.platform == "darwin","requires Darwin APFS renamex_np")
class TestTemporaryInstall(unittest.TestCase):
    def test_background_install_and_restore_do_not_request_the_settings_window(self):
        for options in [[], ["--env", "CFFIXED_USER_HOME=/tmp/enrolled"]]:
            with patch.object(tool.profile.subprocess, "run") as launch:
                tool.profile.launch_background(Path("/Applications/Nearpane.app"), options)
            self.assertEqual(launch.call_args.args[0], ["/usr/bin/open", "-g", *options,
                                                      "/Applications/Nearpane.app", "--args", "--background"])

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.mac = Fixture(self.base)
        metrics = self.base/"metrics"
        metrics.touch(mode=0o700)
        kit = self.base/"kit"
        (kit/"Nearpane Tool Fixture.app").mkdir(parents=True)
        (kit/"tool-selection").touch(mode=0o700)
        self.args = argparse.Namespace(action="run",candidate=self.mac.source,output=self.base/"receipts",
                                      original_source="a"*40,original_cdhash="b"*40,candidate_source="c"*40,
                                      candidate_cdhash="d"*40,metrics=metrics,kit=kit,sessions=self.base/"sessions",
                                      wordbook_driver=None,wordbook_kit=None)
        self.original = tool.inode(self.mac.canonical)
        self.executable = tool.inode(self.mac.canonical/tool.HOST)

    def prepare(self):
        tool.owned_dir(self.mac.root,create=True)
        return tool.Transaction.prepare(self.mac,self.args)

    def recover(self):
        return tool.supervise(self.mac,argparse.Namespace(action="recover"),lambda:0)

    def test_existing_window_recovery_stops_in_place_before_staging_or_quit(self):
        self.args.only = "window-engine"
        with patch.object(tool.window_engine_trial(), "prepare", return_value={"status": "BLOCKED"}):
            r = tool.supervise(self.mac, self.args, lambda: 0)
        self.assertEqual(r["stage"], "daily-preflight-blocked")
        self.assertEqual(self.mac.actions, [])
        self.assertEqual(tool.inode(self.mac.canonical), self.original)
        self.assertFalse((self.mac.root/"active.json").exists())

    def test_engine_unknown_after_swap_preserves_both_bundles_and_never_launches_daily(self):
        tx = self.prepare()
        tx.rec.update(trialScope="window-engine", engineWork=str(self.base), trials={"WindowEngine": {"status": "NOT_RUN"}})
        probe = tool.window_engine_trial()
        def gate(*_):
            return dict(roster=dict(complete=True, session=dict(qualified=True),
                                    pids=[self.mac.pid()] if self.mac.pid() else []), leases=dict(quitPermitted=True))
        def interrupted(trial):
            trial.save("running-installed-window-engine", engineProbeIntended=True)
        with patch.object(probe, "census_and_recovery", side_effect=gate), patch.object(probe, "stamp_is_gone", return_value=True), patch.object(probe, "run", side_effect=interrupted):
            try:
                tx.forward(lambda: 0)
                with self.assertRaisesRegex(ValueError, "cleanup receipt outstanding"):
                    tx.restore()
                self.assertEqual(tool.inode(tx.slot), self.original)
                self.assertIsNone(self.mac.pid())
                self.assertNotIn("launch-daily", self.mac.actions)
            finally:
                tx.release_daily()

    def test_both_trials_separate_real_swaps_exact_original_and_profile(self):
        record = tool.supervise(self.mac,self.args,lambda:0)
        self.assertEqual(self.mac.actions,["quit-daily","launch-isolated","P3","P4","quit-isolated","launch-daily"])
        self.assertEqual(record["restoration"],"PASS")
        self.assertEqual(record["cleanup"],"PASS")
        self.assertFalse(Path(record["home"]).exists())
        self.assertEqual(record["trials"]["P3"],{"status":"BLOCKED"})
        self.assertEqual(record["trials"]["P4"],{"status":"PASS"})
        self.assertEqual(record["isolatedHost"][0]+1,record["lastIsolatedHost"][0])
        self.assertEqual(tool.inode(self.mac.canonical),self.original)
        self.assertEqual(tool.inode(self.mac.canonical/tool.HOST),self.executable)
        self.assertEqual(tool.read_json(self.mac.root/"active.json"),tool.read_json(self.args.output/"installation.json"))
        # Terminal recover cannot reopen an app the user intentionally closed after the test.
        self.mac.active = None
        self.assertEqual(self.recover()["restoration"],"PASS")
        self.assertIsNone(self.mac.pid())

    def test_wordbook_has_its_own_enrolled_home_after_both_cases_and_restores(self):
        self.args.wordbook_driver = self.base/"p4-wordbook-recovery.py"
        self.args.wordbook_driver.touch()
        self.args.wordbook_kit = self.args.kit
        record = tool.supervise(self.mac,self.args,lambda:0)
        self.assertNotEqual(record["home"],record["wordbookHome"])
        self.assertTrue(record["wordbookHostGeneration"].startswith(record["wordbookHome"]+"/"))
        self.assertEqual(self.mac.actions,["quit-daily","launch-isolated","P3","P4","quit-isolated",
                                           "launch-isolated","P4-wordbook","quit-isolated","launch-daily"])
        self.assertEqual(record["restoration"],"PASS")

    def test_p4_service_only_gets_one_installed_permission_read_and_one_trial(self):
        self.args.only="p4-service"
        report=tool.supervise(self.mac,self.args,lambda:0)
        self.assertEqual(list(report["trials"]),["P4"])
        self.assertEqual(self.mac.actions,["quit-daily","launch-isolated","installed-permissions","P4","quit-isolated","launch-daily"])
        permissions=tool.read_json(self.args.output/"host-permissions.json")
        self.assertEqual(permissions["status"],"OBSERVED")
        self.assertFalse(permissions["accessibility"])
        self.assertEqual(permissions["pid"],report["isolatedHost"][0])
        self.assertEqual(permissions["sourceRevision"],report["candidate"]["source"])
        self.assertEqual(report["restoration"],"PASS")

    def test_scoped_p3_and_service_share_one_registered_home_skip_wordbook_and_restore(self):
        self.args.only="p3,p4"
        report=tool.supervise(self.mac,self.args,lambda:0)
        self.assertEqual(list(report["trials"]),["P3","P4"])
        self.assertEqual(self.mac.actions,["quit-daily","launch-isolated","installed-permissions","P3","P4","quit-isolated","launch-daily"])
        self.assertEqual(report["trials"]["P3"]["status"],"BLOCKED")
        self.assertEqual(report["trials"]["P4"]["status"],"PASS")
        self.assertNotIn("wordbookHome",report)
        self.assertEqual(report["restoration"],"PASS")
        self.assertEqual(report["cleanup"],"PASS")

    def test_missing_installed_permission_response_remains_unknown_and_services_still_runs(self):
        self.args.only="p4-service"
        def missing(*args):
            self.mac.actions.append("installed-permissions")
            raise RuntimeError("nonce not observed")
        self.mac.permissions=missing
        report=tool.supervise(self.mac,self.args,lambda:0)
        self.assertEqual(report["hostPermissions"]["status"],"UNKNOWN")
        self.assertNotIn("screen",report["hostPermissions"])
        self.assertEqual(self.mac.actions.count("installed-permissions"),1)
        self.assertEqual(report["trials"],{"P4":{"status":"PASS"}})
        self.assertEqual(report["restoration"],"PASS")

    def test_registered_focus_runs_alone_under_the_same_protected_installation(self):
        self.args.only = "p2"
        (self.args.kit / "system-workspace").touch()
        lease = self.base / "focus-lease.json"
        self.args.focus_lease = lease
        inputs = {key: str(self.args.kit) for key in ("workspace", "documentKit", "originalCheckout")}
        for key in ("originArchive", "dailyArchive", "signingChain"):
            target = self.base / key
            target.touch()
            inputs[key] = str(target)
        inputs["expectedSpace"] = 45
        tool.persist(lease, inputs)
        report = tool.supervise(self.mac, self.args, lambda: 0)
        self.assertEqual(self.mac.actions, ["quit-daily","launch-isolated","installed-permissions","P2","quit-isolated","launch-daily"])
        self.assertEqual(report["hostPermissions"]["status"], "OBSERVED")
        self.assertFalse(report["hostPermissions"]["accessibility"])
        self.assertEqual(report["focusLease"], inputs)
        self.assertEqual(report["restoration"], "PASS")
        self.assertEqual(report["cleanup"], "PASS")
        self.assertNotIn("wordbookHome", report)

    def test_focus_rejects_an_unenrolled_desktop_before_any_installation(self):
        from unittest.mock import patch
        with patch.object(tool.spaces_trials, "private_file", return_value=json.dumps({
                **{key: str(self.base) for key in ("workspace","documentKit","originalCheckout","originArchive","signingChain","dailyArchive")},
                "expectedSpace": False}).encode()), self.assertRaisesRegex(ValueError, "Invalid enrolled"):
            tool.spaces_trials.focus_lease(self.base/"missing.json")

    def test_missing_original_focus_keeps_the_running_daily_host_and_skips_the_trial(self):
        tx = self.prepare()
        tx.rec.update(visitFocusLeaseKit=str(self.base), trials={"P2": {"status":"NOT_RUN"}})
        with patch("lease_visit.daily_reference", return_value=(None, {"ready":False, "reason":"originalSpaceIsNotOrdinary"})):
            tx.forward(lambda: 0)
        tx.restore()
        self.assertEqual(self.mac.actions, [])
        self.assertEqual(tx.rec["trials"]["P2"], dict(status="BLOCKED", reason="originalSpaceIsNotOrdinary",
                         entry="NOT_RUN", candidateStarted=False, productInputsBySetup=0))
        self.assertEqual(tx.rec["initialDailyHost"], tx.rec["restoredDailyHost"])
        self.assertEqual((tx.rec["restoration"], tx.rec["cleanup"]), ("PASS", "PASS"))

    def test_recover_after_atomic_swap_before_observation(self):
        tx = self.prepare()
        tx.save("swapping-to-candidate")
        self.mac.quit(tx.rec["initialDailyHost"])
        code = "import ctypes,os,signal,sys; lib=ctypes.CDLL(None); assert lib.renamex_np(os.fsencode(sys.argv[1]),os.fsencode(sys.argv[2]),2)==0; os.kill(os.getpid(),signal.SIGKILL)"
        killed = subprocess.run([sys.executable,"-c",code,tx.app,tx.slot])
        self.assertEqual(killed.returncode,-signal.SIGKILL)
        self.assertEqual(tool.inode(tx.slot),self.original)
        self.assertEqual(self.recover()["restoration"],"PASS")
        self.assertEqual(self.mac.actions,["quit-daily","launch-daily"])
        self.assertEqual(tool.inode(tx.app),self.original)

    def test_recover_after_reverse_swap_before_daily_open_and_no_trials_replayed(self):
        tx = self.prepare()
        tx.forward(lambda:0)
        self.mac.quit(self.mac.bound(self.mac.pid(),tx.test_root,tx.rec["candidate"]))
        tx.exchange("candidate")
        tx.save("launching-original",dailyLaunchIntended=True)
        tx.release_daily()  # simulate process death after durable intent, before Launch Services
        self.assertEqual(self.recover()["restoration"],"PASS")
        self.assertEqual(self.mac.actions.count("P3"),1)
        self.assertEqual(self.mac.actions.count("launch-daily"),1)

    def test_unexpected_lock_never_quit_or_swap(self):
        self.mac.foreign = True
        with self.assertRaisesRegex(ValueError,"Unexpected owner"):
            tool.supervise(self.mac,self.args,lambda:0)
        self.assertEqual(self.mac.actions,[])
        self.assertEqual(tool.inode(self.mac.canonical),self.original)

    def test_foreign_candidate_owner_withholds_rollback_until_reverified(self):
        tx = self.prepare()
        tx.forward(lambda:0)
        tx.release_daily()
        self.mac.foreign = True
        with self.assertRaisesRegex(ValueError,"Foreign lock"):
            self.recover()
        self.assertEqual(tool.inode(tx.slot),self.original)
        self.assertNotIn("quit-isolated",self.mac.actions)
        self.mac.foreign = False
        self.assertEqual(self.recover()["restoration"],"PASS")

    def test_swap_refuses_changed_slot_content(self):
        tx = self.prepare()
        (tx.slot/"changed").touch()
        with self.assertRaisesRegex(ValueError,"bytes, inode or signature"):
            self.recover()
        self.assertEqual(self.mac.actions,[])
        self.assertEqual(tool.inode(tx.app),self.original)

    def test_unrecognized_version_and_protected_output_are_refused_in_preflight(self):
        self.args.candidate_cdhash = "e"*40
        with self.assertRaisesRegex(ValueError,"signature"):
            tool.supervise(self.mac,self.args,lambda:0)
        self.args.candidate_cdhash = "d"*40
        self.args.output = self.mac.daily/"must-not-exist"
        with self.assertRaisesRegex(ValueError,"output"):
            tool.supervise(self.mac,self.args,lambda:0)
        self.assertFalse(self.args.output.exists())
        self.assertEqual(self.mac.actions,[])

    def test_signal_during_stage_records_not_run_restores_and_does_not_repeat(self):
        signals = []
        old = signal.signal(signal.SIGTERM,lambda signum,frame:signals.append(signum))
        self.addCleanup(signal.signal,signal.SIGTERM,old)
        self.mac.before_trial = lambda name: os.kill(os.getpid(),signal.SIGTERM)
        record = tool.supervise(self.mac,self.args,lambda:signals[0] if signals else 0)
        self.assertEqual(record["terminationSignal"],signal.SIGTERM)
        self.assertEqual(record["trials"]["P4"],{"status":"NOT_RUN"})
        self.assertEqual(self.mac.actions,["quit-daily","launch-isolated","P3","quit-isolated","launch-daily"])
        self.assertEqual(tool.inode(self.mac.canonical),self.original)

    def test_surviving_trial_fd_blocks_recovery_until_program_exits(self):
        tx = self.prepare()
        tx.forward(lambda:0)
        tx.release_daily()
        with tool.free_lock(tx.slot_parent/"trial.lock",create=True) as guard:
            child = subprocess.Popen([sys.executable,"-c","import sys;sys.stdin.read()"],
                                     stdin=subprocess.PIPE,pass_fds=(guard,))
        with child:
            try:
                with self.assertRaises(BlockingIOError):
                    self.recover()
            finally:
                child.communicate()
        self.assertNotIn("quit-isolated",self.mac.actions)
        self.assertEqual(self.recover()["restoration"],"PASS")

    def test_publisher_lock_and_first_trial_error(self):
        with tool.session_lock(self.mac):
            with self.assertRaises(BlockingIOError):
                tool.supervise(self.mac,self.args,lambda:0)
            fd = os.open(self.mac.canonical.parent,os.O_RDONLY|os.O_DIRECTORY)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            finally:
                os.close(fd)
        def fail_first(name):
            if name == "P3":
                raise OSError("isolated evidence unavailable")
        self.mac.before_trial = fail_first
        report = tool.supervise(self.mac,self.args,lambda:0)
        self.assertEqual(report["trials"]["P3"]["status"],"UNKNOWN")
        self.assertEqual(report["trials"]["P4"]["status"],"PASS")
        self.assertEqual(report["restoration"],"PASS")

    def test_missing_external_receipt_directory_cannot_block_exact_rollback(self):
        tx = self.prepare()
        tx.forward(lambda:0)
        tx.release_daily()
        moved = self.base/"operator-moved-output"
        self.args.output.rename(moved)
        self.args.output.mkdir(mode=0o700)
        report = self.recover()
        self.assertEqual(report["restoration"],"PASS")
        self.assertEqual(report["outputMirror"],"UNAVAILABLE")
        self.assertFalse((self.args.output/"installation.json").exists())
        self.assertEqual(tool.inode(self.mac.canonical),self.original)

    def test_actual_local_kernel_process_generation_flock_and_executable_mapping(self):
        app = self.base/"cli.app"
        host = app/tool.HOST
        host.parent.mkdir(parents=True)
        source = self.base/"hold.c"
        source.write_text("#include <sys/file.h>\n#include <stdio.h>\n#include <unistd.h>\n"
                          "int main(int n,char **v){int fd=open(v[1],O_RDWR);"
                          "if(fd<0 || flock(fd,LOCK_EX|LOCK_NB)) return 2;"
                          "puts(\"ready\");fflush(stdout);getchar();return 0;}")
        subprocess.run(["/usr/bin/xcrun","clang",source,"-o",host],check=True,capture_output=True)
        root = self.base/"cli-profile"
        root.mkdir()
        (root/tool.LOCK_FILE).touch(mode=0o600)
        with subprocess.Popen([host,root/tool.LOCK_FILE],stdin=subprocess.PIPE,stdout=subprocess.PIPE) as child:
            try:
                self.assertEqual(child.stdout.readline(),b"ready\n")
                harness = tool.Mac()
                harness.canonical = app
                harness.pid = lambda:child.pid
                stamp = harness.bound(child.pid,root,{"host":tool.inode(host)})
                self.assertEqual(stamp,tool.process_stamp(child.pid))
                self.assertFalse(tool.owner(child.pid,self.mac.daily/tool.LOCK_FILE))
            finally:
                child.communicate()

    def test_changed_daily_config_withholds_further_mutation(self):
        tx = self.prepare()
        tx.forward(lambda:0)
        tx.release_daily()
        self.mac.config_value = digest("unexpected change")
        before = list(self.mac.actions)
        with self.assertRaisesRegex(ValueError,"config changed"):
            self.recover()
        self.assertEqual(before,self.mac.actions)
        self.assertEqual(tool.inode(tx.slot),self.original)


if __name__ == "__main__":
    unittest.main()
