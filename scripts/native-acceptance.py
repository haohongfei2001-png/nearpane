#!/usr/bin/env python3
"""Prepare and assess an isolated real-device session. No live action is implied by prepare or report."""
import argparse
import hashlib
import json
from pathlib import Path
import os
import re
import sqlite3
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SESSIONS = ROOT / "build/native-acceptance"
OBSERVER = ROOT / "scripts/acceptance/draft-observation.js"
sys.path.insert(0, str(ROOT/"scripts/acceptance"))
import voice_evidence
import session_evidence as se

DEFAULT_IDLE_MINUTES = 60


def check(condition, message):
    if not condition:
        raise ValueError(message)


def folder(session):
    check(str(uuid.UUID(session)) == session, "Invalid session ID")
    path = SESSIONS / session
    check(path.resolve() == path and path.is_dir(), "Unknown fixture directory")
    marker = path / "session.json"
    check(not marker.is_symlink() and json.loads(marker.read_text())["session"].lower() == session, "Fixture identity mismatch")
    return path


def write_checkpoint(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, sort_keys=True)
        stream.write("\n")


def observe_browser(path, url, session, nonce, pid, window, tab, arm=False):
    check(re.fullmatch(r"https://chatgpt\.com/c/[a-zA-Z0-9-]+", url), "An exact, disposable ChatGPT test conversation URL is required")
    js = "(" + OBSERVER.read_text() + ")(" + json.dumps(url) + "," + json.dumps("NEARPANE-TEST-" + session) + "," + json.dumps(nonce) + "," + json.dumps(arm) + ")"
    check(all(re.fullmatch(r"[1-9][0-9]*", v or "") for v in (window,tab)), "Specify the authorized window and tab IDs")
    out = subprocess.run([str(path/"observe-draft"),str(pid),window,tab],input="JSON.stringify("+js+")",
                         text=True,capture_output=True,timeout=20)
    check(out.returncode == 0,"The approved PID/window/tab could not be observed with existing permission")
    data = out.stdout.strip()
    sample = json.loads(data)
    check(isinstance(sample, dict), "The unique test marker, composer and existing user-turn identities could not be verified")
    # Persist only digest/counts, never page text, the URL, or message IDs.
    fingerprint = json.dumps([url, sample["timeOrigin"], sample["ids"]], separators=(",", ":"))
    return dict(time=time.time(), page=hashlib.sha256(fingerprint.encode()).hexdigest(), window=window, tab=tab,
                previews=sample["previews"], previewNames=sample["previewNames"], busy=sample["busy"], timeOrigin=sample["timeOrigin"], session=session, nonce=nonce)


def chrome_identity(binary, path, pid):
    check(pid and pid > 0, "Specify the authorized Chrome PID")
    require_tool(binary)
    out = subprocess.run([str(binary), "--verify-bundled-resources", "--native-browser-identity", path.name, str(pid)],
                         cwd=ROOT, text=True, stdout=subprocess.PIPE, check=True)
    identity = out.stdout.strip().splitlines()[-1]
    check(re.fullmatch(rf"chrome-kernel-v1:{pid}:[0-9]+:[0-9]+", identity), "Ambiguous browser process")
    return identity


def allowed_asset(path, asset_id, digest):
    check(asset_id and str(uuid.UUID(asset_id)) == asset_id and digest and re.fullmatch("[a-f0-9]{64}", digest),
          "Supply the approved disposable asset UUID and SHA-256")
    queue = path/"support/Riftlet/queue.sqlite"
    check(queue.resolve() == queue, "Unexpected queue")
    with sqlite3.connect(queue.as_uri()+"?mode=ro", uri=True) as db:
        rows = db.execute("select id,file_name,image_json from assets").fetchall()
        check(len(rows) == 1 and rows[0][0].lower() == asset_id and db.execute("select count(*) from operations").fetchone()[0] == 0,
              "The fixture must contain only the approved capture and no attempts")
    _, name, raw = rows[0]
    asset = json.loads(raw)
    media = queue.parent/"media"/name
    check(Path(name).name == name and media.resolve() == media and asset["id"].lower() == asset_id
          and asset["fileName"] == name and asset["mediaType"] in ("image/png","image/jpeg")
          and asset["sha256"] == digest == hashlib.sha256(media.read_bytes()).hexdigest(), "Asset identity mismatch")


