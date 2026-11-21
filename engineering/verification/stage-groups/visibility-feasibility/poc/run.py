"""Compare three window visibility mechanisms on an empty, disposable GitHub macOS login."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

from build import build


def execute(*args, check=True):
    p = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=12)
    if check and p.returncode:
        raise RuntimeError(f"{Path(str(args[0])).name} exited {p.returncode}: {p.stderr[-350:]}")
    return p


def write(path, obj):
    tmp = path.with_suffix(".pending")
    tmp.write_text(json.dumps(obj, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


def await_file(file, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if file.exists():
            return json.loads(file.read_bytes())
        time.sleep(.04)
    raise RuntimeError("receipt timeout: " + file.name)


def dock_pref():
    # Preserve actual existence and type instead of treating an absent default as false.
    data = subprocess.check_output(["defaults", "export", "com.apple.dock", "-"])
    return plistlib.loads(data).get("minimize-to-application")


def restart_dock():
    execute("killall", "-u", os.getlogin() if os.isatty(0) else os.environ["USER"], "Dock", check=False)
    time.sleep(2.0)


def outcome(checks):
    if any(v is False for v in checks.values()):
        return "FAIL"
    return "PASS" if checks and all(v is True for v in checks.values()) else "UNKNOWN"


def equal_known(a, b):
    return None if a is None or b is None else a == b


def combine(values):
    vals = list(values)
    return False if False in vals else None if None in vals or not vals else True


def center(rect):
    return (rect[0] + rect[2]/2, rect[1] + rect[3]/2)


class Trial:
    def __init__(self, root, out):
        self.root, self.out = root, out
        self.bin = root / "bin"
        self.hosts = []
        self.lease_reader = None
        self.entries = {"methods": {}, "scope": "disposable registered fixture owners and separate inspector"}
        self.seq = 0
        self.ledger = (out / "observations.jsonl").open("x")
        self.log = (out / "process.log").open("x")

    def event(self, event, payload):
        self.seq += 1
        row = dict(seq=self.seq, utc=time.time(), monotonic_ns=time.monotonic_ns(), event=event, data=payload)
        print(json.dumps(row, sort_keys=True), file=self.ledger, flush=True)
        return payload

    def inspected(self, *args):
        p = execute(self.bin / "Inspect", self.root, *args)
        return json.loads(p.stdout)

    def command(self, app, op, index=0):
        nonce = str(uuid.uuid4())
        write(self.root / (app + ".command"), dict(nonce=nonce, op=op, index=index))
        return await_file(self.root / (app + "-" + nonce + ".json"), 3)

    def launch(self):
        build(self.bin)
        self.event("sdk-symbols", json.loads(execute(self.bin / "Inspect","symbols").stdout))
        for name in ("B", "A"):
            bundle = self.root / (name + ".app")
            executable = bundle / "Contents/MacOS/Fixture"
            executable.parent.mkdir(parents=True)
            shutil.copy2(self.bin / "Fixture", executable)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
                CFBundleName="Nearpane Fixture " + name, CFBundlePackageType="APPL", CFBundleExecutable="Fixture",
                CFBundleIdentifier="net.example.nearpane.visibility." + name.lower(), CFBundleVersion="1",
                NSPrincipalClass="NSApplication")))
            execute("codesign", "--sign", "-", "--force", bundle)
            execute("codesign", "--verify", "--strict", bundle)
            cmd = ["open", "-g", "-n", "-W"]
            for k in ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS"):
                cmd.extend(["--env", k + "=" + os.environ[k]])
            self.hosts.append(subprocess.Popen([*cmd,"-a",str(bundle),"--args",name,str(self.root)], stdout=self.log,stderr=self.log))
            self.event("registered-"+name, await_file(self.root / (name+".json"), 14))
        self.lease_reader = subprocess.Popen([self.bin/"Inspect",self.root,"leases"], stdin=subprocess.PIPE,
                                             stdout=subprocess.PIPE, stderr=self.log, text=True)
        enrollment = self.event("retained-AX-reader",json.loads(self.lease_reader.stdout.readline()))
        if set(enrollment["enrolled"]) != {"A0","A1","B0","B1"}:
            raise RuntimeError("could not enroll every AX lease before the trials")

    def snap(self, phase):
        obs = self.inspected("snapshot")
        self.lease_reader.stdin.write("sample\n"); self.lease_reader.stdin.flush()
        leases=json.loads(self.lease_reader.stdout.readline())
        for name in ("A","B"):
            records = self.command(name,"sample")["windows"]
            for index, record in enumerate(records):
                data = obs["windows"][name + str(index)]
                if data["number"] != record["id"]:
                    raise RuntimeError("observer and owner window IDs disagree")
                data["owner"] = record
                data["axLease"] = leases[name + str(index)]
        return self.event(phase, obs)

    def seed_focus(self, tag, index):
        label = "A" + str(index)
        self.command("A","seed",index)
        time.sleep(.22)
        s = self.inspected("snapshot")
        row = s["windows"][label]
        if not row["axFrame"]:
            raise RuntimeError("fixture AX frame unavailable during setup")
        point = center(row["axFrame"])
        hit = self.inspected("hit", *point)
        if hit["cgFrontWindow"] != row["number"] or hit["axPID"] != row["pid"]:
            raise RuntimeError("fixture-only calibration point unavailable")
        # A normal click establishes user intent in a Launch Services -g login. It occurs
        # before the baseline, never in the measurement interval between out and in.
        self.event(tag+".setup-click",self.inspected("click", *point))
        time.sleep(.35)

    def prepare(self, phase):
        # One explicit focus/stack setup before the trial. All following snapshots are passive.
        self.command("B","front")
        self.command("A","reset",0)
        self.command("A","reset",1)
        self.seed_focus(phase,1)
        self.command("A","present-for-setup",0)
        time.sleep(.22)
        s = self.snap(phase + ".baseline")
        if not s["axTrusted"] or not s["postAllowed"] or not s["cgListsAvailable"]:
            raise RuntimeError("WindowServer/AX/input unavailable")
        a = s["windows"]["A0"]
        if not a["axFrame"] or not a["cgScreen"] or self.focused(s,"A1") is not True:
            raise RuntimeError("initial exact fixture focus or visibility unavailable")
        point = center(a["axFrame"])
        if self.event(phase+".baseline-hit",self.inspected("hit",*point))["cgFrontWindow"] != a["number"]:
            raise RuntimeError("enrolled target is not exposed at the test point")
        return s, point

    @staticmethod
    def focused(s,label):
        f, w = s["focus"], s["windows"][label]
        return combine([equal_known(f["actualID"],w["number"]),f["frontPID"] == w["pid"],f["label"] == label,w["owner"]["key"]])

    @staticmethod
    def siblings(before, after, target):
        checks = []
        for k, w in before["windows"].items():
            if k == target:
                continue
            n = after["windows"][k]
            for key in ("axFrame","axMini","cgScreen","spaces"):
                checks.append(equal_known(w[key],n[key]))
            for key in ("id","frame","visible","mini","content"):
                checks.append(equal_known(w["owner"][key],n["owner"][key]))
        return combine(checks)

    def dispatch(self, phase, fn):
        return self.event(phase, fn())

    def clicked(self, tag, point, expected):
        pre = self.snap(tag + ".before-click")
        report = self.event(tag + ".click",self.inspected("click", *point))
        time.sleep(.22)
        post = self.snap(tag + ".after-click")
        delta = {k: w["owner"]["clicks"] - pre["windows"][k]["owner"]["clicks"] for k,w in post["windows"].items()}
        self.event(tag + ".click-delta",delta)
        return None if not report["posted"] else delta == {k:int(k == expected) for k in delta}

    def keyed(self, tag, before, expected):
        post = self.event(tag + ".key",self.inspected("key"))
        time.sleep(.18)
        after = self.snap(tag + ".after-key")
        delta = {k: w["owner"]["keys"]-before["windows"][k]["owner"]["keys"] for k,w in after["windows"].items()}
        self.event(tag + ".key-delta",delta)
        return None if not post["posted"] else delta == {k:int(k == expected) for k in delta}

    def single(self, tag, method, act, index=0, anchor="A1"):
        before, point = self.prepare(tag)
        label = "A" + str(index)
        if index:
            # For the second document B1 can be used as keeper instead; exercise alternating
            # membership with the original document active on this same-owner pass.
            self.seed_focus(tag+".second",0)
            before = self.snap(tag+".baseline-second")
            point = center(before["windows"][label]["axFrame"])
        pre = before["windows"][label]
        hide_result = self.dispatch(tag+".out",lambda: act(True,index))
        time.sleep(.85)
        hidden = self.snap(tag+".hidden")
        time.sleep(.23)
        stable = self.snap(tag+".hidden-settled")
        h = stable["windows"][label]
        checks = {}
        for name,s in (("early",hidden),("settled",stable)):
            target = s["windows"][label]
            checks[name+".notOnScreen"] = target["cgScreen"] is None if s["cgListsAvailable"] else None
            checks[name+".axLease"] = equal_known(target["axLease"]["identifier"],label)
            checks[name+".axMini"] = equal_known(target["axLease"]["mini"],method == "A")
            checks[name+".ownerVisibility"] = not target["owner"]["visible"]
            checks[name+".dock"] = equal_known(s["dock"].get("minimizedTiles"),before["dock"].get("minimizedTiles"))
            checks[name+".focus"] = self.focused(s,anchor)
            checks[name+".space"] = equal_known(pre["spaces"],target["spaces"])
            checks[name+".siblings"] = self.siblings(before,s,label)
            if method == "B":
                checks[name+".wsOrderedOut"] = equal_known(target["ordered"],False)
        checks["hiddenKeyboard"] = self.keyed(tag+".hidden",stable,anchor)
        # A0 has an enrolled nonactivating event receiver underneath it. The second A1 uses
        # passive hit readback; the first pass already proved a physical click at A0.
        if index == 0:
            checks["hiddenMouse"] = self.clicked(tag+".hidden",point,"B0")
        else:
            at = self.event(tag+".hidden-point",self.inspected("hit",*point))
            checks["hiddenMouse"] = at["cgFrontWindow"] != pre["number"] and at["axWindow"] != label
        needs = (h["cgScreen"] is None or h["axMini"] is True or h["ordered"] is False or not h["owner"]["visible"])
        if needs:
            self.dispatch(tag+".in",lambda: act(False,index))
            time.sleep(.85)
            restored = self.snap(tag+".restored"); time.sleep(.20)
            s = self.snap(tag+".restored-settled"); w=s["windows"][label]
            checks.update(restoredVisible=w["cgScreen"] is not None and w["owner"]["visible"], restoredNotMini=equal_known(w["axMini"],False),
                          restoredOrdered=equal_known(w["ordered"],True), restoredFrame=equal_known(w["axFrame"],pre["axFrame"]),
                          restoredCG=equal_known(w["cgScreen"],pre["cgScreen"]), restoredContent=w["owner"]["content"] == pre["owner"]["content"],
                          restoredOwnerFrame=w["owner"]["frame"] == pre["owner"]["frame"], restoredSpace=equal_known(w["spaces"],pre["spaces"]),
                          restoredSiblings=self.siblings(before,s,label), restoredFocus=self.focused(s,anchor), firstRestoreFocus=self.focused(restored,anchor),
                          restoredDock=equal_known(s["dock"].get("minimizedTiles"),before["dock"].get("minimizedTiles")))
            checks["restoredKeyboard"]=self.keyed(tag+".restored",s,anchor)
            checks["restoredMouse"]=self.clicked(tag+".restored",point,label)
        else:
            self.event(tag+".in-skipped", {"reason":"target independently remained ordered on screen","restore":"NOT_NEEDED"})
        r = {"status":outcome(checks),"checks":checks,"hideCall":hide_result,"restorationDispatched":needs}
        self.event(tag+".verdict",r)
        return r

    def restore_only(self, mode, act):
        tag="B."+mode+".restore-only"
        before,pt=self.prepare(tag)
        self.command("A","owner-out",0)
        time.sleep(.45)
        off=self.snap(tag+".owner-seeded")
        target=off["windows"]["A0"]
        if target["cgScreen"] is not None or target["ordered"] != 0 or target["owner"]["visible"]:
            return {"status":"BLOCKED","reason":"owner order-out not witnessed"}
        self.event(tag+".foreign-in",act(False,0))
        time.sleep(.6)
        after=self.snap(tag+".after-in"); w=after["windows"]["A0"]
        checks={"cgScreen":w["cgScreen"] is not None,"ordered":equal_known(w["ordered"],True),
                "ownerVisible":bool(w["owner"]["visible"]),"noDockGrowth":equal_known(off["dock"].get("minimizedTiles"),after["dock"].get("minimizedTiles")),
                "focus":self.focused(after,"A1"),"keyboard":self.keyed(tag,after,"A1"),"mouseReachedRestored":self.clicked(tag,pt,"A0"),
                "siblings":self.siblings(before,after,"A0"),"nativeSpace":equal_known(w["spaces"],before["windows"]["A0"]["spaces"])}
        self.command("A","reset",0); time.sleep(.2); self.snap(tag+".owner-cleanup")
        return {"status":outcome(checks),"checks":checks}

    def active_target(self):
        tag="A.focusedTarget"
        before,_=self.prepare(tag)
        self.seed_focus(tag,0)
        before=self.snap(tag+".key-target")
        if self.focused(before,"A0") is not True: return {"status":"BLOCKED","reason":"target not key"}
        self.event(tag+".minimize",self.inspected("minimize","A0")); time.sleep(.85)
        hidden=self.snap(tag+".hidden")
        routed=self.keyed(tag+".hidden",hidden,"A0")
        self.event(tag+".restore",self.inspected("restore","A0")); time.sleep(.85)
        after=self.snap(tag+".restored")
        return {"status":"OBSERVED","before":before["focus"],"whileHidden":hidden["focus"],"afterRestore":after["focus"],
                "originalWindowRetainedKeyFocus":self.focused(hidden,"A0"),"originalWindowReceivedKey":routed,
                "targetActuallyMinimized":hidden["windows"]["A0"]["axLease"]["mini"]}

    def order_mode(self, mode):
        p = subprocess.Popen([self.bin/"Order",mode,self.root],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log,text=True)
        try:
            self.event("B."+mode+".connection",json.loads(p.stdout.readline()))
            def act(hide,idx):
                p.stdin.write(("out" if hide else "in")+str(idx)+"\n"); p.stdin.flush()
                return json.loads(p.stdout.readline())
            single=self.single("B."+mode,"B",act)
            restored=self.restore_only(mode,act)
            pair=self.single("B."+mode+".second","B",act,1,"A0") if single["status"] == "PASS" else {"status":"NOT_RUN","reason":"single gate"}
            return {"single":single,"foreignRestoreAfterOwnerHide":restored,"sameAppSecond":pair}
        finally:
            if p.poll() is None:
                p.stdin.write("close\n"); p.stdin.flush()
                self.event("B."+mode+".close",json.loads(p.stdout.readline()))
            p.wait(timeout=4)

    def user_dock(self):
        # Independent user-intervention case. Initial windows are owner-minimized deliberately,
        # even if the management mechanism failed its own single-window gate.
        before,_ = self.prepare("A.userDock")
        for i in (0,1):
            self.event("A.userDock.seed"+str(i),self.command("A","mini",i)["action"])
        time.sleep(.85)
        seeded=self.snap("A.userDock.seeded")
        if any(seeded["windows"][k]["axMini"] is not True for k in ("A0","A1")):
            return {"status":"BLOCKED","reason":"two owner-minimized documents not observed"}
        click=self.event("A.userDock.click",self.inspected("dock-click"))
        time.sleep(.45); self.snap("A.userDock.after-click"); time.sleep(.8)
        after=self.snap("A.userDock.settled")
        restored=[k for k in ("A0","A1") if after["windows"][k]["axMini"] is False and after["windows"][k]["cgScreen"] is not None]
        self.event("A.userDock.yield",{"managerWritesAfterUserClick":0,"restored":restored})
        return {"status":"OBSERVED" if click["posted"] else "BLOCKED","dockClickPosted":click["posted"],"restored":restored,
                "tilesBefore":before["dock"].get("minimizedTiles"),"tilesSeeded":seeded["dock"].get("minimizedTiles"),
                "tilesAfter":after["dock"].get("minimizedTiles"),"managerWritesAfterUserClick":0,
                "focusedWindowAfter":after["focus"],"otherWindowReconciliation":"NOT_RUN in production"}

    def mc(self, phase, capture=False):
        _, state = self._mc_state()
        if state is not False:
            return {"status":"BLOCKED","reason":"ordinary Dock state unreadable"}
        # Launch Apple's own Mission Control bundle on a throwaway login. Escape only a witnessed overview.
        try:
            r=execute("open","-a","/System/Applications/Mission Control.app",check=False)
            time.sleep(1.1)
            active=self.snap(phase+".overview")
            if active["dock"].get("missionControl") is not True:
                return {"status":"UNKNOWN","openExit":r.returncode,"overviewWitness":False}
            if capture and active["screenAllowed"]:
                for ordinal in range(1,len(active["displays"])+1):
                    path=self.out/f"{phase}-display-{ordinal}.png"
                    shot=execute("screencapture","-x","-t","png","-D",str(ordinal),path,check=False)
                    self.event(phase+".capture-"+str(ordinal),{"exit":shot.returncode,"file":path.name,
                               "bytes":path.stat().st_size if path.exists() else 0})
            self.event(phase+".escape",self.inspected("escape-mc"))
            time.sleep(.8)
            closed=self.snap(phase+".closed")
            return {"status":"PASS" if closed["dock"].get("missionControl") is False else "UNKNOWN",
                    "activeDisplays":active["displays"],"after":closed["displays"]}
        finally:
            if self._mc_state()[1] is True:
                self.inspected("escape-mc"); time.sleep(.7)

    def _mc_state(self):
        s=self.inspected("snapshot")
        return s, s["dock"].get("missionControl")

    def virtual(self):
        before,pt=self.prepare("C")
        baseline_mc=self.mc("C.baselineMC")
        before,pt=self.prepare("C.preTopology")
        origin=before["windows"]["A0"]["axFrame"][:2]
        pointer=before["pointer"]
        p=subprocess.Popen([self.bin/"Display",self.root],stdout=self.log,stderr=self.log)
        attempted=False
        result={"status":"UNKNOWN","baselineMissionControl":baseline_mc,"physicalAccidentalPointer":"NOT_RUN","physicalMultipleDisplays":"NOT_RUN"}
        try:
            spec=self.event("C.virtual-display",await_file(self.root/"display.json",10))
            result["virtual"]=spec
            if spec["status"] != "READY":
                result.update(status="BLOCKED",reason="WindowServer refused virtual display or arrangement")
                return result
            configured=self.snap("C.topology")
            dest=spec["actual"]
            x,y,w,h=dest
            def shared(other):
                a,b,c,d=other["bounds"]
                if a+c==x or x+w==a: return max(0,min(y+h,b+d)-max(y,b))
                if b+d==y or y+h==b: return max(0,min(x+w,a+c)-max(x,a))
                return 0
            edges=[shared(d) for d in configured["displays"] if d["id"]!=spec["id"]]
            result["sharedEdgesPixels"]=edges
            if not any(d["id"]==spec["id"] for d in configured["displays"]) or len(edges)!=len(before["displays"]):
                result.update(status="BLOCKED",reason="virtual lifetime/topology not independently witnessed")
                return result
            attempted=True
            self.event("C.move",self.inspected("move","A0",x+55,y+90))
            time.sleep(.85)
            parked=self.snap("C.parked"); t=parked["windows"]["A0"]; old=before["windows"]["A0"]
            checks={"onlyTargetMoved":self.siblings(configured,parked,"A0"),
                    "focusAfterTopology":self.focused(configured,"A1"),"focusWhileParked":self.focused(parked,"A1"),
                    "nativeSpaceUnchanged":equal_known(old["spaces"],t["spaces"]),
                    "parkOnVirtual":t["owner"]["display"]==spec["id"], "windowState":old["owner"]["content"]==t["owner"]["content"],
                    "unchangedDockTiles":equal_known(before["dock"].get("minimizedTiles"),parked["dock"].get("minimizedTiles"))}
            checks["keyboardWhileParked"]=self.keyed("C.parked",parked,"A1")
            checks["physicalOldPoint"]=self.clicked("C.physical",pt,"B0")
            result["physicalAccidentalPointer"]="UNKNOWN: no human or physical relative HID on hosted runner"
            warp=center(t["axFrame"]) if checks["parkOnVirtual"] and t["axFrame"] else (x+w/2,y+h/2)
            self.event("C.absoluteWarp",self.inspected("warp",*warp)); time.sleep(.25)
            read=self.snap("C.absolutePointer")
            result["absolutePointerEnteredVirtual"]=x<=read["pointer"][0]<x+w and y<=read["pointer"][1]<y+h
            if result["absolutePointerEnteredVirtual"] and checks["parkOnVirtual"]:
                result["realClickReachedParkedWindow"]=self.clicked("C.virtual-hit",warp,"A0")
                checks["parkedInputIsolated"]=None if result["realClickReachedParkedWindow"] is None else not result["realClickReachedParkedWindow"]
            self.inspected("warp",*pointer)
            result["configuredMissionControl"]=self.mc("C.withVirtual")
            result["checks"]=checks
        finally:
            # Return the exact fixture and cursor before disposing of the display, even on partial failure.
            if attempted:
                self.event("C.move-back",self.inspected("move","A0",*origin))
                self.inspected("warp",*pointer)
                time.sleep(.7)
                self.snap("C.before-dispose")
            (self.root/"display-stop").touch()
            p.wait(timeout=8); time.sleep(.8)
            end=self.snap("C.after-dispose")
            result["topologyRestored"]=end["displays"]==before["displays"]
            a=end["windows"]["A0"]; prev=before["windows"]["A0"]
            result["geometryRestored"]=equal_known(a["axFrame"], prev["axFrame"])
            result["spaceRestored"]=equal_known(a["spaces"],prev["spaces"])
        if "checks" in result:
            result["checks"].update(topologyRestored=result["topologyRestored"],geometryRestored=result["geometryRestored"],
                    spaceRestored=result["spaceRestored"],physicalPointerIsolation=None,physicalMultiDisplay=None)
            result["status"]=outcome(result["checks"])
        return result

    def block(self,label,fn):
        try: rec=fn()
        except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as e:
            rec={"status":"BLOCKED","reason":str(e)}
        self.entries["methods"][label]=rec
        self.event(label+".result",rec); write(self.out/"summary.json",self.entries)


def run(out, suite):
    if [os.getenv(k) for k in ("RUNNER_ENVIRONMENT","GITHUB_ACTIONS","RUNNER_OS","USER")] != ["github-hosted","true","macOS","runner"]:
        raise SystemExit("Live trials require an empty GitHub-hosted macOS login")
    out.mkdir(exist_ok=False,parents=True)
    with tempfile.TemporaryDirectory(prefix="nearpane-visibility-",dir=os.environ["RUNNER_TEMP"]) as temp:
        t=Trial(Path(temp).resolve(),out)
        old=dock_pref()
        t.entries.update(suite=suite,os=execute("sw_vers").stdout.strip(),sip=execute("csrutil","status").stdout.strip(),
                         revision=os.environ["GITHUB_SHA"],image=os.getenv("ImageVersion"),dockOriginal=old,
                         stageManagerPreference=execute("defaults","read","com.apple.WindowManager","GloballyEnabled",check=False).stdout.strip() or "absent")
        modified=old is not True
        try:
            if modified:
                execute("defaults","write","com.apple.dock","minimize-to-application","-bool","true"); restart_dock()
            t.entries["dockDuring"]=dock_pref()
            if dock_pref() is not True: raise RuntimeError("Dock preference did not take effect")
            if t.entries["stageManagerPreference"]=="1": raise RuntimeError("system Stage Manager enabled")
            t.launch()
            if suite == "lifecycle":
                from lifecycle import ax_crash, display_crash
                t.block("A.crash",lambda:ax_crash(t))
                t.block("C.crash",lambda:display_crash(t))
            else:
                def ax_action(hide,idx): return t.inspected("minimize" if hide else "restore","A"+str(idx))
                t.block("A.single",lambda:t.single("A.single","A",ax_action))
                if t.entries["methods"]["A.single"]["status"]=="PASS":
                    t.block("A.sameAppSecond",lambda:t.single("A.sameAppSecond","A",ax_action,1,"A0"))
                else: t.entries["methods"]["A.sameAppSecond"]={"status":"NOT_RUN","reason":"single gate"}
                t.block("A.userDock",t.user_dock)
                t.block("A.focusedTarget",t.active_target)
                t.block("B.ownerControl",lambda:t.single("B.ownerControl","B",lambda hide,idx:t.command("A","raw-out" if hide else "raw-in",idx)["action"]))
                for mode in ("cold-main","appkit-load","app-main","independent","transaction"):
                    t.block("B."+mode,lambda mode=mode:t.order_mode(mode))
                t.block("C.virtual",t.virtual)
        except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as e:
            t.entries["setupFailure"]=str(e)
        finally:
            if t.lease_reader is not None:
                t.lease_reader.stdin.close()
                t.lease_reader.wait(timeout=5)
            (t.root/"display-stop").touch(); (t.root/"stop").touch()
            exits=[]
            for p in t.hosts:
                try: exits.append(p.wait(timeout=8))
                except subprocess.TimeoutExpired: exits.append(None)
            if modified:
                if old is None: execute("defaults","delete","com.apple.dock","minimize-to-application",check=False)
                elif type(old) is bool: execute("defaults","write","com.apple.dock","minimize-to-application","-bool",str(old).lower())
                else: raise RuntimeError("unexpected preference type")
                restart_dock()
            t.entries["cleanup"]={"fixtureLaunchersExit":exits,"fixtureCount":len(t.hosts),"dockRestored":dock_pref()==old,
                                  "temporaryDirectoryRemoved":False}
            t.ledger.close(); t.log.close()
            write(out/"summary.json",t.entries)
    t.entries["cleanup"]["temporaryDirectoryRemoved"]=not t.root.exists()
    write(out/"summary.json",t.entries)
    print(json.dumps({"methods":{k:v.get("status",v.get("single",{}).get("status")) for k,v in t.entries["methods"].items()},"cleanup":t.entries["cleanup"]}))
    if "setupFailure" in t.entries or any(x != 0 for x in exits) or not t.entries["cleanup"]["dockRestored"]: raise SystemExit(1)


if __name__=="__main__":
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument("output",type=Path)
    cli.add_argument("--suite",choices=("core","lifecycle"),default="core")
    args=cli.parse_args()
    run(args.output,args.suite)
