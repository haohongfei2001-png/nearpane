#!/usr/bin/env python3
"""Run installed preview and optional native Split View in one disposable ordinary desktop."""
import argparse
import importlib
import json
import os
from pathlib import Path
import pwd
import signal
import stat
import subprocess
import sys
import time
import uuid

from contract_workspace import Workspace, row, write_owned
from installed_profile import APP, PROFILE, installed_pid, owns_profile, validate_home
from preview_support import surface_checkpoint
from space_scope import ScopeError, private_file, require

HERE = Path(__file__).resolve().parent


def login_env():
    env = os.environ.copy()
    env.pop("CFFIXED_USER_HOME", None)
    env["HOME"] = pwd.getpwuid(os.getuid()).pw_dir
    return env


def states(kit, preflight=False):
    rows = []
    for i in range(2):
        if i: time.sleep(.18)
        args = [kit/"preview-stage-control", "preflight" if preflight else "state"]
        process = subprocess.run(args, env=login_env(), text=True, capture_output=True, timeout=6)
        value = json.loads(process.stdout)
        require(process.returncode == 0, value.get("reason", "actualLoginStageReadUnavailable"))
        require(value.get("uid") == os.getuid() and type(value.get("state")) is bool, "invalidActualLoginStageRead")
        rows.append(value)
    require(rows[0]["state"] == rows[1]["state"] and rows[1]["uptime"] - rows[0]["uptime"] >= .15,
            "actualLoginStageStateChangedBetweenReads")
    return rows


def lease_for(ws, target):
    matching = [(p, json.loads(private_file(p))) for p in ws.ledgers]
    matching = [(p, r) for p, r in matching if r["target"] == str(target) and r["intent"]["boot"] == ws.boot
                and r["intent"]["display"] == ws.display and not p.with_name("removed.json").exists()]
    require(len(matching) == 1 and target in ws.ids(), "newDesktopCreationReceiptUnverified")
    path, receipt = matching[0]
    return path, receipt["after"]["spaceUUIDs"][str(target)]


def empty(ws, n):
    _, identity = lease_for(ws, n)
    def available(o):
        s = ws.check(o)
        census = (o.get("scopedMembers") or {}).get(str(n), {})
        return (s["current"] == n and any(r == dict(id=n, type=0, uuid=identity) for r in s["records"])
                and census.get("ordinary") == [] and census.get("unresolved") == 0 and census.get("otherMembers") == 0)
    # Explicitly require an empty scoped census twice. Workspace.settled alone
    # compares topology, which may stay equal across a transient occupancy refusal.
    before=None;end=time.monotonic()+4;last=None
    while time.monotonic()<end:
        o=ws.read()
        last=(o.get("scopedMembers") or {}).get(str(n),{})
        if available(o):
            if before is not None and o["uptime"]>before:
                return {"space":n,"spaceUUID":identity,"uptimes":[before,o["uptime"]]}
            before=o["uptime"]
        else:before=None
        time.sleep(.16)
    count=len(last["ordinary"]) if isinstance((last or {}).get("ordinary"),list) else None
    raise ScopeError(f"controlledSpaceEmptyMembershipNotProven: ordinary={count}, other={(last or {}).get('otherMembers')}, unresolved={(last or {}).get('unresolved')}")


def child(path, args, *, env=None, timeout):
    command = [sys.executable, str(path), *map(str,args)]
    result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL, timeout=timeout)
    return result.returncode


def readable_result(path):
    return json.loads(private_file(path.resolve(), limit=1_500_000))


def validate_script(path, name):
    if path is None: return None
    require(path.is_absolute() and path.resolve() == path and path.name == name, "unrecognizedOptionalEntry")
    st = path.stat()
    require(stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid() and not st.st_mode & 0o022, "optionalEntryOwnerOrPermissions")
    return path


