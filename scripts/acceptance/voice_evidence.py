"""Read only the isolated Saytile schema. No recognizer, audio or transcript logger."""
import hashlib
import hmac
import json
import sqlite3
import time
from contextlib import closing


def snapshot(path):
    file = path/"support/Nearpane/Voice/Saytile.sqlite"
    if file.resolve() != file or not file.is_file():
        raise ValueError("Isolated voice store unavailable")
    key = (path/"summary.key").read_bytes()
    def digest(text):
        return hmac.new(key, text.encode(),hashlib.sha256).hexdigest()
    with closing(sqlite3.connect(file.as_uri()+"?mode=ro",uri=True)) as db:
        db.execute("begin")
        records = {r[0]:dict(created=r[1],state=r[2],open=bool(r[3]),attempt=r[4],preferred=r[5])
                   for r in db.execute("select id,created_at,recognition_state,is_recording,active_attempt,preferred_revision from recordings where deleted=0")}
        revisions = {r[0]:dict(recording=r[1],origin=r[2],attempt=r[3],created=r[4],nonempty=bool(r[5].strip()),digest=digest(r[5]))
                     for r in db.execute("select id,recording_id,origin,attempt,created_at,text from revisions")}
        drafts = {rid:digest(text) for rid,text in db.execute("select recording_id,text from editing_drafts")}
        # fusion_sessions.id is the logical RecognitionTicket.id (also revisions.attempt).
        # invalidateModelRuns records the first terminal for that ID before clearing active_attempt.
        sessions = {sid:dict(recording=rid,state=state,created=created)
                    for sid,rid,state,created in db.execute("select id,recording_id,state,created_at from fusion_sessions")}
        terminals = {sid:dict(state=state,time=ended)
                     for sid,state,ended in db.execute("select recognition_id,state,occurred_at from fusion_session_terminals")}
    return dict(records=records,revisions=revisions,drafts=drafts,sessions=sessions,terminals=terminals)


def point(path, stage):
    limit = time.monotonic() + (60 if stage == "during" else 0)
    while True:
        log = max(path.glob("events-*.jsonl"), key=lambda p:p.stat().st_mtime, default=None)
        if log:
            lines = log.read_text().splitlines()
            if lines:
                event = json.loads(lines[-1])
                now = time.time()
                state = event["state"]
                if event["kind"] != "drained" and 0 <= now-event["time"] <= 8:
                    data = snapshot(path)
                    active = [r for r,v in data["records"].items() if v["open"] and v["attempt"]]
                    common = dict(session=path.name,run=log.stem,time=time.time(),**data)
                    if stage == "before" and state["voice"] == "standby" and not any(v["open"] for v in data["records"].values()):
                        return common
                    if stage == "during" and state["voice"] == "speaking" and len(active) == 1 and state["recordings"] == active:
                        return dict(common,recording=active[0],attempt=data["records"][active[0]]["attempt"])
                    if stage == "after" and state["voice"] == "standby":
                        return common
        if time.monotonic() >= limit:
            raise ValueError("No current matching speech checkpoint")
        time.sleep(0.2)


def pause_result(events):
    armed = False
    prior = None
    observed = False
    for e in events:
        if e["kind"] == "drained" or not e["state"].get("voiceEnabled",True):
            prior,armed = None,False
            continue
        state = e["state"]["voice"]
        if e["kind"] == "userPause" and state in ("speaking","standby","starting"):
            armed = True
        if state == "paused" and prior in ("speaking","standby","starting","interrupted"):
            if not armed:
                return "FAIL"
            observed,armed = True,False
        if e["kind"] == "userStart":
            armed = False
        prior = state
    return "PASS" if observed else "PENDING"


def verdict(events, points):
    if not points:
        return "PENDING", False
    before, during, after = points
    rid, attempt = during["recording"], during["attempt"]
    if (not all(before.get(k) and before[k] == during.get(k) == after.get(k) for k in ("session","run"))
            or not all("sessions" in p and "terminals" in p for p in points)):
        return "INCONCLUSIVE", False
    seq = [e for e in events if before["time"] <= e["time"] <= after["time"]]
    if pause_result(seq) == "FAIL":
        return "FAIL", False
    rec = after["records"].get(rid, {})
    active = during["records"].get(rid,{})
    session = after["sessions"].get(attempt,{})
    terminal = after["terminals"].get(attempt,{})
    started, ended = session.get("created"), terminal.get("time")
    if not (rid and attempt and before["time"] < during["time"] < after["time"] and rid not in before["records"]
            and active.get("attempt") == attempt and active.get("open") and active.get("state") == "running"
            and rec.get("created") == active.get("created") and before["time"] <= rec["created"] <= during["time"]
            and rec.get("state") == "completed" and not rec["open"]
            and set(after["records"])-set(before["records"]) == {rid}
            and attempt not in before["sessions"] and attempt not in before["terminals"] and attempt not in during["terminals"]
            and session.get("recording") == rid and session.get("state") == terminal.get("state") == "completed"
            and started is not None and ended is not None and rec["created"] <= started <= ended
            and during["time"] <= ended <= after["time"]
            and any(k not in before["revisions"] and v["recording"] == rid and v["attempt"] == attempt
                    and v["origin"] == "final" and v["nonempty"] and started <= v["created"] <= ended
                    for k,v in after["revisions"].items())):
        return "INCONCLUSIVE", False
    # Apple can create this session on its first candidate, after the speaking checkpoint.
    # When already present it must be the very same running session; never borrow a retry's result.
    if attempt in during["sessions"]:
        if during["sessions"][attempt] != dict(recording=rid,state="running",created=started) or started > during["time"]:
            return "INCONCLUSIVE", False
    elif started < during["time"]:
        return "INCONCLUSIVE", False
    speaking = next((e for e in seq if e["state"]["voice"] == "speaking" and e["state"].get("recordings") == [rid]),None)
    if not speaking:
        return "INCONCLUSIVE", False
    tail = [e["state"] for e in seq if e["time"] >= speaking["time"]]
    if not tail or tail[-1]["voice"] != "standby" or any(s["voice"] not in ("standby","speaking") for s in tail):
        return "INCONCLUSIVE", False
    ids = speaking["state"]["trayIDs"]
    independent = all(s["trayCount"] and s["trayConnected"] and s["trayIDs"] == ids for s in tail)
    return "PASS", independent
