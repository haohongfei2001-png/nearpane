"""Replay independent observations without opening any App, launching a trial, or accessing the network."""
import argparse
import gzip
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_bytes())


def audit(directory):
    raw = gzip.decompress((directory/"observations.jsonl.gz").read_bytes())
    events = [json.loads(line) for line in raw.splitlines()]
    if not events or [r["seq"] for r in events] != list(range(1,len(events)+1)):
        raise ValueError("missing observation")
    if any(a["monotonic_ns"] >= b["monotonic_ns"] for a,b in zip(events,events[1:])):
        raise ValueError("unordered observations")
    by = {r["event"]:r["data"] for r in events}
    checks = []
    for name,row in by.items():
        if not isinstance(row,dict) or not isinstance(row.get("windows"),dict):
            continue
        for label,w in row["windows"].items():
            owner=by["registered-"+label[0]]
            if (w["pid"],w["generation"],w["number"]) != (owner["pid"],owner["generation"],owner["windows"][int(label[1])]):
                raise ValueError("identity changed during "+name)
            if w["number"] != w["owner"]["id"]:
                raise ValueError("owner and observer disagree on identity during "+name)
        checks.append(name)
    s=read(directory/"summary.json")
    out={"runRevision":s["revision"],"os":s["os"].splitlines()[1:], "sip":s["sip"], "events":len(events),
         "independentSnapshots":len(checks),"cleanup":s["cleanup"],"dockPreferenceDuring":s.get("dockDuring"),"methods":{}}

    def win(phase):
        row=by.get(phase,{})
        if "windows" not in row: return None
        w=row["windows"]["A0"]
        return dict(ordered=w["ordered"],onScreen=w["cgScreen"] is not None,axMini=w["axMini"],leasedAX=w.get("axLease"),
                    ownerVisible=w["owner"]["visible"],ownerMini=w["owner"]["mini"],ownerContent=w["owner"]["content"],
                    spaces=w["spaces"],cgFrame=w["cgScreen"]["frame"] if w["cgScreen"] else None,
                    ownerFrame=w["owner"]["frame"],key=row["focus"]["label"],actualKeyID=row["focus"]["actualID"],
                    tiles=row["dock"].get("minimizedTiles"))
    for k,v in s["methods"].items():
        result={"status":v.get("status") or v.get("single",{}).get("status"),"reason":v.get("reason")}
        if k in ("A.single","B.ownerControl") or (k.startswith("B.") and "single" in v):
            result.update(baseline=win(k+".baseline"),hidden=win(k+".hidden-settled"),restored=win(k+".restored-settled"),
                          hidKeyDelta=by.get(k+".hidden.key-delta"),hidClickDelta=by.get(k+".hidden.click-delta"),
                          restoredKeyDelta=by.get(k+".restored.key-delta"),restoredClickDelta=by.get(k+".restored.click-delta"),
                          outCall=by.get(k+".out"),inCall=by.get(k+".in"),connection=by.get(k+".connection"),closed=by.get(k+".close"),
                          explicitForeignIn=by.get(k+".restore-only.foreign-in"),ownerSeed=win(k+".restore-only.owner-seeded"),
                          afterForeignIn=win(k+".restore-only.after-in"),foreignInClickDelta=by.get(k+".restore-only.click-delta"))
        if k == "A.userDock":
            result.update(dockClick=by.get(k+".click"),yieldReceipt=by.get(k+".yield"),
                          tilesSeeded=v.get("tilesSeeded"),tilesAfter=v.get("tilesAfter"))
        if k == "A.focusedTarget":
            result.update(before=win(k+".key-target"),hidden=win(k+".hidden"),
                          restored=win(k+".restored"),actualKeyDelta=by.get(k+".hidden.key-delta"))
        if k == "C.virtual":
            result.update(baseline=win("C.preTopology.baseline"),parked=win("C.parked"),afterTeardown=win("C.after-dispose"),
                          sharedEdges=v.get("sharedEdgesPixels"),absolutePointerReadback=by.get("C.absolutePointer",{}).get("pointer"),
                          parkedClickDelta=by.get("C.virtual-hit.click-delta"),physicalPointClickDelta=by.get("C.physical.click-delta"),
                          topologyRestored=v.get("topologyRestored"),humanRelativePointer=v.get("physicalAccidentalPointer"),
                          mcBefore=v.get("baselineMissionControl",{}).get("status"),mcWithVirtual=v.get("configuredMissionControl",{}).get("status"))
        if k == "A.crash":
            result.update(preCrash=win(k+".before-crash"),orphan=win(k+".after-crash"),recovered=win(k+".recovered"),
                          actorPID=by.get(k+".ack",{}).get("actorPID"),actorExit=v.get("actorExit"),
                          restoreKeyDelta=by.get(k+".recovered.key-delta"))
        if k == "C.crash":
            result.update(before=win(k+".preTopology.baseline"),parked=win(k+".before-crash"),postCrash=win(k+".after-crash"),
                          afterCleanup=win(k+".after-explicit-cleanup"),holderExit=v.get("holderExit"),
                          observedAfterCrash=by.get(k+".after-crash",{}).get("displays"))
        out["methods"][k]=result
    return out


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("receipt_directory",type=Path)
    print(json.dumps(audit(p.parse_args().receipt_directory),sort_keys=True,indent=2))