def stage_media(command,kit,folder,ws,target):
    if not command:return {"status":"NOT_RUN","reason":"noStageMediaCommand"}
    result={"status":"BLOCKED","folder":folder.name}
    try:
        script=validate_script(command,"compact-panel.py")
        empty(ws,target)
        require(states(kit)[-1]["state"] is True,"compactPanelOnlyDuringConfirmedOriginalStageOn")
        subprocess.run(["/usr/bin/codesign","--verify","--strict",kit/"compact-tool-capture"],check=True,timeout=5)
        code=child(script,[kit,folder,"--current-empty"],timeout=28)
        headers=[f for f in (folder/"receipt.json",folder/"result.json") if f.is_file()]
        require(bool(headers),"compactToolCaptureDidNotLeaveAReceipt")
        proof=readable_result(headers[0])
        result.update(status=proof["status"],exit=code,receipt=folder.name+"/"+headers[0].name)
        if proof.get("reason"):result["reason"]=str(proof["reason"])[:200]
    except (OSError,ValueError,KeyError,RuntimeError,subprocess.SubprocessError) as exc:result["reason"]=str(exc)[:200]
    return result


class PreviewWorkspace(Workspace):
    fixture=None

    def select(self,n):
        original=self.read();top=self.check(original);current=top["current"]
        if n==current or any(r["id"] in (n,current) and r["type"]!=0 for r in top["records"]):
            return super().select(n)
        require(n in self.ids() or n==self.cleanup_current,"system selection outside preview lease")
        hid=self.hardware();fresh=self.read()
        require(self.check(fresh)==top and hid==self.hardware() and
                (fresh.get("frontmostPID"),fresh.get("focusedNumber"))==(original.get("frontmostPID"),original.get("focusedNumber")),
                "hardware focus or Space changed before direct system AX selection")
        if n==self.cleanup_current:kind="daily-origin"
        else:kind="two-documents" if self.fixture and self.fixture["space"]==n else "empty"
        request=dict(command="select",display=self.display,records=top["records"],current=current,original=self.cleanup_current,
                     owned=self.ids(),target=n,hostPID=self.host["pid"],hostHash=self.host["codeHash"],hostBirth=self.host_birth,
                     hid=hid,kind=kind,fixture=self.fixture if kind=="two-documents" else None)
        self.record("system-AX-tile-intent",source=current,target=n,occupancy=kind)
        r=subprocess.run([self.kit/"preview-space-select"],input=json.dumps(request),text=True,capture_output=True,timeout=24)
        reply=json.loads(r.stdout)
        self.record("system-AX-tile-result",source=current,target=n,proof=reply)
        require(r.returncode==0 and reply.get("issued") is True and reply.get("acknowledged") is True and reply.get("action")=="AXPress"
                and reply.get("targetConfirmedBeforeOwnedOverviewClosed") is True and reply.get("overviewDismissed") is True and not reply.get("error"),
                reply.get("error","semanticSystemDesktopSelectionNotIndependentlyConfirmed"))
        return self.settled(lambda o:self.check(o)["current"]==n and self.check(o)["records"]==top["records"],"systemSelectionArrivalNotStable")


