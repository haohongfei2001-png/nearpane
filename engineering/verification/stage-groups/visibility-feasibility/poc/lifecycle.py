"""Crash only processes created by the disposable lab. Journal restore never addresses another owner."""
import json
import subprocess
import time


def ax_crash(t):
    tag="A.crash"
    before,_=t.prepare(tag)
    initial=before["windows"]["A0"]
    journal={k:initial[k] for k in ("pid","generation","number","axFrame","spaces")}
    journal["ownerContent"]=initial["owner"]["content"]
    file=t.root/"managed-fixture-journal.json"
    with file.open("x") as f:
        json.dump(journal,f); f.flush()
        import os
        os.fsync(f.fileno())
    t.event(tag+".prepared",journal)
    p=subprocess.Popen([t.bin/"Inspect",t.root,"hold-minimized"],stdout=subprocess.PIPE,stderr=t.log,text=True)
    try:
        result=t.event(tag+".ack",json.loads(p.stdout.readline()))
        time.sleep(.65); applied=t.snap(tag+".before-crash")
        if result["axError"] or applied["windows"]["A0"]["axMini"] is not True:
            return {"status":"BLOCKED","reason":"minimize not witnessed"}
        p.kill(); rc=p.wait(timeout=5); time.sleep(.45)
        orphan=t.snap(tag+".after-crash")
        claimed=json.loads(file.read_bytes())
        w=orphan["windows"]["A0"]
        eligible=all(w[k]==claimed[k] for k in ("pid","generation","number","spaces")) and w["owner"]["content"]==claimed["ownerContent"] and w["axMini"] is True
        if rc!=-9 or not eligible:
            return {"status":"UNKNOWN","reason":"owner or journal state changed","actorExit":rc}
        t.event(tag+".new-actor-restore",t.inspected("restore","A0"))
        time.sleep(.8); after=t.snap(tag+".recovered"); a=after["windows"]["A0"]
        key=t.keyed(tag+".recovered",after,"A1")
        return {"status":"OBSERVED","actorExit":rc,"survivedActorDeath":bool(w["axMini"]),"orphanFocus":orphan["focus"],
                "newActorRestored":a["axMini"] is False and a["cgScreen"] is not None,
                "geometryAndContentRestored":a["axFrame"]==claimed["axFrame"] and a["owner"]["content"]==claimed["ownerContent"],
                "focusedAfterRestore":after["focus"],"originalSiblingReceivedKeyAfterRecovery":key}
    finally:
        if p.poll() is None: p.kill(); p.wait(timeout=5)


def display_crash(t):
    from run import await_file
    tag="C.crash"
    base,_=t.prepare(tag)
    before_mc=t.mc(tag+".baseline",capture=True)
    before,_=t.prepare(tag+".preTopology")
    original=before["windows"]["A0"]
    p=subprocess.Popen([t.bin/"Display",t.root],stdout=t.log,stderr=t.log)
    parked=None
    try:
        spec=t.event(tag+".virtual",await_file(t.root/"display.json",10))
        if spec["status"]!="READY": return {"status":"BLOCKED","reason":"no active virtual monitor","display":spec}
        x,y=spec["actual"][:2]
        move=t.event(tag+".move",t.inspected("move","A0",x+55,y+90))
        time.sleep(.7)
        parked=t.snap(tag+".parked")["windows"]["A0"]
        if move["axError"] or parked["owner"]["display"]!=spec["id"]:
            return {"status":"BLOCKED","reason":"parking independently unconfirmed"}
        parked_mc=t.mc(tag+".withVirtual",capture=True)
        t.snap(tag+".before-crash")
        p.kill(); rc=p.wait(timeout=5)
        end=time.monotonic()+4
        while time.monotonic()<end:
            if all(d["id"]!=spec["id"] for d in t.inspected("snapshot")["displays"]): break
            time.sleep(.12)
        time.sleep(.4)
        after=t.snap(tag+".after-crash"); a=after["windows"]["A0"]
        return {"status":"OBSERVED","holderExit":rc,"monitorRemoved":all(d["id"]!=spec["id"] for d in after["displays"]),
                "nativeSpaceReturned":None if not a["spaces"] or not original["spaces"] else a["spaces"]==original["spaces"],
                "originalGeometryReturnedWithoutWrites":a["axFrame"]==original["axFrame"],
                "originalDisplayReturned":a["owner"]["display"]==original["owner"]["display"],
                "contentPreserved":a["owner"]["content"]==original["owner"]["content"],"originalFocus":before["focus"],
                "focusAfterCrash":after["focus"],"priorMC":before_mc["status"],"parkedMC":parked_mc["status"]}
    finally:
        if p.poll() is None:
            (t.root/"display-stop").touch(); p.wait(timeout=8)
        if parked is not None and original["axFrame"]:
            t.event(tag+".fixture-cleanup-move",t.inspected("move","A0",*original["axFrame"][:2]))
            t.inspected("warp",*base["pointer"])
            time.sleep(.6)
            t.snap(tag+".after-explicit-cleanup")
