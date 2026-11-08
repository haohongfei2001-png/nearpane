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


def observe_browser(url, session, nonce, arm=False):
    check(re.fullmatch(r"https://chatgpt\.com/c/[a-zA-Z0-9-]+", url), "An exact, disposable ChatGPT test conversation URL is required")
    js = "(" + OBSERVER.read_text() + ")(" + json.dumps(url) + "," + json.dumps("NEARPANE-TEST-" + session) + "," + json.dumps(nonce) + "," + json.dumps(arm) + ")"
    program = """
on run argv
    if application id "com.google.Chrome" is not running then error "The designated test browser is not running."
    tell application id "com.google.Chrome"
        if (count of windows) = 0 then error "No test window."
        set w to front window
        set t to active tab of w
        if (URL of t) is not (item 1 of argv) then error "Different tab."
        set snapshot to execute t javascript (item 2 of argv)
        return (id of w as text) & linefeed & (id of t as text) & linefeed & snapshot
    end tell
end run"""
    out = subprocess.run(["/usr/bin/osascript", "-l", "AppleScript", "-", url, "JSON.stringify(" + js + ")"],
                         input=program, text=True, capture_output=True, timeout=20)
    check(out.returncode == 0, "The test tab could not be observed. No browser change was requested.")
    window, tab, data = out.stdout.strip().split("\n", 2)
    sample = json.loads(data)
    check(isinstance(sample, dict), "The unique test marker, composer and existing user-turn identities could not be verified")
    # Persist only digest/counts, never page text, the URL, or message IDs.
    fingerprint = json.dumps([url, sample["timeOrigin"], sample["ids"]], separators=(",", ":"))
    return dict(time=time.time(), page=hashlib.sha256(fingerprint.encode()).hexdigest(), window=window, tab=tab,
                previews=sample["previews"], busy=sample["busy"], timeOrigin=sample["timeOrigin"], session=session, nonce=nonce)


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


def observed_transitions(events):
    speaking = None
    disconnected = None
    connected = None
    speech = independent = restored = False
    for event in events:
        s = event["state"]
        if s["voice"] == "speaking":
            if speaking is None:
                speaking = s["trayIDs"] if s["trayConnected"] and s["trayCount"] else ""
        elif s["voice"] == "standby" and speaking is not None and s["hasTranscript"]:
            speech = True
            independent |= bool(speaking and s["trayConnected"] and s["trayIDs"] == speaking)
            speaking = None
        elif s["voice"] != "standby":
            speaking = None
        if s["trayConnected"]:
            if disconnected and s["trayCount"] and s["trayIDs"] == disconnected:
                restored = True
            disconnected = None
            connected = s["trayIDs"] if s["trayCount"] else None
        elif connected:
            disconnected, connected = connected, None
    return speech, independent, restored


