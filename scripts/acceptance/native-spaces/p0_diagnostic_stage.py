"""Borrow Stage Manager only on an independently empty, already-enrolled ordinary desktop."""
import importlib
from copy import copy
import os
from pathlib import Path
import subprocess
import time

from contract_workspace import empty_system_desktop, inactive_empty, write_owned
from space_scope import require

preview=importlib.import_module("preview-workspace")
P0_HID = ("leftMouseDown", "rightMouseDown", "otherMouseDown", "keyDown", "scrollWheel",
          "leftMouseDragged", "rightMouseDragged", "otherMouseDragged")
STAGE_HID = P0_HID[:5]


class StageLoan:
    def __init__(self,kit,out,probe,read_state):
        require(kit==kit.resolve(strict=True) and kit.parent==Path("/private/tmp") and kit.name.startswith("nearpane-d01.")
                and kit.stat().st_uid==os.getuid() and not kit.stat().st_mode & 0o077, "invalid private Stage reader kit")
        for name in ("preview-stage-control","split-view-read","metrics","observe","system-workspace"):
            tool=kit/name
            require(tool==tool.resolve(strict=True) and tool.is_file(),"missing signed Stage reader "+name)
            subprocess.run(["/usr/bin/codesign","--verify","--strict",tool],check=True,capture_output=True,timeout=6)
        self.kit=kit
        self.read_state=read_state
        self.output=out/"stage-manager"
        self.output.mkdir(mode=0o700)
        self.transaction=None
        self.workspace=None
        self.stage_surfaces=[]
        states=preview.states(kit)
        self.original=states[-1]["state"]
        write_owned(self.output/"original.json",dict(login=states,hostProbe=probe))
        require(self.original is probe["stageManagerOwnsDispatch"],"actual login and signed installed Host disagree about Stage Manager")

    def existing(self,args,initial,log):
        fields=[getattr(args,key,None) for key in ("stage_workspace","stage_space","stage_original_checkout","stage_previous_archive","stage_install_receipt")]
        require(all(v is not None for v in fields) or not any(v is not None for v in fields),"incomplete historical Stage setup lease")
        if not all(fields):return
        folder,n,checkout,archive,chain=fields
        if initial["topology"]["current"]!=n:
            log("registered-stage-space-not-current",expected=n,selected=initial["topology"]["current"])
            return
        ledgers=checkout/"build/verification/secondary-route-followup"
        require(ledgers.resolve(strict=True)==ledgers,"existing Stage enrollment root changed")
        ws=preview.PreviewWorkspace(self.kit,folder,log,resume=True,previous_archive=archive,install_receipt=chain,original_ledgers=ledgers)
        ws.bind_quiet_cleanup()
        from p0_diagnostic_pair import endpoints
        owned=ws.ids()
        _,neighbor=endpoints(initial["topology"],owned,{i:preview.lease_for(ws,i)[1] for i in owned})
        for _ in range(2):
            o=ws.read()
            current=ws.check(o)
            peer=(o.get("scopedMembers") or {}).get(str(neighbor),{})
            log("existing-inactive-neighbor",space=neighbor,uptime=o.get("uptime"),ordinaryCount=len(peer.get("ordinary",[])),
                unresolved=peer.get("unresolved"),otherMembers=peer.get("otherMembers"))
            require(current["current"]==n and current["records"]==initial["topology"]["records"] and
                    self.read_state().get("hid")==initial["hid"] and inactive_empty(peer,neighbor,system_surfaces=True),
                    "inactive neighbor contains an ordinary or unidentified window, or the original state changed")
            time.sleep(.12)
        self.workspace=ws
        self.borrow(ws,n,initial["hid"])

    def confirm_hid(self,ws,original,phase):
        # p0-card and system-workspace are separately compiled readers. Bracket the five
        # common events with two complete P0 reads so the three drag counters also stay bound.
        entry=dict(status="UNKNOWN",p0Fields=P0_HID,stageFields=STAGE_HID,original=original,phase=phase)
        def counters(value,size):
            return isinstance(value,list) and len(value)==size and all(type(n) is int and 0<=n<2**32 for n in value)
        def sample():
            state=self.read_state()
            return dict(uptime=state.get("uptime"),hid=state.get("hid"))
        try:
            entry["before"]=sample()
            entry["stageFrom"]=time.monotonic()
            entry["stage"]=ws.hardware()
            entry["stageTo"]=time.monotonic()
            entry["after"]=sample()
            before,after=entry["before"],entry["after"]
            require(all(counters(c,len(P0_HID)) for c in (original,before["hid"],after["hid"]))
                    and counters(entry["stage"],len(STAGE_HID)), "incomplete physical input counter schema during "+phase)
            require(all(type(v) in (int,float) for v in (before["uptime"],after["uptime"])) and
                    before["uptime"]<=after["uptime"] and entry["stageFrom"]<=entry["stageTo"],
                    "Stage input sampling interval is not bracketed by the P0 reader")
            entry["p0Changed"]=[name for i,name in enumerate(P0_HID) if original[i]!=before["hid"][i] or original[i]!=after["hid"][i]]
            entry["stageChanged"]=[name for i,name in enumerate(STAGE_HID) if entry["stage"][i]!=original[i]]
            if entry["p0Changed"] or entry["stageChanged"]:
                entry["status"]="CHANGED"
                raise ValueError("physical input changed during "+phase+": "+", ".join(dict.fromkeys(entry["p0Changed"]+entry["stageChanged"])))
            entry["status"]="CONFIRMED"
        finally:
            write_owned(self.output/(phase+"-hid.json"),entry)

    def borrow(self,ws,target,hid):
        if not self.original or self.transaction is not None:return
        if ws.kit!=self.kit:
            # The Stage samplers validate the same ledger and Host with their own compiled
            # no-pixel membership reader. The P0 workspace and its observers stay intact.
            ws=copy(ws)
            ws.kit=self.kit
        preview.lease_for(ws,target)
        self.confirm_hid(ws,hid,"before-empty-check")
        evidence=empty_system_desktop(ws,target)
        write_owned(self.output/"empty-lease-admission.json",evidence)
        from p2_stage_surfaces import lease_enrollment
        _,space_uuid=preview.lease_for(ws,target)
        enrollment=lease_enrollment(ws,target,space_uuid,self.original,evidence)
        self.stage_surfaces=[dict(space=target,**r) for r in enrollment["surfaces"]]
        require(ws.check(ws.read())["current"]==target,"leased foreground changed before Stage setup")
        self.confirm_hid(ws,hid,"after-empty-check")
        self.transaction=preview.PreferenceStage(self.kit,self.output,ws,target)
        qualified=self.transaction.runtime(True)
        write_owned(self.output/"before.json",qualified)
        require(qualified["status"]=="PASS" and ws.check(ws.read())["current"]==target,
                "Stage setup lost the signed Host or enrolled desktop")
        self.confirm_hid(ws,hid,"before-stage-write")
        # Same preference transaction as the installed P2 acceptance. It records the original
        # value before one compare-and-write, then independently reads the actual Host state.
        proof=self.transaction.toggle("stage-off",True,False)
        write_owned(self.output/"off.json",proof)

    def restore(self):
        if self.transaction is None:
            current=preview.states(self.kit)
            return dict(status="PASS" if current[-1]["state"] is self.original else "UNKNOWN",
                        changedByRun=False,original=self.original,current=current)
        proof=self.transaction.restore(self.original)
        write_owned(self.output/"restored.json",proof)
        return proof