def longest_idle(events):
    longest = 0
    start = previous = None
    for event in events:
        state, now = event["state"], event["uptime"]
        good = (event["kind"] not in ("panelBecameKey","appActivated","drained") and state["visible"]
                and state["layoutMatches"] and not state["active"] and not state["key"])
        if not good:
            start = previous = None
            continue
        if previous is None or not 0 <= now - previous <= 10:
            start = now
        longest = max(longest, now - start)
        previous = now
    return longest


def observed_transitions(events, points=None):
    disconnected = connected = None
    restored = False
    speech, independent = voice_evidence.verdict(events,points)
    for event in events:
        s = event["state"]
        if s["trayConnected"]:
            if disconnected and s["trayCount"] and s["trayIDs"] == disconnected:
                restored = True
            disconnected = None
            connected = s["trayIDs"] if s["trayCount"] else None
        elif connected:
            disconnected, connected = connected, None
    return speech == "PASS", independent, restored


def product_receipt_policy(binary, evidence):
    result = subprocess.run([str(binary), "--verify-bundled-resources", "--native-receipt-policy"],
                            input=json.dumps(evidence), text=True, capture_output=True, timeout=10)
    return result.returncode == 0 and result.stdout.splitlines()[-1:] == ["Domain receipt admitted."]


def transfer_verdict(path, images, operations, starts, policy):
    def read(name):
        return json.loads((path/name).read_text())
    if max(len(images),len(operations),len(starts)) > 1:
        return "FAIL"
    if not all([images, operations, starts]) or not all((path/name).is_file() for name in ("target-binding.json","input-claim.json")):
        return "PENDING"
    row, op, start = images[0], operations[0], starts[0]
    if op["phase"] in ("failed","compensated"):
        return "FAIL"
    if op["phase"] != "succeeded" or row["status"] != "used" or not op["receipt_json"] or not start["receipt_json"]:
        return "INCONCLUSIVE"
    b, claim = read("target-binding.json"), read("input-claim.json")
    before, after = read("browser-before.json"), read("browser-after.json")
    image, target = json.loads(row["image_json"]), json.loads(op["target_json"])
    first, final = json.loads(start["receipt_json"]), json.loads(op["receipt_json"])
    identity = dict(operationID=op["id"], assetID=row["id"], attempt=1, target=target, assetSHA256=image["sha256"])
    def matches(receipt):
        return all(receipt.get(k) == v for k,v in identity.items())
    if not (path.name == b["session"] == claim["session"] and b["nonce"] == claim["nonce"] and matches(claim["identity"])
            and op["attempt"] == 1 and row["id"] == op["asset_id"] == image["id"] and row["id"].lower() == b["assetID"]
            and image["sha256"] == b["sha256"] and start["operation_id"] == op["id"] and matches(first) and matches(final)
            and target.get("applicationID") == "com.google.Chrome" and target.get("adapterID") == "chatgpt-web"
            and target.get("surface") == "webChat" and all(target.get(k) for k in ("documentID","composerID","draftGeneration"))
            and [target.get(k) for k in ("sessionID","windowID","tabID")] == [b[k] for k in ("process","window","tab")]
            and before["previews"] == 0 and before.get("previewNames") == [] and not before["busy"] and len(after) == 2
            and b["boundAt"] == before["time"] <= op["created_at"] <= claim["claimedAt"] <= start["started_at"] <= op["updated_at"] <= after[0]["time"]
            and claim["claimedAt"] <= b["expiresAt"] and after[1]["time"] - after[0]["time"] >= 5
            and all(s.get(k) == b[k] for s in [before,*after] for k in ("session","nonce","process","window","tab","timeOrigin"))
            and all(s["page"] == before["page"] and s["previews"] == 1 and not s["busy"] for s in after)):
        return "FAIL"
    ext = {"image/png":"png","image/jpeg":"jpg"}.get(image["mediaType"])
    expected = "riftlet-" + op["id"].lower() + "." + str(ext)
    if not ext or any(s.get("previewNames") != [expected] for s in after):
        return "INCONCLUSIVE"
    payload = dict(asset=image, start=first, final=final, invocationID=claim["invocationID"])
    if not policy or not policy(payload):
        return "INCONCLUSIVE"
    return "PASS"


