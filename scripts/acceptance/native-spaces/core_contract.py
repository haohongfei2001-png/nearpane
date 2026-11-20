"""Run the installed production sidebar on three disposable, system-witnessed ordinary desktops."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

from acceptance import Receipt, catalog_match, checked, controlled_window, encode, identity, manifest, wait_state
from contract_document import run as document_trials
from contract_workspace import Workspace, row
from space_scope import ScopeError, load_scope, require, validate_live
from space_trials import Driver, prepare_scope, run as space_trials

SCENARIOS = ("S01", "S02", "S03", "W01", "W02", "D01", "R01")
ERRORS = (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError)


class Fixture:
    def __init__(self, kit, app, count=1, split=False):
        self.bundle=kit/(app+" Notes.app")
        self.folder=kit/str(uuid.uuid4())
        self.folder.mkdir(mode=0o700)
        self.path=self.folder/"windows.json"
        self.hash=identity(self.bundle/"Contents/MacOS/FieldNotes")["CDHash"]
        self.proc=subprocess.Popen([str(self.bundle/"Contents/MacOS/FieldNotes"),str(self.folder),str(count)],
                                   env={**os.environ,"NP_FIXTURE_PRESENTATION":"contract-split" if split else "contract"},
                                   stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

    def state(self, predicate=lambda d:True, seconds=5):
        s=wait_state(self.path, lambda d: d.get("pid")==self.proc.pid and d.get("session")==self.folder.name
                     and d["birth"]>0 and predicate(d), time.monotonic()+seconds)
        require(s,"owned fixture did not attest its expected windows/input")
        return s

    def activate(self):
        (self.folder/"activate-first").touch()
        return self.state(lambda d:d["key"]==d["numbers"][0])

    def close(self):
        (self.folder/"close").touch()
        try:self.proc.wait(4)
        except subprocess.TimeoutExpired:
            self.proc.terminate();self.proc.wait(4)


def occupancy_matches(snapshot, expected):
    for n, witnesses in expected.items():
        c=snapshot.get("scopedMembers",{}).get(str(n),{})
        if (c.get("unresolved")!=0 or c.get("otherMembers")!=0 or
                {(w["pid"],w["number"]) for w in c.get("ordinary",[])}!=set(witnesses)):
            return False
    return True


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kit",required=True,type=Path)
    ap.add_argument("--scenarios",type=lambda s:s.upper().split(","),default=list(SCENARIOS))
    ap.add_argument("--performance", action="store_true", help="measure N01 on the same owned A/B/C after core selections")
    ap.add_argument("output",type=Path)
    args=ap.parse_args(); wanted=set(args.scenarios);kit=args.kit.resolve();out=args.output.resolve()
    if not wanted or not wanted.issubset(SCENARIOS):ap.error("unknown core scenario")
    if args.performance:wanted.add("N01")
    os.umask(0o077)
    receipt=Receipt(out); ws=None; fixtures=[]; failures=[]
    os.environ.pop("NEARPANE_CONTRACT_SPACE_IDS",None)
    def interrupt(_sig,_frame): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,interrupt)
    def mark(k,status,why,**facts):
        receipt.scenarios[k]=dict(status=status,reason=why,**facts)
        receipt.log("scenario-result",scenario=k,status=status,reason=why)
    def run_case(k,body):
        try:body()
        except ERRORS as e:
            failures.append((k,str(e))); mark(k,"FAIL" if receipt.scenarios[k]["status"]=="IN_PROGRESS" else "BLOCKED",str(e))
    def fixture(name="Field",count=1,split=False):
        f=Fixture(kit,name,count,split);fixtures.append(f)
        f.state(lambda d:len(d["numbers"])==(1 if split else count))
        receipt.log("fixture-launched",pid=f.proc.pid,session=f.folder.name)
        return f
    def close_fixtures():
        while fixtures:
            f=fixtures[-1]; nums=json.loads(f.path.read_text())["numbers"] if f.path.exists() else []
            f.close();fixtures.pop()
            end=json.loads(checked([str(kit/"observe"),"absence",*map(str,nums)])) if nums else {}
            receipt.log("fixture-exited",pid=f.proc.pid,ownedNumbers=nums,allGone=end.get("allGone"))
            require(not nums or end.get("allGone") is True,"fixture windows survived termination")
    def scope(files,suffix):
        directory=out/("scope-"+suffix)
        prepare_scope(kit/"observe",ws.ledgers,files,directory,scoped_members=True)
        return (directory/"scope.json").resolve()
    def live_scope(path):
        o=ws.read()
        return load_scope(path,o,ws.boot,o["uptime"])
    def one_product_space(path,n):
        o=ws.read(); s=live_scope(path); start=validate_live(s,o,s["host"])
        channel=Driver(kit/"row-driver",s,receipt.log)
        try:
            actions=channel.command([n],[start])
            final=ws.settled(lambda o:validate_live(s,o,s["host"],False)==n
                             and catalog_match(o)["highlightMatchesSystem"],"installed-sidebar target did not arrive")
            require(len(actions)==1 and actions[0]["axError"]==0,"production control did not accept one action")
            return final
        finally:channel.close()
    try:
        ws=Workspace(kit,out,receipt.log)
        frozen=manifest(ws.original,kit/"metrics")
        receipt.write("manifest.json",frozen)
        require(frozen["loadedMatchesInstalled"] and frozen["signatureValid"] and frozen["source"],"signed installed Host differs from running process")
        if "D01" in wanted:
            cap=(frozen.get("nativeCapabilitiesLog") or [{}])[-1]
            if cap.get("canMove") is not True or cap.get("ready") is not True:
                reason="Installed Host move capability is false or unknown; zero drag inputs dispatched."
                details=dict(status="BLOCKED",reason=reason,installedMoveCapability=cap,inputs=0,movementAttempts=0,completed=[])
                receipt.write("D01.json",details)
                mark("D01","BLOCKED",reason,inputs=0)
        for _ in range(3):ws.create()
        a,b,c=ws.ids()
        # Scope membership/knowledge is only queried for positively created numbers.
        os.environ["NEARPANE_CONTRACT_SPACE_IDS"]=",".join(map(str,(a,b,c)))
        ws.select(a)
        if "W01" in wanted:
            def w01():
                actual=document_trials(ws,receipt,a)
                if actual["status"] in ("PASS","FAIL"):
                    mark("W01",actual["status"],actual["reason"],issued=actual["issued"],passes=actual["passes"])
                    return
                child=Receipt(out/"same-app-documents")
                try:
                    reason=controlled_window(kit/"observe",ws.read(),frozen,child,2)
                finally:child.finish()
                receipt.attempts.extend(child.attempts)
                count=child.summary.get("controlledWindowTrials",0)
                require(count==10 and len(child.attempts)==10 and all(r["status"]=="PASS" for r in child.attempts)
                        and child.summary["cleanup"].get("windowNumbersGone"),reason)
                mark("W01","PARTIAL","Ten ordinary AppKit fixture selections verified. System TextEdit: "+actual["reason"],fixturePasses=count)
            run_case("W01",w01)
        if "D01" in wanted and receipt.scenarios["D01"]["status"]=="NOT_RUN":
            def d01():
                ws.select(a); path=scope([],"empty"); dest=out/"drag"
                cmd=[sys.executable,str(Path(__file__).with_name("d01.py")),"--kit",str(kit),"run",str(dest),"--scope",str(path)]
                proc=subprocess.run(cmd,capture_output=True,text=True,timeout=90)
                data=json.loads((dest/"D01.json").read_text())
                mark("D01",data["status"],data["reason"],movementAttempts=data["movementAttempts"],completed=data["completed"],childExit=proc.returncode)
            run_case("D01",d01)
        if wanted & {"S01","S02","S03","R01","N01"}:
            try:
                ws.select(b);fb=fixture("Route")
                ws.select(a);fa=fixture();fa.activate()
                expected={a:[(fa.proc.pid,fa.state()["numbers"][0])],b:[(fb.proc.pid,fb.state()["numbers"][0])],c:[]}
                ws.settled(lambda o:row(o)["current"]==a and occupancy_matches(o,expected) and o.get("frontmostPID")==fa.proc.pid,
                           "A/B/C per-Space inventory or initial owned focus not confirmed")
                path=scope([(a,fa.path),(b,fb.path)],"members")
                if "S01" in wanted:
                    def s01():
                        o=ws.read(); s=live_scope(path);validate_live(s,o,s["host"])
                        catalog=catalog_match(o); sidebar=o["sidebar"]
                        empty_id=f"native-space-row:{ws.display}:{c}"
                        empty,=[r for r in sidebar["rows"] if r["identifier"]==empty_id]
                        receipt.log("S01-inventory",ids=[a,b,c],independent=o["scopedMembers"],catalog=catalog,emptyControl=empty,
                                    visibleA=sidebar["currentWindowCount"],visibleB=sidebar["windowCounts"].get(f"{ws.display}:{b}",0))
                        require(catalog["rowIdentitiesMatch"] and catalog["highlightMatchesSystem"] and empty["press"] and empty["enabled"]
                                and empty.get("membershipLabels") in (["empty"],["unread"]),"empty Space control or explicit coverage label not confirmed")
                        require(sidebar["currentWindowCount"]==1 and sidebar["windowCounts"].get(f"{ws.display}:{b}")==1,
                                "installed sidebar did not expose both independently known test windows")
                        mark("S01","PASS","System UUIDs and exact fixture occupancy match, with an actionable empty Space and explicit membership state.")
                    run_case("S01",s01)
                if wanted & {"S02","R01"}:
                    section=space_trials(kit/"observe",kit/"row-driver",path,out/"selections", run_rapid="R01" in wanted)
                    receipt.attempts.extend(section["attempts"])
                    for k in ("S02","R01"):
                        if k in wanted:mark(k,section[k],section.get("reason") or section.get(k+"Reason") or "Installed row presses and independent readbacks recorded.",sent=section["sent"],unknown=section["unknown"])
                if args.performance:
                    def n01():
                        import performance
                        ws.select(a);fa.activate()
                        data=performance.run(workspace=ws,scope=live_scope(path),observer=kit/"observe",driver=kit/"row-driver",output=out/"performance")
                        mark("N01",data["status"],data["reason"])
                    run_case("N01",n01)
                if "S03" in wanted:
                    def s03():
                        ws.select(a);fa.activate()
                        before=ws.read(); origin_order=row(before)["records"]
                        native=ws.select(b)
                        ws.settled(lambda o:row(o)["current"]==b and catalog_match(o)["highlightMatchesSystem"],"sidebar did not follow native switch")
                        receipt.log("S03-native-selection",fromID=a,target=b,actual=row(native)["current"])
                        one_product_space(path,a)
                        ordered=ws.swap(b,c)
                        try:
                            # Permit only this exact adjacent swap. Post-reorder selection rebinds the row by original ID/UUID.
                            monotonic=ordered["uptime"]; prior=prepare_s03_scope(path,before,ordered,ws.boot)
                            chan=Driver(kit/"row-driver",prior,receipt.log)
                            try:
                                chan.command([b],[a])
                                end=ws.settled(lambda o:validate_live(prior,o,prior["host"],False)==b and catalog_match(o)["highlightMatchesSystem"],
                                               "post-reorder product selection did not reach the same UUID")
                                receipt.log("S03-post-reorder",target=b,oldPosition=[i["id"] for i in origin_order].index(b),
                                            newPosition=[i["id"] for i in row(end)["records"]].index(b),seconds=end["uptime"]-monotonic)
                            finally:chan.close()
                        finally:ws.swap(b,c)
                        ws.select(a)
                        mark("S03","PASS","Native selection and controlled reorder followed by installed row presses to the same original Space identities.")
                    run_case("S03",s03)
            except ERRORS as e:
                for k in wanted & {"S01","S02","S03","R01","N01"}:
                    if receipt.scenarios[k]["status"]=="NOT_RUN":mark(k,"BLOCKED",str(e))
            finally:close_fixtures()
        if "W02" in wanted:
            def w02():
                ws.select(a);other=fixture("Route");docs=fixture(count=2,split=True)
                one=docs.state()["numbers"][0];extra=other.state()["numbers"][0]
                ws.select(b);(docs.folder/"open-second").touch(); state=docs.state(lambda s:len(s["numbers"])==2)
                two=state["numbers"][1]; expected={a:[(docs.proc.pid,one),(other.proc.pid,extra)],b:[(docs.proc.pid,two)],c:[]}
                ws.settled(lambda o:occupancy_matches(o,expected),"same-process W1/A and W2/B plus other-app W3/A fixture layout not confirmed")
                text=["",""];host=frozen["observed"]["host"]
                for idx,src,dst,n in ((0,b,a,one),(1,a,b,two),(0,b,a,one)):
                    before=ws.read()
                    require(row(before)["current"]==src and occupancy_matches(before,expected),"window identity/source changed before click")
                    args=list(map(str,[host["pid"],host["codeHash"],docs.proc.pid,n,docs.bundle,docs.hash,ws.display,src,state["birth"]]))
                    intent=str(uuid.uuid4()); attempt=dict(intent=intent,scenario="W02",target=n,source=src,destination=dst,status="UNKNOWN");receipt.attempts.append(attempt)
                    receipt.log("W02-intent",**attempt)
                    tap=json.loads(checked([str(kit/"observe"),"press-cross",*args,str(dst)]))
                    receipt.log("W02-sidebar",intent=intent,result=tap)
                    require(tap.get("issued") and tap.get("axError")==0,tap.get("reason","cross-desktop window control unavailable"))
                    ws.settled(lambda o:row(o)["current"]==dst and o.get("frontmostPID")==docs.proc.pid and o.get("focusedNumber")==n
                               and occupancy_matches(o,expected),"exact destination Space, focused window and unchanged sibling not confirmed")
                    docs.state(lambda s:s["key"]==s["main"]==n and s["editorsFocused"][idx])
                    marker="NP"+uuid.uuid4().hex[:10];args[-2]=str(dst)
                    typed=json.loads(checked([str(kit/"observe"),"marker",*args],env={**os.environ,"NP_TRIAL_MARKER":marker}))
                    require(typed.get("issued"),typed.get("reason","marker refused"));text[idx]+=marker
                    hashes=[hashlib.sha256(v.encode()).hexdigest() for v in text]
                    docs.state(lambda s:s["key"]==n and s["sha256"]==hashes)
                    attempt["status"]="PASS";receipt.log("W02-confirmed",intent=intent,readbackTypedOnlyTarget=True,documentDigests=hashes)
                mark("W02","PASS","Same-process windows on A/B and third window in a distinct fixture app on A; correct Space, key/main and target-only text read after three installed sidebar selections.")
            try:run_case("W02",w02)
            finally:close_fixtures()
    except (ERRORS + (KeyboardInterrupt,)) as e:
        for k in wanted:
            if receipt.scenarios[k]["status"]=="NOT_RUN":mark(k,"BLOCKED",str(e) or "run interrupted")
        receipt.log("suite-stopped",reason=str(e))
    finally:
        try:close_fixtures()
        except ERRORS as e:failures.append(("fixture-cleanup",str(e)))
        if ws:
            try:receipt.summary["cleanup"]=ws.cleanup()
            except ERRORS as e:receipt.summary["cleanup"]=dict(outstanding=ws.ids(),errors=[str(e)],topologyRestored=False)
        receipt.summary.update(requested=sorted(wanted),failures=failures)
        receipt.finish()
    return 0 if all(receipt.scenarios[k]["status"]=="PASS" for k in wanted) and receipt.summary.get("cleanup",{}).get("topologyRestored") else 2


def prepare_s03_scope(path, before, reordered, boot):
    from space_trials import observed_order
    base=load_scope(path,before,boot,before["uptime"])
    new=observed_order(base,reordered)
    require(new!=base["_shape"],"native reorder did not change leased order")
    base["_shape"],base["_scopes"]=new,reordered["scopes"]
    validate_live(base,reordered,base["host"])
    return base


if __name__=="__main__":sys.exit(main())
