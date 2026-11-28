"""Offline admission and geometry replay. Never launches, fronts or controls a macOS app."""
from contextlib import ExitStack
import copy
import json
import os
import plistlib
import subprocess
import time
import uuid
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import cross_app_pair as cross

ROOT = Path(__file__).resolve().parents[3]
RECEIPT = ROOT/"engineering/verification/native-spaces/5.22-90-sidebar-pair/binding-drag/pair-pointer.json"
ACTIONS = RECEIPT.with_name("actions.jsonl")


class CrossApplicationPairTests(unittest.TestCase):
    def setUp(self):
        previous = json.loads(RECEIPT.read_bytes())["drags"]["right"]
        self.posted = next(r["proof"] for r in map(json.loads,ACTIONS.read_text().splitlines())
                           if r.get("event")=="pair-pointer-system-proof" and r.get("kind")=="right")
        # Preserve the actual tagged packet and geometry. These two owners are synthetic.
        self.owners = [dict(slot=i,pid=80+i,birth=100+i,number=n,identifier=cross.TOOLS[f"Five Notes {i+1}.app"],hash=str(i)*40)
                       for i,n in enumerate(previous["before"]["members"])]
        self.anchor = {**previous["before"],"owners":self.owners}
        self.posted["geometry"]["owners"]=self.owners
        self.reads = [dict(frame,owners=self.owners,leaseState="BOUND") for frame in previous["after"]]
        self.expected=previous["expected"]

    def verdict(self):
        return cross.right_evidence(self.posted,self.reads,self.expected,self.owners,self.anchor)

    def test_two_distinct_live_sources_and_two_exact_repeated_frames(self):
        self.assertTrue(self.verdict())

    def test_old_one_process_trial_does_not_supply_cross_app_proof(self):
        self.owners[1]["pid"]=self.owners[0]["pid"]
        self.assertFalse(self.verdict())

    def test_owner_relaunch_in_post_read(self):
        self.reads[-1]["owners"]=copy.deepcopy(self.owners)
        self.reads[-1]["owners"][0]["birth"]+=1
        self.assertFalse(self.verdict())

    def test_window_reuse_or_same_bundle_rejected(self):
        for field in ("identifier","number","hash"):
            with self.subTest(field=field):
                original=self.owners[1][field]
                self.owners[1][field]=self.owners[0][field]
                self.assertFalse(self.verdict())
                self.owners[1][field]=original

    def test_unissued_missing_route_missing_samples_or_physical_disagreement(self):
        for key,value in (("issued",None),("status","BLOCKED"),("hostRouting",{"status":"UNAVAILABLE"})):
            with self.subTest(field=key):
                original=self.posted.get(key)
                self.posted[key]=value
                self.assertFalse(self.verdict())
                self.posted[key]=original
        self.reads[1]["ax"]=list(reversed(self.reads[1]["ax"]))
        self.assertFalse(self.verdict())
        self.reads.pop()
        self.assertFalse(self.verdict())

    def test_cleanup_exact_two_kernel_generations_no_force(self):
        with tempfile.TemporaryDirectory() as t:
            items=[]
            for owner in self.owners:
                path=Path(t)/str(owner["slot"]);path.mkdir()
                launch=Mock();launch.poll.return_value=0
                items.append(dict(slot=owner["slot"],pid=owner["pid"],birth=owner["birth"],identifier=owner["identifier"],
                                  folder=path,launcher=launch))
            with patch.object(cross,"kernel",side_effect=[{"pid":80,"absent":True},{"pid":81,"birth":999}]):
                result=cross.retire(Path(t),items)
            self.assertEqual(result["status"],"PASS")
            for item in items:
                self.assertTrue((item["folder"]/"close").exists())
                self.assertFalse(item["launcher"].terminate.called or item["launcher"].kill.called)
            self.assertFalse(cross.cleared(items[0],{"pid":80,"birth":100}))
            self.assertFalse(cross.cleared(items[0],{"pid":30,"absent":True}))


    def test_host_files_private_root_owner_modes_links_and_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp).resolve()
            index = profile / "profile-index.json"
            index.write_text('{"active":"a"}')
            for mode in (0o600,0o640,0o644):
                index.chmod(mode)
                proof=[]
                self.assertEqual(cross.host_profile_json(profile,index.name,128,proof)["active"],"a")
                self.assertEqual((proof[0]["permissions"],proof[0]["uid"],proof[0]["links"]),
                                 (f"{mode:04o}",os.getuid(),1))
            for bad in (0o666,0o664,0o744):
                index.chmod(bad)
                with self.assertRaisesRegex(cross.TrialStop,"unsafeHostProfileDocument"):
                    cross.host_profile_json(profile,index.name,128,[])
            index.chmod(0o644)
            with self.assertRaisesRegex(cross.TrialStop,"unsafeHostProfileDocument"):
                cross.host_profile_json(profile,index.name,2,[])
            sibling=profile/"other"
            os.link(index,sibling)
            with self.assertRaisesRegex(cross.TrialStop,"unsafeHostProfileDocument"):
                cross.host_profile_json(profile,index.name,128,[])
            index.unlink()
            index.symlink_to(sibling)
            with self.assertRaises(OSError):
                cross.host_profile_json(profile,index.name,128,[])
            index.unlink()
            sibling.rename(index)
            profile.chmod(0o755)
            with self.assertRaisesRegex(cross.TrialStop,"hostProfileRootNotPrivate"):
                cross.host_profile_json(profile,index.name,128,[])

    def test_complete_two_process_transaction_and_unacknowledged_drop_never_replayed(self):
        for lost in (False, True):
            with self.subTest(lost=lost), tempfile.TemporaryDirectory() as raw, ExitStack() as stack:
                root = Path(raw).resolve()
                profile = root / cross.PROFILE
                generation = profile / "generations" / str(uuid.uuid4())
                (generation / "Nearpane").mkdir(parents=True)
                profile.chmod(0o700)
                index = profile/"profile-index.json"
                index.write_text(json.dumps({"active": generation.name}))
                index.chmod(0o644)
                cfg = generation/"Nearpane/host-configuration.json"
                cfg.write_text('{"edge":"right"}')
                cfg.chmod(0o644)
                app = root/"Candidate.app"
                (app/"Contents").mkdir(parents=True)
                revision = "e"*40
                (app/"Contents/Info.plist").write_bytes(plistlib.dumps(
                    {"NearpaneSourceRevision":revision,"CFBundleVersion":"90","NearpaneSourceState":"clean"}))
                hw = [11]*13
                ws = Mock()
                ws.host = {"pid":9,"codeHash":"c"*40}
                ws.host_birth = 900
                ws.display = self.anchor["displayUUID"]
                ws.hid = hw[:5]
                ws.hardware.return_value = ws.hid
                ws.read.return_value = {"frontmostPID":9,"host":ws.host}
                ws.ids.return_value = [71]
                ws.check.return_value = {"current":71}
                stack.enter_context(patch.dict(os.environ, {"NEARPANE_TEST_HOME":str(root),"NEARPANE_TEST_GENERATION":str(generation)}))
                stack.enter_context(patch.object(cross,"APP",app))
                stack.enter_context(patch.object(cross,"validate_home",return_value=None))
                stack.enter_context(patch.object(cross,"signed_kit",return_value={name:str(i)*40 for i,name in enumerate(cross.TOOLS)}))
                stack.enter_context(patch.object(cross,"owns_profile",return_value=True))
                stack.enter_context(patch.object(cross,"kernel",side_effect=lambda _,pid: {"pid":pid,"birth":900} if pid==9 else {"pid":pid,"absent":True}))
                outbound = []
                fixtures = []
                def open_fixture(arguments,**kwargs):
                    folder=Path(arguments[-2])
                    slot=len(fixtures)
                    ident=cross.TOOLS[f"Five Notes {slot+1}.app"]
                    fixture=dict(session=folder.name,slot=slot,pid=80+slot,birth=100+slot,bundle=ident,
                                 policy=0,displayCount=1,phase=0,numbers=[self.owners[slot]["number"]],
                                 presentation="five-preview",visible=[True],minimized=[False])
                    for name in ("startup","windows"):
                        (folder/(name+".json")).write_text(json.dumps(fixture))
                    fixtures.append(fixture)
                    launch=Mock(); launch.poll.return_value=0
                    return launch
                stack.enter_context(patch.object(cross.subprocess,"Popen",side_effect=open_fixture))
                def packet(argv,**kwargs):
                    data=json.loads(kwargs["input"])
                    kind=data["operation"]
                    owners=data["run"]["owners"]
                    initial=self.anchor["cg"][:len(owners)]
                    final=self.expected if outbound else initial
                    geometry={**self.anchor,"owners":owners,"members":[o["number"] for o in owners],"clock":time.monotonic(),
                              "leaseState":"BOUND","cg":final,"ax":final}
                    if kind=="right":
                        outbound.append(kind)
                        if lost:
                            raise subprocess.TimeoutExpired(argv,13)
                        proof={**self.posted,"geometry":geometry}
                    else:
                        proof={"status":"READ","issued":False,"hardware":hw,"foregroundPID":9,"geometry":geometry}
                        if outbound and lost:
                            proof={"status":"BLOCKED","reason":"foregroundLeftEnrollment","issued":False}
                    return subprocess.CompletedProcess(argv,0,stdout=json.dumps(proof))
                stack.enter_context(patch.object(cross.subprocess,"run",side_effect=packet))
                answer=cross.run(root,root/"out",ws,71,str(uuid.uuid4()),revision)
                self.assertEqual(outbound,["right"])
                self.assertEqual([i["pid"] for i in answer["cleanup"]["fixtures"]],[80,81])
                self.assertEqual(answer["cleanup"]["status"],"PASS")
                self.assertEqual(answer["status"],"UNKNOWN" if lost else "PASS",answer.get("reason"))
                self.assertIs(answer["issued"],None if lost else True)


if __name__=="__main__":
    unittest.main()
