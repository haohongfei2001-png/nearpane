#!/usr/bin/env python3
"""Exercise the acceptance verdicts with generated events. No browser, GUI, audio, or permissions."""
import importlib.util
import json
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
            path = Path(tmp)
            target = {"adapterID":"chatgpt-web","applicationID":"com.google.Chrome","tabID":"3","windowID":"9"}
            database = path/"support/Riftlet/queue.sqlite"
            database.parent.mkdir(parents=True)
            db = sqlite3.connect(database)
            db.executescript("CREATE TABLE assets(id); CREATE TABLE operations(id,asset_id,attempt,target_json,phase,created_at); "
                             "CREATE TABLE upload_starts(operation_id,started_at);")
            self.assertEqual(native.report(path)["checks"]["specifiedDraftNoSend"], "PENDING")
            db.execute("insert into assets values(1)")
            db.execute("insert into operations values(1,1,1,?,'succeeded',2)", (json.dumps(target),))
            db.execute("insert into upload_starts values(1,3)")
            db.commit()
            left = dict(time=1, page="unique-document-and-user-turn-list", window="9", tab="3", previews=0, busy=False)
            right = [dict(left,time=t,previews=1) for t in (4,10)]
            (path/"browser-before.json").write_text(json.dumps(left))
            after = path/"browser-after.json"
            after.write_text(json.dumps(right))
            self.assertEqual(native.report(path)["checks"]["specifiedDraftNoSend"], "PASS")
            for changed in (dict(page="new-user-turn"),dict(tab="other"),dict(previews=2),dict(busy=True),dict(time=5)):
                after.write_text(json.dumps([right[0],dict(right[1],**changed)]))
                self.assertEqual(native.report(path)["checks"]["specifiedDraftNoSend"], "FAIL")
            db.execute("insert into operations values(2,1,2,?,'succeeded',2)", (json.dumps(target),))
            db.commit(); db.close()
            self.assertEqual(native.report(path)["checks"]["oneCaptureOneAttempt"], "FAIL")


if __name__ == "__main__":
    (native.ROOT/"build").mkdir(exist_ok=True)
    unittest.main()
