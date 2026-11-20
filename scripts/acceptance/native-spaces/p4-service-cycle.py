#!/usr/bin/env python3
"""Issue one Services request from a signed synthetic selection and verify its durable word after a normal isolated Host relaunch."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

from acceptance import identity
from installed_profile import APP,HOST,PROFILE,installed_pid,owns_profile,quit_host,launch_isolated

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/"scripts"))
from candidate_signing import gate


def checkpoint(tool,args):
    out=args[1]
    p=subprocess.run([tool,*args],capture_output=True,timeout=75)
    record=json.loads((out/"result.json").read_bytes())
    return dict(exit=p.returncode,status=record["status"],result=str(out.name)+"/result.json"),record


def run(kit,out,revision):
    os.umask(0o077);out.mkdir(parents=True,mode=0o700,exist_ok=False)
    receipt=dict(status="BLOCKED",requestCount=0,restart="NOT_RUN",wordAfterRestart="NOT_RUN")
    def save():
        tmp=out/"case.next"
        tmp.write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+"\n");os.replace(tmp,out/"result.json")
    save()
    try:
        info=plistlib.loads((APP/"Contents/Info.plist").read_bytes())
        gate.verify_install_identity(APP)
        if info.get("NearpaneSourceRevision")!=revision or info.get("CFBundleVersion")!="90":
            raise ValueError("Unexpected installed candidate or build")
        receipt["installed"]=dict(source=revision,cdhash=identity(APP)["CDHash"],build=info["CFBundleVersion"])
        if b"nearpane-translation-content-" not in HOST.read_bytes():
            raise ValueError("Installed candidate predates request-bound panel evidence; original installed trials are retained separately")
        tool=kit/"tool-selection"
        for path in (tool,kit/"Nearpane Tool Fixture.app"):
            subprocess.run(["codesign","--verify","--strict",path],check=True,capture_output=True,timeout=8)
        home=Path(os.environ["NEARPANE_TEST_HOME"]); generation=Path(os.environ["NEARPANE_TEST_GENERATION"])
        pid=installed_pid()
        if not pid or not owns_profile(pid,home/PROFILE): raise ValueError("Installed Host must hold an isolated profile")
        receipt["registration"],route=checkpoint(tool,["service-route",out/"registration"])
        if route["status"]!="READY": raise ValueError(route.get("reason","Service registration unavailable"))
        summary,translation=checkpoint(tool,["translate",out/"translation"])
        receipt.update(translation=summary,requestCount=int(translation.get("serviceDispatched") is True),
                       handoff=translation.get("serviceRequestHandoff","UNKNOWN"),
                       nonactivatingPanel=translation.get("visibleNonactivatingBubble","UNKNOWN"))
        save()
        if translation["status"]!="PASS":
            receipt.update(status=translation["status"],reason=translation.get("reason","Service arrival or word not confirmed"))
            return
        if installed_pid()!=pid or not owns_profile(pid,home/PROFILE): raise ValueError("Original isolated Host lost ownership before relaunch")
        quit_host(pid)
        fresh,active=launch_isolated(home)
        if active!=generation or not owns_profile(fresh,home/PROFILE): raise ValueError("Relaunch did not own original generation")
        receipt["restart"]="PASS";save()
        summary,word=checkpoint(tool,["wordbook",out/"reopen",out/"translation/result.json"])
        receipt.update(reopen=summary,wordAfterRestart=word["status"],status=word["status"])
    except (ValueError,OSError,KeyError,RuntimeError,subprocess.SubprocessError) as error:
        receipt["reason"]=str(error)[:200]
        if receipt["requestCount"]: receipt["status"]="UNKNOWN"
    finally:
        save()
    return receipt["status"]


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("kit",type=Path);p.add_argument("output",type=Path);p.add_argument("--expected-source",required=True)
    args=p.parse_args();run(args.kit.resolve(),args.output.resolve(),args.expected_source)
    raise SystemExit(0 if json.loads((args.output/"result.json").read_text())["status"]=="PASS" else 2)
