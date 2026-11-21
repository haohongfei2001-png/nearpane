#!/usr/bin/env python3
"""Compare a physical Host's two membership reads with one ordinary signed app's own AppKit window."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
import candidate_signing

spec = importlib.util.spec_from_file_location("host_scope", HERE / "observe-scope.py")
scope_reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope_reader)


def read_when_ready(path, process, deadline):
    while time.monotonic() < deadline:
        if path.exists():
            raw = scope_reader.read_private(path, 8192)
            if raw.endswith(b"\n"):
                return json.loads(raw)
        if process.poll() is not None:
            break
        time.sleep(0.03)
    return None


def eligible(row):
    return (
        row
        and row["regularApplication"]
        and row["ordinaryWindow"]
        and row["visible"]
        and row["onActiveSpace"]
        and row["window"] > 0
        and row["sameFront"]
        and not any(row[k] for k in ("active", "key", "main"))
        and row["alpha"] == 0
        and row["ignoresMouseEvents"]
    )


def legacy_matches(receipt, image):
    subject = receipt.get("subject", {})
    return (receipt.get("status") == "PASS" and receipt.get("osBuild") == "26A428"
            and receipt.get("spaceScope", {}).get("scope", {}).get("status") == "PASS"
            and receipt.get("permissions", {}).get("accessibility") is True
            and receipt.get("permissions", {}).get("listenEvent") is True
            and image["source"] == subject.get("source") and image["CDHash"] == subject.get("cdhash")
            and image["Identifier"] == subject.get("identifier"))


def installed_matches(app, image, revision, digest):
    return app == scope_reader.DAILY and product_matches(image, revision, digest)


def product_matches(image, revision, digest):
    return (image.get("Identifier") == "com.holdsnow.nearpane.alpha"
            and image.get("TeamIdentifier") == "ZB9D4T66QB" and image.get("multipleInstancesProhibited") is True
            and image.get("version") == "5.22" and image.get("build") == "90"
            and image.get("sourceState") == "clean" and image.get("engineABI") == 1
            and re.fullmatch(r"[0-9a-f]{40}", revision or "") is not None
            and re.fullmatch(r"[0-9a-f]{40}", digest or "") is not None
            and revision == image.get("source") and digest == image.get("CDHash"))


def launch_readiness(candidate, installed, revision, digest, roster, target):
    """A staged image may be inspected. Only the pinned canonical image can be launched."""
    blockers = []
    if target != dict(os="27.0", build="26A428", architecture="arm64", sip="System Integrity Protection status: enabled."):
        blockers.append("targetBuildArchitectureOrSIP")
    if not product_matches(candidate, revision, digest):
        blockers.append("candidateIdentityOrEngineABI")
    if not installed_matches(scope_reader.DAILY, installed, revision, digest):
        blockers.append("installedHostIsNotPinnedEngineCandidate")
    if roster.get("pids"):
        blockers.append("sameProductInstanceRunning")
    session = roster.get("session", {})
    if session.get("qualified") is not True:
        blockers.append("noUnlockedConsoleForCaller")
    pids = roster.get("pids")
    complete = (roster.get("complete") is True and isinstance(pids, list)
                and all(type(pid) is int and pid > 1 for pid in pids) and len(set(pids)) == len(pids)
                and type(session.get("qualified")) is bool and type(session.get("securitySessionID")) is int
                and (session.get("qualified") is False or session["securitySessionID"] > 0))
    if not complete:
        blockers.append("incompleteProcessOrSessionCensus")
    return dict(status="UNKNOWN" if not complete else "BLOCKED" if blockers else "PASS",
                blockers=blockers, target=target, candidate=candidate, installed=installed, roster=roster,
                scope="readOnlyLaunchReadiness", hostLaunches=0, windowWrites=0, spaceWrites=0,
                hostPermissions="NOT_RUN", singleWindowHideRestore="NOT_RUN", productionQualified=False)


def inspect_launch(candidate, revision, digest):
    installed = scope_reader.identity(scope_reader.DAILY)
    target = dict(os=scope_reader.command("sw_vers", "-productVersion").strip(),
                  build=scope_reader.command("sw_vers", "-buildVersion").strip(),
                  architecture=os.uname().machine, sip=scope_reader.command("csrutil", "status").strip())
    with tempfile.TemporaryDirectory(dir="/private/tmp", prefix="nearpane-engine-roster.") as scratch:
        launcher = scope_reader.build_launcher(Path(scratch))
        roster = json.loads(scope_reader.command(launcher, scope_reader.DAILY, "--roster"))
    return launch_readiness(candidate, installed, revision, digest, roster, target)


def preflight_allows(pre):
    return (pre["spaceScope"]["scope"].get("status") == "PASS"
            and pre["system"]["build"] == "26A428" and pre["system"]["sip"].get("enabled") is True
            and pre["permissions"]["accessibility"] is True and pre["permissions"]["listenEvent"] is True
            and all(s["session"]["qualified"] is True and s["display"]["topologyConfirmed"] is True
                    and s["display"]["activeCGCount"] == 1 for s in pre["spaceScope"]["samples"]))


def prepare_fixture(work, report):
    fixture = work / "Membership Window.app"
    exe = fixture / "Contents/MacOS/MembershipWindow"
    exe.parent.mkdir(parents=True)
    ident = "com.holdsnow.nearpane.engine-fixture.a"
    (fixture / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            dict(
                CFBundlePackageType="APPL",
                CFBundleIdentifier=ident,
                CFBundleExecutable=exe.name,
                CFBundleName="Nearpane Membership Window",
                CFBundleVersion="1",
                CFBundleShortVersionString="1.0",
                LSUIElement=False,
            )
        )
    )
    scope_reader.command(
        "xcrun",
        "clang",
        "-fobjc-arc",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-mmacosx-version-min=26.0",
        HERE / "membership-window.m",
        "-framework",
        "AppKit",
        "-o",
        exe,
    )
    key = candidate_signing.product_fingerprint(
        scope_reader.command("/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
    )
    scope_reader.command(
        "/usr/bin/codesign",
        "--sign",
        key,
        "--timestamp=none",
        "--options",
        "runtime",
        "--identifier",
        ident,
        fixture,
    )
    scope_reader.command("/usr/bin/codesign", "--verify", "--strict", "--deep", fixture)
    fields = dict(
        re.findall(
            r"^(CDHash|Identifier|TeamIdentifier)=(.+)$",
            scope_reader.command("/usr/bin/codesign", "-dvvv", fixture),
            re.M,
        )
    )
    if fields["TeamIdentifier"] != "ZB9D4T66QB" or fields["Identifier"] != ident:
        raise ValueError("unexpected test signer")
    report["fixture"] = fields
    report["fixtureSourceSHA256"] = hashlib.sha256((HERE / "membership-window.m").read_bytes()).hexdigest()
    return fixture, exe, fields["CDHash"]


@contextmanager
def registered_window(pre, challenge, work, fixture, exe, digest, report):
    if not preflight_allows(pre):
        report["fixtureAdmission"] = "HostScopeOrOwnAuthorizationUnavailable"
        yield None
        return
    first = None
    with (work / "launch.log").open("xb") as log:
        args = ["/usr/bin/open", "-g", "-W", "-a", fixture, "--args", "--read-membership", challenge]
        if report["requestedSpacesCycle"]:
            args.append("--enrolled-spaces-cycle")
        report["fixtureLaunchRequested"] = True
        process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
        try:
            first = read_when_ready(work / "owner-start.json", process, time.monotonic() + 5)
            report["ownerStart"] = first
            if not eligible(first):
                report["fixtureAdmission"] = "backgroundOrdinaryFixtureDidNotEnroll"
                yield None
            else:
                report["fixtureAdmission"] = "registeredSignedBackgroundWindow"
                if report["requestedSpacesCycle"]:
                    report.update(backendSafeToRollback=False, retainedForRecovery=True)
                yield json.dumps(dict(pid=first["pid"], birth=first["birth"], window=first["window"],
                                      executable=str(exe), cdhash=digest)).encode()
        finally:
            if report.get("retainedForRecovery"):
                report["ownerClosed"] = False
                report["ownerCloseReason"] = "pendingBackendRecoveryNoCloseRequested"
            else:
                (work / "stop").touch(mode=0o600, exist_ok=False)
                last = read_when_ready(work / "owner-closed.json", process, time.monotonic() + 4)
                try:
                    exit_code = process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    exit_code = None
                report.update(ownerEnd=last, launchExit=exit_code)
                for key, file in (("ownerPreflight","owner-preflight.json"), ("ownerSession","owner-session.json")):
                    if (work / file).is_file():
                        report[key] = json.loads((work / file).read_bytes())
                same = last and first and all(first.get(k) == last.get(k) for k in ("pid","birth","window"))
                gone = False
                pid = (first or report.get("ownerPreflight") or {}).get("pid")
                if isinstance(pid, int) and pid > 1:
                    found = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "pid="], capture_output=True, text=True)
                    gone = found.returncode == 1 and not found.stdout.strip() and not found.stderr.strip()
                report["ownedProcessExited"] = gone
                report["ownerClosed"] = bool(last and same and last["closed"] and last["stopSeen"] and exit_code == 0 and gone)


def panel_verdict(observed, challenge):
    if observed.get("status") != "PASS":
        return observed.get("status", "UNKNOWN")
    row = observed.get("installedSpacesCanary", {})
    if row.get("status") in {"BLOCKED", "FAIL", "TIMEOUT", "CANCELLED"}:
        return row["status"]
    panel, fixture = row.get("canary", {}), row.get("fixture", {})
    operations = ("create", "hide", "return", "destroy")
    def counts(document, count):
        actual = document.get("dispatchAttempts")
        return (isinstance(actual, dict) and set(actual) == set(operations)
                and all(type(n) is int and n == count for n in actual.values()))
    native = observed.get("spaceScope", {}).get("scope", {})
    checks = row.get("admission", {})
    ids = [panel.get(key) for key in ("window", "originalSpace", "parkingID")]
    clean = (row.get("status") == "PASS" and row.get("trial") == "ownPanelOnly" and row.get("phase") == "completed"
             and row.get("challenge") == challenge and observed.get("hostExit", {}).get("status") == "PASS"
             and panel.get("owner") == "installedHostPrivateNonactivatingPanel"
             and panel.get("pid") == observed.get("subject", {}).get("pid") and type(panel.get("pid")) is int
             and all(type(n) is int and n > 0 for n in ids)
             and native.get("status") == "PASS" and panel.get("originalSpace") == native.get("nativeID")
             and panel["parkingID"] != panel["originalSpace"]
             and all(checks.get(key) is True for key in ("installedHostSignatureAndPath", "exact26A428AndSIP",
                     "existingHostAccessibility", "sameConsoleAndDisplay", "externalFocusAndHIDRecorded", "durableOneUseClaim"))
             and all(panel.get(k) is True for k in ("observedRegistration", "restored", "closed", "parkingGone"))
             and counts(panel, 1) and fixture.get("status") == "NOT_RUN" and counts(fixture, 0)
             and row.get("endInventoryAndFocusReads") == 2 and row.get("canaryUnresolved") is False
             and row.get("heldWindows") == row.get("heldSpaces") == 0 and row.get("safeToRollback") is True)
    return "PASS" if clean else "UNKNOWN"


def run(a, report):
    app = a.host.resolve(strict=True)
    image = scope_reader.identity(app)
    if a.installed:
        readiness = inspect_launch(image, a.expected_source, a.expected_cdhash)
        report["launchReadiness"] = readiness
        if a.preflight_only or readiness["status"] != "PASS":
            report.update(status=readiness["status"], reason="formalHostLaunchReadiness",
                          scope="readOnlyFormalHostLaunchReadiness", membershipStatus="NOT_RUN")
            return
        admitted = installed_matches(app, image, a.expected_source, a.expected_cdhash)
    else:
        if (report["osBuild"] != "26A428" or scope_reader.command("/usr/bin/csrutil", "status").strip()
                != "System Integrity Protection status: enabled."):
            report.update(status="BLOCKED", reason="targetMacUnavailable")
            return
        admitted = legacy_matches(json.loads(a.preflight.read_bytes()), image)
    if not admitted:
        report.update(status="BLOCKED", reason="installedImageOrPriorHostReceiptMismatch")
        return
    raw_output = a.out.with_name(a.out.stem + "-host.json")
    with raw_output.open("x"):
        pass
    challenge = str(uuid.uuid4())
    report.update(host=image, challenge=challenge, hostReadback=raw_output.name)
    channel = Path("/private/tmp") / ("nearpane-host-scope." + challenge)
    channel.mkdir(mode=0o700)
    if a.own_spaces_canary:
        report.update(scope="physicalInstalledHostOwnPanelOnly", hostObservationStarted=True)
        observed = scope_reader.observe(app, challenge, channel, raw_output, expected_image=image, own_canary=True)
        report.update(hostLaunchRequested=observed.get("launchRequested"), hostExit=observed.get("hostExit"),
                      preexistingSameID=observed.get("launchServices", {}).get("prelaunch", {}).get("pids", []),
                      subject=observed.get("subject"), permissions=observed.get("permissions"),
                      canary=observed.get("installedSpacesCanary"), rawHostSHA256=observed.get("rawSHA256"),
                      membershipStatus="NOT_RUN", status=panel_verdict(observed, challenge))
        report["reason"] = observed.get("reason") if observed.get("status") != "PASS" else "ownPanelPhysicalReadback"
        return
    work = Path("/private/tmp") / ("nearpane-membership." + challenge)
    work.mkdir(mode=0o700)
    fixture, exe, digest = prepare_fixture(work, report)
    def enroll(pre):
        return registered_window(pre, challenge, work, fixture, exe, digest, report)
    def inspect_final(raw):
        if a.enrolled_spaces_cycle:
            cycle = raw.get("installedSpacesFixtureCycle", {})
            report["backendSafeToRollback"] = cycle.get("safeToRollback") is True
            report["retainedForRecovery"] = not report["backendSafeToRollback"]
            report["spacesCycleStatus"] = cycle.get("status", "UNKNOWN")
    report["hostObservationStarted"] = True
    observed = scope_reader.observe(app, challenge, channel, raw_output, enroll=enroll, expected_image=image,
                                    spaces_cycle=a.enrolled_spaces_cycle, inspect_final=inspect_final)
    report["hostLaunchRequested"] = observed.get("launchRequested")
    report["preexistingSameID"] = observed.get("launchServices", {}).get("prelaunch", {}).get("pids", [])
    source = observed if observed.get("subject") else observed.get("preflight", {})
    report.update(rawHostSHA256=observed.get("rawSHA256"), hostExit=observed.get("hostExit"),
                  subject=source.get("subject"), permissions=source.get("permissions"),
                  hostPermissionPhase="registered" if observed.get("subject") else "initial" if source else "NOT_RUN")
    if observed.get("status") != "PASS":
        report.update(status=observed.get("status", "UNKNOWN"), reason=observed.get("reason", "hostReadUnavailable"),
                      membershipStatus="UNKNOWN" if report.get("ownerStart") else "NOT_RUN")
        return
    current = observed["spaceScope"]
    member = current.get("fixtureMembership", {})
    valid = (current.get("scope", {}).get("status") == "PASS" and member.get("status") == "PASS"
             and all(member.get(k, {}).get("status") == "PASS" for k in ("windowToSpaces", "spaceToWindow")))
    if not valid:
        report.update(status=member.get("status") if member.get("status") in {"FAIL","BLOCKED"} else "UNKNOWN",
                      reason="scopeOrMembershipIncomplete")
    elif not report.get("ownerClosed") or not eligible(report.get("ownerEnd")):
        report.update(status="UNKNOWN", reason="owningWindowOrFocusChangedBeforeCleanup")
    else:
        report.update(status="PASS", reason="oneHostOwnerAndTwoDirectionalHostReads")
    report["membershipStatus"] = report["status"]
    if a.enrolled_spaces_cycle and report.get("spacesCycleStatus") != "PASS":
        report.update(status=report.get("spacesCycleStatus", "UNKNOWN"), reason="enrolledCycleRequiresSeparatePositiveReceipt")


def resources(report):
    if report.get("preexistingSameID"):
        host = "BLOCKED"
    elif not report.get("hostObservationStarted") or report.get("hostLaunchRequested") is False:
        host = "NOT_RUN"
    else:
        host = (report.get("hostExit") or {}).get("status", "UNKNOWN")
        if host != "PASS":
            host = "UNKNOWN"
    fixture = "NOT_RUN"
    if report.get("fixtureLaunchRequested"):
        fixture = "PASS" if report.get("ownerClosed") and report.get("ownedProcessExited") else "UNKNOWN"
    backend = "NOT_RUN"
    if report.get("requestedOwnCanary") and report.get("hostObservationStarted") and report.get("hostLaunchRequested") is not False:
        backend = "PASS" if (report.get("canary") or {}).get("safeToRollback") is True else "UNKNOWN"
    elif report["requestedSpacesCycle"] and report.get("fixtureAdmission") == "registeredSignedBackgroundWindow":
        backend = "PASS" if report.get("backendSafeToRollback") is True else "UNKNOWN"
    return dict(candidateExit=host, registeredWindowExit=fixture, backendCleanup=backend,
                clear=all(state in {"PASS", "NOT_RUN"} for state in (host, fixture, backend)))




def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("host", type=Path)
    p.add_argument("preflight", type=Path, nargs="?", help="existing Host receipt for legacy comparison mode")
    p.add_argument("out", type=Path)
    p.add_argument("--installed", action="store_true", help="bind the standard installed Alpha using the supplied release fingerprints")
    p.add_argument("--expected-source")
    p.add_argument("--expected-cdhash")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--preflight-only", action="store_true", help="inspect the signed candidate, standard installation and process roster without launching either app")
    mode.add_argument("--own-spaces-canary", action="store_true", help="cycle only the installed Host's own panel, without preparing a fixture")
    mode.add_argument("--enrolled-spaces-cycle", action="store_true", help="also request the separately scoped installed fixture operation")
    a = p.parse_args()
    if a.installed == bool(a.preflight) or (a.installed and not (a.expected_source and a.expected_cdhash)):
        p.error("provide either a prior Host receipt or --installed with expected source and CDHash")
    if (a.enrolled_spaces_cycle or a.own_spaces_canary or a.preflight_only) and not a.installed:
        p.error("formal Host qualification requires --installed")
    with a.out.open("x"):
        pass
    report = dict(
        schema=2,
        scope="physicalReadOnlyRegisteredWindowMembership",
        osBuild=scope_reader.command("sw_vers", "-buildVersion").strip(),
        observedUTC=datetime.now(timezone.utc).isoformat(),
        runnerSource=scope_reader.command("git", "-C", ROOT, "rev-parse", "HEAD").strip(),
        status="UNKNOWN",
        scopeWindowWrites=0,
        scopeSpaceWrites=0,
        scopePostedInput=0,
        requestedSpacesCycle=a.enrolled_spaces_cycle,
        requestedOwnCanary=a.own_spaces_canary,
        permissionPrompts=0,
        singleWindowHideRestore="NOT_RUN",
        productionQualified=False,
    )
    try:
        run(a, report)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError) as err:
        report.update(status="UNKNOWN", reason=type(err).__name__, error=str(err)[:300])
    finally:
        report["probeResources"] = resources(report)
        report["probeResourcesClear"] = report["safeToRollback"] = report["probeResources"]["clear"]
        a.out.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
