#!/usr/bin/env python3
"""Measure only an isolated, passive Alpha window in both native AppKit appearances."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import time

import session_evidence as se

PREP = runpy.run_path(str(Path(__file__).with_name("verify-size-reset.py")))
ROOT, SESSIONS = PREP["ROOT"], PREP["SESSIONS"]
OUT = ROOT / "build/verification/product-closeout/appearance"
read, put = PREP["read"], PREP["put"]


def verify(app, baseline=None):
    host = app / "Contents/MacOS/NearpaneHost"
    offline = PREP["offline_command"]()
    def run(*args):
        return subprocess.check_output([*offline, *map(str, args)], text=True, timeout=15)
    def contrast(png, geometry):
        buttons = [row["frame"] for row in geometry["visible"] if row["kind"] == "startCapture"]
        se.require(len(buttons) == 1, "Need one fully visible, enabled capture button")
        return json.loads(run(OUT/"measure-glyph", png, *geometry["panel"], *buttons[0]))
    def focus():
        sample = json.loads(run(OUT / "focus"))
        return {k:sample[k] for k in ("side", "front", "focus", "bounds")}

    sid = PREP["prepare"](app)
    folder = SESSIONS / sid
    manifest = read(folder / "manifest.json")
    se.verify_manifest(ROOT, folder, host, manifest)
    se.require(not list(folder.glob("startup-*.json")) and not (folder / "target-binding.json").exists(), "Use a fresh unbound fixture")
    out = OUT / sid
    out.mkdir(mode=0o700)
    ready = focus()
    se.require(ready["front"] > 0 and ready["focus"] > 0, "No focus baseline")
    config = folder / "support/Nearpane/host-configuration.json"
    prefs = read(config)
    se.require(not prefs["displays"] and prefs["preferredDisplayID"] == ready["side"], "Secondary fixture identity mismatch")
    # Choose one supported full layout; no personal display preferences are read or written.
    prefs["displays"] = {ready["side"]: {
        "placement":"docked", "policy":"onDemand", "anchor":"top", "spacesDismissed":False,
        "measures":["panelWidth", {"unit":"pt", "value":240}]
    }}
    put(config, prefs)
    before = se.durable(folder)
    se.require(before["voiceRecords"] > 0 and len(before["assetOrder"]) == 5 and not before["attempts"] and not before["starts"],
               "Need the synthetic note and five generated assets")
    receipt = {"session":sid, "candidateSHA256":manifest["appSHA256"], "initialFocus": ready, "checks":[]}
    try:
        for request, expected in (("aqua", "NSAppearanceNameAqua"), ("darkAqua", "NSAppearanceNameDarkAqua")):
            se.require(focus() == ready, "Foreground or topology changed")
            se.require(subprocess.run(["pgrep", "-x", "NearpaneHost"], stdout=subprocess.DEVNULL).returncode == 1, "Another Host is active")
            existing = set(folder.glob("startup-*.json"))
            with (out / (request + ".log")).open("w") as log:
                proc = subprocess.Popen([*offline, sys.executable, "-B", ROOT / "scripts/native-acceptance.py",
                                         "launch", "--app", app, "--secondary-only", "--session", sid],
                    cwd=ROOT, env=dict(os.environ, NEARPANE_APPEARANCE_SESSION=sid, NEARPANE_PANEL_APPEARANCE=request),
                    start_new_session=True, stdout=log, stderr=subprocess.STDOUT)
            try:
                def startup():
                    se.require(proc.poll() is None, "Host stopped before appearance check")
                    new = set(folder.glob("startup-*.json")) - existing
                    return read(next(iter(new))) if len(new) == 1 else None
                launch = PREP["await_value"](startup, 18)
                pid = launch["pid"]
                stream = folder / (launch["run"] + ".jsonl")
                def state():
                    return next((event["state"] for event in reversed(se.events(stream)) if event["state"]["visible"]
                                 and event["state"]["layoutMatches"] and event["state"]["trayConnected"]
                                 and event["state"]["hasTranscript"] and event["state"]["effectiveAppearance"] == expected), None)
                panel = PREP["await_value"](state, 6)
                wid = panel["windowID"]
                se.require(panel["pid"] == pid and se.process_path(pid) == host and not panel["active"] and not panel["key"]
                           and focus() == ready, "Host, window, or focus mismatch")
                time.sleep(.4)
                measured = json.loads(run(OUT/"controls", pid, wid, host, "read-appearance"))
                image = out / (request + ".png")
                run(folder / "capture-panel", pid, wid, host, image, "--secondary-only")
                record = {"effectiveAppearance":panel["effectiveAppearance"], "pid":pid, "window":wid,
                          "geometry":measured, "imageSHA256":hashlib.sha256(image.read_bytes()).hexdigest()}
                receipt["checks"].append(record)
                put(out/"result.json", receipt)
                record["captureGlyph"] = contrast(image, measured)
                if baseline:
                    old = read(baseline/"result.json")
                    old_row, = [r for r in old["checks"] if r["effectiveAppearance"] == expected]
                    old_image = baseline/(request + ".png")
                    se.require(old["candidateSHA256"] != manifest["appSHA256"]
                               and old_row["imageSHA256"] == hashlib.sha256(old_image.read_bytes()).hexdigest()
                               and measured["panel"] == old_row["geometry"]["panel"], "Unmatched baseline")
                    for kind in ("transcript", "thumbnail"):
                        se.require(sorted(v["frame"] for v in measured["visible"] if v["kind"] == kind)
                                   == sorted(v["frame"] for v in old_row["geometry"]["visible"] if v["kind"] == kind),
                                   "Baseline layout changed")
                    record["previousImageAtMatchingPanelCoordinates"] = {
                        "session":old["session"], "hostSHA256":old["candidateSHA256"], "imageSHA256":old_row["imageSHA256"],
                        "measurement": contrast(old_image, measured)
                    }
                put(out/"result.json", receipt)
                kinds = [v["kind"] for v in measured["visible"]]
                se.require("transcript" in kinds and kinds.count("thumbnail") >= 2,
                           "Fewer than one synthetic transcript and two fully contained thumbnails")
                proc.wait(timeout=32)  # the passive Host closes through its own exit barrier
                se.require(proc.returncode == 0, "Host exit failed")
                se.require(all(e["state"]["foreground"] == ready["front"] and not e["state"]["active"] and not e["state"]["key"]
                               for e in se.events(stream)), "Unexpected foreground or key change")
            finally:
                if proc.poll() is None:
                    # The only processes in this group are the isolated supervisor and its child.
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=6)
                se.require(focus() == ready, "Focus changed during cleanup")
        a, b = receipt["checks"]
        se.require(a["geometry"]["panel"] == b["geometry"]["panel"], "Panel bounds changed with appearance")
        for kind in ("transcript", "thumbnail", "startCapture"):
            def frames(record):
                return sorted(row["frame"] for row in record["geometry"]["visible"] if row["kind"] == kind)
            se.require(frames(a) == frames(b), kind + " geometry changed with appearance")
        se.require(a["imageSHA256"] != b["imageSHA256"], "Window renders indistinguishable")
        se.require(all(row["captureGlyph"]["ratio"] >= 3 for row in receipt["checks"]),
                   "Enabled capture glyph contrast below 3:1")
        receipt["result"] = "PASS"
    except Exception as exc:
        receipt.update(result="FAIL", error=str(exc))
        raise
    finally:
        receipt["finalFocus"] = focus()
        receipt["dataUnchanged"] = se.durable(folder) == before
        work = folder / "support/WorkRect"
        receipt["windowWrites"] = sum(len(list(work.rglob(pattern))) for pattern in ("attempt-*.json", "action-*.json"))
        status = read(work / "status.json") if (work / "status.json").exists() else {}
        receipt["management"] = {k:status.get(k) for k in ("mode", "members")}
        if (not receipt["dataUnchanged"] or receipt["windowWrites"] or list(work.rglob("journal.json"))
                or receipt["management"] != {"mode":"off", "members":0}):
            receipt.update(result="FAIL", error="Domain data changed or window management ran")
        put(out/"result.json", receipt)
    se.require(receipt["result"] == "PASS", "Appearance acceptance failed")
    print(out / "result.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--compile-only", action="store_true")
    mode.add_argument("--app", type=Path)
    parser.add_argument("--compare-baseline", type=Path, help="Earlier owned appearance receipt and its original PNGs")
    args = parser.parse_args()
    if args.compile_only:
        OUT.mkdir(mode=0o700, parents=True, exist_ok=True)
        for src, name in (("ordinary-windows/SystemReadback.swift","focus"), ("fullscreen-controls.swift","controls"),
                          ("measure-panel-glyph.swift","measure-glyph")):
            subprocess.run(["xcrun", "swiftc", "-module-cache-path", OUT/"compiler-cache",
                            ROOT/"scripts/acceptance"/src, "-o", OUT/name], check=True)
    else:
        baseline = args.compare_baseline.resolve(strict=True) if args.compare_baseline else None
        se.require(baseline is None or baseline.parent == OUT, "Baseline must be a local synthetic appearance receipt")
        verify(args.app.resolve(strict=True), baseline)
