"""One production card drop between two independently signed application processes on the enrolled Space."""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import uuid

from acceptance import wait_state
from installed_profile import APP, PROFILE, owns_profile, validate_home
from pair_pointer import close, halves, host_route, post_frames, rect, reservation, work_rect
from p2_documents import require, static_part, TrialStop

TOOLS = {"cross-pointer": "net.example.nearpane.p2-cross-pointer",
         "process-generation": "net.example.nearpane.p2-cross-process",
         **{f"Five Notes {i}.app": f"net.example.nearpane-five-preview.{i}" for i in (1, 2)}}
ERRORS = (ValueError, KeyError, TypeError, OSError, RuntimeError, subprocess.SubprocessError)


STOP_ERRORS = (KeyboardInterrupt,) + ERRORS


def host_profile_json(profile, relative, limit, evidence):
    """Read one Host-created file inside its 0700 profile, via pinned directory FDs."""
    path = Path(relative)
    parts = path.parts
    label = "profileIndex" if parts == ("profile-index.json",) else "configuration"
    valid = label == "profileIndex" or (
        len(parts) == 4 and parts[0] == "generations" and parts[2:] == ("Nearpane", "host-configuration.json")
        and str(uuid.UUID(parts[1])) == parts[1]
    )
    require(valid, "unsupportedHostProfileDocument")
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    require(profile == profile.resolve(strict=True), "symbolicHostProfileRoot")
    directory = os.open(profile, directory_flags)
    try:
        root = os.fstat(directory)
        require(root.st_uid == os.getuid() and stat.S_IMODE(root.st_mode) == 0o700, "hostProfileRootNotPrivate")
        for part in parts[:-1]:
            child = os.open(part, directory_flags, dir_fd=directory)
            os.close(directory)
            directory = child
            info = os.fstat(directory)
            require(info.st_uid == os.getuid() and not stat.S_IMODE(info.st_mode) & 0o022,
                    "unsafeHostProfileSubdirectory")
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
        with os.fdopen(os.open(parts[-1], flags, dir_fd=directory), "rb") as stream:
            info = os.fstat(stream.fileno())
            mode = stat.S_IMODE(info.st_mode)
            row = dict(document=label, permissions=f"{mode:04o}", uid=info.st_uid, bytes=info.st_size,
                       links=info.st_nlink, rootPermissions="0700", limit=limit)
            evidence.append(row)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                    and mode & ~0o644 == 0 and mode & 0o400 and 0 < info.st_size <= limit,
                    "unsafeHostProfileDocument:"+label)
            raw = stream.read(limit+1)
            after = os.fstat(stream.fileno())
            attrs = ("st_dev","st_ino","st_uid","st_nlink","st_mode","st_size","st_ctime_ns","st_mtime_ns")
            named = os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)
            require(len(raw) == info.st_size and all(getattr(info,k)==getattr(after,k)==getattr(named,k) for k in attrs),
                    "hostProfileDocumentChanged:"+label)
            row["sha256"] = hashlib.sha256(raw).hexdigest()
            return json.loads(raw)
    finally:
        os.close(directory)


def signed_kit(kit):
    require(kit == kit.resolve(strict=True) and kit.parent == Path("/private/tmp") and kit.name.startswith("nearpane-d01.")
            and kit.stat().st_uid == os.getuid() and kit.stat().st_mode & 0o777 == 0o700, "unqualifiedCrossApplicationKit")
    signatures = {name: static_part(kit/name, ident)["CDHash"] for name, ident in TOOLS.items()}
    require(len(set(signatures.values())) == len(TOOLS), "distinctSignedBinariesRequired")
    return signatures


def kernel(kit, pid):
    return json.loads(subprocess.check_output([kit/"process-generation", str(pid)], timeout=3))


def cleared(item, observation):
    return observation.get("pid") == item.get("pid") and (
        observation.get("absent") is True or (type(observation.get("birth")) is int
                                             and observation["birth"] > 0 and observation["birth"] != item.get("birth")))


def save(out, report):
    scratch = out/"result.next"
    scratch.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False)+"\n")
    scratch.replace(out/"result.json")


