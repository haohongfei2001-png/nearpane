"""Borrow Stage Manager only on an independently empty, already-enrolled ordinary desktop."""
import importlib
from copy import copy
import os
from pathlib import Path
import subprocess

from contract_workspace import empty_system_desktop, write_owned
from space_scope import require

preview=importlib.import_module("preview-workspace")


class StageLoan:
    def __init__(self,kit,out,probe):
        require(kit==kit.resolve(strict=True) and kit.parent==Path("/private/tmp") and kit.name.startswith("nearpane-d01.")
                and kit.stat().st_uid==os.getuid() and not kit.stat().st_mode & 0o077, "invalid private Stage reader kit")
        for name in ("preview-stage-control","split-view-read","metrics","observe","system-workspace"):
            tool=kit/name
            require(tool==tool.resolve(strict=True) and tool.is_file(),"missing signed Stage reader "+name)
            subprocess.run(["/usr/bin/codesign","--verify","--strict",tool],check=True,capture_output=True,timeout=6)
        self.kit=kit
        self.output=out/"stage-manager"
        self.output.mkdir(mode=0o700)
        self.transaction=None
        states=preview.states(kit)
        self.original=states[-1]["state"]
        write_owned(self.output/"original.json",dict(login=states,hostProbe=probe))
        require(self.original is probe["stageManagerOwnsDispatch"],"actual login and signed installed Host disagree about Stage Manager")

    def existing(self,args,initial,log):
        fields=[getattr(args,key,None) for key in ("stage_workspace","stage_space","stage_original_checkout","stage_previous_archive","stage_install_receipt")]
        require(all(v is not None for v in fields) or not any(v is not None for v in fields),"incomplete historical Stage setup lease")
        if not self.original or not all(fields):return
        folder,n,checkout,archive,chain=fields
        if initial["topology"]["current"]!=n:
            log("registered-stage-space-not-current",expected=n,selected=initial["topology"]["current"])
            return
        ledgers=checkout/"build/verification/secondary-route-followup"
        require(ledgers.resolve(strict=True)==ledgers,"existing Stage enrollment root changed")
        ws=preview.PreviewWorkspace(self.kit,folder,log,resume=True,previous_archive=archive,install_receipt=chain,original_ledgers=ledgers)
        ws.bind_quiet_cleanup()
        self.borrow(ws,n,initial["hid"])

    def borrow(self,ws,target,hid):
        if not self.original or self.transaction is not None:return
        if ws.kit!=self.kit:
            # The Stage samplers validate the same ledger and Host with their own compiled
            # no-pixel membership reader. The P0 workspace and its observers stay intact.
            ws=copy(ws)
            ws.kit=self.kit
        preview.lease_for(ws,target)
        require(ws.hardware()==hid,"physical input changed before Stage setup")
        evidence=empty_system_desktop(ws,target)
        write_owned(self.output/"empty-lease-admission.json",evidence)
        require(ws.check(ws.read())["current"]==target and ws.hardware()==hid,"leased foreground changed before Stage setup")
        self.transaction=preview.PreferenceStage(self.kit,self.output,ws,target)
        qualified=self.transaction.runtime(True)
        write_owned(self.output/"before.json",qualified)
        require(qualified["status"]=="PASS" and ws.check(ws.read())["current"]==target and ws.hardware()==hid,
                "Stage setup lost the signed Host, physical input or enrolled desktop")
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
