#!/usr/bin/env python3
"""Supervise a fresh, passive secondary-screen geometry fixture. Raw output stays in its marked session."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

import session_evidence as se

ROOT = Path(__file__).resolve().parents[2]
FIELDS = ("x", "y", "width", "height")


def check_sample(receipt, pid):
    s = receipt["snapshot"]
    evidence = s["native"]
    se.require(evidence["population"] == "markedFixture" and not receipt["hostActive"], "Unexpected desktop population or activation")
    fixtures = {f["number"]: f for f in receipt["fixtures"]}
    se.require(len(fixtures) == 2 and all(not f["key"] for f in fixtures.values()), "Invalid owned window pair")
    windows = s["windows"]
    se.require(all(w["metadata"]["pid"] == pid and w["metadata"]["number"] in fixtures for w in windows),
               "Unexpected window in fixture")
    displays = s["displays"]
    se.require(len(displays) == 2 and displays[0]["id"] != displays[1]["id"], "Secondary unavailable")
    screen = displays[1]["frame"]
    errors, ax_errors = [], []
    for f in fixtures.values():
        r = f["expectedCG"]
        se.require(screen["x"] <= r["x"] < r["x"]+r["width"] <= screen["x"]+screen["width"] and
                   screen["y"] <= r["y"] < r["y"]+r["height"] <= screen["y"]+screen["height"], "Fixture left secondary")
    for w in windows:
        m = w["metadata"]
        se.require(w["displayID"] == displays[1]["id"], "Unexpected display")
        expected = fixtures[m["number"]]["expectedCG"]
        errors.append(max(abs(m["globalFrame"][k] - expected[k]) for k in FIELDS))
        if m.get("axFrame"):
            ax_errors.append(max(abs(m["axFrame"][k] - expected[k]) for k in FIELDS))
    if s["freshness"] == "fresh":
        se.require(all(n <= 2 for n in errors + ax_errors), "Stable window geometry mismatch")
    else:
        se.require(s["freshness"] in ("transient", "stale") and not evidence["rows"], "Unstable sample attests a Space")
    for row in evidence["rows"]:
        a = row["anchor"]
        se.require(row["displayID"] == displays[1]["id"] and a["number"] in fixtures and a["witness"] == "ownedWindow"
                   and fixtures[a["number"]]["activeSpace"] and len(windows) == 2 and
                   any(w["metadata"]["number"] == a["number"] and w["membership"].get("known", {}).get("recordIDs") == [row["recordID"]]
                       for w in windows), "Unwitnessed current row")
    return dict(revision=s["revision"], freshness=s["freshness"], status=evidence["spaces"], windows=len(windows),
                confirmedRows=len(evidence["rows"]), cgErrors=errors, axErrors=ax_errors)


def preserved_domains(before, startup, end):
    expected = before.copy()
    if not before["voiceAvailable"]:
        if before["voiceSHA256"] != se.fingerprint(None) or before["voiceRecords"] or before["voiceRevisions"]:
            return False
        # First launch creates an empty Saytile database. Every persisted observation must be empty.
        empty = dict(records={}, revisions={}, drafts={}, sessions={}, terminals={})
        expected.update(voiceAvailable=True, voiceSHA256=se.fingerprint(empty))
    return expected == startup == end and end["intactMedia"]


def finished_process(path):
    exits = list(path.glob("process-*.json"))
    se.require(len(exits) == 1, "Missing unique exit")
    stamp = json.loads(exits[0].read_bytes())
    se.require(stamp["session"] == path.name and stamp["run"].startswith("events-") and
               str(uuid.UUID(stamp["run"][7:])) == stamp["run"][7:], "Wrong process receipt")
    stream = se.events(path/(stamp["run"]+".jsonl"))
    se.require(all(e["state"]["pid"] == stamp["pid"] for e in stream), "Process identity changed")
    se.require(stamp["exitCode"] == 0 and stream and stream[-1]["kind"] == "drained" and
               not any(e["state"]["active"] or e["state"]["key"] for e in stream), "Exit/focus evidence failed")
    se.require(any(e["state"]["visible"] and e["state"]["voiceEnabled"] and e["state"]["trayConnected"] for e in stream),
               "Domain pair did not open")
    se.require(preserved_domains(stamp["prelaunch"], stamp["startup"], stamp["postExit"]), "Domain state changed")
    return stamp


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", required=True)
    parser.add_argument("--app", type=Path, default=ROOT/"build/release/Nearpane.app")
    parser.add_argument("--capture", action="store_true", help="Take per-window ScreenCaptureKit images using existing permission")
    parser.add_argument("--replay", action="store_true", help="Evaluate a completed marked run from its durable receipts, without launching any process or taking images")
    args = parser.parse_args()
    if args.replay and args.capture:
        parser.error("--replay cannot capture")
    se.require(str(uuid.UUID(args.session)) == args.session, "Invalid session")
    path = ROOT/"build/native-acceptance"/args.session
    app = args.app.resolve(strict=True)
    binary = app/"Contents/MacOS/NearpaneHost"
    se.require(path.resolve(strict=True) == path, "Isolated session required")
    seal = json.loads((path/"manifest.json").read_bytes())
    se.verify_manifest(ROOT, path, binary, seal)
    if args.replay:
        stamp = finished_process(path)
        prefix = "desktop-" + stamp["run"][7:] + "-"
        observations = []
        for file in path.glob(prefix+"*.json"):
            receipt = json.loads(file.read_bytes())
            row = check_sample(receipt, stamp["pid"])
            se.require(file.stem == prefix+str(row["revision"]), "Wrong recorded revision")
            observations.append(row)
        se.require(any(r["freshness"] == "fresh" and r["windows"] == 2 for r in observations), "No stable window pair")
        result = dict(session=path.name, run=stamp["run"], scriptSHA256=se.digest(Path(__file__).read_bytes()),
                      observations=sorted(observations, key=lambda r: r["revision"]), domainsPreserved=True,
                      exitCode=stamp["exitCode"], newCaptures=0)
        se.put(path/("desktop-replay-"+str(uuid.uuid4())+".json"), result)
        print(json.dumps(result, indent=2))
        return
    se.require(not list(path.glob("events-*")), "Fresh isolated session required")
    observations, captures, seen, attempted = [], {}, set(), set()
    command = [sys.executable, "-B", str(ROOT/"scripts/native-acceptance.py"), "launch", "--app", str(app),
               "--session", args.session, "--secondary-only", "--desktop-fixture"]
    with (path/"desktop-supervisor.log").open("x") as log, subprocess.Popen(command, stdout=log, stderr=log) as supervisor:
        while supervisor.poll() is None:
            for file in sorted(path.glob("desktop-*.json")):
                if file.name in seen:
                    continue
                run, _, revision = file.stem.removeprefix("desktop-").rpartition("-")
                startup = path/("startup-"+run+".json")
                if not startup.exists():
                    continue
                try:
                    receipt = json.loads(file.read_bytes())
                    stamp = json.loads(startup.read_bytes())
                except json.JSONDecodeError:
                    continue
                stream = se.events(path/("events-"+run+".jsonl"))
                if not stream:
                    continue
                state = stream[-1]["state"]
                se.require(stamp["session"] == args.session and stamp["pid"] == state["pid"]
                           and not state["key"] and not state["active"], "Session or focus changed")
                if not state["visible"] or state["windowID"] <= 0:
                    continue  # The opened event precedes orderFront. Wait for the first visible heartbeat.
                se.require(state["layoutMatches"] and time.time()-stream[-1]["time"] <= 10, "Invalid secondary panel heartbeat")
                summary = check_sample(receipt, state["pid"])
                se.require(int(revision) == summary["revision"], "Receipt revision mismatch")
                observations.append(summary)
                seen.add(file.name)
                phase = summary["status"]
                if args.capture and phase in ("disabled", "observed") and phase not in attempted and summary["freshness"] == "fresh":
                    attempted.add(phase)
                    time.sleep(0.35)
                    targets = {"panel-"+phase: state["windowID"]}
                    if phase == "disabled":
                        targets.update({"owned-"+str(i+1): f["number"] for i,f in enumerate(receipt["fixtures"])})
                    for name, number in targets.items():
                        target = path/(name+".png")
                        proc = subprocess.run([path/"capture-panel", str(state["pid"]), str(number), binary, target, "--secondary-only"],
                                              capture_output=True, timeout=5)
                        captures[name] = (se.digest(target.read_bytes()) if proc.returncode == 0 else
                                          {"unavailable": proc.stderr.decode(errors="replace").strip()[:180]})
            time.sleep(.12)
        se.require(supervisor.returncode == 0, "Passive host failed; inspect its supervisor and process receipts")
    stamp = finished_process(path)
    result = dict(session=args.session, scriptSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  observations=observations, singleWindowCaptures=captures, drained=True, exitCode=stamp["exitCode"],
                  domainsPreserved=True, assets=len(stamp["postExit"]["assetOrder"]), starts=stamp["postExit"]["starts"],
                  attempts=stamp["postExit"]["attempts"])
    se.put(path/"desktop-result.json", result)
    print(json.dumps(result, indent=2))
    se.require(any(r["freshness"] == "fresh" and r["windows"] == 2 for r in observations), "No complete pair measured")


if __name__ == "__main__":
    main()
