#!/usr/bin/env python3
"""Read sealed installed candidate, known disposable browser markers and optional Host-side TCC evidence. Never opens a browser."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import uuid

from acceptance import identity
from installed_profile import APP, HOST, PROFILE, installed_pid, owns_profile

ROOT=Path(__file__).resolve().parents[3]
PROBE="draft-qualification-read-only-v1"
REFERENCE="c886b3c1baad2e72099ace80ba5b718afe450699"
STATES=("granted","denied","notRequested","browserNotRunning","browserNotInstalled","unavailable","unverifiedBrowser","generationChanged")
sys.path.insert(0,str(ROOT/"scripts"))
from candidate_signing import gate


def markers(root, authorization):
    """Only per-session marker metadata is opened; browser user-data is never traversed."""
    count=0
    authorized=False
    if not root.is_dir() or root.is_symlink(): return dict(disposableMarkers=0,authorizedMarker=False)
    for folder in root.iterdir():
        try:
            if str(uuid.UUID(folder.name))!=folder.name or folder.is_symlink() or folder.resolve()!=folder: continue
            bundle=folder/"chrome-profile"
            stamp=bundle/"fixture.json"
            session=folder/"session.json"
            if any(x.is_symlink() for x in (bundle,stamp,session)) or not stamp.is_file(): continue
            for directory in (folder,bundle):
                info=directory.stat()
                if info.st_uid!=os.getuid() or info.st_mode & 0o077 or not stat.S_ISDIR(info.st_mode): raise ValueError()
            if stamp.stat().st_size>4096 or session.stat().st_size>16384: continue
            if json.loads(session.read_bytes()).get("session")!=folder.name.upper(): continue
            marker=json.loads(stamp.read_bytes())
            if marker!={"version":1,"session":folder.name,"purpose":"isolated-native-draft"}: continue
            count+=1
            authorized |= authorization == folder.name
        except (OSError,ValueError,TypeError): continue
    return dict(disposableMarkers=count,authorizedMarker=authorized)


def archived(name):
    path="engineering/verification/native-spaces/5.22-p3/"+name+".json"
    row=subprocess.run(["git","-C",ROOT,"show",REFERENCE+":"+path],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=8)
    if row.returncode: return dict(status="UNAVAILABLE",revision=REFERENCE)
    data=json.loads(row.stdout)
    return dict(status=data["result"],revision=REFERENCE,sha256=hashlib.sha256(row.stdout).hexdigest(),cases=data.get("outcomes"),
                coldStarts=data.get("coldRestartOutcomes"),liveAuthentication=data.get("liveAuthenticatedAcceptance"),
                liveUpload=data.get("liveUploadCompleted"),ordinaryRouteEnabled=data.get("ordinaryProductionEnabledForQualification"))


def host_result(metrics, static):
    if not static["readOnlyProbePackaged"]: return dict(status="BLOCKED",state=None,reason="installed Host has no separate nonprompting grant-only diagnostic")
    if not metrics: return dict(status="NOT_RUN",state=None,reason="explicit isolated Host sampling not selected")
    raw_home=os.getenv("NEARPANE_TEST_HOME")
    pid=installed_pid()
    if not raw_home or not pid or not owns_profile(pid,Path(raw_home)/PROFILE): return dict(status="BLOCKED",state=None,reason="signed installed Host must own the disposable profile")
    subprocess.run(["/usr/bin/codesign","--verify","--strict",metrics],check=True,timeout=5)
    nonce=str(uuid.UUID(subprocess.check_output([metrics,str(pid),"--draft-qualification"],text=True,timeout=7).strip())).upper()
    prefix="Draft qualification "+nonce+" chrome="
    predicate=f'processID == {pid} AND subsystem == "com.holdsnow.nearpane.alpha" AND category == "PermissionCheck" AND eventMessage BEGINSWITH "{prefix}"'
    logs=subprocess.check_output(["/usr/bin/log","show","--style","compact","--last","30s","--predicate",predicate],text=True,timeout=12)
    found=re.findall(re.escape(prefix)+r"([A-Za-z]+)\b",logs)
    if len(found)!=1 or found[0] not in STATES or installed_pid()!=pid or not owns_profile(pid,Path(raw_home)/PROFILE):
        return dict(status="UNKNOWN",state=None,reason="nonce-bound Host log or isolated generation unavailable")
    return dict(status="PASS" if found[0]=="granted" else "BLOCKED",state=found[0],pid=pid,nonce=nonce,
                browser="signed Chrome",askUserIfNeeded=False,tabQueries=0,documentsRead=0)


def run(args):
    out=dict(schema=1,checkedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),scope="read-only installed qualification",
             remoteUpload={"status":"NOT_RUN","completed":None},actions={"browserLaunches":0,"pageReads":0,"fileWritesToDraft":0,"sends":0,"submits":0,"enters":0})
    try:
        app=APP
        subprocess.run(["/usr/bin/codesign","--verify","--strict","--deep",app],check=True,timeout=18,capture_output=True)
        gate.verify_install_identity(app)
        info=plistlib.loads((app/"Contents/Info.plist").read_bytes())
        raw=(app/"Contents/Resources/Upstream/riftlet/source.json").read_bytes()
        actual=json.loads(raw)
        pin=json.loads((ROOT/"Dependencies/domains.lock.json").read_bytes())["domains"]["riftlet"]
        revision=info.get("NearpaneSourceRevision")
        if revision!=args.expected_source or info.get("CFBundleVersion")!="90": raise ValueError("unexpected installed source or build")
        guard=app/"Contents/Resources/AcceptanceTargetGuard.js"
        expected_guard=subprocess.check_output(["git","-C",ROOT,"show",revision+":Resources/AcceptanceTargetGuard.js"],timeout=6)
        static=dict(cdhash=identity(app)["CDHash"],source=revision,build=info.get("CFBundleVersion"),bundle=info.get("CFBundleIdentifier"),
                    developerIdentityVerified=True,usageStringDeclared=bool(info.get("NSAppleEventsUsageDescription")),
                    readOnlyProbePackaged=PROBE.encode() in HOST.read_bytes(),riftletPin=actual.get("commit"),
                    riftletTree=actual.get("treeSHA256"),pinnedSourceMatches=all(actual.get(k)==pin.get(k) for k in ("commit","treeSHA256")),
                    packagedGuardMatchesCandidate=guard.read_bytes()==expected_guard,
                    guardSHA256=hashlib.sha256(expected_guard).hexdigest())
        out["installed"]=static
        if not (static["pinnedSourceMatches"] and static["usageStringDeclared"] and static["packagedGuardMatchesCandidate"]): raise ValueError("installed provider or draft guard does not match candidate")
        m=markers(args.sessions.resolve(),args.authorized_session)
        out["profile"]={**m,"authorizationSupplied":bool(args.authorized_session),"accountRead":False,"authenticated":"UNKNOWN",
                        "status":"UNKNOWN_AUTHENTICATION" if m["authorizedMarker"] else "BLOCKED_NO_EXPLICIT_AUTHORIZED_ISOLATED_AUTHENTICATED_PROFILE"}
        out["fixtureReference"]={k:archived(k) for k in ("qualification","cold-restart")}
        out["tcc"]=host_result(args.metrics,static)
        out["liveBrowserScope"]="Chrome/ChatGPT production capability only; Edge and other services isolated-fixture only; Safari writing disabled"
        out["remoteUpload"]["status"]="BLOCKED_NO_AUTHORIZED_AUTHENTICATED_PROFILE" if not m["authorizedMarker"] else "NOT_RUN_AUTHENTICATION_UNCONFIRMED"
        out["status"]="BLOCKED"
    except (ValueError,OSError,subprocess.SubprocessError,KeyError) as error:
        out["status"]="UNKNOWN"; out["failure"]=type(error).__name__+": "+str(error)[:160]
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open("x") as f: json.dump(out,f,ensure_ascii=False,indent=2);f.write("\n")
    return 1 if out["status"]=="UNKNOWN" else 0


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output",required=True,type=Path)
    parser.add_argument("--expected-source",required=True)
    parser.add_argument("--sessions",type=Path,default=ROOT/"build/native-acceptance")
    parser.add_argument("--authorized-session",help="optional session UUID explicitly authorized for this run; never inferred from profile files")
    parser.add_argument("--metrics",type=Path,help="request a nonprompting diagnostic from the existing signed Host holding its isolated profile")
    opts=parser.parse_args()
    raise SystemExit(run(opts))
