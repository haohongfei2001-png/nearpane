#!/usr/bin/env python3
"""Drive real P5.1 AppKit controls with synthetic fullscreen evidence in one marked secondary fixture."""
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess as sp
import sys
import time
import uuid

import session_evidence as se


def check(condition, message):
    if not condition:
        raise ValueError(message)


def get(path):
    return json.loads(path.read_bytes())


def until(sample, seconds=6):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            result = sample()
        except (FileNotFoundError, json.JSONDecodeError):
            result = None
        if result:
            return result
        time.sleep(0.08)
    raise ValueError(f"checkpoint timeout at line {sample.__code__.co_firstlineno}")


def main(sid, app, inspect=False):
    repo = Path(__file__).resolve().parents[2]
    sid = str(uuid.UUID(sid))
    session = repo / "build/native-acceptance" / sid
    app = app.resolve(strict=True)
    binary = app / "Contents/MacOS/NearpaneHost"
    check(app.name == "Nearpane P5.1 Alpha.app", "P5.1 required")
    offline = runpy.run_path(str(repo / "scripts/acceptance/verify-product-capture.py"))["offline_command"](repo)

    def offline_run(*args):
        return sp.check_output([*offline, *map(str, args)], text=True, timeout=10, cwd=repo).strip()

    sp.run(["/usr/bin/codesign","--verify","--strict","--deep",app],check=True)
    se.verify_manifest(repo, session, binary, get(session / "manifest.json"))
    check(not list(session.glob("process-*.json")) and not (session/"target-binding.json").exists(), "fresh unbound session required")
    check(sp.run(["pgrep","-x","NearpaneHost"],stdout=sp.DEVNULL).returncode == 1, "another Host active")
    out = repo / "build/verification/p51" / sid
    out.mkdir(mode=0o700, parents=True)
    for name in ("fullscreen-controls","fullscreen-film"):
        args = ["xcrun","swiftc", *(["-parse-as-library"] if name == "fullscreen-film" else []),
                "-module-cache-path",str(repo/"build/verification/p51/controls/cache"),
                str(repo/f"scripts/acceptance/{name}.swift"), "-o", str(out/name)]
        sp.run(args, check=True)
    cfg_path = session / "support/Nearpane/host-configuration.json"
    cfg = get(cfg_path)
    side = cfg["preferredDisplayID"]
    check(not cfg["displays"] and offline_run(out/"fullscreen-controls","preflight")==side,
          "expected untouched, permitted secondary display")
    cfg["displays"][side] = {"fullscreenTools":{"enabled":True,"voice":True,"capture":True,"corner":"topRight"}}
    cfg_path.write_text(json.dumps(cfg))
    baseline = se.durable(session)
    check(baseline["attempts"] == 0 and baseline["voiceRecords"] == 0 and not baseline["assetOrder"], "prepare with --empty-draft")
    receipts = []
    media_limits = []
    pixel_checks = {}
    def launch(restart):
        seq = 0
        old = set(session.glob("startup-*.json"))
        with (out/("second.log" if restart else "first.log")).open("w") as stream:
            host = sp.Popen([*offline,sys.executable,"-B",str(repo/"scripts/native-acceptance.py"),"launch",
                             "--app",str(app),"--session",sid,"--secondary-only","--desktop-fixture"],
                            env=dict(os.environ,NEARPANE_FULLSCREEN_ACCEPTANCE=sid),cwd=repo,stdout=stream,stderr=sp.STDOUT)
        def alive():
            check(host.poll() is None,"supervised Host exited early")
        run = None
        try:
            def startup():
                alive()
                diff = set(session.glob("startup-*.json"))-old
                return get(diff.pop()) if len(diff)==1 else None
            stamp = until(startup,15)
            pid = stamp["pid"]
            run = str(uuid.UUID(stamp["run"].removeprefix("events-")))
            check(se.process_path(pid)==binary,"running executable differs")
            evidence = session/f"fullscreen-{run}.json"
            def checkpoint(native, visible):
                def match():
                    alive()
                    row = get(evidence)
                    return row if row["step"]==seq and row["native"]==native and bool(row["tool"])==visible else None
                r = until(match)
                check(r["display"]==side and r["pid"]==pid and not any(r[k] for k in ("key","main","active")),"focus or display changed")
                return r
            first = checkpoint(False,False)
            focus = first["frontPID"]
            def step(native):
                nonlocal seq
                seq += 1
                (session/f"fullscreen-step-{run}-{seq}").write_text("native" if native else "ordinary")
                return checkpoint(native,native)
            def ui(wid,command):
                return offline_run(out/"fullscreen-controls",pid,wid,binary,command)
            def read(wid):
                r = json.loads(ui(wid,"read"))
                check(r["frontPID"]==focus, "foreground changed")
                return r
            def state(wid, key):
                return until(lambda:(lambda r:r if key in r["controls"] else None)(read(wid)))
            def photo(wid,name):
                # Capture the tested control inside the application while retaining its privacy
                # protections. Two newer native samples ensure that the view has laid out.
                def samples():
                    return sorted(session.glob(f"tool-frame-{run}-*.json"))
                previous_count = len(samples())
                frame = until(lambda: (lambda files: files[-1] if len(files)>=previous_count+3 else None)(samples()))
                check(get(frame)["id"] == wid, "rendered window identity changed")
                img = frame.with_suffix(".png")
                pix = json.loads(offline_run(out/"fullscreen-film","inspect",img))
                pixel_checks[name] = pix
                if pix["pixels"]>=24 and pix["contrast"]>=12 and pix["colors"]>6:
                    shutil.copyfile(img, out/name)
                else:
                    media_limits.append(f"{name} missing meaningful AppKit pixels; excluded from delivery.")
            def check_system_capture(wid):
                # Keep this independent observation, including an intentionally transparent frame.
                raw = out/"system-strip.raw.png"
                proc = sp.run([*offline,str(session/"capture-panel"),str(pid),str(wid),str(binary),str(raw),"--secondary-only"],
                              text=True,capture_output=True,cwd=repo,timeout=10)
                if proc.returncode and "Panel capture failed: screenCapturePermission" in proc.stderr:
                    media_limits.append("No existing ScreenCaptureKit authority.")
                    return
                check(proc.returncode == 0, proc.stderr.strip() or "panel capture did not complete")
                pix = json.loads(offline_run(out/"fullscreen-film","inspect",raw))
                pixel_checks[raw.name] = pix
                if pix["contrast"] < 12 or pix["colors"]<=6:
                    media_limits.append("System-returned window pixels do not show controls; raw image excluded from delivery.")
            def ordinary_state():
                log = se.events(session/(stamp["run"]+".jsonl"))
                return log[-1]["state"] if log else {}
            def ordinary_visible():
                panel = ordinary_state()
                return panel.get("visible") and panel.get("layoutMatches")
            until(ordinary_visible)
            strip = step(True)
            wid = strip["tool"]
            voice = "np.fullscreen.open.voice"
            capture = "np.fullscreen.open.capture"
            close = "np.fullscreen.close"
            collapsed = state(wid,voice)
            check(capture in collapsed["controls"] and close not in collapsed["controls"], "expected only strip")
            until(lambda:ordinary_state().get("visible") is False)
            if not restart:
                if not inspect:
                    (session/f"fullscreen-render-{run}").touch()
                    photo(wid, "strip.png")
                check_system_capture(wid)
            ui(wid,voice)
            expanded = state(wid,close)
            check(voice not in expanded["controls"] and capture not in expanded["controls"],"wrong expanded controls")
            (out/"voice-accessibility.json").write_text(json.dumps(expanded,indent=2))
            if inspect:
                return
            if not restart:
                photo(wid, "voice.png")
                ui(wid,"np.fullscreen.move")
                moved = until(lambda:(lambda r:r if r["bounds"]!=expanded["bounds"] else None)(state(wid,close)))
                check(moved["bounds"][0] == expanded["bounds"][0]-16 and moved["bounds"][1:]==expanded["bounds"][1:], "unverified user move")
                anchor = until(lambda:get(cfg_path)["displays"][side].get("toolAnchor"))
            else:
                check(expanded["bounds"]==receipts[0]["moved"]["bounds"], "persisted position not restored")
            ui(wid,close)
            state(wid,voice)
            ui(wid,capture)
            cap = state(wid,close)
            if not restart:
                check(cap["bounds"]==moved["bounds"], "capture did not use saved position")
                photo(wid,"capture.png")
            ui(wid,close)
            state(wid,voice)
            if not restart:
                # End the recording before the ordinary return. No other surface is sampled.
                (session/f"fullscreen-render-{run}").unlink()
                if all((out/name).exists() for name in ("strip.png","voice.png","capture.png")):
                    with (out/"film.log").open("w") as stream:
                        sp.run([*offline,str(out/"fullscreen-film"),str(session),run,str(wid),str(out/"tools.mov")],
                               check=True,cwd=repo,timeout=12,stdout=stream,stderr=sp.STDOUT)
            step(False)
            until(ordinary_visible)
            if not restart:
                # Enter a second time in this PID: old expansion must not survive the return.
                next_strip = step(True)
                after_return = state(next_strip["tool"],voice)
                check(close not in after_return["controls"] and capture in after_return["controls"],
                      "previous tool selection survived a new fullscreen transition")
                until(lambda:ordinary_state().get("visible") is False)
                step(False)
                until(ordinary_visible)
            check(se.durable(session)==baseline,"domain data or attempt counts changed")
            result = {"pid":pid,"run":run,"source":"synthetic ordinary/native/ordinary; real native controls",
                      "frontPID":focus,"collapsed":collapsed,"expanded":expanded,"capture":cap,"ordinaryRestored":True}
            if not restart:
                result.update(moved=moved,anchor=anchor,reentry=after_return)
            receipts.append(result)
        finally:
            if run and host.poll() is None:
                (session/f"fullscreen-finish-{run}").touch()
            check(host.wait(timeout=75)==0,"Host did not finish normally")
    launch(False)
    if inspect:
        print(out/"voice-accessibility.json")
        return
    launch(True)
    check(receipts[0]["pid"]!=receipts[1]["pid"] and se.durable(session)==baseline, "restart evidence mismatch")
    summary={"session":sid,"binary":sha256(binary.read_bytes()).hexdigest(),"runs":receipts,
             "nativeFullscreenEntered":0,"spaceSwitchesRequested":0,"inputAttempts":baseline["attempts"],
             "mediaLimits":media_limits,"pixelVerification":pixel_checks,
             "mediaSource":"Rendered from actual displayed AppKit controls; neutral canvas excludes system compositor backdrop",
             "media":{f.name:sha256(f.read_bytes()).hexdigest() for f in out.iterdir() if f.name in ("strip.png","voice.png","capture.png","tools.mov")}}
    (out/"summary.json").write_text(json.dumps(summary,indent=2))
    print(out/"summary.json")

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("session")
    p.add_argument("--inspect",action="store_true",help="inspect one expanded test panel and finish")
    p.add_argument("--app",type=Path,default=Path.home()/"Applications/Nearpane P5.1/Nearpane P5.1 Alpha.app")
    args=p.parse_args()
    main(args.session,args.app,args.inspect)
