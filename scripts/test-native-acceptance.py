#!/usr/bin/env python3
"""Exercise the acceptance verdicts with generated events. No browser, GUI, audio, or permissions."""
import importlib.util
import json
import copy
import os
import uuid
from pathlib import Path
import sqlite3
import tempfile
import unittest

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


class NativeAcceptanceTests(unittest.TestCase):
    def test_idle_requires_observed_continuity_and_focus(self):
        sample = [event(t) for t in range(0, 901, 5)]
        self.assertEqual(native.longest_idle(sample), 900)
        self.assertLess(native.longest_idle(sample[:60] + sample[64:]), 900)
        sample[80]["kind"] = "panelBecameKey"
        self.assertLess(native.longest_idle(sample), 900)

    def test_return_to_standby_and_restored_ids(self):
        series = [event(1,voice="speaking"),event(2),event(3,trayConnected=False,trayCount=0),event(4)]
        self.assertEqual(native.observed_transitions(series), (True, True, True))
        series[1]["state"]["voice"] = "paused"
        series[3]["state"]["trayIDs"] = "changed"
        self.assertEqual(native.observed_transitions(series), (False, False, False))

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


if __name__ == "__main__":
    (native.ROOT/"build").mkdir(exist_ok=True)
    unittest.main()