def report(path, idle_minutes=DEFAULT_IDLE_MINUTES, policy=None):
    check(idle_minutes > 0, "Positive residence time required")
    by_run = {p.stem:se.events(p) for p in sorted(path.glob("events-*.jsonl"))}
    streams = list(by_run.values())
    samples = [e for stream in streams for e in stream]
    speech = "PENDING"
    independent = False
    speech_files = [path/("speech-"+stage+".json") for stage in ("before","during","after")]
    if all(p.is_file() for p in speech_files):
        points = [json.loads(p.read_text()) for p in speech_files]
        if all(p["session"] == path.name and p["run"] == points[0]["run"] for p in points):
            series = by_run.get(points[0]["run"],[])
            speech,independent = voice_evidence.verdict(series,points)
    transitions = [observed_transitions(stream) for stream in streams]
    queue = path / "support/Riftlet/queue.sqlite"
    check(queue.resolve() == queue, "Fixture queue path mismatch")
    db = sqlite3.connect(queue.as_uri() + "?mode=ro", uri=True)
    try:
        db.row_factory = sqlite3.Row
        db.execute("begin")
        images = [dict(r) for r in db.execute("select id,image_json,status from assets")]
        ops = [dict(r) for r in db.execute("select id,asset_id,attempt,target_json,phase,created_at,updated_at,receipt_json from operations")]
        receipts = [dict(r) for r in db.execute("select operation_id,receipt_json,started_at from upload_starts")]
        assets, starts = len(images), len(receipts)
    finally:
        db.close()
    gates = {
        "visibleGeometry": any(e["state"]["visible"] and e["state"]["layoutMatches"] for e in samples),
        "speechReturnsToStandby": speech == "PASS",
        "trayAndVoiceTogether": independent,
        "sameQueueAfterDisconnect": any(t[2] for t in transitions),
        "oneCaptureOneAttempt": False,
    }
    states = {k: "PASS" if v else "PENDING" for k,v in gates.items()}
    for scene in se.SCENES:
        files = [path/("focus-"+scene+"-"+edge+".json") for edge in ("start","end")]
        bounds = [json.loads(p.read_text()) for p in files] if all(p.is_file() for p in files) else []
        valid = bounds and all(b["session"] == path.name for b in bounds)
        states[scene+"Focus"] = se.focus_verdict(scene,bounds if valid else [],by_run.get(bounds[0]["run"],[]) if bounds else [],idle_minutes*60)
    states["drainedExitAndFreshRestart"] = se.restart_verdict(path,by_run)
    pauses = [voice_evidence.pause_result(stream) for stream in streams]
    states["userPauseOnly"] = "FAIL" if "FAIL" in pauses else "PASS" if "PASS" in pauses else "PENDING"
    states["speechReturnsToStandby"] = "FAIL" if "FAIL" in pauses else speech
    states["visibleAppearance"] = "REQUIRES_AUTHORIZED_VISUAL_REVIEW"
    review = path / "visual-review.json"
    if review.is_file():
        decision = json.loads(review.read_text())
        image = path / "panel.png"
        same = image.is_file() and hashlib.sha256(image.read_bytes()).hexdigest() == decision["imageSHA256"]
        states["visibleAppearance"] = "PASS" if same and gates["visibleGeometry"] and decision["matchesReference"] else "FAIL"
    states["specifiedDraftNoSend"] = "PENDING"
    if max(assets, len(ops), starts) > 1:
        states["oneCaptureOneAttempt"] = "FAIL"
    before, after = path/"browser-before.json", path/"browser-after.json"
    if before.exists() and after.exists():
        verdict = transfer_verdict(path, images, ops, receipts, policy)
        states["specifiedDraftNoSend"] = verdict
        if verdict == "PASS":
            states["oneCaptureOneAttempt"] = verdict
    manifest = path/"manifest.json"
    statuses = list(states.values())
    overall = "FAIL" if "FAIL" in statuses else "PASS" if all(v == "PASS" for v in statuses) and manifest.exists() else "PENDING"
    checkpoints = {p.name:se.digest(p.read_bytes()) for p in sorted(path.glob("*.json")) if not p.name.startswith("report-")}
    errors = [p.name for p in sorted(path.glob("error-*.json"))]
    return dict(overall=overall, checkpoints=checkpoints, errors=errors, manifestSHA256=checkpoints.get("manifest.json"),
                session=path.name, launches=len(streams), assets=assets, operations=len(ops), uploadStarts=starts,
                idleTargetMinutes=idle_minutes, longestObservedIdleSeconds=max(map(longest_idle,streams),default=0), checks=states)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare","report","launch","capture-panel","review-visual","browser-before","browser-after","speech-before","speech-during","speech-after","focus-start","focus-end","before-exit"])
    parser.add_argument("--app", type=Path, default=ROOT / "build/release/Nearpane.app")
    parser.add_argument("--session")
    parser.add_argument("--idle-minutes", type=int, default=DEFAULT_IDLE_MINUTES)
    parser.add_argument("--url")
    parser.add_argument("--browser-pid", type=int)
    parser.add_argument("--browser-window")
    parser.add_argument("--browser-tab")
    parser.add_argument("--asset-id")
    parser.add_argument("--asset-sha256")
    parser.add_argument("--scene", choices=se.SCENES)
    parser.add_argument("--verdict", choices=["pass","fail"])
    args = parser.parse_args()
    binary = args.app.resolve() / "Contents/MacOS/NearpaneHost"
    if args.action == "prepare":
        session = str(uuid.uuid4())
        # Refuse an older app which would interpret an unfamiliar CLI switch as an ordinary GUI launch.
        require_tool(binary)
        subprocess.run([str(binary),"--verify-bundled-resources","--native-acceptance-prepare",session], cwd=ROOT, check=True)
        path = folder(session)
        with (path/"summary.key").open("xb") as secret:
            secret.write(os.urandom(32))
        # Compile only. The panel helper never executes during preparation.
        for helper in ("capture-panel","observe-draft"):
            subprocess.run(["/usr/bin/xcrun","swiftc","-parse-as-library","-target",os.uname().machine+"-apple-macos26.0",
                            "-module-cache-path",str(path/"compiler-cache"),str(ROOT/("scripts/acceptance/"+helper+".swift")),
                            "-o",str(path/helper)], check=True)
        write_checkpoint(path/"manifest.json",se.manifest(ROOT,path,binary))
        print(json.dumps(report(path,args.idle_minutes), ensure_ascii=False, indent=2))
        return
    path = folder(args.session or "")
    manifest = json.loads((path/"manifest.json").read_text())
    check(manifest["session"] == path.name and manifest["appSHA256"] == se.digest(binary.read_bytes()),"Test executable changed")
    for name,expected in manifest["scripts"].items():
        check(se.digest((ROOT/name).read_bytes()) == expected,"Acceptance script changed")
    if args.action == "report":
        marker = json.loads((path/"session.json").read_text())
        def admitted(evidence):
            require_tool(binary)
            check(hashlib.sha256(binary.read_bytes()).hexdigest() == marker["executableSHA256"], "Unexpected policy executable")
            return product_receipt_policy(binary, evidence)
        result = report(path,args.idle_minutes,admitted)
        write_checkpoint(path/("report-"+str(uuid.uuid4())+".json"),result)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.action == "launch":
        require_tool(binary)
        marker = json.loads((path/"session.json").read_text())
        check(hashlib.sha256(binary.read_bytes()).hexdigest() == marker["executableSHA256"], "Different build from this session")
        se.supervise(path,[str(binary),"--native-acceptance-session",path.name],ROOT)
    elif args.action in ("focus-start","focus-end"):
        check(args.scene,"Specify the intended focus scenario")
        edge = args.action.split("-")[1]
        if edge == "end": check((path/("focus-"+args.scene+"-start.json")).is_file(),"Missing focus start")
        write_checkpoint(path/("focus-"+args.scene+"-"+edge+".json"),se.current_point(path))
    elif args.action == "before-exit":
        point = se.current_point(path)
        point["durable"] = se.durable(path)
        write_checkpoint(path/("before-exit-"+point["run"]+".json"),point)
    elif args.action.startswith("speech-"):
        write_checkpoint(path/(args.action+".json"), voice_evidence.point(path,args.action.split("-")[1]))
    elif args.action == "capture-panel":
        latest = max(path.glob("events-*.jsonl"), key=lambda p: p.stat().st_mtime)
        event = json.loads(latest.read_text().splitlines()[-1])
        check(event["kind"] != "drained" and 0 <= time.time() - event["time"] <= 10 and event["state"]["visible"],
              "No recent visible panel in this session")
        marker = json.loads((path/"session.json").read_text())
        check(hashlib.sha256(binary.read_bytes()).hexdigest() == marker["executableSHA256"], "Unexpected package")
        check(se.code_subject(path/"capture-panel") == manifest["subjects"]["panelHelper"],"Panel helper changed")
        subprocess.run([str(path/"capture-panel"),str(event["state"]["pid"]),str(event["state"]["windowID"]),
                        str(binary),str(path/"panel.png")], check=True)
    elif args.action == "review-visual":
        check(args.verdict, "Record the result after inspecting the captured test panel against the visual authority")
        image = path/"panel.png"
        write_checkpoint(path/"visual-review.json", dict(matchesReference=args.verdict == "pass",
                         imageSHA256=hashlib.sha256(image.read_bytes()).hexdigest()))
    else:
        check(args.url, "Pass the previously designated test draft URL")
        destination = path/(args.action+".json")
        check(not destination.exists(), "This checkpoint already exists")
        check(se.code_subject(path/"observe-draft") == manifest["subjects"]["browserObserver"],"Browser observer changed")
        process = chrome_identity(binary, path, args.browser_pid)
        subject = se.code_subject(se.process_path(args.browser_pid))
        check(subject["bundleID"] == "com.google.Chrome", "Unexpected target application")
        if args.action == "browser-before":
            write_checkpoint(path/"browser-subject.json",dict(process=process,subject=subject))
        else:
            check(json.loads((path/"browser-subject.json").read_text()) == dict(process=process,subject=subject),"Browser code or lifetime changed")
        if args.action == "browser-before":
            allowed_asset(path, args.asset_id, args.asset_sha256)
            nonce = str(uuid.uuid4())
            snapshot = observe_browser(path,args.url,path.name,nonce,args.browser_pid,args.browser_window,args.browser_tab,arm=True)
            check(chrome_identity(binary, path, args.browser_pid) == process, "Browser restarted during binding")
            check(snapshot["previews"] == 0 and not snapshot["busy"], "The designated draft is not empty of attachments")
            snapshot["process"] = process
            binding = dict(session=path.name, nonce=nonce, process=process, window=snapshot["window"], tab=snapshot["tab"],
                           url=args.url, timeOrigin=snapshot["timeOrigin"], assetID=args.asset_id, sha256=args.asset_sha256,
                           boundAt=snapshot["time"], expiresAt=snapshot["time"] + 900)
            write_checkpoint(destination, snapshot)
            write_checkpoint(path/"target-binding.json", binding)
        else:
            check((path/"browser-before.json").is_file(), "Capture the baseline first")
            binding = json.loads((path/"target-binding.json").read_text())
            check(binding["process"] == process and binding["url"] == args.url, "Binding differs")
            def observe():
                snapshot = observe_browser(path,args.url,path.name,binding["nonce"],args.browser_pid,binding["window"],binding["tab"])
                check(chrome_identity(binary, path, args.browser_pid) == process, "Browser restarted")
                return dict(snapshot, process=process)
            first = observe()
            time.sleep(5.1)
            write_checkpoint(destination, [first, observe()])


def require_tool(binary):
    import plistlib
    plist = binary.parents[1]/"Info.plist"
    with plist.open("rb") as source:
        metadata = plistlib.load(source)
    check(metadata.get("NearpaneNativeAcceptanceSchema") == 2, "Choose an integrated package with native acceptance schema 2")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, TypeError, sqlite3.Error, subprocess.SubprocessError) as error:
        if "--session" in sys.argv:
            try:
                target = folder(sys.argv[sys.argv.index("--session")+1])
                write_checkpoint(target/("error-"+str(uuid.uuid4())+".json"),dict(action=sys.argv[1],time=time.time(),kind=type(error).__name__))
            except (OSError,ValueError,IndexError,KeyError): pass
        sys.exit(f"Native acceptance: {error}")