def retire(kit, launched):
    # The private marker is consumed only by the one invocation that received this random directory.
    for item in launched:
        (item["folder"]/"close").touch(exist_ok=True)
    deadline = time.monotonic()+10
    reads = []
    for item in launched:
        row = {"slot":item["slot"], "pid":item.get("pid"), "birth":item.get("birth"), "generationGone":False,
               "launcherExited":False}
        try:
            if "pid" not in item:
                start = wait_state(item["folder"]/"startup.json", lambda x: x.get("session") == item["folder"].name and
                                   x.get("bundle") == item["identifier"] and x.get("pid",0)>1 and x.get("birth",0)>0,
                                   min(deadline,time.monotonic()+2))
                if start:
                    item.update(pid=start["pid"],birth=start["birth"])
                    row.update(pid=item["pid"],birth=item["birth"])
            while "pid" in item:
                observation = kernel(kit,item["pid"])
                row["generationGone"] = cleared(item,observation)
                if row["generationGone"] or time.monotonic() >= deadline:
                    break
                time.sleep(.12)
            item["launcher"].wait(timeout=max(.1,deadline-time.monotonic()))
        except ERRORS:
            pass
        row["launcherExit"] = item["launcher"].poll()
        row["launcherExited"] = row["launcherExit"] is not None
        reads.append(row)
    return {"status":"PASS" if all(r["generationGone"] and r["launcherExited"] for r in reads) else "UNKNOWN","fixtures":reads}


def right_evidence(dispatch, post, expected, owners, anchor):
    # A released mouse packet and pictures from five-Space tests are insufficient: bind the
    # original Host, both actual event endpoints and each owner's two repeated physical frames.
    numbers = [owner["number"] for owner in owners]
    if len(owners)!=2 or [o["slot"] for o in owners]!=[0,1] or any(len({o[k] for o in owners})!=2 for k in ("pid","number","identifier","hash")):
        return False
    if any(o["identifier"]!=TOOLS[f"Five Notes {o['slot']+1}.app"] or o["birth"]<=0 for o in owners):
        return False
    if anchor.get("owners")!=owners or (dispatch.get("geometry") or {}).get("owners")!=owners:
        return False
    if dispatch.get("status") != "DISPATCHED" or dispatch.get("issued") is not True:
        return False
    route = host_route(dispatch)
    if route.get("status") != "HOST_PANEL" or route.get("dragMotion") != "MATCHED" or route.get("timestampPreserved") != [True,True]:
        return False
    if len(post)!=2 or not post[0]["clock"]<post[1]["clock"]:
        return False
    if len(anchor.get("cards", [])) != 2:
        return False
    points = [dispatch["events"][0]["point"], dispatch["events"][-1]["point"]]
    for index, (point, box) in enumerate(zip(points, anchor["cards"])):
        x,y,w,h = rect(box)
        lower = x+w/2 if index else x
        if not (lower <= point[0] < x+w and y <= point[1] < y+h):
            return False
    return all(sample.get("owners")==owners and sample.get("leaseState")=="BOUND" and sample.get("displayUUID")==anchor["displayUUID"] and
               sample.get("members")==numbers and close(rect(sample["visible"]),rect(anchor["visible"])) and
               post_frames(sample,expected) for sample in post)


