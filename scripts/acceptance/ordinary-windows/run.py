#!/usr/bin/env python3
"""Native tests using only the new sample app and the candidate's passive Settings."""
from argparse import ArgumentParser
import hashlib
import json
import os
from pathlib import Path
import select
import tempfile
import signal
import subprocess as sp
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / "build/verification/p54/ordinary"
OUT = WORK / str(uuid.uuid4())
OUT.mkdir(mode=0o700)
OFF = ["/usr/bin/sandbox-exec", "-p",
       '(version 1)(allow default)(deny network-outbound)(deny file-read* file-write* (regex #"/Library/Application Support/(Nearpane|Riftlet|Saytile)"))']
sys.path.insert(0, str(ROOT / "scripts/acceptance"))
import session_evidence as se

def check(value, message):
    if not value:
        raise RuntimeError(message)

def put(path, data):
    temp = path.with_suffix(".pending")
    temp.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    temp.replace(path)

def reply(cmd):
    return json.loads(sp.check_output(cmd, timeout=6, text=True))

def wait(test, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            val = test()
            if val:
                return val
        except (FileNotFoundError, json.JSONDecodeError, IndexError):
            pass
        time.sleep(.09)
    raise TimeoutError(f"checkpoint {test.__code__.co_firstlineno}")

def line(proc):
    check(select.select([proc.stdout],[],[],4)[0], "sample app response timeout")
    raw = proc.stdout.readline()
    check(raw, "sample app closed its output")
    return json.loads(raw)

def same_rect(a, b):
    return a is not None and b is not None and len(a)==len(b)==4 and all(abs(i-j)<=1 for i,j in zip(a,b))

class Trial:
    def __init__(self):
        self.app = Path((WORK/"fixture-path.txt").read_text().strip())
        self.exe = self.app / "Contents/MacOS/StandardWindows"
        check(self.app.parent.parent == Path("/private/tmp") and self.app.parent.name.startswith("nearpane-standard-windows."), "fixture location")
        sp.run(["/usr/bin/codesign","--verify","--strict",'-R=identifier "net.example.standard-documents"',self.app], check=True)
        # Wait for a quiet existing desktop before creating any GUI object.
        samples=[]; since=None; deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            each=self.observe()
            if not samples or (each["front"],each["focus"])!=(samples[-1]["front"],samples[-1]["focus"]):
                since=time.monotonic()
            samples.append(each)
            if time.monotonic()-since>=2: break
            time.sleep(.22)
        put(OUT/"quiet-preflight.json",samples)
        check(time.monotonic()-since>=2,"no stable foreground window before launch")
        self.run_focus = samples[-1]
        put(OUT/"initial.json",self.run_focus)
        self.pipes = tempfile.TemporaryDirectory(prefix="np-window-pipes-",dir="/private/tmp")
        io = Path(self.pipes.name)
        for n in ("requests","reports"): os.mkfifo(io/n,0o600)
        # Open request pipe first, then read from the reports pipe without blocking launch.
        req = os.open(io/"requests",os.O_RDWR)
        reports = os.open(io/"reports",os.O_RDONLY|os.O_NONBLOCK)
        ticket=self.app.parent/"sample-pipes"
        ticket.write_text(str(io))
        launched = reply(OFF+[WORK/"observe","launch",str(self.app),str(io)])
        self.fixture = type("Fixture",(),{})()
        put(OUT/"launch.json",launched)
        self.fixture.pid = launched["subjectPID"]
        self.fixture.stdin = os.fdopen(req,"w",buffering=1)
        self.fixture.stdout = os.fdopen(reports)
        self.fixture.poll = lambda: None if se.process_path(self.fixture.pid)==self.exe else 0
        self.host = None
        self.hostpid = None
        self.all_windows=set()
        self.checkpoints=[]
        self.sequence=0

    def observe(self, numbers=None):
        args = [] if numbers is None else [str(self.fixture.pid), str(self.exe), *map(str,numbers)]
        return reply(OFF+[WORK/"observe", *args])

    def command(self, value):
        self.fixture.stdin.write(value+"\n")
        self.fixture.stdin.flush()
        r = line(self.fixture)
        if "exit" in r: put(OUT/"fixture-final.json",r)
        check("exit" not in r or value=="quit",str(r))
        self.all_windows.update(row["number"] for row in r.get("windows",[]))
        return r

    def sample(self, label, stable=True):
        owner = self.command("read")
        system = self.observe([r["number"] for r in owner["windows"]])
        result = {"label":label, "owner":owner,"system":system}
        self.checkpoints.append(result)
        put(OUT/"geometry.json",self.checkpoints)
        check(system["side"]==self.run_focus["side"] and self.focus(system) and owner["focusEvents"]==0,
              "focus or display changed")
        check(len(owner["windows"])==len(system["windows"]), "incomplete independent readback")
        for w, z in zip(owner["windows"],system["windows"]):
            check(w["number"]==z["number"] and not w["key"] and not w["main"],"key/main or window identity changed")
            if stable:
                check(z.get("axMatches")==z.get("cgMatches")==1 and z.get("on") and z.get("layer")==0
                      and z.get("role")=="AXStandardWindow" and same_rect(z.get("ax"),z.get("cg"))
                      and same_rect(w["frame"], z.get("cg")),"inconsistent AX/CG/owner for "+label+" window "+str(w["index"]))
        return {w["number"]: w["frame"] for w in owner["windows"]}

    def focus(self, record):
        return all(record[k]==self.run_focus[k] for k in ("front","focus"))

    def baseline(self,count=3):
        ready = line(self.fixture)
        if self.fixture.pid == -1 and int(ready.get("ready", -1)) > 1 and se.process_path(ready["ready"]) == self.exe: self.fixture.pid = ready["ready"]
        check(ready.get("ready")==self.fixture.pid and ready["front"]==self.run_focus["front"],"launch or foreground")
        # The ordinary primary window orders first, secondary-role siblings afterwards.
        for i in range(1,count+1):
            self.command("add "+str(i))
        time.sleep(.8)
        first=self.sample("baseline")
        time.sleep(.12)
        check(self.sample("baseline-stable")==first,"unstable initial frames")
        return first

    def start_host(self, restart=False):
        app=Path.home()/"Applications/Nearpane P5.4/Nearpane P5.4 Alpha.app"
        self.hostexe=app/"Contents/MacOS/NearpaneHost"
        sp.run(["/usr/bin/codesign","--verify","--strict","--deep",app],check=True)
        if not restart:
            check(sp.run(["pgrep","-x","NearpaneHost"],stdout=sp.DEVNULL).returncode==1, "a Host is already running")
            self.sid=str(uuid.uuid4())
            self.session=ROOT/"build/native-acceptance"/self.sid
            self.records=self.session/"support/WorkRect/ordinary"
            sp.run(OFF+[self.hostexe,"--verify-bundled-resources","--native-acceptance-prepare-draft",self.sid],cwd=ROOT,check=True,stdout=(OUT/"prepare.log").open("w"))
            cfg=self.session/"support/Nearpane/host-configuration.json"
            self.start_config=json.loads(cfg.read_text())
            side=self.run_focus["side"]
            check(self.start_config["preferredDisplayID"]==side,"unexpected secondary")
            self.start_config["displays"][side]=dict(edge="left", placement="docked", policy="onDemand",
                                                 spacesDismissed=False, anchor="top", measures=["reservedWidth",{"unit":"pt","value":160}])
            put(cfg,self.start_config)
            self.receipts=[]
        marker=json.loads((self.session/"session.json").read_text())
        check(marker["executableSHA256"]==hashlib.sha256(self.hostexe.read_bytes()).hexdigest(),"changed executable")
        self.epoch=str(uuid.uuid4())
        self.sequence=0
        env=dict(os.environ,NEARPANE_ACCEPTANCE_RUN=self.epoch, NEARPANE_MANAGEMENT_ACCEPTANCE=self.sid,
                 NEARPANE_ADMISSION_ACCEPTANCE=self.sid, NEARPANE_ORDINARY_ACCEPTANCE=self.sid,
                 NEARPANE_ORDINARY_PID=str(self.fixture.pid))
        log=(OUT/("host-"+self.epoch+".log")).open("wb")
        self.host=sp.Popen(OFF+[self.hostexe,"--native-acceptance-secondary",self.sid],env=env,cwd=ROOT,stdout=log,stderr=log)
        self.hostpid=self.host.pid
        self.settings=wait(lambda:json.loads((self.session/("management-panel-"+self.epoch+".json")).read_text()))
        check(se.process_path(self.hostpid)==self.hostexe,"wrong host")
        put(OUT/("host-session-"+self.epoch+".json"),dict(session=self.sid,epoch=self.epoch,exe=marker["executableSHA256"],pid=self.hostpid,window=self.settings))

    def ui(self):
        proc=sp.run(OFF+[WORK/"controls",str(self.hostpid),str(self.settings),self.hostexe,"read","--ordinary-secondary"],
                    capture_output=True,text=True,timeout=4)
        if proc.returncode and proc.stderr.strip()=="no unique secondary panel":
            return {}  # AppKit is still ordering the panel. Read-only polls expire after 8 seconds.
        check(proc.returncode==0,proc.stderr.strip())
        r=json.loads(proc.stdout)
        return {e["id"]:e for e in r["nodes"]}

    def press(self, key):
        wait(lambda:self.ui().get(key,{}).get("enabled"))
        check(self.focus(self.observe()),"focus changed before "+key)
        # Retain the one-shot AXPress rule: this exact helper refusal is emitted
        # BEFORE AXPress, e.g. when a periodic safety sample temporarily disables a button.
        for _ in range(8):
            proc=sp.run(OFF+[WORK/"controls",str(self.hostpid),str(self.settings),self.hostexe,key,"--ordinary-secondary"],
                        text=True,timeout=5,capture_output=True)
            if proc.returncode == 0: break
            if proc.stderr.strip() != "missing, disabled or ambiguous: "+key:
                raise ValueError(proc.stderr.strip())
            time.sleep(.1)
        else: raise ValueError("control stayed unavailable before AXPress: "+key)
        result=proc.stdout
        time.sleep(.22)
        check(self.focus(self.observe()),"focus changed after "+key)
        return result

    def action(self, verb, wait_ack=True):
        self.sequence+=1
        put(self.session/"management-request.json",dict(run=self.epoch,sequence=self.sequence,action=verb))
        if wait_ack:
            wait(lambda:json.loads((self.session/("management-ack-"+self.epoch+".json")).read_text())==self.sequence)
            time.sleep(.2)

    def checkpoint(self,label,expected, counts=None):
        if counts is not None:
            wait(lambda:len(list(self.records.glob("action-*.json")))>=counts)
        time.sleep(.18)
        actual=self.sample(label)
        check(set(actual)==set(expected) and all(same_rect(actual[k],expected[k]) for k in expected),label+" geometry mismatch")
        actions=[json.loads(f.read_text()) for f in self.records.glob("action-*.json")]
        max_error=0
        operations=set()
        for a in actions:
            ident=a["id"]
            check(a["operation"] not in operations and ident["pid"]==self.fixture.pid and ident["number"] in self.all_windows,
                  "wrong action identity")
            operations.add(a["operation"])
            for snap in a["readback"].values():
                check(snap["number"]==snap["axNumber"]==ident["number"] and snap["launch"]==ident["launch"] and snap["element"]==ident["element"],"identity changed during readback")
                for c in ["axFrame","cgFrame"]:
                    max_error=max(max_error,max(abs(snap[c][k]-v) for k,v in a["requested"].items()))
            for step in a["steps"]:
                for c in ("ax","cg"):
                    max_error=max(max_error,max(abs(step[c][k]-v) for k,v in step["to"].items()))
        check(max_error<=1,"receipt outside geometry tolerance")
        result=dict(label=label,expected=expected,actual=actual,actions=actions,maxErrorPt=max_error,status=self.ui().get("ordinary-status"))
        self.receipts.append(result)
        put(OUT/"manager.json",self.receipts)
        return actions

    def select(self,number):
        self.press("admission-window-"+str(number))
        self.press("admission-read")
        try: self.press("ordinary-confirm")
        except Exception:
            put(OUT/"refused.json",self.ui()); raise

    def trial(self,original,mode):
        self.start_host()
        self.press("admission-open");self.press("admission-ordinary-app")
        n1=next(iter(original))
        n2,n3=(list(original)[1:]+[None,None])[:2]
        x,y,w,h=self.run_focus["bounds"]
        # Current isolated profile reserves 160 pt along the left edge.
        rx=x+160; rw=w-160; half=rw/2
        full=[rx,y,rw,h]
        single={**original,n1:full}
        pair={**original,n1:[rx,y,half,h],n2:[rx+half,y,half,h]}
        triple={n1:[rx+half,y,half,h/2],n2:[rx+half,y+h/2,half,h/2],n3:[rx,y,half,h]}
        custom={**original,n1:[rx,y,round(rw*.6),h],n2:[rx+round(rw*.6),y,rw-round(rw*.6),h]}
        if mode == "exclude-display":
            for n in (n1,n2): self.press("admission-window-"+str(n))
            self.press("admission-read");self.press("ordinary-confirm")
            self.checkpoint("pair-on-shipping",pair,2)
            self.press("ordinary-pause");self.checkpoint("paused",pair)
            self.press("ordinary-resume");self.checkpoint("continued",pair)
            self.press("ordinary-exclude-"+str(n2))
            retained={**original,n2:pair[n2]}
            self.checkpoint("excluded-sibling",{**retained,n1:full},3)
            before={n:sorted(a["operation"] for a in self.receipts[-1]["actions"] if a["id"]["number"]==n) for n in original}
            # Prove normal exit/restore on this shipping hash before testing the independent display change.
            self.press("ordinary-stop");self.checkpoint("restored-one-excluded-one",retained,4)
            self.press("admission-ordinary-app");self.select(n1)
            self.checkpoint("docked-regrant",{**retained,n1:full},5)
            self.action("floating");self.checkpoint("floating",{**retained,n1:[x,y,w,h]},6)
            self.action("docked");self.checkpoint("redocked",{**retained,n1:full},7)
            self.press("ordinary-stop");self.checkpoint("restored-from-display-changes",retained,8)
            after={n:sorted(a["operation"] for a in self.receipts[-1]["actions"] if a["id"]["number"]==n) for n in original}
            check(before[n2]==after[n2] and not after[n3],"write to excluded or unauthorized sibling")
            put(OUT/"native-result.json",dict(result="completed listed checkpoints",session=self.sid,
                 actionsBeforeFurtherChanges=before,actionsAfterStop=after))
            return
        if mode == "floating":
            self.select(n1); self.checkpoint("docked", single,1)
            self.action("floating"); self.checkpoint("floating",{**original,n1:[x,y,w,h]})
            self.action("docked");self.checkpoint("redocked",single)
            self.press("ordinary-stop");self.checkpoint("restored",original)
            return
        if mode == "fault":
            self.select(n1);self.checkpoint("before-fault",single,1)
            self.external_edit_and_crash(original,n1)
            return
        if mode == "lifecycle":
            for n in (n1,n2,n3): self.press("admission-window-"+str(n))
            self.press("admission-read"); self.press("ordinary-confirm")
            self.checkpoint("authorized-three",triple,3)
            custom=pair
        else:
            self.select(n1)
            self.checkpoint("single",single,1)
            self.press("ordinary-stop")
            self.checkpoint("restored-single",original,2)
            self.press("admission-read");self.press("ordinary-confirm")
            self.checkpoint("single-again",single,3)
            self.select(n2)
            self.checkpoint("two",pair,5)
            self.press("ordinary-pair")
            self.checkpoint("custom",custom,7)
            self.select(n3)
            self.checkpoint("three",triple,10)
        self.press("ordinary-pause"); self.checkpoint("paused",triple)
        self.press("ordinary-resume"); self.checkpoint("resumed",triple)
        if mode == "full":
            for verb in ("icon","normal-size","hide","show"):
                self.action(verb); self.checkpoint(verb,triple)
        self.press("ordinary-exclude-"+str(n3))
        # An explicitly excluded window stays at its last frame and receives no writes.
        self.checkpoint("exclude-third",{**custom,n3:triple[n3]})
        self.press("ordinary-stop");self.checkpoint("stop-pair",{**original,n3:triple[n3]})
        # Verify the display setting on this same explicit grant. Floating is exercised
        # only after we can recover the selected ordinary window.

        # Start a new selection. A closed/rebuilt window no longer has the old number.
        self.press("admission-ordinary-app");self.select(n1)
        others={**original,n3:triple[n3]}
        self.checkpoint("regranted-for-display", {**others,n1:full})
        self.external_edit_and_crash(original,n1)

    def external_edit_and_crash(self,original,n1):
        before_edit=self.action_ids()
        self.command("edit 1");time.sleep(.4)
        edited=self.sample("independent-app-edit")
        self.press("ordinary-stop")
        self.checkpoint("refused-restore-after-external-edit",edited)
        check((self.records/"journal.json").exists(),"missing unresolved journal")
        check(self.action_ids()==before_edit,"layout overwritten on external edit")
        self.command("close 1");new=self.command("add 1")
        new_number=new["windows"][0]["number"]
        check(new_number!=n1,"window number unexpectedly reused")
        held=self.sample("rebuilt-without-consent")
        # Use current actual profile and same exact test fixture on restart.
        check(se.process_path(self.hostpid)==self.hostexe and self.host.poll() is None, "wrong SIGKILL target")
        before=list(self.records.glob("action-*.json")); self.host.kill();check(self.host.wait(timeout=5)==-9,"wrong kill status")
        self.start_host(restart=True);time.sleep(.5)
        self.checkpoint("restart-does-not-replay",held)
        check(len(list(self.records.glob("action-*.json")))==len(before),"new action on restart")
        # Finish the actual independent application, then check the disposition
        # of the unresolved grant while the restarted Host is still running.
        self.command("quit")
        def gone():
            try: return self.fixture.poll() is not None
            except ValueError: return True
        wait(gone,4)
        time.sleep(.45)
        check(self.action_ids()==before_edit and (self.records/"journal.json").exists(),
              "new writes or lost unresolved record after application exit")
        put(OUT/"native-result.json",dict(result="completed listed checkpoints",session=self.sid,
            beforeEditReceipts=sorted(before_edit),afterProcessExitReceipts=sorted(self.action_ids()),
            recovery=json.loads((self.records/"journal.json").read_text())))

    def action_ids(self):
        return {p.name for p in self.records.glob("action-*.json")}


    def close(self):
        if self.host is not None:
            if self.host.poll() is None and self.hostpid:
                if getattr(self,"settings",None):
                    try: self.action("quit", wait_ack=False)
                    except Exception: pass
                try: self.host.wait(timeout=4)
                except sp.TimeoutExpired:
                    if se.process_path(self.hostpid)==self.hostexe: os.kill(self.hostpid,signal.SIGTERM)
            try: self.host.wait(timeout=4)
            except sp.TimeoutExpired: pass
        try: alive=self.fixture.poll() is None
        except ValueError: alive=False
        if alive:
            put(OUT/"pre-cleanup-focus.json",self.observe())
            try: self.command("quit")
            except (BrokenPipeError, ValueError, RuntimeError): pass
            self.fixture.stdin.close()
        def ended():
            try: return self.fixture.poll() is not None
            except ValueError: return True
        wait(ended,5)
        self.pipes.cleanup()
        (self.app.parent/"sample-pipes").unlink(missing_ok=True)
        post=self.observe()
        # Existing process is already gone; enumerate only exact recorded CG numbers.
        if self.all_windows:
            vanished=reply(OFF+[WORK/"observe","gone",str(self.fixture.pid),*map(str,self.all_windows)])
            check(vanished.get("residual")==[],"fixture window remained")
        else:
            vanished={"residual":[]}
        cleanup={"fixtureGone":True,"fixturePID":self.fixture.pid,"windowIDs":sorted(self.all_windows),
                 "finalFocus":post,"sameFocus":self.focus(post),"CGResidual":vanished['residual']}
        if self.host is not None: cleanup.update(hostPID=self.hostpid, launcherExit=self.host.poll())
        put(OUT/"cleanup.json",cleanup)
        check(cleanup["sameFocus"],"foreground/focused window changed during run")

if __name__ == "__main__":
    p=ArgumentParser()
    mode=p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--probe",action="store_true")
    mode.add_argument("--mode",choices=["full","lifecycle","fault","floating","exclude-display"])
    args=p.parse_args()
    with (OUT/"run.txt").open("w") as fp: fp.write("probe" if args.probe else args.mode)
    print(OUT,flush=True)
    t=Trial()
    try:
        original=t.baseline(1 if args.mode in ("fault","floating") else 3)
        if not args.probe: t.trial(original,args.mode)
    finally:
        t.close()
