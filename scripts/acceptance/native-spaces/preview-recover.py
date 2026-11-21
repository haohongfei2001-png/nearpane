#!/usr/bin/env python3
"""Recover one previously dispatched Stage Manager switch, its enrolled Settings window and its Space."""
import argparse
import importlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from installed_profile import APP, PROFILE, installed_pid, owns_profile
from space_scope import private_file, require

driver=importlib.import_module("preview-workspace")


def enrollment(output):
    original=json.loads(private_file(output/"result.json",limit=1_000_000))
    intent=json.loads(private_file(output/"stage-off-intent.json"))
    events=[json.loads(l) for l in private_file(output/"stage-off.jsonl").splitlines()]
    owned=[e for e in events if e.get("event")=="owned-settings"]
    presses=[e for e in events if e.get("event")=="press-intent"]
    replies=[e for e in events if e.get("event")=="press-reply"]
    baseline=original.get("stageBaseline",[])
    require(len(baseline)==2 and all(r.get("state") is True and r["uid"]==os.getuid() for r in baseline)
            and str(uuid.UUID(intent["operation"]))==intent["operation"] and intent["request"]["targetState"] is False
            and intent["request"]["expectedState"] is True and original["leasedSpace"]==intent["request"]["space"],
            "originalTrueLoginAndRequestedTransitionMissing")
    require(len(owned)==len(presses)==len(replies)==1 and presses[0].get("id")=="stage-manager-on"
            and presses[0].get("target") is False and replies[0].get("ax")==0 and
            owned[0]["uptime"]<=presses[0]["uptime"]<=replies[0]["uptime"],"priorPressNotUniquelyAcknowledged")
    require(any(e.get("event")=="switch-read" and e.get("window")==presses[0]["window"] and
                e.get("ui") is False and e.get("login") is False and e["uptime"]>=replies[0]["uptime"] for e in events),
            "noExternalPostDispatchOffReadForEnrolledWindow")
    return (intent["request"],{k:owned[0][k] for k in ("pid","birth","cdHash")}|{"window":presses[0]["window"]})


def recovery_owner(prior,source):
    intent=json.loads(private_file(prior/"fresh-off-to-original-on-intent.json"))
    r=intent["request"]
    require(r["expectedState"] is False and r["targetState"] is True and all(r[k]==source[k] for k in ("space","spaceUUID","display","hostHash")),
            "newRecoveryUIWasNotOpenedForTheOriginalEscrow")
    events=[json.loads(s) for s in private_file(prior/"fresh-off-to-original-on.jsonl").splitlines()]
    opened=[e for e in events if e.get("event")=="owned-settings"]
    reads=[e for e in events if e.get("event")=="switch-read" and e.get("ui") is False and e.get("login") is False]
    require(len(opened)==1 and len(reads)>=2 and reads[0]["window"]==reads[1]["window"] and
            reads[0]["uptime"]>=opened[0]["uptime"] and reads[1]["uptime"]>reads[0]["uptime"],"newRecoverySettingsWindowNotIndependentlyRegistered")
    return {k:opened[0][k] for k in ("pid","birth","cdHash")}|{"window":reads[0]["window"]}