def system_switch(ws, a, fixture, folder):
    """System selection A → empty B → A. Every read is bound to the original two window numbers."""
    folder.mkdir(mode=0o700)
    result={"status":"BLOCKED","operation":"system Mission Control Space selection","productActions":0,
            "physicalThreeFingerGesture":"NOT_RUN","a":a,"b":None,"readbacks":[],"returnedA":False}
    host=ws.host;windows=fixture["numbers"];p=fixture["fixturePID"]
    def persist():
        tmp=folder/"result.next"
        tmp.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n");tmp.replace(folder/"result.json")
    def check_members(expected_current,b):
        out=[]
        for i in range(2):
            if i:time.sleep(.17)
            args=[ws.kit/"preview-surface","members",str(host["pid"]),host["codeHash"],str(p),str(fixture["fixtureBirth"]),fixture["fixtureHash"],*map(str,windows)]
            reverse=json.loads(subprocess.check_output(args,text=True,timeout=5))
            snapshot=ws.read();current=ws.check(snapshot)["current"]
            membership=(snapshot.get("scopedMembers") or {})
            view={}
            for sid in [a]+([b] if b is not None else []):
                c=membership.get(str(sid),{});raw=c.get("ordinary")
                view[str(sid)]={"complete":isinstance(raw,list) and c.get("otherMembers")==0 and c.get("unresolved")==0,
                                "count":len(raw) if isinstance(raw,list) else None,
                                "enrolled":sorted(w["number"] for w in (raw or []) if w["pid"]==p and w["number"] in windows)}
            value={"current":current,"expectedCurrent":expected_current,"forward":view,"reverse":reverse,"uptime":snapshot["uptime"]}
            out.append(value);result["readbacks"].append(value);persist()
            require(reverse.get("available") is True and reverse.get("current")==current==expected_current,"currentSpaceOrExactWindowGenerationUnconfirmed")
            require(all(c["complete"] for c in view.values()),"partialIndependentForwardCensus")
            if reverse["reverse"]!=[[a],[a]] or view[str(a)]["enrolled"]!=sorted(windows) or (b is not None and view[str(b)]["enrolled"]):
                result["status"]="FAIL";raise ScopeError("enrolledWindowsDidNotStayExclusivelyOnA")
            require(view[str(a)]["count"]==2 and (b is None or view[str(b)]["count"]==0),"anotherOrdinaryWindowEnteredControlledSpace")
        return out
    def card_pair():
        tool=ws.kit/"paired-scope"
        app=ws.kit/"Field Notes.app/Contents/MacOS/FieldNotes"
        args=[tool,host["pid"],host["codeHash"],p,fixture["fixtureBirth"],fixture["fixtureHash"],app,*windows,a]
        rows=[]
        for i in range(2):
            if i:time.sleep(.17)
            report=json.loads(subprocess.check_output(list(map(str,args)),text=True,timeout=5))
            rows.append({k:report[k] for k in ("ready","reason","space","numbers","fixtureBirth","hostBirth","kinds","present") if k in report})
        return {"reads":rows,"exact":all(r.get("ready") and r.get("space")==a and r.get("numbers")==windows and
                      r.get("fixtureBirth")==fixture["fixtureBirth"] and r.get("hostBirth")==fixture["hostBirth"] for r in rows)}
    b=None;baseline=ws.hardware();persist();ws.fixture=fixture
    try:
        require(a in ws.ids() and ws.check(ws.read())["current"]==a and states(ws.kit)[-1]["state"] is False,"requiresStageOffOwnedSpaceA")
        check_members(a,None);result["beforeA"]=card_pair();require(result["beforeA"]["exact"],"exactSourceCardsBeforeSystemSwitchMissing")
        b=ws.create();result["b"]=b;lease_for(ws,b);persist()
        current=ws.check(ws.read())["current"]
        require(current in (a,b) and ws.hardware()==baseline,"userInputOrUnenrolledSpaceChangedDuringDesktopCreation")
        check_members(current,b)
        ws.select(b)
        check_members(b,b)
        surface=surface_checkpoint(ws.kit,host,b,False,0)
        result["emptyBProduct"]=surface
        leaks=[r["surface"] for r in surface["observations"] if r.get("surface",{}).get("space")==b and
               r["surface"].get("hostBirth")==fixture["hostBirth"] and (r["surface"].get("windowCards") or 0)>0]
        result["oldCardObservationsOnVerifiedEmptyB"]=len(leaks)
        if leaks:
            first_zero=next((r["surface"]["uptime"] for r in surface["observations"]
                            if r.get("surface",{}).get("space")==b and r["surface"].get("windowCards")==0 and
                            r["surface"]["uptime"]>=leaks[0]["uptime"]),None)
            result["firstNonzeroUptime"]=leaks[0]["uptime"];result["firstSubsequentZeroUptime"]=first_zero
            result["status"]="FAIL";raise ScopeError("productionSidebarShowedCardsOnIndependentlyEmptyB")
        require(surface["status"]=="PASS","twoProductZeroCardReadsOnEmptyBUnconfirmed")
        result["status"]="PASS"
    except (OSError,ValueError,KeyError,RuntimeError,subprocess.SubprocessError) as e:result["reason"]=str(e)[:220]
    finally:
        try:
            current=ws.check(ws.read())["current"]
            require(current in (a,b) and ws.hardware()==baseline,"anotherUserSelectionOrInputSupersededReturnA")
            ws.select(a);check_members(a,b);result["returnedA"]=True;result["afterA"]=card_pair()
            require(result["afterA"]["exact"],"exactSourceCardsAfterSystemReturnMissing")
        except (OSError,ValueError,KeyError,RuntimeError,subprocess.SubprocessError) as e:
            result["returnReason"]=str(e)[:220]
            if result["status"]!="FAIL":result["status"]="BLOCKED"
        ws.fixture=None
        persist()
    return result


