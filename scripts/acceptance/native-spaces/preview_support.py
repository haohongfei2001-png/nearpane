"""Private raw pixel receipts and the existing installed Host visibility/budget contract."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

from acceptance import Receipt, hidden_budget
from space_scope import private_file, require


def surface_checkpoint(kit, host, n, stage, expected):
    """Two signed Host reads of the same visible product controls, without traversing other apps."""
    result={"status":"BLOCKED","stage":stage,"expectedCardCount":expected,"observations":[]}
    until=time.monotonic()+5;streak=0;previous=None
    while time.monotonic()<until:
        try:
            facts=json.loads(subprocess.check_output([kit/"preview-surface",str(host["pid"]),host["codeHash"]],text=True,timeout=3))
            metrics=json.loads(subprocess.check_output([kit/"metrics",str(host["pid"])],text=True,timeout=3))
            result["observations"].append({"surface":facts,"metrics":metrics})
            controls=facts.get("controls",{})
            valid=(facts.get("available") is True and facts.get("hostPID")==host["pid"] and facts.get("hostHash")==host["codeHash"] and
                   facts.get("space")==n and facts.get("stageManager") is stage and metrics.get("stageManagerOwnsDispatch")==int(stage) and
                   facts.get("windowCards")==expected and facts.get("duplicatedCards")==0 and facts.get("bareSpaceRows")==0 and
                   facts.get("legacyCards")==0 and facts.get("placeholderLabels")==[] and len(facts.get("panels",[]))==1 and
                   controls.get("tray-content",0)>0 and controls.get("voice-capture-toggle",0)>0 and
                   (controls.get("desktop-reserved-region")==0 if stage else controls.get("desktop-reserved-region")==1))
            key=(facts.get("hostBirth"),facts.get("panels"),facts.get("display"),facts.get("space"),controls)
            streak=streak+1 if valid and key==previous else 1 if valid else 0
            if streak>=2:result["status"]="PASS";break
            previous=key
        except (ValueError,OSError,subprocess.SubprocessError) as e:
            result["observations"].append({"readError":type(e).__name__});streak=0;previous=None
        time.sleep(.18)
    if result["status"]!="PASS":result["reason"]="requiredVisibleToolsHeaderCountsOrStageGuardUnconfirmed"
    return result


def copy_checked(folder, out, name, claimed, size, *, png=False):
    if png:
        require(name=="paired-overview.png", "unexpected overview output name")
    else:
        require(re.fullmatch(r"preview-[0-9]{5}\.rgba",name), "unexpected raw witness name")
    raw=private_file((folder/name).absolute(),limit=size)
    require((len(raw)<=size and png and raw.startswith(b"\x89PNG\r\n\x1a\n")) or (not png and len(raw)==size),
            "invalid witness encoding or size")
    require(hashlib.sha256(raw).hexdigest()==claimed,"witness digest mismatch")
    if not png:
        for i in range(0,1024,256):
            patch=raw[i:i+256];require(patch[3]==255 and patch==patch[:4]*64,"raw patch is not a uniform opaque test color")
    out.mkdir(mode=0o700,exist_ok=True)
    with (out/name).open("xb") as stream:stream.write(raw)


def copy_witnesses(folder, output, events, batches, identity):
    seen=set()
    for e in events:
        if "witness" not in e:continue
        w=e["witness"];n=w["batch"];epoch=w["epoch"]
        require(type(n) is int and 1<=n<=len(batches) and n not in seen and type(epoch) is int and 0<=epoch<7,
                "witness batch/epoch invalid")
        observed=batches[n-1]
        require(all(w[k]==identity[k] for k in ("hostPID","fixturePID","numbers","panel"))
                and w["file"]==f"preview-{n:05d}.rgba" and (w["cardKinds"]==["窗口画面","窗口画面"] or w.get("physicalFourPatch") is True)
                and w["bindingBefore"]<=min(p["start"] for p in observed) and w["bindingAfter"]>=max(p["end"] for p in observed)
                and w["bindingAfter"]-w["bindingBefore"]<=3 and w["uptime"]==observed[2]["end"]
                and [p["color"] for p in observed]==[f"0/{epoch}",f"1/{epoch}"]*2,"raw witness has no matching bound sample")
        copy_checked(folder,output/"witness",w["file"],w["sha256"],1024)
        seen.add(n)
    return len(seen)


def overview(kit, folder, output, binding):
    tool=kit/"paired-overview"
    if not tool.is_file():return {"status":"NOT_RUN","reason":"optionalOverviewKitUnavailable"}
    call=subprocess.run([tool,folder],input=json.dumps(binding),text=True,capture_output=True,timeout=20)
    proof=json.loads(call.stdout)
    if proof.get("status")=="CAPTURED":
        require(call.returncode==0,"overview capture returned a failure")
        copy_checked(folder,output/"witness",proof["file"],proof["sha256"],4_000_000,png=True)
    return proof


def with_current_streams(kit, host, profile_holds, binding, output):
    """Require positive real frames before hiding and again after the exact status-menu restoration."""
    result={"status":"BLOCKED","newStreamsDuringHidden":"NOT_MEASURED",
            "contract":"installed status menu, seven readbacks over 60s, restored delivery"}
    rec=Receipt(output)
    def counters():
        require(profile_holds(),"isolated Host writer changed")
        return json.loads(subprocess.check_output([kit/"metrics",str(host["pid"])],text=True,timeout=4))
    def advancing():
        points=[];end=time.monotonic()+4
        while time.monotonic()<end:
            s=counters()
            points.append({**s,"uptime":time.monotonic()})
            if "deliveredFrames" not in s:return points,False
            if len(points)>=2 and all(p.get("surfaceHidden")==0 and p.get("visibleDisplays")==1 and
                    p.get("stageManagerOwnsDispatch")==0 and p.get("activeStreams")==2 for p in points[-2:]) and s["deliveredFrames"]>points[-2]["deliveredFrames"]:
                return points,True
            time.sleep(.16)
        return points,False
    try:
        points,positive=advancing();result["before"]=points
        before=binding()
        result["originalCardKinds"]=before.get("kinds")
        require(positive and before.get("cardIdentityProven") and before.get("present")==[True,True],
                "exactTwoVisibleCardsAndTwoDeliveringProductionStreamsUnproven")
        observation=json.loads(subprocess.check_output([kit/"observe"],text=True,timeout=6))
        require(all(observation.get("host",{}).get(k)==v for k,v in host.items()),"installedHostGenerationChangedBeforeHiddenBudget")
        conclusion=hidden_budget(kit/"observe",observation,{"signatureValid":True,"loadedMatchesInstalled":True},rec)
        result["originalContract"]=conclusion;result.update(rec.summary)
        rec.stream.flush()
        samples=[json.loads(l) for l in (output/"actions.jsonl").read_text().splitlines()]
        hidden=[r for r in samples if r["event"]=="metrics-hidden-interval"]
        enough=len(hidden)==7 and hidden[-1]["elapsed"]-hidden[0]["elapsed"]>=59.8
        values=[r["sample"] for r in hidden]
        stopped=enough and all(v.get("activeStreams")==0 and v.get("capturesInFlight")==0 and v.get("surfaceHidden")==1
                               and v.get("visibleDisplays")==0 and v.get("gallerySessions")==0 for v in values)
        flat=enough and all(type(v.get("deliveredFrames")) is int and v["deliveredFrames"]==values[0]["deliveredFrames"] for v in values)
        result.update(zeroActiveStreamsAtEverySample=stopped,noNewDeliveredFramesAcrossMinute=flat)
        # The product has no cumulative stream-start counter. Sampled activeStreams
        # and immutable deliveredFrames cannot prove there was no undelivered transient stream.
        if not rec.summary.get("sidebarVisibilityRestored"):result["status"]="FAIL";return result
        result["after"],running=advancing()
        fresh=binding()
        result["restoredBoundCards"]=fresh.get("cardIdentityProven") is True and fresh.get("present")==[True,True]
        result["status"]="PASS" if (stopped and flat and running and result["restoredBoundCards"] and
                                     rec.summary.get("hiddenBudget",{}).get("zeroNewRequests") is True) else "FAIL"
    except (ValueError,KeyError,OSError,subprocess.SubprocessError) as exc:
        result["reason"]=str(exc)[:220]
    finally:
        rec.summary["streamDelivery"]=result.copy();rec.finish()
    return result