def run(kit,original,out,prior=None,cleanup_only=False):
    os.umask(0o077);out.mkdir(mode=0o700,parents=True,exist_ok=False)
    result={"status":"BLOCKED","setting":{"status":"NOT_RUN"},"cleanup":{"status":"NOT_RUN"}}
    def save():
        p=out/"result.next";p.write_text(json.dumps(result,indent=2)+"\n");p.replace(out/"result.json")
    def log(event,**data):
        with (out/"actions.jsonl").open("a") as f:f.write(json.dumps(dict(event=event,**data))+"\n");f.flush();os.fsync(f.fileno())
    ws=None;keeper=None;stable=False;initial_pid=None
    try:
        request,owner=enrollment(original)
        if prior:owner=recovery_owner(prior,request)
        for app in [APP,kit/"preview-space-select",kit/"preview-stage-control",kit/"p0-card"]:
            subprocess.run(["/usr/bin/codesign","--verify","--strict",app],check=True,timeout=6)
        ws=driver.PreviewWorkspace(kit,original/"workspace",log,resume=True)
        initial_pid=installed_pid()
        require(ws.host["codeHash"]==request["hostHash"] and initial_pid==ws.host["pid"] and
                owns_profile(initial_pid,Path.home()/PROFILE),"actualSignedDailyHostOrProfileDoesNotMatchOriginalCandidate")
        n=request["space"];result["space"]=n
        active=ws.ids()
        if not active:
            readings=driver.states(kit)
            require(readings[-1]["state"] is True,"StageStillOffAfterOriginalSpaceWasRemoved")
            result.update(status="PASS",setting={"status":"PASS","actual":readings},cleanup={"status":"PASS","alreadyRemoved":True})
            return 0
        require(active==[n] and driver.lease_for(ws,n)[1]==request["spaceUUID"] and ws.display==request["display"],"originalSingleLeaseOrUUIDChanged")
        keeper=importlib.import_module("p0-focus").DailyFocus(kit/"p0-card",out,initial_pid)
        ws.bind_quiet_cleanup()
        before=driver.states(kit,preflight=True);result["before"]=before;save()
        if cleanup_only:
            require(before[-1]["state"] is True,"restorationOfTheOriginalStageStatePrecedesCleanup")
            m=json.loads(subprocess.check_output([kit/"metrics",str(ws.host["pid"])],text=True,timeout=5))
            require(m.get("stageManagerOwnsDispatch")==1,"runtimeHasNotConfirmedStageOwnsDispatch")
            result["runtimeStageManagerOwnsDispatch"]=1
            if before[-1]["existingSettingsInstance"]:
                top=ws.check(ws.read());cur=top["current"]
                require(cur==ws.cleanup_current and cur!=n,"mustBeOnConfirmedProtectedForegroundBeforeBackgroundClose")
                original_id=next(r["uuid"] for r in top["records"] if r["id"]==cur)
                req=dict(request,targetState=True,expectedState=False,hostPID=ws.host["pid"],hostBirth=ws.host_birth,hid=ws.hardware())
                with (out/"inactive-normal-quit.jsonl").open("xb") as stream:
                    call=subprocess.run([kit/"preview-stage-control","close-inactive"],
                                        input=json.dumps(dict(request=req,original=cur,originalUUID=original_id,**owner)).encode(),
                                        stdout=stream,env=driver.login_env(),timeout=16)
                require(call.returncode==0,"registeredInactiveQuitUnconfirmedSeeJournal")
        elif before[-1]["existingSettingsInstance"]:
            def qualified(snapshot):
                state=ws.check(snapshot);c=(snapshot.get("scopedMembers") or {}).get(str(n),{})
                return (state["current"] in (n,ws.cleanup_current) and c.get("unresolved")==0 and c.get("otherMembers")==0 and
                        c.get("ordinary")==[{"number":owner["window"],"pid":owner["pid"]}])
            hid=ws.hardware();snap=ws.read();time.sleep(.35);second=ws.read()
            require(qualified(snap) and qualified(second) and ws.check(snap)==ws.check(second) and ws.hardware()==hid,
                    "onlyRegisteredSettingsWindowQuietPeriodUnconfirmed")
            top=ws.check(second);cur=top["current"]
            if cur!=n:
                ask=dict(command="select",display=ws.display,records=top["records"],current=cur,original=ws.cleanup_current,owned=active,
                         target=n,hostPID=ws.host["pid"],hostHash=ws.host["codeHash"],hostBirth=ws.host_birth,hid=hid,kind="registered-settings",settings=owner)
                log("select-owned-settings-intent",target=n,window=owner["window"])
                call=subprocess.run([kit/"preview-space-select"],input=json.dumps(ask),text=True,capture_output=True,timeout=24)
                reply=json.loads(call.stdout);log("select-owned-settings-result",proof=reply)
                require(call.returncode==0 and reply.get("issued") and reply.get("acknowledged") and reply.get("overviewDismissed")
                        and reply.get("targetConfirmedBeforeOwnedOverviewClosed") and not reply.get("error"),reply.get("error","ownedSettingsSpaceSelectionIncomplete"))
                ws.settled(lambda o:qualified(o) and ws.check(o)["current"]==n,"ownedSettingsDesktopDidNotRemainCurrent")
            current=dict(request,targetState=True,expectedState=False,hostPID=ws.host["pid"],hostBirth=ws.host_birth,hid=ws.hardware())
            with (out/"registered-restore.jsonl").open("xb") as stream:
                call=subprocess.run([kit/"preview-stage-control","restore-registered"],input=json.dumps(dict(request=current,**owner)).encode(),
                                    stdout=stream,env=driver.login_env(),timeout=24)
            require(call.returncode==0,"registeredSettingsRestoreIncompleteSeeJournal")
        elif before[-1]["state"] is False:
            ws.select(n);driver.empty(ws,n)
            stage=driver.StageTransaction(kit,out,ws,n)
            try:stage.switch("fresh-off-to-original-on",False,True)
            finally:stage.cleanup_settings("fresh-off-to-original-on")
        after=driver.states(kit,preflight=True)
        require(after[-1]["state"] is True and not after[-1]["existingSettingsInstance"],"originalOnOrOwnedSettingsExitNotConfirmed")
        result["setting"]={"status":"PASS","actual":after};stable=True
        result["cleanup"]=ws.cleanup()
        require(result["cleanup"].get("topologyRestored") and result["cleanup"].get("outstanding")==[] and not result["cleanup"].get("errors"),
                "leasedDesktopRemovalOrSignedReturnNotConfirmed")
        result["status"]="PASS"
    except (ValueError,OSError,KeyError,subprocess.SubprocessError) as exc:
        result["reason"]=str(exc)[:240]
        if ws and not stable:
            try:
                if ws.check(ws.read())["current"] in ws.ids():ws.select(ws.cleanup_current)
            except (ValueError,KeyError,OSError,subprocess.SubprocessError) as e:result["returnReason"]=str(e)[:200]
    finally:
        if keeper:
            same=installed_pid()==initial_pid and owns_profile(initial_pid,Path.home()/PROFILE)
            keeper.finish(same);result["dailyFocus"]=keeper.info["status"];result["dailyHostAndLock"]=same
            if not same:result["status"]="BLOCKED"
        save()
    return 0 if result["status"]=="PASS" else 2


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("kit",type=Path);p.add_argument("original",type=Path);p.add_argument("output",type=Path)
    p.add_argument("--prior-recovery",type=Path,help="use the exact replacement Settings window journalled during an earlier restoration attempt")
    p.add_argument("--cleanup-only",action="store_true",help="require already-restored live Stage ON, quit only the exact background Settings generation, remove its resulting empty lease")
    a=p.parse_args();raise SystemExit(run(a.kit.resolve(),a.original.resolve(),a.output.resolve(),a.prior_recovery.resolve() if a.prior_recovery else None,a.cleanup_only))
