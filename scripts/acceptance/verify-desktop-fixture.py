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
    se.require(all(n <= 2 for n in errors + ax_errors), "Window geometry mismatch")
    for row in evidence["rows"]:
        a = row["anchor"]
        se.require(row["displayID"] == displays[1]["id"] and a["number"] in fixtures and a["witness"] == "ownedWindow"
                   and fixtures[a["number"]]["activeSpace"] and len(windows) == 2 and
                   any(w["metadata"]["number"] == a["number"] and w["membership"].get("known", {}).get("recordIDs") == [row["recordID"]]
                       for w in windows), "Unwitnessed current row")
    return dict(revision=s["revision"], freshness=s["freshness"], status=evidence["spaces"], windows=len(windows),
                confirmedRows=len(evidence["rows"]), cgErrors=errors, axErrors=ax_errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", required=True)
    parser.add_argument("--app", type=Path, default=ROOT/"build/release/Nearpane.app")
    parser.add_argument("--capture", action="store_true", help="Take per-window ScreenCaptureKit images using existing permission")
    args = parser.parse_args()
    se.require(str(uuid.UUID(args.session)) == args.session, "Invalid session")
    path = ROOT/"build/native-acceptance"/args.session
    app = args.app.resolve(strict=True)
    binary = app/"Contents/MacOS/NearpaneHost"
    se.require(path.resolve(strict=True) == path and not list(path.glob("events-*")), "Fresh isolated session required")
    seal = json.loads((path/"manifest.json").read_bytes())
    se.verify_manifest(ROOT, path, binary, seal)
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
    exits = list(path.glob("process-*.json"))
    se.require(len(exits) == 1, "Missing unique exit")
    stamp = json.loads(exits[0].read_bytes())
    stream = se.events(path/(stamp["run"]+".jsonl"))
    se.require(stamp["exitCode"] == 0 and stream and stream[-1]["kind"] == "drained" and
               not any(e["state"]["active"] or e["state"]["key"] for e in stream), "Exit/focus evidence failed")
    se.require(stamp["prelaunch"] == stamp["postExit"] and stamp["postExit"]["intactMedia"], "Domain state changed")
    result = dict(session=args.session, scriptSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  observations=observations, singleWindowCaptures=captures, drained=True, exitCode=stamp["exitCode"],
                  domainsPreserved=True, assets=len(stamp["postExit"]["assetOrder"]), starts=stamp["postExit"]["starts"],
                  attempts=stamp["postExit"]["attempts"])
    se.put(path/"desktop-result.json", result)
    print(json.dumps(result, indent=2))
    se.require(any(r["freshness"] == "fresh" and r["windows"] == 2 for r in observations), "No complete pair measured")


if __name__ == "__main__":
    main()
