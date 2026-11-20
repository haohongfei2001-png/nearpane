#!/usr/bin/env python3
"""Verify a P3 checkout using private, network-blocked headless fixtures and immutable local receipts."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[3]
BROWSERS = {
    "chrome": ("/Applications/Google Chrome.app", "scripting.sdef", "com.google.Chrome"),
    "edge": ("/Applications/Microsoft Edge.app", "scripting.sdef", "com.microsoft.edgemac"),
    "safari": ("/Applications/Safari.app", "Safari.sdef", "com.apple.Safari"),
}
SERVICES = ("chatgpt.com", "claude.ai", "gemini.google.com", "chat.deepseek.com")
SUITES = "CaptureAttachmentProviderTests|TrayDomainTests|ProductDraftExecutorTests|TestTargetBindingTests|TrayTests|CaptureConsentTests"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(args, stdin=None, timeout=240):
    env = dict(os.environ, NEARPANE_OFFLINE="1")
    result = subprocess.run(args, cwd=ROOT, input=stdin, capture_output=True, text=True, timeout=timeout, env=env)
    if result.returncode:
        print((result.stdout + result.stderr)[-4000:], file=sys.stderr)
        raise RuntimeError("process exit " + str(result.returncode))
    return result.stdout + result.stderr


def browser_install(key):
    name, dictionary, expected = BROWSERS[key]
    bundle = Path(name) / "Contents"
    info = bundle / "Info.plist"
    if not info.is_file():
        return {"installed":False}
    data = plistlib.loads(info.read_bytes())
    if data.get("CFBundleIdentifier") != expected:
        return {"installed":False, "expectedIdentity":False}
    source = bundle / "Resources" / dictionary
    schema = ElementTree.parse(source)
    tab = next(c for c in schema.iter("class") if c.get("name") == "tab")
    properties = {p.get("name") for p in tab.findall("property")}
    commands = {c.get("name") for c in schema.iter("command")}
    return {"installed":True, "bundleID":expected, "version":data["CFBundleShortVersionString"],
            "dictionarySHA256":digest(source), "declaresStableTabID":"id" in properties,
            "declaresSelectedTabJavaScript":bool({"execute","do JavaScript"} & commands)}


def read_result(text):
    return next(json.loads(s) for s in reversed(text.splitlines()) if s.startswith('{"directory":'))


def stage_record(result, case):
    root = Path(result["directory"])
    folder = (root / case["scenario"] / "capture-attachment-evidence-v1")
    if root.parent != ROOT / "build" or not root.name.startswith("local-browser-") or '/' in case["scenario"]:
        raise ValueError("unexpected fixture path")
    events = []
    for path in folder.glob("*.json"):
        row = json.loads(path.read_bytes())
        assert path.name == row["intentID"] + "." + row["stage"] + ".json"
        events.append({k:row[k] for k in ("intentID","stage","state","dispatch","independentObservation","cleanup",
                      "monotonicNanoseconds","operationID","invocationID","sourceSHA256","timedOut") if k in row})
    events.sort(key=lambda e:e["monotonicNanoseconds"])
    assert events and events[0]["stage"] == "intent" and all(e["sourceSHA256"] == result["assetSHA256"] for e in events if "sourceSHA256" in e)
    kinds = [e["stage"] for e in events]
    domain, observed = case["domain"], case["events"]
    if domain.get("start") == "uploadStarted":
        assert "uploadStart" in kinds
    repeat = case.get("repeat")
    return {"case":case["scenario"],"independentDOM":{k:observed.get(k) for k in
                ("setter","change","foreignChange","sendClick","submit","previews","previewSize","pickerCanceled")},
            "fileHashMatches":observed["hash"] == result["assetSHA256"] if observed["hash"] else None,
            "attempt":domain.get("attempt"),"durablePhase":domain.get("phase"),"uploadStartReceipt":domain.get("start"),
            "uploadCompleted":True if domain.get("receipt") == "verifiedReady" else None,
            "repeatSameAttempt":repeat["operation"] == domain.get("operation") and repeat["attempt"] == domain.get("attempt") if repeat else None,
            "reopenedSameStatus":case["freshProcess"]["status"] == domain["status"] if case.get("freshProcess") else None,
            "intentEvents":events}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="new receipt file")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("--output must name a new receipt")
    lock = json.loads((ROOT/"Dependencies/domains.lock.json").read_bytes())["domains"]["riftlet"]
    sources = ["Resources/AcceptanceTargetGuard.js","Sources/NearpaneTray/DraftCapability.swift",
               "Sources/NearpaneTray/CaptureAttachmentProvider.swift","Sources/NearpaneTray/AcceptanceBrowserRoute.swift",
               "Sources/NearpaneTray/ProductDraftBinding.swift","Sources/NearpaneTray/TrayOwner.swift","Sources/NearpaneTray/TrayModule.swift",
               "Sources/NearpaneTray/ScreenshotArchive.swift","Sources/NearpaneTray/TrayAttachmentFeedback.swift","Sources/NearpaneTray/TraySurface.swift"]
    report = {"schema":1,"startedUTC":datetime.now(timezone.utc).isoformat(),
              "macOSBuild":execute(["/usr/bin/sw_vers","-buildVersion"]).strip(),"scope":"P3 source checkout and network-isolated fixtures",
              "sourceBase":execute(["git","rev-parse","90808bd^{commit}"]).strip(),
              "riftlet":{"commit":lock["commit"],"treeSHA256":lock["treeSHA256"]},
              "sourceSHA256":{p:digest(ROOT/p) for p in sources},"browserInstallations":{},"capabilityFixtures":{},
              "realDesktopCapture":"NOT_RUN","realDisplayRotationAndMirroring":"NOT_RUN",
              "liveProfile":"BLOCKED_NO_AUTHORIZED_ISOLATED_AUTHENTICATED_PROFILE","liveAttempts":0,
              "liveObservedSendEvents":None,"installedHostOnThisRevision":"NOT_RUN","errors":{}}
    try:
        swift=execute(["scripts/test.sh","--filter",SUITES])
        matched=re.search(r"Test run with (\d+) tests in (\d+) suites passed",swift)
        if not matched:
            raise ValueError("test summary unavailable")
        report["swiftTests"]={"result":"PASS","count":int(matched[1]),"suites":int(matched[2])}
    except Exception as exc:
        report["errors"]["swift"]=str(exc)
    (ROOT/"build").mkdir(exist_ok=True)
    for browser in BROWSERS:
        try:
            app=browser_install(browser)
            report["browserInstallations"][browser]=app
            if browser == "safari" or not app["installed"]:
                continue
            result=read_result(execute(["node","scripts/acceptance/local-browser.mjs"],json.dumps({"capabilityBrowser":browser})))
            assert all(c["independent"]["unchanged"] for c in result["cases"])
            assert not (Path(result["directory"])/"user-data").exists()
            report["capabilityFixtures"][browser]={"result":"PASS_FIXTURE","privateProfileRemoved":True,
                "browserVersion":result["chrome"],"interceptedDocuments":result["fixtureDocumentResponses"],"cases":result["cases"]}
        except Exception as exc:
            report["errors"]["capabilities-"+browser]=str(exc)
    if "swift" not in report["errors"] and report["browserInstallations"].get("chrome",{}).get("installed"):
        try:
            result=read_result(execute([sys.executable,"scripts/acceptance/run-local-adapter.py","--product","--swiftpm-fixture"]))
            assert not (Path(result["directory"])/"user-data").exists()
            assert result["browserRestart"]["privateProfileRemoved"] and result["browserRestart"]["refusedRestartedProcess"]
            report["browserRestartFixture"]=result["browserRestart"]
            report["productFixture"]={"result":"PASS_FIXTURE","nativeBrowserAddress":"replaced by private pipe",
                "browserVersion":result["chrome"],"sourceSHA256":result["assetSHA256"],"privateProfileRemoved":True,
                "interceptedDocuments":result["fixtureDocumentResponses"],"otherRequestsDenied":result["otherRequestsDenied"],
                "cases":[stage_record(result,case) for case in result["cases"]]}
        except Exception as exc:
            report["errors"]["product-fixture"]=str(exc)
    report["matrix"]=[]
    for browser in BROWSERS:
        for service in SERVICES:
            probe=report["capabilityFixtures"].get(browser)
            report["matrix"].append({"browser":browser,"service":service,
                "nativeAddress":"signed PID, birth and window; tab index only" if browser=="safari" else "signed PID, birth, window ID and tab ID",
                "siteProbeFixture":"NOT_RUN_WEBKIT" if browser=="safari" else "PASS_FIXTURE" if probe else "NOT_RUN",
                "lockedWriter":"chatgpt-web" if (browser,service)==("chrome","chatgpt.com") else "NOT_IMPLEMENTED_AT_THIS_PIN",
                "liveAuthentication":None,"freshConversationCreated":None,"editor":None,"pickerAccepted":None,
                "attachmentRendered":None,"uploadComplete":None,"liveSendEventCount":None,"live":"BLOCKED"})
    report["finishedUTC"]=datetime.now(timezone.utc).isoformat()
    report["assessment"]="FAILED_FIXTURE" if report["errors"] else "LIVE_BLOCKED"
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open("x") as f:
        json.dump(report,f,ensure_ascii=False,indent=2)
        f.write("\n")
    print(report["assessment"],"receipt",args.output)
    return int(bool(report["errors"]))


if __name__=="__main__":
    raise SystemExit(main())
