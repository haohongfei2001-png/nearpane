"""One offline-enrolled ordinary pair, one Apple setup shortcut, no Space creation or deletion."""
import hashlib
import importlib
import json
from pathlib import Path
import subprocess
import time

from space_scope import private_file, require

preview=importlib.import_module("preview-workspace")


def endpoints(topology, owned, enrolled):
    source=topology["current"]
    rows=topology["records"]
    order=[r["id"] for r in rows]
    require(len(owned)==2 and source in owned and len(set(owned))==2, "two existing owned ordinary endpoints required")
    target=next(n for n in owned if n!=source)
    require(all(n in order and rows[order.index(n)]==dict(id=n,type=0,uuid=enrolled[n]) for n in owned)
            and abs(order.index(source)-order.index(target))==1, "existing leased ordinary endpoints are no longer adjacent and UUID-matched")
    return source,target


class BookedPair:
    def __init__(self,kit,loan,initial,log):
        self.workspace=loan.workspace
        require(self.workspace is not None, "historical Stage lease was not admitted")
        self.tool=kit/"p0-booked"
        require(self.tool.resolve(strict=True)==self.tool, "borrowed lease reader path changed")
        subprocess.run(["/usr/bin/codesign","--verify","--strict",self.tool],check=True,capture_output=True,timeout=4)
        self.topology=initial["topology"]
        self.initial=initial
        self.card=kit/"p0-card"
        self.log=log
        ws=self.workspace
        refs=[]
        for n in ws.ids():
            p,identity=preview.lease_for(ws,n)
            refs.append(dict(space=n,uuid=identity,receipt=str(p),digest=hashlib.sha256(private_file(p)).hexdigest()))
        self.source,self.target=endpoints(self.topology,ws.ids(),{r["space"]:r["uuid"] for r in refs})
        self.binding=dict(leases=refs,hid=initial["hid"],boot=ws.boot,hostPID=ws.host["pid"],hostBirth=ws.host_birth,
                          hostHash=ws.host["codeHash"],stageSurfaces=loan.stage_surfaces)
        self.documents={}
        self.setup_attempted=False
        self.log("borrowed-adjacent-pair",source=self.source,target=self.target,leases=refs,create=False,remove=False,pixels=0)

    def recoverable_front(self,sample,initial,process):
        pid,number=sample.get("frontPID"),sample.get("focusedNumber")
        if pid==self.binding["hostPID"]:
            return True
        if any((w["pid"],w["number"])==(pid,number) for w in self.documents.values()):
            return True
        # Finder and the system may acquire empty-desktop focus. Never address those processes.
        if number is not None or type(pid) is not int or pid<=1:
            return False
        if (pid,number)==(initial.get("frontPID"),initial.get("focusedNumber")):
            return True
        live=process(pid)
        allowed={"com.apple.finder":"/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                 "com.apple.dock":"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
                 "com.apple.WindowManager":"/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"}
        executable=allowed.get(live.get("identifier"))
        return bool(executable and live.get("pid")==pid and live.get("executable")==executable and
                    subprocess.run(["/usr/bin/codesign","--verify","--strict","-R=anchor apple",executable],capture_output=True,timeout=3).returncode==0)

    def read(self,source,phase,mode="leased-census"):
        ws=self.workspace
        target=self.target if source==self.source else self.source
        require({source,target}=={self.source,self.target}, "unregistered endpoint requested")
        current=ws.check(ws.read())
        require(current["current"]==source and current["scope"]==self.topology["display"] and current["records"]==self.topology["records"],
                "independent leased roster or current changed during "+phase)
        request=dict(self.binding,topology=dict(self.topology,current=source),target=target,
                     documents=[dict(space=n,window=w) for n,w in self.documents.items()])
        proc=subprocess.run([self.tool,mode],input=json.dumps(request),text=True,capture_output=True,timeout=7,env=preview.login_env())
        proof=json.loads(proc.stdout)
        self.log("booked-lease-"+phase,requested=mode,proof=proof)
        if mode=="leased-setup-arrow":
            require(proc.returncode==0 and proof.get("issued") is True and proof.get("setupOnly") is True and
                    (proof.get("source"),proof.get("target"))==(source,target),proof.get("error","Apple setup input outcome unknown"))
        else:
            require(proc.returncode==0 and proof.get("status")=="READ" and proof.get("pixels")==0 and proof.get("current")==source and
                    set(proof.get("counts",{}))=={str(n) for n in ws.ids()},proof.get("error","bound no-pixel desktop census unavailable"))
        return proof

    def confirm(self,source,phase):
        first=self.read(source,phase)
        time.sleep(.17)
        last=self.read(source,phase)
        require(last["uptime"]>first["uptime"] and first["counts"]==last["counts"], "two stable endpoint censuses unavailable during "+phase)

    def setup(self,state):
        require(not self.setup_attempted and set(self.documents)=={self.source}, "one setup input requires only the original owned document")
        self.confirm(self.source,"before-shortcut")
        self.setup_attempted=True
        self.read(self.source,"system-shortcut","leased-setup-arrow")
        consecutive=0
        deadline=time.monotonic()+6
        while time.monotonic()<deadline:
            sample=state()
            obs=sample["topology"]
            require(sample["hid"]==self.binding["hid"] and obs["display"]==self.topology["display"] and
                    obs["records"]==self.topology["records"] and obs["current"] in (self.source,self.target),
                    "physical input, display or UUID order changed during Apple setup")
            consecutive=consecutive+1 if obs["current"]==self.target else 0
            if consecutive>=2:
                self.confirm(self.target,"empty-arrival")
                active=state()
                def process(pid):
                    return json.loads(subprocess.check_output([self.card,"process",str(pid)],text=True,timeout=3))
                require(active["hid"]==self.binding["hid"] and active["topology"]==dict(self.topology,current=self.target) and
                        self.recoverable_front(active,self.initial,process), "external Space or foreground arrived after Apple setup")
                return
            time.sleep(.12)
        raise ValueError("Apple setup was sent once; independent WindowServer did not confirm the enrolled neighbor")