class StageTransaction:
    def __init__(self, kit, output, ws, n):
        self.kit, self.output, self.ws, self.n = kit, output, ws, n

    def switch(self, name, old, new):
        clean = empty(self.ws, self.n)
        request = dict(targetState=new, expectedState=old, display=self.ws.display, space=self.n,
                       spaceUUID=clean["spaceUUID"],hostPID=self.ws.host["pid"],hostBirth=self.ws.host_birth,
                       hostHash=self.ws.host["codeHash"],hid=self.ws.hardware())
        write_owned(self.output/(name+"-intent.json"), {"operation":str(uuid.uuid4()),"request":request,"empty":clean})
        path = self.output/(name+".jsonl")
        with path.open("xb") as stream:
            subprocess.run([self.kit/"preview-stage-control","switch"],input=json.dumps(request).encode(),
                           stdout=stream,stderr=subprocess.DEVNULL,env=login_env(),timeout=45)
        events = self.events(name)
        require(events and events[-1].get("event") == "complete",
                next((e["reason"] for e in reversed(events) if "reason" in e), "systemSettingsTransactionIncomplete"))
        after = states(self.kit)
        require(after[-1]["state"] is new, "postSettingsIndependentLoginStateMismatch")
        return dict(status="PASS", actual=after, empty=empty(self.ws, self.n), journal=path.name)

    def events(self, name):
        p = self.output/(name+".jsonl")
        if not p.is_file(): return []
        rows=[]
        for line in p.read_bytes().splitlines():
            try: rows.append(json.loads(line))
            except ValueError: rows.append({"event":"unknown-truncated-reply"})
        return rows

    def cleanup_settings(self,name):
        events=self.events(name)
        owned = [e for e in events if e.get("event") == "owned-settings"]
        closed = {e["pid"] for e in events if e.get("event") == "owned-settings-closed"}
        for e in owned:
            if e["pid"] in closed:continue
            # Read the actual generation written before the action. A later Settings
            # instance or a user's new input cannot inherit this normal-quit request.
            original=json.loads(private_file(self.output/(name+"-intent.json")))["request"]
            recovery=dict(request=original,**{k:e[k] for k in ("pid","birth","cdHash")})
            with (self.output/(name+"-settings-cleanup.jsonl")).open("xb") as out:
                call=subprocess.run([self.kit/"preview-stage-control","close-owned"],input=json.dumps(recovery).encode(),
                                    stdout=out,stderr=subprocess.DEVNULL,env=login_env(),timeout=14)
            require(call.returncode==0,"ownedSettingsNormalQuitUnconfirmed: "+name)

    def restore(self, initial):
        events=self.events("stage-off")
        owned=[e for e in events if e.get("event")=="owned-settings"]
        presses=[e for e in events if e.get("event")=="press-intent" and e.get("id")=="stage-manager-on" and e.get("target") is False]
        qualified=(initial is True and len(owned)==len(presses)==1 and not any(e.get("event")=="owned-settings-closed" for e in events)
                   and any(e.get("event")=="press-reply" and e.get("ax")==0 for e in events)
                   and any(e.get("event")=="switch-read" and e.get("ui") is False and e.get("login") is False and
                           e.get("window")==presses[0]["window"] for e in events))
        if qualified and states(self.kit,preflight=True)[-1]["existingSettingsInstance"]:
            owner=owned[0];request=json.loads(private_file(self.output/"stage-off-intent.json"))["request"]
            request.update(expectedState=False,targetState=True,hid=self.ws.hardware())
            with (self.output/"stage-restore-registered.jsonl").open("xb") as out:
                call=subprocess.run([self.kit/"preview-stage-control","restore-registered"],
                                    input=json.dumps(dict(request=request,window=presses[0]["window"],**{k:owner[k] for k in ("pid","birth","cdHash")})).encode(),
                                    stdout=out,env=login_env(),timeout=26)
            require(call.returncode==0,"originalRegisteredSettingsRestoreUnconfirmed")
            actual=states(self.kit,preflight=True)
            require(actual[-1]["state"] is True and not actual[-1]["existingSettingsInstance"],"registeredRestoreOrExitNotConfirmed")
            return dict(status="PASS",actual=actual,changedByRun=True,registeredRecovery=True,journal="stage-restore-registered.jsonl")
        self.cleanup_settings("stage-off")
        now = states(self.kit)
        had_press = any(e.get("event") == "press-intent" for e in self.events("stage-off"))
        if now[-1]["state"] is initial:
            return dict(status="PASS",actual=now,changedByRun=had_press,restorationPress=False)
        require(initial is True and had_press, "stateChangedWithoutThisRunsSystemSwitchDispatch")
        try:result=self.switch("stage-restore",False,True)
        finally:self.cleanup_settings("stage-restore")
        result.update(changedByRun=True,restorationPress=True)
        return result


