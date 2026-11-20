"""Observe a single real card press with display-based fixture video and an optional isolated physical crop.

The installed P0 runner calls enroll during both initial round-trip starts, then start and finish
for each ten-stage press. No screen capture is requested when permission is absent. All control
paths are under a private attempt directory; the native Recorder owns a 25-second maximum.
"""
import argparse
import collections
import hashlib
import importlib
import json
import math
import os
from pathlib import Path
import stat
import sys
import subprocess
import tempfile
import time
import uuid


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CHILDREN = {}
ERRORS = (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError)
POLICY = "Observed absence of a user-visible whole-display blackout during this interval; changes below measured sampling resolution are outside the evidence."
SOURCES = ["https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:including:)",
           "https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/displaytime"]


def require(ok, message):
    if not ok:
        raise ValueError(message)


def write(path, value):
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as temp:
        json.dump(value, temp, ensure_ascii=False, sort_keys=True, indent=2)
        temp.write("\n")
        temp.flush()
        os.fsync(temp.fileno())
    os.replace(temp.name, path)


def private(path, directory=False):
    path = Path(path).absolute()
    bits = path.lstat()
    require(path == path.resolve() and bits.st_uid == os.getuid(), "noncanonical or unowned path")
    require((stat.S_ISDIR(bits.st_mode) if directory else stat.S_ISREG(bits.st_mode) and bits.st_nlink == 1)
            and bits.st_mode & 0o022 == 0, "uncontrolled path")
    return path


def read(path):
    with private(path).open("rb") as f:
        data = f.read(6_000_001)
        require(len(data) <= 6_000_000, "oversize device receipt")
        return json.loads(data)


def kit_paths(kit):
    kit = private(kit, directory=True)
    require(kit.parent == Path("/private/tmp") and kit.name.startswith("nearpane-d01."), "fixture kit path mismatch")
    return kit, private(kit / "p0-card")


def binary(kit):
    source = HERE / "p0-visual.swift"
    header = HERE / "contract_members.h"
    objects = [private(kit / name) for name in ("reader.o", "members.o")]
    h = hashlib.sha256()
    for path in [source, header, *objects]:
        h.update(path.read_bytes())
    exe = kit / ("p0-visual-" + h.hexdigest()[:20])
    if not exe.exists():
        with tempfile.TemporaryDirectory(dir=kit) as tmp:
            fresh = Path(tmp)/"recorder"
            result = subprocess.run(["/usr/bin/xcrun","swiftc","-O","-parse-as-library","-Xcc","-I","-Xcc",
                str(ROOT/"Sources/CReadOnlySpaces/include"), "-import-objc-header",str(header),str(source),
                *map(str, objects),"-framework","ColorSync","-o",str(fresh)], capture_output=True, timeout=85)
            require(result.returncode == 0, "native display observer did not compile")
            fresh.chmod(0o700)
            fresh.replace(exe)
    return private(exe)


def ask(reader, mode, args=None, body=None):
    answer = subprocess.run([str(reader), mode, *map(str, args or [])],
                            input=json.dumps(body) if body is not None else None, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=4)
    require(answer.returncode == 0, "independent P0 reader refused " + mode)
    return json.loads(answer.stdout)


def witness(kit, p, at, window_witness=None):
    _, reader = kit_paths(kit)
    topology = p["topology"]
    ids = [s["id"] for s in topology["records"]]
    require(topology["current"] != p["target"] and abs(ids.index(topology["current"]) - ids.index(p["target"])) == 1,
            "endpoints are not adjacent")
    uuid.UUID(topology["display"])
    windows = [p["sourceWindow"], p["targetWindow"]]
    known = {"org.nearpane.acceptance.LifecycleWindow": ("Lifecycle Window.app", "Lifecycle"),
             "net.example.spaces-route-witness": ("Route Notes.app", "FieldNotes"),
             "net.example.spaces-document": ("Field Notes.app", "FieldNotes")}
    require(windows[0]["number"] != windows[1]["number"], "duplicate fixture window number")
    for w in windows:
        app, file = known[w["identifier"]]
        require(w["executable"] == str(kit/app/"Contents/MacOS"/file), "fixture executable is outside this kit")
    # The keeper pins the actual foreground AX objects across Spaces. Standalone
    # invocation has no such reference and must use the one-shot conservative read.
    answer = window_witness(windows) if window_witness is not None else ask(reader, "windows", body=windows)
    lived = answer["windows"]
    require(len(lived) == 2, "exact pair was not verified")
    records = []
    for w, proof, sid in zip(windows, lived, [topology["current"], p["target"]]):
        require(all(proof.get(k) == w[k] for k in ("pid", "birth", "number"))
                and proof["forward"] is True and proof["standard"] is True and proof["reverse"] == [sid],
                "fixture generation, exact AX window, or two-way Space membership changed")
        records.append({k: w[k] for k in ("pid", "birth", "number", "identifier", "hash")})
    state = ask(reader, "state")
    require(state["topology"] == dict(topology, current=at) and state["hid"] == p["hid"],
            "physical display, Space UUID order, current ID or real input changed")
    return {"current": at, "uptime": state["uptime"], "display": topology["display"], "windows": records}


