#!/usr/bin/env python3
"""Exercise the acceptance verdicts with generated events. No browser, GUI, audio, or permissions."""
import importlib.util
import json
import copy
import os
import hashlib
import runpy
import uuid
from pathlib import Path
import sqlite3
import tempfile
import unittest
from contextlib import closing

spec = importlib.util.spec_from_file_location("native_acceptance", Path(__file__).with_name("native-acceptance.py"))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def event(t, **changes):
    state = dict(visible=True, layoutMatches=True, active=False, key=False, voice="standby", trayConnected=True,
                 trayCount=1, trayIDs="fixture-a", hasTranscript=True)
    state.update(changes)
    return dict(kind="sample", time=t, uptime=t, state=state)


class TransferFixture:
    def __init__(self, base):
        self.path = base/str(uuid.uuid4())
        queue = self.path/"support/Riftlet/queue.sqlite"
        queue.parent.mkdir(parents=True)
        self.db = sqlite3.connect(queue)
        self.db.executescript("CREATE TABLE assets(id,image_json,status); CREATE TABLE operations(id,asset_id,attempt,target_json,phase,created_at,updated_at,receipt_json); "
                              "CREATE TABLE upload_starts(operation_id,receipt_json,started_at);")
        a, op, inv = (str(uuid.uuid4()).upper() for _ in range(3))
        sha = "f"*64
        b = dict(session=self.path.name, nonce=str(uuid.uuid4()), process="chrome-kernel-v1:1:20:3", window="9",tab="3",
                 timeOrigin=100,assetID=a.lower(),sha256=sha,boundAt=1,expiresAt=901, url="https://chatgpt.com/c/test")
        t = dict(adapterID="chatgpt-web",surface="webChat",applicationID="com.google.Chrome",sessionID=b["process"],
                 windowID="9",tabID="3",documentID="doc",composerID="editor",draftGeneration="gen")
        identity = dict(operationID=op,assetID=a,attempt=1,assetSHA256=sha,target=t)
        commons = dict(**identity, attachmentID="doc:node-2", belongsToOriginalDraft=True, isUploading=False,hasError=False,safeToRetry=False,reason="")
        first = dict(**commons,outcome="uploadStarted",profileID="chatgpt-web-product-system-attached-20261102-v1",positiveReady=False,
                     attachmentAcceptanceEvidence=dict(version=1,profileID="chatgpt-web-product-system-start-20261102-v1",
                                                       evidenceID="start",inputCount=1,signal="attachmentAccepted"))
        final = dict(**commons,outcome="verifiedReady",positiveReady=True,profileID=first["profileID"],completionEvidence=dict(version=1,
                     kind="exactOriginalBytes",evidenceID="end",binding=dict(**identity,version=1,invocationID=inv,attachmentID="doc:node-2"),
                     originalByteCount=7,originalSHA256=sha,observedByteCount=7,observedSHA256=sha))
        image = dict(id=a,sourceKey="fixture",fileName="fixture.png",sha256=sha,byteCount=7,pixelWidth=16,pixelHeight=9,mediaType="image/png",
                     firstSeenAt=0,importedAt=0,origin="systemScreenshot")
        self.db.execute("insert into assets values(?,?,?)",(a,json.dumps(image),"used"))
        self.db.execute("insert into operations values(?,?,1,?,'succeeded',2,4,?)",(op,a,json.dumps(t),json.dumps(final)))
        self.db.execute("insert into upload_starts values(?,?,3)",(op,json.dumps(first)))
        self.db.commit()
        self.left = dict(time=1,page="document-user-turns",previews=0,previewNames=[],busy=False,
                         **{k:b[k] for k in ("session","nonce","process","window","tab","timeOrigin")})
        self.right = [dict(self.left,time=i,previews=1,previewNames=["riftlet-"+op.lower()+".png"]) for i in (5,11)]
        self.write("target-binding.json",b)
        self.write("input-claim.json",dict(session=b["session"],nonce=b["nonce"],identity=identity,invocationID=inv,claimedAt=2.5))
        self.first, self.final = first, final

    def write(self,name,value):
        (self.path/name).write_text(json.dumps(value))

    def checkpoints(self):
        self.write("browser-before.json",self.left)
        self.write("browser-after.json",self.right)

    def result(self):
        self.db.commit()
        def policy(e):
            binary = os.environ.get("NEARPANE_RECEIPT_TEST_BINARY")
            if binary:
                return native.product_receipt_policy(Path(binary),e)
            # The isolated data-suite seam; the packaging regression also runs this vector through Swift.
            return e["start"] == self.first and e["final"] == self.final
        return native.report(self.path, policy=policy)["checks"]