class PreferenceStage:
    """Explicit acceptance-only loan of one existing boolean in the actual login domain."""
    domain="com.apple.WindowManager"
    key="GloballyEnabled"
    def __init__(self,kit,output,ws,n):
        self.kit,self.output,self.ws,self.n=kit,output,ws,n

    def runtime(self,value):
        samples=[];positive=[];end=time.monotonic()+7
        while time.monotonic()<end:
            state=states(self.kit)
            m=json.loads(subprocess.check_output([self.kit/"metrics",str(self.ws.host["pid"])],text=True,timeout=4))
            o=self.ws.read()
            top=row(o)
            sample={"actualLogin":state,"runtime":m,"hostUnchanged":o.get("host")==self.ws.host,"current":top["current"]}
            samples.append(sample)
            criteria=(state[-1]["state"] is value and sample["hostUnchanged"] and m.get("stageManagerOwnsDispatch")==int(value))
            if value:
                criteria=criteria and all(m.get(k)==0 for k in ("activeStreams","capturesInFlight","gallerySessions","visibleDisplays"))
            else:criteria=criteria and m.get("visibleDisplays")==1 and m.get("gallerySessions") in (0,1) and type(m.get("deliveredFrames")) is int
            if criteria:positive.append(m)
            else:positive=[]
            if len(positive)>=2 and (not value or all(positive[-1].get(k)==positive[-2].get(k) for k in ("deliveredFrames","captureRequests"))):
                return {"status":"PASS","reads":samples}
            time.sleep(.16)
        return {"status":"BLOCKED","reads":samples,"reason":"independentLoginAndActualSignedHostDidNotConverge"}

    def toggle(self,name,old,new):
        current=states(self.kit)
        require(current[-1]["state"] is old and type(old) is bool and new is not old,"singlePreferenceCompareBeforeWriteFailed")
        kind=subprocess.check_output(["/usr/bin/defaults","read-type",self.domain,self.key],text=True,env=login_env(),timeout=4).strip()
        require(kind.lower().endswith("boolean"),"existingLoginPreferenceIsNotBoolean")
        path=self.output/(name+"-preference-intent.json")
        write_owned(path,dict(operation=str(uuid.uuid4()),uid=os.getuid(),display=self.ws.display,space=self.n,
                              host=self.ws.host,domain=self.domain,key=self.key,previous=old,target=new,baseline=current,
                              setupOnly=True,countsAsAppleUIAcceptance=False))
        command=["/usr/bin/defaults","write",self.domain,self.key,"-bool","true" if new else "false"]
        call=subprocess.run(command,env=login_env(),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=4)
        write_owned(self.output/(name+"-preference-delivery.json"),dict(exit=call.returncode,setupOnly=True))
        require(call.returncode==0,"oneScopedPreferenceWriteNotAcknowledged")
        proof=self.runtime(new)
        write_owned(self.output/(name+"-runtime.json"),proof)
        require(proof["status"]=="PASS",proof.get("reason","unknownRuntimeReadback"))
        return {"status":"PASS","method":"isolated acceptance, temporary existing login boolean","setupOnly":True,
                "countsAsAppleUIAcceptance":False,"runtimeReceipt":name+"-runtime.json"}

    def switch(self,name,old,new):
        require(name=="stage-off" and old is True and new is False,"invalidTemporarySetupRequested")
        empty(self.ws,self.n);runtime=self.runtime(old)
        require(runtime["status"]=="PASS","originalLoginAndRuntimeBeforeTemporarySetupUnconfirmed")
        return self.toggle(name,old,new)

    def restore(self,initial):
        before=states(self.kit)
        if before[-1]["state"] is initial:
            actual=self.runtime(initial)
            return {"status":actual["status"],"method":"already at original setting","actual":actual,
                    "setupOnly":True,"restorationPress":False}
        intent=json.loads(private_file(self.output/"stage-off-preference-intent.json"))
        require(initial is True and intent["previous"] is True and intent["target"] is False and intent["uid"]==os.getuid()
                and intent["domain"]==self.domain and intent["key"]==self.key and intent["host"]==self.ws.host and intent["space"]==self.n,
                "noMatchingSingleSettingLoanForReturn")
        # Restoration addresses only the one held login key, even when a child failed
        # and its window delays desktop removal. It sends no input to the foreground.
        return self.toggle("stage-restore",False,True)


