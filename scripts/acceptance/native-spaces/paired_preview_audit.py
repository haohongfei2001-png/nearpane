"""Enroll just two synthetic windows of one signed process in the installed Host's existing audit."""
import importlib
import json
import os
from pathlib import Path
import tempfile
import math
import stat
import hashlib
import uuid
from space_scope import private_file
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
        if os.environ.get("NEARPANE_PREVIEW_DIAGNOSTICS") == "1":
            p0.require(Path(os.environ.get("NEARPANE_TEST_HOME", "")).absolute() == self.home and
                       self.host.get("identifier") == "com.holdsnow.nearpane.alpha" and
                       self.host.get("executable") == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost" and
                       not os.path.lexists(self.home / "p0-preview-transitions.jsonl"),
                       "preview trace requires the signed installed Host and a fresh isolated home")
            self.manifest["previewTrace"] = dict(token=str(uuid.uuid4()), hostPID=self.host["pid"],
                hostBirth=self.host["birth"], hostHash=self.host["hash"], fixtureHash=expected["hash"])
        fd,name=tempfile.mkstemp(dir=self.home,prefix=".preview-window-audit-")
        try:
            with os.fdopen(fd,"w") as f:
                os.fchmod(f.fileno(),0o600);json.dump(self.manifest,f);f.flush();os.fsync(f.fileno())
            os.link(name,self.request,follow_symlinks=False)
        finally:Path(name).unlink(missing_ok=True)
        p0.store(self.output/"registered-targets.json",self.manifest)

    def transitions(self, phase):
        request = self.manifest["previewTrace"]
        path = self.home / "p0-preview-transitions.jsonl"
        if not os.path.lexists(path):
            return {"status": "UNAVAILABLE", "reason": "noOptedInHostTransitions"}
        p0.require(path.is_absolute() and path.resolve() == path, "invalid transition receipt path")
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
            start = os.fstat(stream.fileno())
            p0.require(stat.S_ISREG(start.st_mode) and start.st_uid == os.getuid() and start.st_nlink == 1 and
                       start.st_mode & 0o077 == 0 and 0 <= start.st_size <= 384 * 1024, "invalid transition receipt file")
            # The signed writer appends once per record. Read exactly the prefix visible at open.
            raw = stream.read(start.st_size)
            end = os.fstat(stream.fileno())
            p0.require(len(raw) == start.st_size and end.st_size >= start.st_size and end.st_nlink == 1 and
                       end.st_mode == start.st_mode and end.st_uid == start.st_uid, "transition receipt changed")
        rows = []
        lanes = {"stream", "admission", "membership", "lookup", "cache", "card", "lifecycle"}
        reasons = set(("enrolled capacityReached complete started idle blank suspended stopped invalidMetadata invalidBuffer "
                       "unknownStatus streamError allowed leaseChanged notPermitted notVisible incarnationChanged sessionUnavailable "
                       "screenDenied snapshotChanged staleSnapshot rosterMismatch ownerUnavailable publicListMissing metadataMissing "
                       "surfaceMismatch notDrawn sharingDenied offscreen frameChanged publicMembership freshMembership "
                       "membershipUnconfirmed streamEpochChanged noFrame streamInactive stillMismatch conversionFailed invalidPixelCost "
                       "notStored removed current previous recent mapOnly liveImage selectedImage previousImage outline mounted unmounted "
                       "created cleared targetChanged ended").split())
        required = {"writerPID", "hostBirth", "window", "token", "feed", "epoch", "revision", "ordinal", "uptime", "lane", "reason", "stage"}
        partial = False
        for line in raw.splitlines(keepends=True):
            if not line.endswith(b"\n"):
                partial = True
                break
            row = json.loads(line)
            p0.require(isinstance(row, dict) and required <= row.keys() <= required | {"streamEpoch", "frameSequence"} and
                       row["stage"] == "preview-transition" and row["writerPID"] == request["hostPID"] and
                       row["hostBirth"] == request["hostBirth"] and row["token"].lower() == request["token"] and
                       row["window"] in self.targets and row["ordinal"] == len(rows) + 1 <= 513 and
                       type(row["uptime"]) in (int, float) and math.isfinite(row["uptime"]) and row["uptime"] >= self.registeredAt and
                       row["lane"] in lanes and row["reason"] in reasons and
                       all(type(row[k]) is int and row[k] >= 0 for k in ("revision", "streamEpoch", "frameSequence") if k in row),
                       "unexpected preview transition envelope")
            for field in ("feed", "epoch"):
                uuid.UUID(row[field])
            rows.append(row)
        p0.store(self.output / (phase + "-preview-transitions.json"), rows)
        capped = any(r["reason"] == "capacityReached" for r in rows)
        coverage = [sorted({r["lane"] for r in rows if r["window"] == target}) for target in self.targets]
        complete = all({"stream", "card"} <= set(lanes) for lanes in coverage)
        state = "TRUNCATED" if capped else "INCOMPLETE" if partial else "OBSERVED" if complete else "PARTIAL" if rows else "UNAVAILABLE"
        return dict(status=state, count=len(rows), lanesByTarget=coverage, capacity=512, incompleteFinalLine=partial,
                    sourceSHA256=hashlib.sha256(raw).hexdigest(), file=phase + "-preview-transitions.json")

    def evidence(self, phase, release=False):
        summary={"status":"UNAVAILABLE","targets":self.targets,"registeredAt":self.registeredAt}
        try:
            actual=p0.cmd(self.kit/"p0-card","process",self.host["pid"])
            p0.require(actual==self.host,"installed Host generation changed during audit")
            if self.manifest.get("previewTrace"):
                try:
                    summary["previewTransitions"] = self.transitions(phase)
                except (OSError, ValueError, TypeError, KeyError, RuntimeError):
                    summary["previewTransitions"] = {"status": "UNAVAILABLE", "reason": "invalidOrChangingTransitionReceipt"}
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
