#!/usr/bin/env python3
"""Drive only the isolated, secondary-only admission Settings, never a frame setter."""
import hashlib
import json
import re
import os
import subprocess as sp
import sys
import time
import uuid
from pathlib import Path

import session_evidence as se

R = Path(__file__).resolve().parents[2]
A = Path.home() / "Applications/Nearpane P4.9/Nearpane P4.9 Alpha.app"
B = A / "Contents/MacOS/NearpaneHost"
F = A / "Contents/Helpers/NearpaneFixtureWindows.app/Contents/MacOS/NearpaneFixtureWindows"
W = R / "build/verification/p49"
OFF = R / "build/verification/P3.6/offline-run"

def get(path):
    return json.loads(path.read_bytes())

def put(path, payload):
    temp = path.with_suffix(".pending")
    temp.write_text(json.dumps(payload, ensure_ascii=False, indent=2))
    os.replace(temp, path)

def until(test, seconds=6):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            value = test()
            if value:
                return value
        except (FileNotFoundError, json.JSONDecodeError, IndexError):
            pass
        time.sleep(.09)
    raise RuntimeError("checkpoint missing at " + str(test.__code__.co_firstlineno))

def check(value, why):
    if not value:
        raise ValueError(why)

def path(pid):
    try:
        return se.process_path(pid)
    except ValueError:
        return None

def run(*cmd):
    return sp.check_output([OFF, *cmd], timeout=9, text=True)