def report(path, idle_minutes=DEFAULT_IDLE_MINUTES):
    check(idle_minutes > 0, "Positive residence time required")
    streams = [[json.loads(row) for row in p.read_text().splitlines()] for p in sorted(path.glob("events-*.jsonl"))]
    samples = [e for stream in streams for e in stream]
    transitions = [observed_transitions(stream) for stream in streams]
    queue = path / "support/Riftlet/queue.sqlite"
    check(queue.resolve() == queue, "Fixture queue path mismatch")
    db = sqlite3.connect(queue.as_uri() + "?mode=ro", uri=True)
    try:
        assets, = db.execute("select count(*) from assets").fetchone()
        ops = list(db.execute("select asset_id,attempt,target_json,phase,created_at from operations"))
        receipts = list(db.execute("select s.started_at from upload_starts s join operations o on o.id=s.operation_id"))
        starts = len(receipts)
    finally:
        db.close()
    completed = [e for e in samples if e["kind"] == "drained"]
    restarts = sorted((s for s in streams if s), key=lambda seq: seq[0]["time"])
    restarted = any(a[-1]["kind"] == "drained" and a[-1]["time"] <= b[0]["time"] and b[0]["kind"] == "opened"
                    and b[0]["state"]["voice"] == "paused" and not b[0]["state"]["trayConnected"]
                    for a,b in zip(restarts, restarts[1:]))
    gates = {
        "visibleGeometry": any(e["state"]["visible"] and e["state"]["layoutMatches"] for e in samples),
        "idleFocus": any(longest_idle(s) >= idle_minutes * 60 for s in streams),
        "speechReturnsToStandby": any(t[0] for t in transitions),
        "trayAndVoiceTogether": any(t[1] for t in transitions),
        "sameQueueAfterDisconnect": any(t[2] for t in transitions),
        "drainedExitAndFreshRestart": bool(completed and restarted),
        "oneCaptureOneAttempt": assets == len(ops) == starts == 1 and ops[0][1] == 1,
    }
    states = {k: "PASS" if v else "PENDING" for k,v in gates.items()}
    states["visibleAppearance"] = "REQUIRES_AUTHORIZED_VISUAL_REVIEW"
    review = path / "visual-review.json"
    if review.is_file():
        decision = json.loads(review.read_text())
        image = path / "panel.png"
        same = image.is_file() and hashlib.sha256(image.read_bytes()).hexdigest() == decision["imageSHA256"]
        states["visibleAppearance"] = "PASS" if same and gates["visibleGeometry"] and decision["matchesReference"] else "FAIL"
    states["specifiedDraftNoSend"] = "PENDING"
    if assets > 1 or len(ops) > 1:
        states["oneCaptureOneAttempt"] = "FAIL"
    before, after = path/"browser-before.json", path/"browser-after.json"
    if before.exists() and after.exists():
        left, right = json.loads(before.read_text()), json.loads(after.read_text())
        target = json.loads(ops[0][2]) if len(ops) == 1 else {}
        exact = (gates["oneCaptureOneAttempt"] and ops[0][3] not in ("failed","compensated") and
                 target.get("adapterID") == "chatgpt-web" and target.get("applicationID") == "com.google.Chrome" and str(target.get("tabID")) == left["tab"]
                 and str(target.get("windowID")) == left["window"] and left["previews"] == 0 and not left["busy"]
                 and len(right) == 2 and left["time"] <= ops[0][4] <= receipts[0][0] <= right[0]["time"]
                 and right[1]["time"] - right[0]["time"] >= 5
                 and all(s["time"] > left["time"] and s["page"] == left["page"] and s["tab"] == left["tab"]
                         and s["window"] == left["window"] and s["previews"] == 1 and not s["busy"] for s in right))
        states["specifiedDraftNoSend"] = "PASS" if exact else "FAIL"
    return dict(session=path.name, launches=len(streams), assets=assets, operations=len(ops), uploadStarts=starts,
                idleTargetMinutes=idle_minutes, longestObservedIdleSeconds=max(map(longest_idle,streams),default=0), checks=states)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare","report","launch","capture-panel","review-visual","browser-before","browser-after"])
    parser.add_argument("--app", type=Path, default=ROOT / "build/release/Nearpane.app")
    parser.add_argument("--session")
    parser.add_argument("--idle-minutes", type=int, default=DEFAULT_IDLE_MINUTES)
    parser.add_argument("--url")
    parser.add_argument("--browser-pid", type=int)
    parser.add_argument("--asset-id")
    parser.add_argument("--asset-sha256")
    parser.add_argument("--verdict", choices=["pass","fail"])
    args = parser.parse_args()
    binary = args.app.resolve() / "Contents/MacOS/NearpaneHost"
    if args.action == "prepare":
        session = str(uuid.uuid4())
        # Refuse an older app which would interpret an unfamiliar CLI switch as an ordinary GUI launch.
        require_tool(binary)
        subprocess.run([str(binary),"--verify-bundled-resources","--native-acceptance-prepare",session], cwd=ROOT, check=True)
        path = folder(session)
        # Compile only. The panel helper never executes during preparation.
        subprocess.run(["/usr/bin/xcrun","swiftc","-parse-as-library","-target",os.uname().machine+"-apple-macos26.0",
                        "-module-cache-path",str(path/"compiler-cache"),str(ROOT/"scripts/acceptance/capture-panel.swift"),"-o",str(path/"capture-panel")], check=True)
        print(json.dumps(report(path,args.idle_minutes), ensure_ascii=False, indent=2))
        return
    path = folder(args.session or "")
    if args.action == "report":
        print(json.dumps(report(path,args.idle_minutes), ensure_ascii=False, indent=2))
    elif args.action == "launch":
        require_tool(binary)
        marker = json.loads((path/"session.json").read_text())
        check(hashlib.sha256(binary.read_bytes()).hexdigest() == marker["executableSHA256"], "Different build from this session")
        subprocess.run([str(binary),"--native-acceptance-session",path.name], cwd=ROOT, check=True)
    elif args.action == "capture-panel":
        latest = max(path.glob("events-*.jsonl"), key=lambda p: p.stat().st_mtime)
        event = json.loads(latest.read_text().splitlines()[-1])
        check(event["kind"] != "drained" and 0 <= time.time() - event["time"] <= 10 and event["state"]["visible"],
              "No recent visible panel in this session")
        marker = json.loads((path/"session.json").read_text())
        check(hashlib.sha256(binary.read_bytes()).hexdigest() == marker["executableSHA256"], "Unexpected package")
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
        process = chrome_identity(binary, path, args.browser_pid)
        if args.action == "browser-before":
            allowed_asset(path, args.asset_id, args.asset_sha256)
            nonce = str(uuid.uuid4())
            snapshot = observe_browser(args.url, path.name, nonce, arm=True)
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
                snapshot = observe_browser(args.url, path.name, binding["nonce"])
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
    check(metadata.get("NearpaneNativeAcceptanceSchema") == 1, "Choose an integrated package with native acceptance schema 1")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, sqlite3.Error, subprocess.SubprocessError) as error:
        sys.exit(f"Native acceptance: {error}")