def run(kit, out, ws, space, space_uuid, expected_source):
    os.umask(0o077)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    result={"scope":"one explicit right drop on two Developer ID AppKit fixture cards","status":"BLOCKED",
            "operationStatus":"NOT_RUN","issued":False,"attempts":0,"initial":[],"preflights":[],"post":[],"savedPixels":0,"hostProfileFiles":[],
            "cleanup":{"status":"NOT_RUN"}}
    save(out,result)
    launched=[]; temp=None
    def interrupt(signum, frame):
        raise KeyboardInterrupt("terminatedDuringCrossApplicationTrial")
    termination = signal.signal(signal.SIGTERM, interrupt)
    try:
        signatures=signed_kit(kit)
        home=Path(os.environ["NEARPANE_TEST_HOME"]);generation=Path(os.environ["NEARPANE_TEST_GENERATION"])
        require(home.is_dir(), "isolatedHomeUnavailable")
        validate_home(home)
        profile=home/PROFILE
        def active_generation():
            return (owns_profile(ws.host["pid"],profile) and generation==generation.resolve(strict=True)
                    and generation.parent==profile/"generations" and str(uuid.UUID(generation.name))==generation.name
                    and host_profile_json(profile,"profile-index.json",16_384,result["hostProfileFiles"])["active"]==generation.name)
        require(active_generation(),
                "canonicalHostDoesNotOwnThisIsolatedGeneration")
        info=plistlib.loads((APP/"Contents/Info.plist").read_bytes())
        require(info.get("NearpaneSourceState")=="clean" and expected_source==info.get("NearpaneSourceRevision") and
                info.get("CFBundleVersion")=="90" and len(expected_source)==40, "installedCandidateSourceMismatch")
        initial=ws.read()
        require(space in ws.ids() and ws.check(initial)["current"]==space and initial["host"]["pid"]==ws.host["pid"] and
                initial["host"]["codeHash"]==ws.host["codeHash"] and ws.hardware()==ws.hid,"enrolledDesktopOrHostChanged")
        original=initial["frontmostPID"]; birth=kernel(kit,original).get("birth")
        require(type(birth) is int and birth>0,"initialForegroundGenerationUnknown")
        run={"hostPID":ws.host["pid"],"hostBirth":ws.host_birth,"hostHash":ws.host["codeHash"],"space":space,
             "spaceUUID":space_uuid,"display":ws.display,"owners":[]}
        request={"run":run,"originalFront":original,"originalFrontBirth":birth}
        result.update(source=expected_source,signatures=signatures,run=run)

        def witness(op="read", extra=None):
            payload={**request,**(extra or {}),"operation":op}
            process=subprocess.run([kit/"cross-pointer","compare-roster"],input=json.dumps(payload),capture_output=True,
                                   text=True,timeout=13 if op=="right" else 4)
            require(process.returncode==0,"signedWitnessExited","UNKNOWN")
            return json.loads(process.stdout)

        def read(need_cards=False, seconds=4):
            until=time.monotonic()+seconds
            while True:
                proof=witness()
                result["preflights"].append({"at":time.monotonic(),"status":proof.get("status"),"reason":proof.get("reason"),
                                              "enrolled":len(run["owners"]),"visibleCards":len(proof.get("geometry",{}).get("cards",[]))})
                if proof.get("status")=="READ":
                    if not need_cards or (proof.get("geometry",{}).get("panelID") and len(proof["geometry"].get("cards",[]))==2):
                        return proof
                if proof.get("reason") in ("hardwareChanged","foregroundLeftEnrollment") or time.monotonic()>=until:
                    raise TrialStop(proof.get("reason") or "registeredProductionCardsUnconfirmed")
                time.sleep(.12)

        before=read()
        hardware=before["hardware"]
        require(len(hardware)==13 and hardware[:5]==ws.hid and before["geometry"]["members"]==[], "emptyLeaseOrInputNotEstablished")
        request["hardware"]=hardware
        temp=Path(tempfile.mkdtemp(prefix="nearpane-five.",dir="/private/tmp")).resolve()
        (temp/"home").mkdir(mode=0o700)
        for slot in (0,1):
            prep=read()
            result["initial"].append(prep)
            require(len(prep["geometry"]["members"])==slot and prep["hardware"]==hardware and ws.hardware()==ws.hid
                    and owns_profile(run["hostPID"],profile), "leaseChangedBeforeFixtureLaunch")
            name=f"Five Notes {slot+1}.app"; ident=TOOLS[name]
            folder=temp/str(uuid.uuid4());folder.mkdir(mode=0o700)
            (folder/"launch.json").write_text(json.dumps(dict(session=folder.name,originalFront=prep["foregroundPID"],
                                                             hardware=hardware,admittedAt=prep["geometry"]["clock"])))
            open_args=["/usr/bin/open","-g","-n","-W","-a",str(kit/name),"--env",f"HOME={temp/'home'}","--env",
                       f"CFFIXED_USER_HOME={temp/'home'}","--env","NP_FIXTURE_PRESENTATION=five-preview","--args",str(folder),"1"]
            proc=subprocess.Popen(open_args,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            item={"folder":folder,"launcher":proc,"slot":slot,"identifier":ident};launched.append(item)
            startup=wait_state(folder/"startup.json",lambda s:s.get("session")==folder.name and s.get("bundle")==ident and
                               s.get("policy")==0 and s.get("displayCount")==1 and s.get("pid",0)>1 and s.get("birth",0)>0,time.monotonic()+5)
            require(startup,"privateFixtureStartupUnavailable")
            item.update(pid=startup["pid"],birth=startup["birth"])
            state=wait_state(folder/"windows.json",lambda s:s.get("session")==folder.name and s.get("pid")==item["pid"] and
                             s.get("birth")==item["birth"] and s.get("bundle")==ident and s.get("slot")==slot and
                             s.get("presentation")=="five-preview" and s.get("visible")==[True] and s.get("minimized")==[False] and
                             len(s.get("numbers",[]))==1 and s["numbers"][0]>0,time.monotonic()+6)
            require(state,"privateFixtureWindowNotConfirmed")
            run["owners"].append(dict(pid=item["pid"],birth=item["birth"],number=state["numbers"][0],slot=slot,identifier=ident,hash=signatures[name]))
            save(out,result)
        baseline=read(True)["geometry"];time.sleep(.18)
        confirm=read(True)["geometry"];numbers=[o["number"] for o in run["owners"]]
        require(baseline["members"]==confirm["members"]==numbers and len(set(numbers))==2 and len({o["pid"] for o in run["owners"]})==2 and
                baseline["panelID"]==confirm["panelID"] and baseline["cg"]==confirm["cg"] and baseline["ax"]==confirm["ax"] and
                baseline["clock"]<confirm["clock"],"twoIndependentEnrolledInitialSamplesRequired")
        require(active_generation(), "isolatedGenerationChangedBeforeDrop")
        cfg=host_profile_json(profile, generation.relative_to(profile)/"Nearpane/host-configuration.json",
                              128*1024, result["hostProfileFiles"])
        area=work_rect(confirm,reservation(cfg,run["display"]))
        expected=halves(area)[::-1]
        require(all(not close(rect(old),rect(want)) for old,want in zip(confirm["cg"],expected)), "bothWindowsMustHaveDistinguishableInitialGeometry")
        result.update(initialGeometry=[baseline,confirm],workRect=area,expected=expected,attempts=1,operationStatus="UNKNOWN",issued=None)
        save(out,result)
        # No action retry, even after an unknown transport outcome.
        try:
            posted=witness("right",dict(initialFrames=confirm["cg"],originalPanel=confirm["panelID"],deadline=confirm["clock"]+8))
        except ERRORS as e:
            posted={"status":"UNKNOWN","issued":None,"reason":type(e).__name__}
        result.update(dispatch=posted,issued=posted.get("issued"),routing=host_route(posted))
        save(out,result)
        recent=[]; mismatches=[]
        until=time.monotonic()+7
        while True:
            observed=witness(); result["post"].append(observed)
            if observed.get("reason") in ("hardwareChanged","foregroundLeftEnrollment"):
                break
            frame=observed.get("geometry",{})
            if observed.get("status")=="READ" and frame.get("members")==numbers:
                if post_frames(frame,expected):
                    recent=(recent+[frame])[-2:]; mismatches=[]
                    if right_evidence(posted,recent,expected,run["owners"],confirm):
                        result.update(status="PASS",operationStatus="PASS",reason="oneHostRoutedDropTwoIndependentOwnerFrames");break
                else:
                    recent=[];mismatches=(mismatches+[frame])[-2:]
            else:
                recent=[];mismatches=[]
            if time.monotonic()>=until:break
            time.sleep(.14)
        if result["operationStatus"]!="PASS":
            if posted.get("issued") is False:
                status="BLOCKED";reason=posted.get("reason","unissued")
            elif result["routing"].get("status")=="HOST_PANEL" and len(mismatches)==2 and (
                    mismatches[0]["cg"]==mismatches[1]["cg"] and mismatches[0]["ax"]==mismatches[1]["ax"]):
                status="FAIL";reason="differentStableTwoOwnerGeometry"
            else:status="UNKNOWN";reason=observed.get("reason","twoAffirmativePlacementReadsUnavailable")
            result.update(status=status,operationStatus=status,reason=reason)
    except STOP_ERRORS as e:
        result["reason"]=getattr(e,"reason",str(e))[:240]
        result["status"]="UNKNOWN" if result["attempts"] else "BLOCKED"
    finally:
        if launched:
            try:result["cleanup"]=retire(kit,launched)
            except ERRORS as e:result["cleanup"]={"status":"UNKNOWN","reason":type(e).__name__}
        else:result["cleanup"]={"status":"NOT_NEEDED"}
        if result["cleanup"]["status"]=="UNKNOWN":result["status"]="BLOCKED"
        elif temp is not None:
            try:
                shutil.rmtree(temp)
            except OSError:
                result["cleanup"]["dataDirectoryRemoved"]=False
                result["status"]="BLOCKED"
        save(out,result)
        signal.signal(signal.SIGTERM, termination)
    return result