def run(args):
    os.umask(0o077)
    kit, output = args.kit.resolve(), args.output.resolve()
    output.mkdir(mode=0o700,parents=True,exist_ok=False)
    result={"status":"BLOCKED","preflightOnly":args.preflight_only,"ordinaryDesktopsRequested":2 if args.system_switch else 1,
            "preview":{"status":"NOT_RUN"},"splitView":{"status":"NOT_RUN"},"media":{"status":"NOT_RUN"},
            "stageSetup":{"status":"NOT_RUN"},"stageRestore":{"status":"NOT_RUN"},"workspaceCleanup":{"status":"NOT_RUN"}}
    def save():
        next_path=output/"result.next"
        next_path.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n");os.replace(next_path,output/"result.json")
    def record(event, **info):
        with (output/"workspace-actions.jsonl").open("a") as log:
            log.write(json.dumps(dict(event=event,**info),ensure_ascii=False)+"\n");log.flush();os.fsync(log.fileno())
    errors=(OSError,ValueError,KeyError,RuntimeError,subprocess.SubprocessError,KeyboardInterrupt)
    ws=None; stage=None; initial=None;media=None
    save()
    try:
        require(kit.parent==Path("/private/tmp") and kit.name.startswith("nearpane-d01.") and kit.stat().st_uid==os.getuid()
                and not kit.stat().st_mode&0o077,"unqualifiedPrivateKit")
        for tool in ("preview-stage-control","preview-surface","preview-space-select","paired-scope","paired-capture","observe","system-workspace","metrics"):
            subprocess.run(["/usr/bin/codesign","--verify","--strict",kit/tool],check=True,timeout=6)
        split=validate_script(args.split_command,"split-view.py")
        media=validate_script(args.media_command,"live-preview-media.py")
        subprocess.run(["/usr/bin/codesign","--verify","--strict","--deep","-R=identifier \"com.holdsnow.nearpane.alpha\"",APP],check=True,timeout=10)
        initial_reads=states(kit,preflight=True)
        result["stageBaseline"]=initial_reads;initial=initial_reads[-1]["state"];save()
        require(all(r.get("ax") and r.get("screen") for r in initial_reads),"observerAXOrScreenPermissionMissing")
        require(args.stage_method=="temporary-preference" or not initial or all(r.get("existingSettingsInstance") is False for r in initial_reads),
                "existingSettingsInstanceProtected")
        if args.preflight_only:
            result["status"]="READY";return 0
        test=os.environ.get("NEARPANE_TEST_HOME")
        require(test and os.environ.get("NEARPANE_TEST_GENERATION"),"runInsideInstalledProfileWrapper")
        home=Path(test);validate_home(home);pid=installed_pid()
        require(owns_profile(pid,home/PROFILE),"installedHostDoesNotOwnIsolatedWriterLock")
        desktop=output/"workspace";desktop.mkdir(mode=0o700)
        ws=PreviewWorkspace(kit,desktop,record)
        require(ws.host["pid"]==pid,"workspaceHostDoesNotMatchIsolatedInstalledHost")
        target=ws.create();result["leasedSpace"]=target;save()
        ws.select(target);result["initialEmptyScope"]=empty(ws,target)
        stage=(PreferenceStage if args.stage_method=="temporary-preference" else StageTransaction)(kit,output,ws,target)
        result["stageMethod"]=args.stage_method
        result["originalStageSurface"]=surface_checkpoint(kit,ws.host,target,initial,0)
        if initial and args.stage_media_command:
            result["stageOnMedia"]=stage_media(args.stage_media_command,kit,output/"stage-on-media",ws,target);save()
        if initial:
            result["stageSetup"]=stage.switch("stage-off",True,False)
        else:
            fresh=states(kit);require(fresh[-1]["state"] is False,"stageChangedBeforePreview")
            result["stageSetup"]={"status":"PASS","initiallyOff":True,"actual":fresh,"press":False}
        save()
        result["offZeroBefore"]=surface_checkpoint(kit,ws.host,target,False,0)
        quiet=ws.hardware()
        empty(ws,target);time.sleep(.35)
        require(ws.hardware()==quiet and ws.check(ws.read())["current"]==target,"newPhysicalInputBeforeOpeningOwnedDocuments")
        preview=output/"preview"
        callback=(lambda binding:system_switch(ws,target,binding,output/"system-switch")) if args.system_switch else None
        code=importlib.import_module("paired-preview").run(kit,preview,expected_space=target,witness=True,budget=args.hidden_budget,cross_space=callback)
        proof=readable_result(preview/"result.json")
        result["preview"]={"status":proof["status"],"exit":code,"receipt":"preview/result.json","reason":proof.get("reason")}
        result["hiddenBudget"]=proof.get("hiddenBudget",{"status":"NOT_RUN"})
        result["offTwo"]=proof.get("twoCardSurface",{"status":"NOT_RUN"})
        result["systemDesktopSwitch"]=proof.get("systemDesktopSwitch",{"status":"NOT_RUN"})
        save()
        result["emptyAfterPreview"]=empty(ws,target)
        result["offZeroAfter"]=surface_checkpoint(kit,ws.host,target,False,0)
        if split:
            require(states(kit)[-1]["state"] is False,"stageChangedBeforeSplitView")
            # The newest creation receipt includes every still-held ordinary Space.
            # Its recorded protected topology is also the Split helper's immutable baseline.
            split_space=ws.ids()[-1]
            split_lease=lease_for(ws,split_space)[0]
            env=dict(os.environ,NEARPANE_SPLIT_LEASE=str(split_lease))
            try:
                ws.select(split_space);empty(ws,split_space)
                code=child(split,[kit,output/"split","--expected-space",split_space],env=env,timeout=140)
                proof=readable_result(output/"split/result.json")
                result["splitView"]={"status":proof["status"],"exit":code,"space":split_space,"receipt":"split/result.json","reason":proof.get("reason")}
                save()
                result["emptyAfterSplit"]=empty(ws,split_space)
            finally:
                if split_space!=target and ws.check(ws.read())["current"]==split_space:ws.select(target)
        required=[result[k]["status"] for k in ("preview","offZeroBefore","offTwo","offZeroAfter")]
        if split:required.append(result["splitView"]["status"])
        if args.hidden_budget:required.append(result["hiddenBudget"]["status"])
        if args.system_switch:required.append(result["systemDesktopSwitch"]["status"])
        result["status"]="PASS" if all(r=="PASS" for r in required) else "FAIL" if "FAIL" in required else "BLOCKED" if "BLOCKED" in required else "INCONCLUSIVE"
    except errors as exc:
        result["reason"]=str(exc)[:260] or "interrupted"
        if (output/"stage-off-intent.json").exists() and result["stageSetup"]["status"]=="NOT_RUN":
            result["stageSetup"]={"status":"BLOCKED","reason":result["reason"],"journal":"stage-off.jsonl"}
        if (output/"stage-off-preference-intent.json").exists() and result["stageSetup"]["status"]=="NOT_RUN":
            result["stageSetup"]={"status":"BLOCKED","reason":result["reason"],"journal":"stage-off-preference-intent.json"}
    finally:
        if stage is not None:
            try:
                result["stageRestore"]=stage.restore(initial)
                result["restoredSurface"]=surface_checkpoint(kit,ws.host,stage.n,initial,0)
                if initial and args.stage_media_command and result.get("stageOnMedia",{}).get("status")=="BLOCKED":
                    result["stageOnMediaAfterRestore"]=stage_media(args.stage_media_command,kit,output/"stage-on-media-restored",ws,stage.n)
            except errors as e:result["stageRestore"]={"status":"BLOCKED","reason":str(e)[:260] or "interrupted"}
        if ws is not None:
            try:
                restored=ws.cleanup()
                ok=restored["topologyRestored"] and restored["focusRestored"] and not restored["outstanding"] and not restored["errors"]
                result["workspaceCleanup"]={"status":"PASS" if ok else "BLOCKED",**restored}
                if ok:
                    checkpoints=[]
                    for i in range(2):
                        if i:time.sleep(.18)
                        reading=ws.read();scope=ws.check(reading)
                        checkpoints.append({"space":scope["current"],"spaceUUID":next(r["uuid"] for r in scope["records"] if r["id"]==scope["current"]),
                                            "uptime":reading["uptime"],"hostCurrent":reading.get("host")==ws.host,
                                            "sameOriginalFocus":(reading.get("frontmostPID"),reading.get("focusedNumber"))==(ws.original.get("frontmostPID"),ws.original.get("focusedNumber"))})
                    result["returnedDailySpace"]=checkpoints
                    require(all(s["space"]==ws.home and s["hostCurrent"] and s["sameOriginalFocus"] for s in checkpoints),"dailySpaceOrFocusSecondReadIncomplete")
            except errors as e:result["workspaceCleanup"]={"status":"BLOCKED","reason":str(e)[:260] or "interrupted"}
        if any(result[k]["status"]=="BLOCKED" for k in ("stageRestore","workspaceCleanup")):result["status"]="BLOCKED"
        if media and (output/"preview/result.json").is_file():
            try:
                code=child(media,[output/"preview"],timeout=35)
                proof=readable_result(output/"preview/media/receipt.json")
                result["media"]={"status":proof["status"],"exit":code,"receipt":"preview/media/receipt.json"}
            except errors as e:result["media"]={"status":"BLOCKED","reason":str(e)[:220]}
        if result["status"]=="PASS" and any(result.get(k,{}).get("status")!="PASS" for k in ("originalStageSurface","restoredSurface")):
            result["status"]="INCONCLUSIVE"
        save()
    return 0 if result["status"] in ("READY","PASS") else 2


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("kit",type=Path);p.add_argument("output",type=Path)
    p.add_argument("--preflight-only",action="store_true",help="read the signed kit and real login only")
    p.add_argument("--split-command",type=Path,help="optional reviewed split-view.py; receives this same lease")
    p.add_argument("--media-command",type=Path,help="optional reviewed live-preview-media.py; reads the recorded pixels")
    p.add_argument("--stage-media-command",type=Path,help="optional reviewed compact-panel.py; capture the original ON tools on this empty lease")
    p.add_argument("--stage-method",choices=("settings-ui","temporary-preference"),default="settings-ui",
                   help="explicit temporary-preference mode loans just the proved existing logged-in Stage Manager boolean and verifies production runtime independently")
    p.add_argument("--hidden-budget",action="store_true",help="measure the existing one-minute budget once while the same positive preview is open")
    p.add_argument("--system-switch",action="store_true",help="while both enrolled A windows exist, select an additional system-created empty B and return to A")
    args=p.parse_args()
    def interrupt(signum,frame): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,interrupt)
    raise SystemExit(run(args))
