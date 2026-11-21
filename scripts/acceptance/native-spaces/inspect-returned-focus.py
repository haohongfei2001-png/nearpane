#!/usr/bin/env python3
"""Check a closed protected transaction without activating or raising an application."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib
import json
import os
from pathlib import Path
import subprocess
import uuid
from contract_workspace import write_owned
from p2_documents import static_part
from space_scope import private_file, require

transaction = importlib.import_module("private-installed-trials")


def inspect(kit, receipt):
    mac=transaction.Mac()
    raw=private_file(receipt,limit=4_000_000); r=json.loads(raw)
    tid=str(uuid.UUID(r["transaction"]))
    require(tid == r["transaction"] and json.loads(private_file(mac.root/(tid+".json"),limit=4_000_000)) == r and
            r["stage"] == "restored" and r["restoration"] == r["cleanup"] == "PASS",
            "Not a complete transaction matching its private archive")
    focus=r["visitDailyOriginal"]
    require(focus["ready"] and len(focus["hid"])==13,"Complete original foreground identity and input counters required")
    require(Path(r["output"])/"installation.json" == receipt,"The accepted receipt must be in its own transaction output")
    source=json.loads(private_file(Path(r["focusLease"]["workspace"])/"original.json"))
    boot=str(uuid.UUID(source["boot"])).upper()
    require(focus.get("boot",boot)==boot,"Original focus and lease boot disagree")
    stamp=r["restoredDailyHost"]; old=r["original"]
    require(len(stamp)==3 and all(type(x)==int for x in stamp),"Invalid restored Host stamp")
    require(kit == kit.resolve(strict=True) and kit.parent == Path("/private/tmp") and
            kit.stat().st_uid==os.getuid() and not kit.stat().st_mode & 0o077 and kit.name.startswith("nearpane-d01."),
            "Private enrolled observer kit required")
    reader=kit/"lease-visit-focus"; sign=static_part(reader,"net.example.nearpane.lease-visit-focus")
    values=dict(pid=focus["pid"],birth=focus["birth"],number=focus["number"],topology=focus["topology"],hid=focus["hid"],
                boot=boot,signer=focus.get("signingCDHash"),host=dict(pid=stamp[0],birth=stamp[1]*1_000_000+stamp[2],cdhash=old["cdhash"]))
    response=subprocess.run([reader,"--inspect-closed"],input=json.dumps(values),capture_output=True,text=True,timeout=12,check=True)
    facts=json.loads(response.stdout)
    require(facts.get("scope")=="readOnlyClosedTransaction" and facts.get("issued") is False and facts.get("retainedOriginalAX") is False,
            "The observer did not attest the read-only closed-transaction mode")
    return dict(schema=1,utc=datetime.now(timezone.utc).isoformat(),transaction=tid,receiptSHA256=hashlib.sha256(raw).hexdigest(),
                observerCDHash=sign["CDHash"],previouslyRetainedReferenceReleased=True,historicalInitialSignerRecorded=bool(focus.get("signingCDHash")),
                historicalInputsByTrial=0 if r["trials"].get("P0-diagnostic",{}).get("scope")=="SETUP_ONLY" else None,
                diagnosis=facts,status="BLOCKED",normalActivationIssued=False)


if __name__=="__main__":
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("kit",type=Path);ap.add_argument("installation_receipt",type=Path);ap.add_argument("--output",type=Path,required=True)
    args=ap.parse_args();os.umask(0o077)
    report=inspect(args.kit,args.installation_receipt.resolve(strict=True))
    write_owned(args.output,report);print(json.dumps(report,indent=2))