class RecognitionAttemptTests(unittest.TestCase):
    """Three read-only snapshots of a disposable DB created from the locked domain DDL."""
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(dir=native.ROOT/"build")
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name)/str(uuid.uuid4())
        file = self.path/"support/Nearpane/Voice/Saytile.sqlite"
        file.parent.mkdir(parents=True)
        (self.path/"summary.key").write_bytes(bytes(range(32)))
        resolver = runpy.run_path(str(native.ROOT/"scripts/prepare-domains.py"))
        pin = json.loads(resolver["LOCK"].read_text())["domains"]["saytile"]
        store = "Sources/SaytileKit/Store.swift"
        src = (resolver["cache_root"]()/resolver["key"](pin)/store).read_bytes()
        self.assertEqual(hashlib.sha256(src).hexdigest(),pin["files"][store])
        ddl = src.decode().split('private static let schema = """',1)[1].split('"""',1)[0]
        self.db = sqlite3.connect(file)
        self.addCleanup(self.db.close)
        self.db.executescript("PRAGMA foreign_keys=ON;" + ddl)
        self.r,self.a,self.b,self.old = (str(uuid.uuid4()).upper() for _ in range(4))
        self.series = [event(1),event(2,voice="speaking",recordings=[self.r]),event(3.9)]
        self.sql("INSERT INTO recordings(id,created_at,sample_rate,is_recording) VALUES(?,0,16000,0)",self.old)
        self.before = self.snap(1)
        self.sql("INSERT INTO recordings(id,created_at,sample_rate,recognition_state,active_attempt) VALUES(?,1.2,16000,'running',?)",self.r,self.a)

    def sql(self, statement, *args):
        self.db.execute(statement,args)

    def snap(self, t):
        self.db.commit()
        data = native.voice_evidence.snapshot(self.path)
        self.assertNotIn("synthetic words",json.dumps(data))
        return dict(session=self.path.name,run="events-fixture",time=t,**data)

    def session(self, ticket, t, recording=None):
        self.sql("INSERT INTO fusion_sessions(id,recording_id,audio_epoch,mode,state,created_at) VALUES(?,?,1,'highestQuality','running',?)",
                 ticket,recording or self.r,t)

    def terminal(self, ticket, state, t):
        self.sql("UPDATE fusion_sessions SET state=? WHERE id=?",state,ticket)
        self.sql("INSERT INTO fusion_session_terminals(recognition_id,state,occurred_at) VALUES(?,?,?)",ticket,state,t)

    def revision(self, ticket, t, origin="final", text="synthetic words"):
        rev = str(uuid.uuid4()).upper()
        self.sql("INSERT INTO revisions(id,recording_id,text,origin,created_at,attempt) VALUES(?,?,?,?,?,?)",rev,self.r,text,origin,t,ticket)
        self.sql("UPDATE recordings SET preferred_revision=? WHERE id=?",rev,self.r)

    def speaking(self, ticket):
        self.during = dict(self.snap(2),recording=self.r,attempt=ticket)

    def finish(self):
        self.sql("UPDATE recordings SET recognition_state='completed',active_attempt=NULL,is_recording=0 WHERE id=?",self.r)
        points = [self.before,self.during,self.snap(4)]
        return native.voice_evidence.verdict(self.series,points)[0]

    def retry(self, *, new_final):
        self.session(self.a,1.5)
        self.speaking(self.a)
        self.revision(self.a,2.2)
        self.terminal(self.a,"failed",2.4)
        self.sql("UPDATE recordings SET active_attempt=? WHERE id=?",self.b,self.r)
        self.session(self.b,2.5)
        if new_final:
            self.revision(self.b,3)  # even byte-for-byte identical words cannot validate A
        self.terminal(self.b,"completed",3.5)
        self.assertEqual(self.finish(),"INCONCLUSIVE")

    def test_a_failed_b_completed_with_retained_a_final(self):
        self.retry(new_final=True)

    def test_b_reuses_a_words_without_new_final(self):
        self.retry(new_final=False)

    def test_observed_b_cannot_borrow_prior_a_final(self):
        self.session(self.a,1.4); self.revision(self.a,1.5); self.terminal(self.a,"failed",1.6)
        self.sql("UPDATE recordings SET active_attempt=? WHERE id=?",self.b,self.r)
        self.session(self.b,1.7); self.speaking(self.b); self.terminal(self.b,"completed",3.5)
        self.assertEqual(self.finish(),"INCONCLUSIVE")

    def test_missing_attempt_terminal(self):
        self.session(self.a,1.5); self.speaking(self.a); self.revision(self.a,2.5)
        self.sql("UPDATE fusion_sessions SET state='completed' WHERE id=?",self.a)
        self.assertEqual(self.finish(),"INCONCLUSIVE")

    def test_terminal_belongs_to_different_session(self):
        self.session(self.a,1.5); self.speaking(self.a); self.revision(self.a,2.5)
        self.sql("UPDATE fusion_sessions SET state='completed' WHERE id=?",self.a)
        self.session(self.b,2.8); self.terminal(self.b,"completed",3.5)
        self.assertEqual(self.finish(),"INCONCLUSIVE")

    def test_session_belongs_to_different_recording(self):
        self.session(self.a,1.5,recording=self.old); self.speaking(self.a); self.revision(self.a,2.5); self.terminal(self.a,"completed",3.5)
        self.assertEqual(self.finish(),"INCONCLUSIVE")

    def test_other_checkpoint_run_cannot_supply_evidence(self):
        self.session(self.a,1.5); self.speaking(self.a); self.during["run"] = "events-other"
        self.revision(self.a,2.5); self.terminal(self.a,"completed",3.5)
        self.assertEqual(self.finish(),"INCONCLUSIVE")

    def test_terminal_outside_observation_interval(self):
        self.session(self.a,1.5); self.speaking(self.a); self.revision(self.a,2.5); self.terminal(self.a,"completed",4.1)
        self.assertEqual(self.finish(),"INCONCLUSIVE")

    def test_final_after_own_terminal(self):
        self.session(self.a,1.5); self.speaking(self.a); self.terminal(self.a,"completed",2.3); self.revision(self.a,2.5)
        self.assertEqual(self.finish(),"INCONCLUSIVE")

    def test_own_completion_survives_user_selected_edit(self):
        self.session(self.a,1.5); self.speaking(self.a); self.revision(self.a,2.5); self.terminal(self.a,"completed",3.2)
        self.revision(None,3.7,origin="userEdit",text="different synthetic words")
        self.assertEqual(self.finish(),"PASS")

    def test_local_session_materializes_on_first_result_after_speaking_point(self):
        self.speaking(self.a); self.session(self.a,2.3); self.revision(self.a,2.5); self.terminal(self.a,"completed",3.2)
        self.assertEqual(self.finish(),"PASS")