def pair_id(p):
    windows = [(sid, w["pid"], w["birth"], w["number"], w["identifier"], w["hash"])
               for sid, w in [(p["topology"]["current"], p["sourceWindow"]), (p["target"], p["targetWindow"])]]
    data = {"display": p["topology"]["display"], "records": p["topology"]["records"], "windows": sorted(windows)}
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


def binding(kit, p, folder, guardian, endpoints=None):
    born = ask(kit/"p0-card", "process", [guardian])["birth"]
    b = dict(nonce=str(uuid.uuid4()).upper(), guardian=guardian, guardianBirth=born, request=p, endpoints=endpoints)
    write(folder/"binding.json", b)
    return b


def enrollment_admission(folder, attempt, request, nonce):
    source=folder/"admission.json"
    if not source.is_file():return {}
    data=read(source)
    require(data.get("nonce")==nonce and data.get("sourceSpace")==request["topology"]["current"] and
            data.get("targetSpace")==request["target"],"endpoint admission belongs to a different attempt")
    write(attempt/"visual-calibration.json",data)
    return data


def enroll(kit, attempt, request, *, window_witness=None):
    diagnostic={}
    try:
        kit,_=kit_paths(kit)
        attempt=private(attempt,directory=True)
        pre=witness(kit,request,request["topology"]["current"],window_witness)
        root=attempt.parent/".p0-visual-endpoints"
        root.mkdir(mode=0o700,exist_ok=True)
        private(root,directory=True)
        with tempfile.TemporaryDirectory(dir=root) as tmp:
            folder=Path(tmp)
            b=binding(kit,request,folder,os.getpid())
            try:
                result=subprocess.run([str(binary(kit)),str(folder),"enroll"],stdin=subprocess.DEVNULL,
                                      stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
            finally:
                diagnostic=enrollment_admission(folder,attempt,request,b["nonce"])
            if result.returncode:
                raise ValueError((read(folder/"error.json") if (folder/"error.json").exists() else {}).get("error","endpoint calibration unavailable"))
            require(diagnostic.get("actualDisplayMatchesOwnedReference") is True,"actual display and identified fixture reference were not corroborated")
            witness(kit,request,pre["current"],window_witness)
            observed=read(folder/"endpoint.json")
            require(observed["space"]==pre["current"] and observed["display"].upper()==pre["display"].upper(),"unexpected enrollment identity")
            name=f'{pair_id(request)}-{pre["current"]}.json'
            observed["actualDisplayMatchesOwnedReference"]=True
            write(root/name,observed)
            return {"status":"READY","display":pre["display"],"space":pre["current"],"nonce":b["nonce"],"admission":diagnostic}
    except ERRORS as error:
        return {"status":"UNKNOWN","reason":str(error),"admission":diagnostic}


def unknown(reason):
    return dict(status="UNKNOWN", ready=False, reason=reason, scope=POLICY, screenshotTaken=False, sources=SOURCES)


def start(kit, attempt, request, guardian=None, *, window_witness=None):
    folder = None
    try:
        kit, _ = kit_paths(kit)
        attempt = private(attempt, directory=True)
        path = attempt/"visual"
        path.mkdir(mode=0o700)
        folder = path
        pre = witness(kit, request, request["topology"]["current"], window_witness)
        write(folder/"before.json", pre)
        endpoints = {}
        for sid in [pre["current"], request["target"]]:
            f = attempt.parent/".p0-visual-endpoints"/f'{pair_id(request)}-{sid}.json'
            if f.is_file():
                endpoints[str(sid)] = read(f)
        missing=[sid for sid in [pre["current"],request["target"]] if
                 endpoints.get(str(sid),{}).get("actualDisplayMatchesOwnedReference") is not True]
        if missing:
            failures=[]
            for file in sorted(attempt.parent.glob("roundTrip-*/visual-enrollment.json")):
                entry=read(file);details=entry.get("admission") or {}
                if details.get("sourceSpace") in missing:failures.append({"space":details["sourceSpace"],"reason":entry.get("reason"),"failed":details.get("failed",[])})
            result=unknown("Missing corroborated physical endpoint calibration for Space "+", ".join(map(str,missing)))
            result.update(missingEndpointSpaces=missing,calibrationFailures=failures,physicalReady=False)
            write(folder/"admission.json",result);write(folder/"receipt.json",result);return result
        b = binding(kit, request, folder, guardian or os.getpid(), endpoints)
        proc = subprocess.Popen([str(binary(kit)), str(folder)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)
        CHILDREN[str(folder)] = proc
        limit = time.monotonic() + 8
        while time.monotonic() < limit and proc.poll() is None and not (folder/"ready.json").is_file():
            time.sleep(.025)
        if (folder/"ready.json").is_file():
            ready = read(folder/"ready.json")
            require(ready["nonce"] == b["nonce"] and ready["pid"] == proc.pid and ready["ready"], "recorder handshake mismatch")
            return dict(status="READY" if ready.get("physicalReady") is True else "FIXTURE_STREAM_ONLY", **ready)
        write(folder/"end.json", dict(nonce=b["nonce"], allowMovie=False, pressed=0.0, ended=0.0))
        detail = read(folder/"error.json").get("error") if (folder/"error.json").is_file() else "no genuine source frame before dispatch"
        raise ValueError(detail)
    except ERRORS as error:
        result = unknown(str(error))
        if folder is not None:
            write(folder/"receipt.json", result)
        return result


def stamp(row, key):
    value=row.get(key)
    return value if isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value) and value>0 else None


def tick_matches_time(row, base):
    ticks,numer,denom=row.get("presentationMachTicks"),base.get("numerator"),base.get("denominator")
    t=stamp(row,"displayTime")
    return bool(t and all(type(n) is int and n>0 for n in (ticks,numer,denom)) and
                abs(ticks*numer/denom/1e9-t)<=math.ulp(t))


def presentation_proof(genuine, index, source, target, hz, version):
    row=genuine[index]
    t,callback=stamp(row,"displayTime"),stamp(row,"callback")
    bound_blank=(version>=3 and row.get("status")==2 and row.get("blankDisplayBound") is True)
    if not t or not callback or row.get("space") not in (source,target) or (not bound_blank and
            (row.get("safe") is not True or row.get("visible") not in ("source","target","appleWallpaper"))):
        return False,row.get("blockedBy") or "unscopedNativePresentation",None
    if version>=3:
        reads=row.get("postPresentationSurfaces") or []
        if type(row.get("presentationMachTicks")) is not int or row["presentationMachTicks"]<=0 or len(reads)!=2:
            return False,"missingNativeTimeOrTwoPostPresentationReads",None
        a,b=reads
        times=[stamp(read,k) for read,k in [(a,"from"),(a,"to"),(b,"from"),(b,"to")]]
        if any(v is None for v in times) or times!=sorted(times) or times[0]<t or times[-1]-t>.050 or t-callback>1/hz:
            return False,"postPresentationReadsOutsideBound",None
        def confirms(read):
            if read.get("sameDisplayAndInput") is not True or read.get("space")!=row["space"]:return False
            if bound_blank:return True
            reason="verifiedSealedWallpaper" if row["visible"]=="appleWallpaper" else "exactOpaqueFixture"
            return read.get("visible")==row["visible"] and read.get("reason")==reason
        spanning=row.get("spanningSurface")
        if not all(confirms(read) for read in reads) or (spanning is not None and
                (not confirms(spanning) or not stamp(spanning,"from") or not stamp(spanning,"to") or not spanning["from"]<=t<=spanning["to"])):
            return False,"contradictoryForegroundOrSpaceAtPresentation",None
        return True,"twoRealPostPresentationSurfaceReads",(max(0,t-callback),times[-1]-t)
    through=stamp(row,"metadataThrough") if "metadataThrough" in row else callback
    if through is None or through<callback or through-t>.075 or t-callback>1/hz:
        return False,"nativePresentationAndSourceChecksNotTimeBound",None
    if through>=t:return True,"contemporaneousSourceRead",None
    for later in genuine[index+1:]:
        next_proof=stamp(later,"metadataThrough") if "metadataThrough" in later else stamp(later,"callback")
        arrival=stamp(later,"callback")
        if (next_proof is None or arrival is None or next_proof<arrival or next_proof-t>.050 or later.get("safe") is not True
                or later.get("space")!=row["space"] or later.get("visible")!=row["visible"] or later.get("status") not in (0,1,4)):
            break
        if arrival>=t:return True,"followingUnchangedNativeSurface",(t-callback,next_proof-t)
    return False,"earlyPresentationMissingFollowingSurfaceAndSpace",None


def score(data, request, pressed, ended, pre, post):
    result = unknown("The allowlisted fixture stream does not establish the visible desktop")
    result["captureFilter"] = "ScreenCaptureKit physical display, including only two exact fixture windows"
    result["wallpaperIncludedInMovie"] = False
    frames = data.get("frames", [])
    counts = collections.Counter(r.get("status", "unknown") for r in frames)
    result["allowlistedFrameCounts"] = dict(counts)
    result["filteredDarkFrames"] = sum(r.get("opaque", 0) >= 4 and r.get("dark") == r["opaque"] for r in frames)
    result["filteredEmptyFrames"] = sum(r.get("transparent", -1) == data.get("width", 0) * data.get("height", 0) for r in frames)
    result["movieSource"] = "real fixture pixels; excluded transparent areas matted gray"
    result["physicallyQualified"] = False
    checks = {"nativePresentationCoverage": "UNKNOWN", "continuousVisibleLight": "UNKNOWN",
              "streamingTargetMatched": False, "independentTerminalTargetMatched": None,
              "scopedNativeBlankEventsDuringPress": None}
    result["subchecks"] = checks
    probe=data.get("physical") or {}
    version=probe.get("presentationReviewVersion",1)
    genuine=[r for r in probe.get("frames",[]) if r.get("origin","sck-display")=="sck-display"]
    hz=data.get("displayModeHz",0) or data.get("refreshLimitHz",0)
    source,target=request["topology"]["current"],request["target"]
    valid_clock=isinstance(hz,(int,float)) and 24<=hz<=240
    valid_issue=math.isfinite(pressed) and math.isfinite(ended) and 0<pressed<ended
    # A positively scoped OS blank during a real press is a failure even if other frames or later terminal reads are missing.
    # Unknown, unscoped or foreign blank declarations remain explicit evidence without establishing a black physical display.
    if (valid_issue and pre and pre.get("current")==source and pre.get("uptime",math.inf)<=pressed and data.get("ready") and valid_clock
            and probe.get("armed") and probe.get("sourceFrameReadyBeforePress") is True and probe.get("filter")=="display-excluding-other-apps"):
        blanks=[(i,r) for i,r in enumerate(genuine) if r.get("status")==2 and stamp(r,"displayTime") and pressed<=r["displayTime"]<=ended]
        confirmed=[r["displayTime"] for i,r in blanks if presentation_proof(genuine,i,source,target,hz,version)[0]
                   and (version<3 or tick_matches_time(r,probe.get("machTimebase") or {}))]
        checks["rawNativeBlankEventsDuringPress"]=len(blanks)
        checks["scopedNativeBlankEventsDuringPress"]=len(confirmed)
        if confirmed:
            checks["continuousVisibleLight"]="FAIL"
            result.update(status="FAIL",physicallyQualified=True,blankPresentationTimes=confirmed,
                          reason="The scoped native display stream reported SCFrameStatus.blank during the issued press")
            return result
    if not (math.isfinite(pressed) and math.isfinite(ended) and 0 < pressed < ended and pre and post
            and pre["current"] == request["topology"]["current"] and post["current"] == request["target"]
            and data.get("postSpace") == request["target"] and pre["windows"] == post["windows"]
            and pre["uptime"] <= pressed < ended <= post["uptime"] and data.get("ready")
            and not data.get("changed") and not data.get("stoppedEarly")):
        result["reason"] = "Issued interval or independently revalidated endpoints unavailable"
        return result
    probe = data.get("physical", {})
    result["displayProbe"] = {"armed": probe.get("armed",False), "censusAfter": probe.get("censusAfter",False),
                              "cropPoints": probe.get("crop"), "privatePixelOutput": False}
    result["displayProbe"]["sourceFrameReadyBeforePress"]=probe.get("sourceFrameReadyBeforePress") is True
    if isinstance(probe.get("admission"),dict):result["displayProbe"]["admission"]=probe["admission"]
    if not (probe.get("armed") and probe.get("sourceFrameReadyBeforePress") is True and probe.get("censusAfter") and not probe.get("error")
            and probe.get("filter") == "display-excluding-other-apps"):
        diagnostics=probe.get("admission") or {}
        result["reason"]="; ".join(diagnostics.get("failed") or []) or diagnostics.get("streamStartError") or (
            "Physical display source frame was not verified before the product press" if not probe.get("sourceFrameReadyBeforePress")
            else "Missing continuous physical display stream or independently confirmed final desktop membership")
        return result
    rows=probe["frames"]
    genuine=[r for r in rows if r.get("origin","sck-display")=="sck-display"]
    auxiliary=[r for r in rows if r.get("origin")=="guarded-current-display-crop"]
    result["displayProbe"]["totalNativeEvents"]=len(genuine)
    result["displayProbe"]["auxiliaryRequestCount"]=len(auxiliary)
    result["displayProbe"]["blockedReadbacks"]=dict(collections.Counter(r["blockedBy"] for r in genuine if r.get("blockedBy")))
    if len(genuine)+len(auxiliary)!=len(rows):
        result["reason"]="Unidentified physical sample origin";return result
    if not genuine or any(stamp(r,"displayTime") is None or stamp(r,"callback") is None for r in genuine):
        result["reason"]="Missing genuine WindowServer presentation or callback timestamp";return result
    if any(b["displayTime"]<a["displayTime"] for a,b in zip(genuine,genuine[1:])):
        result["reason"]="Native presentation timestamps regressed";return result
    before=[i for i,r in enumerate(genuine) if r["displayTime"]<=pressed and r.get("status") in (0,4) and r.get("safe") is True and
            r.get("matchesSource") is True and r.get("lit") is True and r.get("visible")=="source" and r.get("space")==pre["current"]]
    terminal = probe.get("terminalTarget") or {}
    link_at = stamp(terminal,"nativeTargetTime")
    if version >= 2:
        result["displayProbe"]["terminalTarget"] = terminal
        requested, returned = stamp(terminal,"sampleRequested"), stamp(terminal,"sampleReturned")
        checks["independentTerminalTargetMatched"] = bool(terminal.get("eligible") is True and terminal.get("sameStream") is True
            and terminal.get("freshFramesAgreeWithEnrolledCrop") is True and terminal.get("shareableTargetOnScreen") is True
            and terminal.get("independentTargetAndDisplayAgree") is True and requested and returned and ended <= requested <= returned <= post["uptime"]
            and (version<3 or terminal.get("confirmedConsecutiveCensuses")==2))
    boundary = max(ended, link_at) if version >= 2 and link_at else ended
    after=[i for i,r in enumerate(genuine) if r["displayTime"]>=boundary]
    if not before or not after:
        result["reason"]="Missing a genuine source presentation before press or native presentation after independent observation";return result
    if not valid_clock:
        result["reason"]="Display refresh cadence unavailable";return result
    first,last=before[-1],after[0]
    window=genuine[first:last+1]
    lower,upper=window[0]["displayTime"],window[-1]["displayTime"]
    limit=.050
    gaps=[(a["displayTime"],b["displayTime"]) for a,b in zip(window,window[1:])]
    base=probe.get("machTimebase") or {}
    numer,denom=base.get("numerator"),base.get("denominator")
    if version>=3:
        if not all(tick_matches_time(r,base) for r in window):
            result["reason"]="Native Mach event ticks and clock timebase could not be bound";return result
        exact=[(b["presentationMachTicks"]-a["presentationMachTicks"])*numer for a,b in zip(window,window[1:])]
        if any(n<0 for n in exact):
            result["reason"]="Native Mach presentation order regressed";return result
        large=[{"from":a,"to":b,"gapMS":n/denom/1e6} for (a,b),n in zip(gaps,exact) if n>50_000_000*denom]
        max_gap=max(exact,default=0)/denom/1e6
    else:
        large=[{"from":a,"to":b,"gapMS":(b-a)*1000} for a,b in gaps if b-a>limit]
        max_gap=max((b-a for a,b in gaps),default=0)*1000
    result["coverage"]={"from":lower,"to":upper,"samples":len(window),"maxGapMS":max_gap,
                        "permittedGapMS":limit*1000,"uncoveredIntervals":large,"statusCounts":dict(collections.Counter(str(r["status"]) for r in window))}
    supplements=[]
    for r in auxiliary:
        start,end=stamp(r,"from"),stamp(r,"to")
        supplements.append({"validPhysicalTiming":False,"usedForCoverage":False,"safe":r.get("safe") is True,
            "requestMS":(end-start)*1000 if start and end else None,
            "nativePresentationsInsideRequest":sum(start<=n["displayTime"]<=end for n in genuine) if start and end else None,
            "whollyInsideAuditedSpan":bool(start and end and lower<=start<=end<=upper)})
    result["displayProbe"]["auxiliaryRequests"]=supplements
    result["displayProbe"]["currentCropReads"]=0
    proofs=[presentation_proof(genuine,i,source,target,hz,version) for i in range(first,last+1)]
    issues=[{"displayTime":r["displayTime"],"reason":proof[1]} for r,proof in zip(window,proofs) if not proof[0]]
    early=[proof[2] for proof in proofs if proof[0] and proof[2] and proof[2][0]>0]
    coverage=result["coverage"]
    coverage.update(timingFailures=issues[:40],timingFailureCount=len(issues),timingFailureReasons=dict(collections.Counter(i["reason"] for i in issues)),
                    earlyEventsWithFollowingProof=len(early),maximumLeadMS=max((a for a,_ in early),default=0)*1000,
                    maximumFollowingProofMS=max((b for _,b in early),default=0)*1000)
    if len(gaps)>=2 and not large:checks["nativePresentationCoverage"]="PASS"
    lit=target_marker=False
    failures=[]
    for r,proof in zip(window,proofs):
        if r["status"] in (0,4):
            lit=r.get("lit") is True
            target_marker=proof[0] and r.get("matchesTarget") is True and r.get("space")==target and r.get("visible")=="target"
        elif r["status"]==1:
            target_marker=target_marker and proof[0] and r.get("visible")=="target" and r.get("space")==target
        else:
            lit=target_marker=False
            failures.append("nativeStatus"+str(r["status"]))
        if not lit:failures.append("litNativeFrameUnavailable")
    checks["streamingTargetMatched"]=target_marker
    if not issues and not failures and checks["nativePresentationCoverage"]=="PASS":checks["continuousVisibleLight"]="PASS"
    coverage["pixelFailures"]=dict(collections.Counter(failures))
    final_frames=[r for r in genuine if r["status"] in (0,4) and r.get("safe") is True and r.get("visible")=="target" and r.get("space")==post["current"]]
    surface_frames=[r for r in genuine if r["status"] in (0,4) and r.get("safe") is True and r.get("visible")=="target"]
    result["displayProbe"]["targetCompleteColorCounts"]={
        "allTargetSurfaceCompleteIncludingTransition":len(surface_frames),"targetSurfaceMatchingColor":sum(r.get("matchesTarget") is True for r in surface_frames),
        "allNativeTargetComplete":len(final_frames),"matchingTarget":sum(r.get("matchesTarget") is True for r in final_frames),
        "matchingSource":sum(r.get("matchesSource") is True for r in final_frames),
        "matchingNeither":sum(r.get("matchesTarget") is False and r.get("matchesSource") is False for r in final_frames),
        "sourceDeltaBands":dict(collections.Counter(r["sourceColorMaxDeltaBand"] for r in final_frames if "sourceColorMaxDeltaBand" in r)),
        "targetDeltaBands":dict(collections.Counter(r["targetColorMaxDeltaBand"] for r in final_frames if "targetColorMaxDeltaBand" in r))}
    # Keep all independent causes, including the minimum positive physical target evidence, in one receipt.
    if issues or failures or large or len(gaps)<2:
        reasons=[]
        if issues:reasons.append("Physical presentation ownership/timing: "+", ".join(coverage["timingFailureReasons"]))
        if failures:reasons.append("Unqualified native pixel/status: "+", ".join(coverage["pixelFailures"]))
        if len(gaps)<2 or large:reasons.append("A gap between genuine display presentations exceeded 50 ms")
        result["reason"]="; ".join(reasons);return result
    if not target_marker:
        result["reason"]="The genuine display stream did not match the target fixture color on its final Space";return result
    if version>=2 and not (checks["independentTerminalTargetMatched"] and terminal.get("linkedToNativeTarget") is True and link_at
                           and link_at==upper and returned<=link_at<=post["uptime"]):
        result["reason"]=terminal.get("reason") or "Fresh physical display, isolated target marker and same-stream presentation were not jointly verified"
        return result
    result.update(status="PASS",physicallyQualified=True,reason="Genuine time-bound physical presentations remained lit and reached the independently bound target marker")
    return result


def finish(kit, attempt, pressed, ended, *, window_witness=None):
    folder = None
    try:
        kit, _ = kit_paths(kit)
        folder = private(private(attempt, directory=True)/"visual", directory=True)
        receipt = folder/"receipt.json"
        if receipt.exists():
            return read(receipt)
        b = read(folder/"binding.json")
        p = b["request"]
        post = None
        if 0 < pressed < ended and math.isfinite(ended):
            try:
                post = witness(kit, p, p["target"], window_witness)
            except ERRORS:
                pass
        write(folder/"end.json", dict(nonce=b["nonce"], pressed=pressed, ended=ended, allowMovie=bool(post)))
        limit = time.monotonic() + 11
        while time.monotonic() < limit and not (folder/"frames.json").exists() and not (folder/"error.json").exists():
            time.sleep(.04)
        observed = read(folder/"frames.json")
        require(observed["nonce"] == b["nonce"], "recorder generation changed")
        pre = read(folder/"before.json")
        if post:
            post = witness(kit, p, p["target"], window_witness)
            write(folder/"after.json", post)
        result = score(observed, p, float(pressed), float(ended), pre, post)
        movie = folder/"verified-pair.mp4"
        if movie.is_file() and observed.get("movie") and post:
            result["silentMovie"] = {"file":movie.name, "sha256":hashlib.sha256(private(movie).read_bytes()).hexdigest()}
        result.update(frameLog="frames.json", nonce=b["nonce"], source=p["topology"]["current"], target=p["target"], pressed=pressed, ended=ended)
    except ERRORS as error:
        result = unknown(str(error))
        if folder:
            (folder/"verified-pair.mp4").unlink(missing_ok=True)
    finally:
        proc = CHILDREN.pop(str(folder), None)
        if proc:
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try: proc.wait(timeout=2)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait()
    if folder:
        write(folder/"receipt.json", result)
    return result


def replay(attempt, destination):
    """Independently verify archived input, preserving every original file and verdict."""
    attempt = private(attempt, directory=True)
    dest = Path(destination).absolute()
    private(dest.parent, directory=True)
    require(dest.parent != attempt and attempt not in dest.parents, "write offline review outside the archived attempt")
    result = read(attempt/"result.json")
    name = result.get("hostJournalFile", "")
    require(name.endswith(".json") and str(uuid.UUID(name[:-5])).upper()+".json"==name, "invalid terminal Host receipt filename")
    paths = ["identity.json", "card-before.json", "ax-dispatch.json", "visual-start.json", "result.json", name, "windowserver.jsonl",
             *["visual/"+n+".json" for n in ("receipt", "binding", "end", "ready", "admission", "before", "after", "frames")]]
    inputs = {}
    digests = {}
    for path in paths:
        with private(attempt/path).open("rb") as stream:
            data=stream.read(6_000_001)
        require(0<len(data)<=6_000_000, "archived input missing or oversized")
        digests[path]=hashlib.sha256(data).hexdigest()
        inputs[path]=[json.loads(line) for line in data.splitlines()] if path.endswith(".jsonl") else json.loads(data)
    require(inputs["result.json"]==result, "attempt changed during offline review")
    request, dispatch, journal=inputs["identity.json"], inputs["ax-dispatch.json"], inputs[name]
    before, after, frames, end, original=[inputs["visual/"+n+".json"] for n in ("before", "after", "frames", "end", "receipt")]
    bound=inputs["visual/binding.json"]
    nonce=bound["nonce"]
    require(str(uuid.UUID(nonce)).upper()==nonce and bound["request"]==request and all(inputs[f].get("nonce")==nonce for f in
        ("visual/ready.json", "visual-start.json", "visual/end.json", "visual/receipt.json", "visual/frames.json", "visual/admission.json")), "visual generation or fixture request changed")
    pressed, ended=end["pressed"],end["ended"]
    window=request["targetWindow"]
    control=f"native-space-window:{request['topology']['display']}:{request['target']}:{window['pid']}:{window['number']}"
    require(inputs["card-before.json"].get("control")==control and dispatch.get("control")==control and dispatch.get("issued") is True
            and dispatch.get("visibleHitVerified") is True and dispatch.get("axError")==0 and pressed==dispatch["uptime"]
            and original["pressed"]==pressed and original["ended"]==ended and end["allowMovie"] is True, "visual interval unbound from the issued exact card")
    cards=importlib.import_module("p0-cards")
    host=cards.match_receipt(journal,name,request,pressed)
    windows=inputs["windowserver.jsonl"]
    require(windows and windows[-1].get("uptime")==ended and host["confirmed"] is True and cards.assess(windows,request,pressed,host,dispatch)[0]=="PASS"
            and result.get("navigationStatus")=="PASS", "independent navigation or exact production Host evidence incomplete")
    fresh=score(frames,request,pressed,ended,before,after)
    review={"method":"offline review of preserved native presentation metadata", "selfContainedReviewVersion":2,
            "originalVisual":{"status":original["status"], "reason":original["reason"]},"originalNavigation":result["navigationStatus"],
            "hostReceipt":host["id"], "nonce":nonce,"pressed":pressed,"ended":ended,"inputSHA256":digests,
            "evaluatorSHA256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "review":fresh}
    with os.fdopen(os.open(dest,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600),"w") as f:
        json.dump(review,f,ensure_ascii=False,sort_keys=True,indent=2);f.write("\n");f.flush();os.fsync(f.fileno())
    return review


if __name__ == "__main__":
    if sys.argv[1:2] == ["replay"]:
        parser=argparse.ArgumentParser(description="Re-score archived macOS presentation evidence without accessing the display")
        parser.add_argument("attempt",type=Path);parser.add_argument("output",type=Path)
        args=parser.parse_args(sys.argv[2:]);os.umask(0o077)
        try:
            review=replay(args.attempt,args.output)
        except ERRORS as error:
            parser.exit(2, f"Cannot bind offline review: {error}\n")
        print(json.dumps({"status":review["review"]["status"],"review":str(args.output),"originalStatus":review["originalVisual"]["status"]}));sys.exit(0)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["enroll","start","finish"])
    parser.add_argument("kit", type=Path)
    parser.add_argument("attempt", type=Path)
    parser.add_argument("values", nargs="+")
    args = parser.parse_args()
    os.umask(0o077)
    if args.mode == "finish":
        answer = finish(args.kit, args.attempt, *map(float,args.values))
    elif args.mode == "enroll":
        answer = enroll(args.kit, args.attempt, read(Path(args.values[0])))
    else:
        answer = start(args.kit, args.attempt, read(Path(args.values[0])), guardian=os.getppid())
    print(json.dumps(answer))
    raise SystemExit(0 if answer["status"] in ("READY","PASS") else 2)
