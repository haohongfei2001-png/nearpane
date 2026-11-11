#!/usr/bin/env python3
"""Capture ONE opaque window owned by the marked secondary-only fixture. No browser connection."""
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess as sp
import sys
import time
import uuid

import session_evidence as se

def need(ok, why):
    if not ok: raise ValueError(why)

def wait(read, timeout=8):
    until=time.monotonic()+timeout
    while time.monotonic()<until:
        try:
            value=read()
            if value: return value
        except (FileNotFoundError, IndexError, json.JSONDecodeError): pass
        time.sleep(.08)
    raise ValueError("checkpoint missing at line "+str(read.__code__.co_firstlineno))

def main(sid):
    repo=Path(__file__).resolve().parents[2]; w=repo/"build/verification/p50"
    s=repo/"build/native-acceptance"/str(uuid.UUID(sid))
    out=w/s.name;out.mkdir(mode=0o700)
    app=Path.home()/"Applications/Nearpane P5.0/Nearpane P5.0 Alpha.app";host=app/"Contents/MacOS/NearpaneHost"
    runner=repo/"build/verification/P3.6/offline-run"
    se.verify_manifest(repo,s,host,json.loads((s/"manifest.json").read_bytes()))
    need(not list(s.glob("startup-*.json")) and not (s/"target-binding.json").exists(),"fresh unbound test session only")
    need(sp.run(["pgrep","-x","NearpaneHost"],stdout=sp.DEVNULL).returncode==1,"another Host is in use")
    before=se.durable(s)
    need(not before["assetOrder"] and before["attempts"]==before["starts"]==0,"empty isolated library required")
    def launch(name):
        prior=set(s.glob("startup-*.json"))
        with (out/(name+".log")).open("wb") as stream:
            p=sp.Popen([runner,sys.executable,"-B",repo/"scripts/native-acceptance.py","launch","--session",sid,
                        "--app",app,"--secondary-only","--desktop-fixture"],cwd=repo,stdout=stream,stderr=stream)
        try:
            stamp=json.loads(wait(lambda:next(iter(set(s.glob("startup-*.json"))-prior),None),10).read_bytes())
            pid=stamp["pid"];need(se.process_path(pid)==host,"installed process mismatch")
            events=s/(stamp["run"]+".jsonl")
            state=wait(lambda:next((e["state"] for e in reversed(se.events(events)) if e["state"]["visible"] and
                        e["state"]["windowID"]>0 and e["state"]["trayConnected"] and not e["state"]["mayAttach"]),None))
            def system(*c): return sp.run([runner,*c],check=True,timeout=8,cwd=repo)
            if name=="capture":
                # Product rechecks that the exact opaque NSWindow is on the secondary screen.
                # The button is pressed once only. Never invoke a chooser or retry after input.
                for action in ("expand","capture"):
                    system(w/"p50-capture-controls",str(pid),str(state["windowID"]),host,action)
                    time.sleep(.28)
                wait(lambda:len(se.durable(s)["assetOrder"])==1,7)
                wait(lambda:se.events(events)[-1]["state"]["trayCount"]==1)
                system(s/"capture-panel",str(pid),str(state["windowID"]),host,out/"系统截图入托盘.png","--secondary-only")
            else:
                wait(lambda:se.events(events)[-1]["state"]["trayCount"]==1)
            return pid
        finally:
            # The marked passive Host terminates itself through its ordinary shutdown barrier.
            need(p.wait(timeout=32)==0,"unclean Host exit")
    first=launch("capture")
    observed=se.durable(s)
    need(observed["intactMedia"] and len(observed["assetOrder"])==1 and not observed["attempts"] and not observed["starts"],"capture evidence mismatch")
    library=s/"support/Riftlet"
    with sqlite3.connect((library/"queue.sqlite").as_uri()+"?mode=ro",uri=True) as db:
        row=db.execute("select id,file_name,image_json from assets").fetchone()
        image=json.loads(row[2])
    media=library/"media"/row[1]
    need(media.parent==library/"media" and media.resolve()==media and image["origin"]=="applicationScreenshot" and row[1]==image["fileName"],"unexpected capture origin")
    digest=hashlib.sha256(media.read_bytes()).hexdigest()
    need(digest==image["sha256"],"asset hash mismatch")
    data=dict(session=sid,assetID=row[0],sha256=digest,bytes=media.stat().st_size,origin=image["origin"],firstPID=first,
              firstExit=0,starts=observed["starts"],attempts=observed["attempts"],chatGPTReceipt=None)
    (out/"captured.json").write_text(json.dumps(data,indent=2))
    (w/"captured.path").write_text(str(out/"captured.json"))
    second=launch("restart")
    need(se.durable(s)==observed and second!=first,"restart modified the queue or replayed an operation")
    (out/"restart.json").write_text(json.dumps(dict(secondPID=second,exit=0,durableUnchanged=True),indent=2))
    print(json.dumps(data))
if __name__=="__main__":main(sys.argv[1])
