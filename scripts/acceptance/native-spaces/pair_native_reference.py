"""Two passive P2 reads after the protected lease's own documents have been verified."""
import hashlib
import math
import re
import subprocess
import uuid

from p2_documents import Superseded, TrialStop, check_hid


READS = (("environment","focus-reference-environment","ENVIRONMENT_OBSERVED"),
         ("applePicker","apple-focus-reference","LINKS_OBSERVED"))
COUNT_KEYS = ("displayContainers","buttons","firstLinks","secondLinks")
REFUSALS = {
    "CGWindowOrSpaceMembershipChanged","editorHierarchyChanged","editorHierarchyOverBound",
    "enrolledDocumentAXWindowOrURLUnavailable","enrolledDocumentEditorOrBoundedTextUnavailable",
    "enrolledNativeReferenceScopeUnavailable","enrolledWindowCGNumberNotUnique","fixtureAXWindowInventoryUnavailable",
    "incompleteEnrollment","installedHostOrLeasedSpaceChanged","kernelExecutableIdentityChanged",
    "liveGenerationOrDeveloperIDMismatch","observerAXUnavailable","unsupportedFixtureKit","wrongFixtureOrSession",
    "LSRegularAppIdentityUnavailable","LSBundleOrRegisteredExecutableUnavailable","unadmittedActionOrDocumentDigests",
    "enrolledSpaceWindowsOrEnvironmentChanged","enrollmentOrPhysicalDisplayUnavailable","environmentChanged",
    "scopeChangedDuringNativeRead","signedOverviewOwnerCouldNotBeConfirmed","twoStableSystemLinksAndHitTestsUnavailable",
}


def numeric(values, count):
    return isinstance(values,list) and len(values)==count and all(type(v) in (int,float) and math.isfinite(v) for v in values)


def evidence(raw, binding, expected):
    result = {"status":"UNKNOWN","scope":"afterVerifiedFixtureForeground","physicalLatencySamples":0,
              "reason":"unconfirmedObserverResponse"}
    counts = raw.get("observations")
    if isinstance(counts,list) and len(counts) <= 2 and all(isinstance(row,dict) and all(
            type(row.get(k)) is int and row[k] >= 0 for k in COUNT_KEYS) for row in counts):
        result["observations"] = [{k:row[k] for k in COUNT_KEYS} for row in counts]
        if len(counts)==2 and all(row["displayContainers"] == 0 for row in counts):
            result["systemView"] = "noMatchingSystemDisplayContainerObserved"
        elif any(row["displayContainers"] for row in counts):
            result["systemView"] = "systemContainerObserved"
    if raw.get("issued") is False:
        result["issued"] = False
    if type(raw.get("retainedPixelBytes")) is int and raw["retainedPixelBytes"] == 0:
        result["retainedPixelBytes"] = 0
    if raw.get("status") == "BLOCKED":
        reason = raw.get("reason")
        result.update(status="BLOCKED",reason=reason if isinstance(reason,str) and reason in REFUSALS else "observerRefused")
        return result
    env = raw.get("environment")
    if (raw.get("status") != expected or result.get("issued") is not False or result.get("retainedPixelBytes") != 0 or
            type(raw.get("presentationSamples")) is not int or raw["presentationSamples"] != 0 or not isinstance(env,dict)):
        return result
    wanted = {k:binding[k] for k in ("hostPID","hostBirth","hostHash","display","space","spaceUUID","session","numbers")}
    wanted.update(fixturePID=binding["pid"],fixtureBirth=binding["birth"],fixtureHash=binding["hash"])
    if any(env.get(k)!=v for k,v in wanted.items()):
        result["reason"]="observedFixtureOrLeaseMismatch"
        return result
    clock=raw.get("interval")
    if not (numeric(clock,2) and 0 < clock[0] <= clock[1] and numeric(env.get("bounds"),4) and
            numeric(env.get("modePixels"),2) and isinstance(env.get("frames"),list) and len(env["frames"]) == 2 and
            all(numeric(r,4) for r in env["frames"]) and type(env.get("reduceMotion")) is bool and
            env.get("stageManager") is False and type(env.get("otherOrdinaryAppWindows")) is int and env["otherOrdinaryAppWindows"] == 0 and
            isinstance(env.get("osBuild"),str) and re.fullmatch(r"[0-9]{1,3}[A-Za-z][A-Za-z0-9]{1,10}",env["osBuild"]) and
            (env.get("refreshHz") is None or numeric([env["refreshHz"]],1) and env["refreshHz"] > 0)):
        return result
    scene = {**wanted,**{k:env[k] for k in ("bounds","modePixels","frames","reduceMotion","stageManager","otherOrdinaryAppWindows","osBuild")}}
    scene.update(boot=str(uuid.UUID(env["boot"])),refreshHz=env.get("refreshHz"))
    if expected == "LINKS_OBSERVED":
        owner,targets = raw.get("owner"),raw.get("targets")
        if not (isinstance(owner,dict) and owner.get("bundle") in ("com.apple.dock","com.apple.WindowManager") and
                type(owner.get("pid")) is int and owner["pid"]>1 and type(owner.get("birth")) is int and owner["birth"]>0 and
                isinstance(owner.get("cdHash"),str) and re.fullmatch(r"[0-9a-f]{40}",owner["cdHash"]) and
                isinstance(targets,list) and len(targets)==2 and all(isinstance(row,dict) and row.get("number")==n and
                numeric(row.get("rect"),4) for row,n in zip(targets,binding["numbers"])) and
                len(result.get("observations",[]))==2 and all(r["firstLinks"]==r["secondLinks"]==1 for r in result["observations"]) and
                all(raw.get(k)==wanted[k] for k in ("display","space","spaceUUID","session","fixturePID","fixtureBirth","fixtureHash"))):
            return result
        result.update(owner={k:owner[k] for k in ("bundle","pid","birth","cdHash")},
                      targets=[{"number":r["number"],"rect":r["rect"]} for r in targets],systemView="twoOriginalDocumentsLinked")
    result.update(status=expected,interval=clock,environment=scene)
    del result["reason"]
    return result


