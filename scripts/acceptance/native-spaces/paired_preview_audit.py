"""Enroll just two synthetic windows of one signed process in the installed Host's existing audit."""
import importlib
import json
import os
from pathlib import Path
import tempfile
import time

p0 = importlib.import_module("p0-cards")


class PairedWindowAudit(p0.InstalledWindowAudit):
    def bind(self, observed, expected, numbers):
        keys=("pid","birth","hash","identifier","executable")
        p0.require(all(expected.get(k)==observed.get(k) for k in keys) and expected["identifier"]=="net.example.spaces-document"
                   and len(numbers)==len(set(numbers))==2 and all(type(n) is int and n>0 for n in numbers),
                   "two unique windows of the exact signed Field Notes generation are required")
        self.targets=[dict(pid=expected["pid"],birth=expected["birth"],number=n) for n in numbers]
        self.registeredAt=time.monotonic()
        self.manifest=dict(version=1,targets=self.targets)
        fd,name=tempfile.mkstemp(dir=self.home,prefix=".preview-window-audit-")
        try:
            with os.fdopen(fd,"w") as f:
                os.fchmod(f.fileno(),0o600);json.dump(self.manifest,f);f.flush();os.fsync(f.fileno())
            os.link(name,self.request,follow_symlinks=False)
        finally:Path(name).unlink(missing_ok=True)
        p0.store(self.output/"registered-targets.json",self.manifest)

    def evidence(self, phase, release=False):
        summary={"status":"UNAVAILABLE","targets":self.targets,"registeredAt":self.registeredAt}
        try:
            actual=p0.cmd(self.kit/"p0-card","process",self.host["pid"])
            p0.require(actual==self.host,"installed Host generation changed during audit")
            records,information=self.read()
            verified=[]
            for _,row,_ in records:
                if row.get("window") is not None and row["window"] not in self.targets:continue
                if row["uptime"]>=self.registeredAt:verified.append(row)
            summary.update(information,status="OBSERVED" if verified else "UNAVAILABLE",
                           stages=sorted({row["stage"] for row in verified}),enrolledRecords=len(verified))
            p0.store(self.output/(phase+"-records.json"),verified)
        except (OSError,ValueError,RuntimeError) as exc:
            summary["reason"]=type(exc).__name__ if isinstance(exc,FileNotFoundError) else str(exc)[:180]
        finally:
            if release:
                from space_scope import private_file
                if json.loads(private_file(self.request))==self.manifest:
                    self.request.unlink();summary["manifestRemoved"]=True
        p0.store(self.output/(phase+".json"),summary)
        return summary