def main(session, tight=False):
    S = R / "build/native-acceptance" / str(uuid.UUID(session))
    se.verify_manifest(R, S, B, get(S / "manifest.json"))
    check(not list(S.glob("startup-*.json")), "use a fresh marked session")
    check(sp.run(["pgrep", "-x", "NearpaneHost"], stdout=sp.DEVNULL).returncode == 1, "other Host active")
    pre = json.loads(run(A / "Contents/Helpers/NearpaneFrameController.app/Contents/MacOS/NearpaneFrameController", "preflight"))
    cfg = S / "support/Nearpane/host-configuration.json"
    config = get(cfg)
    side = config["preferredDisplayID"]
    check(pre["trusted"] and pre["screens"]["secondary"] == side != pre["screens"]["main"], "two displays / existing permission required")
    check(not config["displays"], "not a fresh profile")
    config["displays"][side] = dict(placement="docked", policy="onDemand", spacesDismissed=False, anchor="top",
        measures=["panelWidth", {"unit":"pt","value":20}, "panelHeight", {"unit":"pt","value":20},
                  "reservedWidth", {"unit":"pt","value":760 if tight else 120}])
    put(cfg, config)
    base = se.durable(S)
    out = W / ("native-" + session)
    out.mkdir(mode=0o700)
    sequence = 0
    epoch = None
    d = None
    baseline = {}
    injected = None
    root = S / "support/WorkRect"
    def send(action):
        nonlocal sequence
        sequence += 1
        put(S/"management-request.json", dict(run=epoch, sequence=sequence, action=action))
        until(lambda: get(S/("management-ack-"+epoch+".json")) == sequence)
    def owner():
        data = get(d / "owner.json")
        check(data["session"].lower() == d.name and path(data["owner"]["pid"]) == F and not data["keyOrMain"], "fixture identity/focus changed")
        return data
    def proof(label):
        data = owner()
        current = {str(m["id"]["element"]): f for m,f in zip(data["members"],data["frames"],strict=True)}
        for k,v in current.items():
            check(baseline.setdefault(k,v) == v, "fixture moved: "+label)
        artifacts = [p.name for p in d.iterdir() if p.name.startswith(("attempt-", "ticket", "grant", "journal", "presentation-request", "candidate.json"))]
        if injected is not None and "journal.json" in artifacts:
            check(hashlib.sha256((d/"journal.json").read_bytes()).hexdigest()==injected,"injected journal was changed")
            artifacts.remove("journal.json")
        check(not artifacts and get(root/"status.json")["mode"] == "off", "write channel used: "+str(artifacts))
        put(out/(label+"-owner.json"), dict(owner=data, writerArtifacts=artifacts, management="off"))
    def read(win):
        return json.loads(run(W/"admission-controls",str(pid),str(win),B,"read"))
    def ui(win):
        return {e["id"]:e["name"]+" "+e["value"] for e in read(win)["nodes"]}
    def press(win, control):
        # No retry of input; wait only for the read-side identifier.
        until(lambda: control in ui(win))
        run(W/"admission-controls",str(pid),str(win),B,control)
        time.sleep(.14)
    def sample(label, numbers=(),expected=None):
        press(settings,"admission-read")
        facts = until(lambda: (v if "admission-verdict" in v else None) if (v:=ui(settings)) else None)
        put(out/(label+".json"),facts)
        print(label, facts["admission-verdict"],facts.get("admission-reason",""),flush=True)
        if expected: check(expected in facts["admission-verdict"], label+" wrong verdict")
        for n in numbers:
            check("预计" in facts.get("admission-frame-"+str(n),""),label+" no proposed frame")
        proof(label)
        return facts
    hostlog = (out/"host.log").open("wb")
    child = sp.Popen([OFF, sys.executable,"-B",R/"scripts/native-acceptance.py","launch","--app",A,"--session",S.name,"--secondary-only"],
        cwd=R,env={**os.environ,"NEARPANE_MANAGEMENT_ACCEPTANCE":S.name,"NEARPANE_ADMISSION_ACCEPTANCE":S.name},stdout=hostlog,stderr=hostlog)
    try:
        stamp=get(until(lambda:next(iter(S.glob("startup-*.json")),None),12))
        pid=stamp["pid"];epoch=stamp["run"][7:]
        check(path(pid)==B,"wrong Host")
        settings=until(lambda:get(S/("management-panel-"+epoch+".json")))
        state=until(lambda:next((e["state"] for e in reversed(se.events(S/(stamp["run"]+".jsonl"))) if e["state"]["visible"]),None))
        sidebar=state["windowID"]
        icon=read(sidebar)
        check(icon["bounds"][2:]==[20,20] and "nearpane-open-panel" in ui(sidebar),"icon not shown")
        front=icon["frontPID"]
        for i in range(1,2 if tight else 4):
            send("open")
            d=until(lambda:next(iter(root.glob("????????-????-????-????-????????????")),None))
            until(lambda:len(owner()["members"])==i)
            proof("birth-"+str(i))
        ids=[m["id"]["number"] for m in owner()["members"]]
        press(settings,"admission-open");press(settings,"admission-fixture-app")
        if tight:
            press(settings,"admission-window-"+str(ids[0]))
            limited=sample("minimum-conflict",expected="明确不可管理")
            check("最小" in limited["admission-reason"] or "下限" in limited["admission-reason"],"no minimum-size reason")
            check("预计 (" not in limited["admission-frame-"+str(ids[0])],"infeasible slot drawn")
            press(settings,"admission-floating")
            sample("floating-fits",ids)
            return
        for i,num in enumerate(ids):
            press(settings,"admission-window-"+str(num))
            observed=sample("members-"+str(i+1),ids[:i+1],"可以进入进一步授权")
            if i==1:
                press(settings,"admission-custom")
                custom=sample("two-custom",ids[:2])
                check(custom["admission-frame-"+str(ids[0])]!=observed["admission-frame-"+str(ids[0])],"no change from hypothetical 60% pair")
                press(settings,"admission-custom")
        # Assert the actual geometry shown by installed Settings, separately from the
        # owner frames and before-setter attempt audit. This display has a right reservation.
        frames=[m for m in owner()["frames"]]
        for n,f in zip(ids,frames,strict=True):
            actual=observed["admission-frame-"+str(n)].split("当前 ",1)[1].split(", 预计",1)[0]
            ungroup=lambda text: re.sub(r"(?<=\d),(?=\d{3}\b)","",text)
            values=[float(x) for x in re.findall(r"-?\d+(?:\.\d+)?",ungroup(actual))]
            check(values == [f[k] for k in ("x","y","width","height")],"UI current frame differs from owner")
        run(S/"capture-panel",str(pid),str(settings),B,out/"Settings-三窗准入.png","--secondary-only")
        press(settings,"admission-floating");floating=sample("floating",ids)
        press(settings,"admission-docked");docked=sample("docked",ids)
        check(docked["admission-workrect"]!=floating["admission-workrect"],"no WorkRect change")
        press(settings,"admission-current")
        send("exclude-last")
        until(lambda: "exclude" in get(cfg)["workspaces"]["windows"])
        sample("excluded",expected="明确不可管理")
        send("include-last")
        until(lambda: "exclude" not in get(cfg)["workspaces"]["windows"])
        sample("included",ids,"可以进入进一步授权")
        # Isolated fault injection: only our brand-new, never-granted scope. An
        # incomplete journal is a test input, not a crash or evidence of a write.
        wal=d/"journal.json"
        o=owner()
        testwal=dict(session=o["session"],owner=o["owner"],status="prepared",display=side,
                     transaction=str(uuid.uuid4()),changes=[])
        with wal.open("xb") as f: f.write(json.dumps(testwal).encode())
        injected=hashlib.sha256(wal.read_bytes()).hexdigest()
        try:
            refused=sample("pending-journal",expected="当前条件不足")
            check("恢复记录" in refused.get("admission-reason",""),"pending journal not noticed")
        finally:
            check(hashlib.sha256(wal.read_bytes()).hexdigest()==injected,"refuse to remove altered WAL")
            wal.unlink()
            injected=None
        press(sidebar,"nearpane-open-panel");until(lambda:"nearpane-close-panel" in ui(sidebar))
        press(sidebar,"nearpane-close-panel");until(lambda:read(sidebar)["bounds"][2:]==[20,20])
        sample("returned-from-icon",ids,"可以进入进一步授权")
        send("close");until(lambda:len(owner()["members"])==2);send("open");until(lambda:len(owner()["members"])==3)
        check(ids[-1] not in [m["id"]["number"] for m in owner()["members"]],"window number reused; inspect generation")
        stale=sample("recreated")
        check("可以进入进一步授权" not in stale["admission-verdict"],"stale selection admitted")
        check(read(settings)["frontPID"]==front and front not in (pid,owner()["owner"]["pid"]), "frontmost changed")
        put(out/"summary.json",dict(session=session,fixtureIDs=ids,installedHostPID=pid,windowManagement="off",
            actualFrameWriteAttempts=0,proof="No writer grant, ticket, WAL or before-setter attempt; owner frames unchanged for every original incarnation.",
            icon=icon["bounds"],frontmostUnchanged=True))
    except Exception:
        if "settings" in locals() and path(pid) == B:
            try: put(out/"settings-at-stop.json",read(settings))
            except (ValueError,OSError,sp.SubprocessError): pass
        raise
    finally:
        if child.poll() is None and epoch:
            try: send("quit")
            except (RuntimeError,OSError): pass
        rc=child.wait(timeout=106)
        hostlog.close()
        if d is not None and (d/"owner.json").exists():
            o=get(d/"owner.json");fp=o["owner"]["pid"]
            if path(fp)==F and o["session"].lower()==d.name:
                put(d/"command.json",dict(sequence=o["command"]+1,action="quit",index=0))
                until(lambda:path(fp) is None)
        check(rc==0 and se.durable(S)==base,"exit/domain readback mismatch")
        put(out/"cleanup.json",dict(hostExit=rc,fixtureEnded=not d or path(get(d/"owner.json")["owner"]["pid"]) is None,domainStateUnchanged=True))

if __name__ == "__main__":
    if len(sys.argv) not in (2,3) or (len(sys.argv)==3 and sys.argv[2]!="--tight"):
        raise SystemExit("usage: verify-window-admission.py SESSION [--tight]")
    main(sys.argv[1], tight=len(sys.argv)==3)