def checkpoint(run, hashes):
    superseded = False
    for name,mode,expected in READS:
        result = {"status":"NOT_RUN","reason":"previousReadSuperseded","physicalLatencySamples":0}
        if not superseded:
            try:
                raw=run.call(mode,{"digests":hashes})
                check_hid(raw,run.baseline)
                result=evidence(raw,run.binding,expected)
            except Superseded:
                superseded = True
                result={"status":"BLOCKED","reason":"userSuperseded","physicalLatencySamples":0}
            except (OSError,ValueError,TypeError,KeyError,AttributeError,subprocess.SubprocessError) as error:
                result={"status":"UNKNOWN","reason":"observerUnavailable","errorType":type(error).__name__,"physicalLatencySamples":0}
        filename = mode + ".json"
        run.rec.write(filename,result)
        digest = hashlib.sha256((run.rec.output/filename).read_bytes()).hexdigest()
        run.out["nativeReferenceProbe"][name] = {"status":result["status"],"file":filename,"sha256":digest,
                                                 **{k:result[k] for k in ("reason","systemView") if k in result}}
        run.rec.log("P2-passive-reference-checkpoint",kind=name,**run.out["nativeReferenceProbe"][name])
    if superseded:
        raise Superseded()
    scope_losses = {"observedFixtureOrLeaseMismatch","installedHostOrLeasedSpaceChanged","kernelExecutableIdentityChanged",
                    "liveGenerationOrDeveloperIDMismatch","CGWindowOrSpaceMembershipChanged",
                    "scopeChangedDuringNativeRead","wrongFixtureOrSession"}
    if any(item.get("reason") in scope_losses for item in run.out["nativeReferenceProbe"].values()):
        raise TrialStop("enrolledScopeChangedDuringPassiveReference")
    if run.out["nativeReferenceProbe"]["applePicker"]["status"] == "LINKS_OBSERVED":
        raise TrialStop("nativePickerCurrentlyOwnsBothFixtureTargets")