class NativeAcceptanceTests(unittest.TestCase):
    def test_residence_reads_latest_heartbeat_and_preserves_partial_rows(self):
        import residence
        with tempfile.TemporaryFile(mode="w+b") as stream:
            stream.write(b'{"time":1}\n{"time":5}\n{"time":')
            stream.seek(0)
            self.assertEqual(residence.latest_event(stream,{}), {"time":5})
            cursor = stream.tell()
            stream.seek(0,2)
            stream.write(b'8}\n')
            stream.seek(cursor)
            self.assertEqual(residence.latest_event(stream,{}), {"time":8})

    def test_frozen_inventory_rejects_drift_and_missing_entries(self):
        se = native.se
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            path = root/"session"
            binary = root/"test.app/Contents/MacOS/Host"
            resource = binary.parents[1]/"Resources/r"
            plist = binary.parents[1]/"Info.plist"
            lock = root/"Dependencies/domains.lock.json"
            helpers = {"panelHelper":path/"capture-panel","browserObserver":path/"observe-draft"}
            files = [binary,resource,plist,lock,*helpers.values(),*(root/n for n in se.SEALED_SCRIPTS)]
            for f in files:
                f.parent.mkdir(parents=True,exist_ok=True)
                f.write_bytes(b"original")
            sha = se.digest(b"original")
            seal = dict(schema=3,session=path.name,appSHA256=sha,resourcesSHA256=se.resources_hash(binary),
                        infoPlistSHA256=sha,domainLockSHA256=sha,scripts=dict.fromkeys(se.SEALED_SCRIPTS,sha),
                        subjects={k:dict(sha256=sha) for k in helpers})
            se.verify_manifest(root,path,binary,seal)
            for f in files:
                f.write_bytes(b"changed")
                with self.assertRaises(ValueError,msg=str(f)):
                    se.verify_manifest(root,path,binary,seal)
                f.write_bytes(b"original")
            del seal["scripts"]["scripts/acceptance/residence.py"]
            with self.assertRaises(ValueError):
                se.verify_manifest(root,path,binary,seal)

    def test_idle_requires_observed_continuity_and_focus(self):
        sample = [event(t) for t in range(0, 901, 5)]
        self.assertEqual(native.longest_idle(sample), 900)
        self.assertLess(native.longest_idle(sample[:60] + sample[64:]), 900)
        sample[80]["kind"] = "panelBecameKey"
        self.assertLess(native.longest_idle(sample), 900)

    def test_return_to_standby_and_restored_ids(self):
        series, points = self.speech_fixture()
        series.extend([event(5,trayConnected=False,trayCount=0),event(6)])
        self.assertEqual(native.observed_transitions(series,points), (True, True, True))
        series[2]["state"]["voice"] = "paused"
        series[-1]["state"]["trayIDs"] = "changed"
        self.assertEqual(native.observed_transitions(series,points), (False, False, False))

    def speech_fixture(self):
        scope = dict(session="fixture",run="events-fixture")
        old = dict(scope,records={"old":{"open":False}}, revisions={"old-rev":{"digest":"old-text"}},sessions={},terminals={})
        recording = dict(open=True,state="running",attempt="attempt",created=1.5)
        revision = dict(recording="new",attempt="attempt",origin="final",nonempty=True,created=3)
        fusion = dict(recording="new",state="running",created=1.6)
        during = dict(scope,time=2,recording="new",attempt="attempt",records={"new":recording},sessions={"attempt":fusion},terminals={})
        after = dict(scope,time=4,records={**old["records"],"new":dict(recording,open=False,state="completed",attempt=None)},
                     sessions={"attempt":dict(fusion,state="completed")},terminals={"attempt":dict(state="completed",time=3.3)},
                     revisions={**old["revisions"],"new-rev":revision})
        return [event(1),event(2,voice="speaking",recordings=["new"]),event(3.5)], [dict(old,time=1),during,after]

    def test_speech_requires_this_completed_recognition_and_explicit_pause(self):
        for case in ("old text","failed","partial","another recording","manual edit","no standby","auto pause","other attempt","no active ID"):
            with self.subTest(case=case):
                events,points = self.speech_fixture()
                rev = points[2]["revisions"]["new-rev"]
                if case == "old text": del points[2]["revisions"]["new-rev"]
                if case == "failed": points[2]["records"]["new"]["state"] = "failed"
                if case == "partial": rev["origin"] = "partial"
                if case == "another recording": rev["recording"] = "old"
                if case == "manual edit": rev["origin"] = "userEdit"
                if case == "no standby": events[-1]["state"]["voice"] = "speaking"
                if case == "auto pause": events.insert(2,event(2.2,voice="paused"))
                if case == "other attempt": rev["attempt"] = "different"
                if case == "no active ID": events[1]["state"]["recordings"] = []
                self.assertNotEqual(native.voice_evidence.verdict(events,points)[0],"PASS")
        events = [event(1),dict(event(2),kind="userPause"),event(3,voice="paused")]
        self.assertEqual(native.voice_evidence.pause_result(events),"PASS")
        self.assertEqual(native.voice_evidence.pause_result([events[0],events[2]]),"FAIL")
        events,points = self.speech_fixture()
        points[2]["records"]["new"]["preferred"] = "manual"
        self.assertEqual(native.voice_evidence.verdict(events,points)[0],"PASS")

    def test_no_send_needs_the_same_target_one_receipt_and_unchanged_user_turns(self):
        with tempfile.TemporaryDirectory(dir=native.ROOT/"build") as tmp:
            f = TransferFixture(Path(tmp))
            self.addCleanup(f.db.close)
            self.assertEqual(f.result()["specifiedDraftNoSend"], "PENDING")
            f.checkpoints()
            self.assertEqual(f.result()["specifiedDraftNoSend"], "PASS")
            original = copy.deepcopy(f.right)
            for changed in (dict(page="new-user-turn"),dict(tab="other"),dict(previews=2),dict(busy=True),dict(time=6)):
                f.write("browser-after.json",[original[0],dict(original[1],**changed)])
                self.assertEqual(f.result()["specifiedDraftNoSend"], "FAIL")
            f.db.execute("insert into operations select * from operations")
            self.assertEqual(f.result()["oneCaptureOneAttempt"], "FAIL")

    def test_terminal_and_browser_counterexamples(self):
        cases = {
            "unknown plus START and preview": lambda f:f.db.execute("update operations set phase='unknown'"),
            "failed plus preview": lambda f:f.db.execute("update operations set phase='failed'"),
            "incomplete receipt": lambda f:f.db.execute("update operations set receipt_json='{}'"),
            "missing completion": lambda f:f.db.execute("update operations set receipt_json=NULL"),
            "foreign preview": lambda f:f.right[0].update(previewNames=["riftlet-other.png"]),
            "unidentified blob": lambda f:f.right[0].update(previewNames=[None]),
            "prior attachment": lambda f:f.left.update(previews=1,previewNames=["prior"]),
            "wrong operation": lambda f:f.db.execute("update upload_starts set operation_id='other'"),
            "wrong attempt": lambda f:f.db.execute("update operations set attempt=2"),
            "changed target": lambda f:f.right[1].update(window="8"),
            "duplicate start": lambda f:f.db.execute("insert into upload_starts select * from upload_starts"),
            "two previews": lambda f:f.right[0].update(previews=2),
            "unadmitted completion": lambda f:f.db.execute("update operations set receipt_json=?",(json.dumps(dict(f.final,profileID="unadmitted")),)),
        }
        for label,change in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory(dir=native.ROOT/"build") as tmp:
                f = TransferFixture(Path(tmp))
                try:
                    change(f)
                    f.checkpoints()
                    result = f.result()
                    self.assertNotEqual(result["specifiedDraftNoSend"], "PASS")
                    self.assertNotEqual(result["oneCaptureOneAttempt"], "PASS")
                finally:
                    f.db.close()

    def test_focus_scenarios_require_their_own_action_and_bounds(self):
        se = native.se
        def stream(kind,second,**state):
            return dict(event(second,pid=11,foreground=22,editorFocused=False,**state),kind=kind)
        def assess(scene,rows):
            points = [dict(run="run",time=e["time"],state=e["state"]) for e in (rows[0],rows[-1])]
            return se.focus_verdict(scene,points,rows,10)
        idle = [stream("sample",t) for t in (0,5,10)]
        self.assertEqual(assess("idle",idle),"PASS")
        self.assertNotEqual(assess("button",idle),"PASS")
        button = [idle[0],stream("trayButton",5),idle[-1]]
        self.assertEqual(assess("button",button),"PASS")
        button[1]["state"]["foreground"] = 33
        self.assertEqual(assess("button",button),"FAIL")
        edit = [idle[0],stream("editorClick",1),stream("userEdit",2,key=True),idle[-1]]
        edit[2]["state"]["editorFocused"] = True
        self.assertEqual(assess("edit",edit),"PASS")
        self.assertEqual(assess("edit",[idle[0],edit[2],idle[-1]]),"FAIL")
        hidden = stream("sample",5,visible=False)
        self.assertEqual(assess("hide",[idle[0],hidden]),"PASS")
        self.assertEqual(assess("restore",[hidden,idle[-1]]),"PASS")
        self.assertNotEqual(assess("hide",idle),"PASS")
        self.assertNotEqual(se.focus_verdict("idle",[],idle,10),"PASS")

    def test_restart_requires_a_challenge_and_rejects_multiple_inputs(self):
        state = dict(voiceRecords=1,voiceRevisions=1,assetOrder=["one"],attempts=1,starts=1,inputClaim="digest")
        self.assertEqual(native.se.restart_coverage(state), "PASS")
        for key, value in (("voiceRevisions",0),("assetOrder",[]),("starts",0),("inputClaim",None)):
            self.assertEqual(native.se.restart_coverage(dict(state,**{key:value})), "INCONCLUSIVE", key)
        for key in ("starts", "attempts"):
            self.assertEqual(native.se.restart_coverage(dict(state,**{key:2})), "FAIL", key)

    def test_real_waitpid_and_durable_restart_evidence_without_launching_an_app(self):
        import sys
        se = native.se
        with tempfile.TemporaryDirectory(dir=native.ROOT/"build") as tmp:
            p = Path(tmp)
            queue = p/"support/Riftlet/queue.sqlite"
            queue.parent.mkdir(parents=True)
            with closing(sqlite3.connect(queue)) as db, db:
                db.executescript("create table assets(id,image_json,status,visibility,visibility_revision,sort_at,sequence);"
                                 "create table operations(id,asset_id,attempt,target_key,phase,receipt_json,sequence);"
                                 "create table upload_starts(operation_id,receipt_json); create table checkpoints(key,value);")
            media = queue.parent/"media"
            media.mkdir()
            (media/"fixture.png").write_bytes(b"test image")
            img = json.dumps(dict(fileName="fixture.png",sha256=se.digest(b"test image")))
            with closing(sqlite3.connect(queue)) as db, db:
                db.execute("insert into assets values('asset',?,'unknown','swallowed',1,1,1)",(img,))
                db.execute("insert into operations values('op','asset',1,'draft','unknown','{}',1)")
                db.execute("insert into upload_starts values('op','{}')")
                db.execute("insert into checkpoints values('transfer-dispatch-call-v1:op','test-call')")
            se.put(p/"input-claim.json",{"operationID":"op"})
            voice = p/"support/Nearpane/Voice/Saytile.sqlite"
            voice.parent.mkdir(parents=True)
            (p/"summary.key").write_bytes(bytes(range(32)))
            with closing(sqlite3.connect(voice)) as db, db:
                db.executescript("create table recordings(id,created_at,recognition_state,is_recording,active_attempt,preferred_revision,deleted);"
                                 "create table revisions(id,recording_id,origin,attempt,created_at,text); create table editing_drafts(recording_id,text);"
                                 "create table fusion_sessions(id,recording_id,state,created_at); create table fusion_session_terminals(recognition_id,state,occurred_at);"
                                 "insert into recordings values('old',1,'completed',0,NULL,'revision',0);"
                                 "insert into revisions values('revision','old','final','attempt',2,'synthetic phrase');"
                                 "insert into editing_drafts values('old','synthetic private text');")
            # A real, harmless child exits. Its own tiny fixture stream stands in for AppKit.
            child = r"""import os,json,time,pathlib
p=pathlib.Path('.'); run='events-'+os.environ['NEARPANE_ACCEPTANCE_RUN']
state=dict(pid=os.getpid(),voice='paused',trayConnected=False,mayAttach=False,collecting=False,micAuthorization=3,speechAuthorization=3)
with (p/(run+'.jsonl')).open('w') as f:
 for kind in ['opened','drained']:
  f.write(json.dumps(dict(kind=kind,time=time.time(),state=state))+'\n'); f.flush(); time.sleep(.22)
"""
            for _ in range(2):
                se.supervise(p,[sys.executable,"-c",child],p)
            streams={x.stem:se.events(x) for x in p.glob("events-*.jsonl")}
            old,new = sorted((json.loads(x.read_text()) for x in p.glob("startup-*.json")),key=lambda r:r["started"])
            self.assertNotEqual(se.restart_verdict(p,streams),"PASS")
            checkpoint = dict(session=p.name,run=old["run"],time=old["openedAt"],state=streams[old["run"]][0]["state"],durable=old["startup"])
            file=p/("before-exit-"+old["run"]+".json")
            se.put(file,checkpoint)
            self.assertEqual(se.restart_verdict(p,streams),"PASS")
            for field in ("voiceSHA256","assetOrder","unresolved","attempts","starts","inputClaim"):
                altered=copy.deepcopy(checkpoint)
                altered["durable"][field]="changed"
                file.write_text(json.dumps(altered))
                self.assertNotEqual(se.restart_verdict(p,streams),"PASS",field)
            file.write_text(json.dumps(checkpoint))
            streams[new["run"]][0]["state"]["mayAttach"]=True
            self.assertNotEqual(se.restart_verdict(p,streams),"PASS")
            streams[new["run"]][0]["state"]["mayAttach"]=False
            (p/(old["run"].replace("events-","process-")+".json")).unlink()
            self.assertNotEqual(se.restart_verdict(p,streams),"PASS")
            self.assertNotIn("synthetic private text",json.dumps(se.durable(p)))


if __name__ == "__main__":
    (native.ROOT/"build").mkdir(exist_ok=True)
    unittest.main()
