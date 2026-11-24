#!/usr/bin/env python3
"""Compare a physical Host's two membership reads with one ordinary signed app's own AppKit window."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import uuid
import membership_trace
import overview_admission

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
import candidate_signing

spec = importlib.util.spec_from_file_location("host_scope", HERE / "observe-scope.py")
scope_reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope_reader)
spec = importlib.util.spec_from_file_location("spaces_journal", HERE.parent / "spaces/inspect-installed-journal.py")
journal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(journal)


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


def eligible(row, survival=False):
    return (
        row
        and row["regularApplication"]
        and row["ordinaryWindow"]
        and row["visible"]
        and row["onActiveSpace"]
        and row["window"] > 0
        and row["sameFront"]
        and not any(row[k] for k in ("active", "key", "main"))
        and row["alpha"] == (1 if survival else 0)
        and row["ignoresMouseEvents"] is (not survival)
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


def internal_survival_gates(pre, *, guardian=True):
    # The first signed v1 reader boxed Darwin Boolean as the JSON integer 0 or 1.
    # Treat other numeric values, strings and missing fields as unmeasured.
    principal = pre.get("guardianPrincipal") or {}
    value = principal.get("accessibility")
    ax = ("PASS" if value == 1 else "BLOCKED") if type(value) in (bool, int) and value in (0, 1) else "UNKNOWN"
    host = pre["subject"]
    child = principal.get("pid")
    signed_child = (type(child) is int and child > 1 and child != host["pid"] and
                    principal.get("hostPID") == host["pid"] and principal.get("hostBirth") == host["birth"] and
                    principal.get("hostHash") == host["cdhash"] and
                    principal.get("identifier") == "com.holdsnow.nearpane.host.corner-guardian")
    scope = pre["spaceScope"]
    continuity = pre.get("survivalContinuity", {})
    focus = continuity.get("currentFocus", {})
    gates = dict(
        ordinaryDesktop=scope["scope"].get("status", "UNKNOWN"),
        singleDisplayConsole="PASS" if len(scope["samples"]) == 2 and all(s["session"]["qualified"] and
            s["display"]["topologyConfirmed"] and s["display"]["activeCGCount"] == 1 for s in scope["samples"]) else "BLOCKED",
        targetSystem="PASS" if pre["system"]["build"] == "26A428" and pre["system"]["sip"].get("enabled") is True else "BLOCKED",
        hostAccessibility="PASS" if pre["permissions"].get("accessibility") is True else "BLOCKED",
        originalFocus="PASS" if focus.get("sameOriginalAX") is True else "UNKNOWN",
        quietHID="PASS" if continuity.get("inputQuiet") is True else "BLOCKED")
    if guardian:
        gates.update(guardianAccessibility=ax if signed_child else "UNKNOWN",
                     guardianResponsibility="PASS" if signed_child and principal.get("responsiblePID") in (child, host["pid"]) else "UNKNOWN")
    return gates


def corroborate_corner_read(report, native_id):
    result = report.get("cornerWindowReadback") or {}
    owner = report.get("ownerStart") or {}
    publication = report.get("ownerPublication") or {}
    published = publication.get("first") or {}
    frame = published.get("frame") or []
    rows = result.get("reads") or []
    return bool(result.get("status") == "PASS" and result.get("handleClosed") is True and result.get("writes") == 0
                and result.get("signedCDHash") == (report.get("fixture") or {}).get("CDHash") and result.get("signedCDHash")
                and all(result.get(key) == owner.get(key) and owner.get(key) for key in ("pid", "birth", "window"))
                and published == publication.get("second") and published.get("pid") == owner["pid"]
                and published.get("window") == owner["window"] and len(frame) == 4 and native_id
                and publication.get("secondUptime", 0) > publication.get("firstUptime", 0) > 0
                and len(rows) == 2 and rows[1].get("uptimeNS", 0) > rows[0].get("uptimeNS", 0) > 0
                and all(row.get("birthAndSigner") is True and row.get("owned") == row.get("detail") == row.get("status") == 0
                        and row.get("flags") == 45 and row.get("nativeID") == native_id and len(row.get("frame") or []) == 4
                        and all(math.isclose(a, b, rel_tol=0, abs_tol=.75) for a, b in zip(frame, row["frame"])) for row in rows))


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
        *(["-DNP_SURVIVAL_WINDOW=1"] if report.get("requestedGuardianSurvival") or report.get("cornerReadbackRequested") or report.get("visibleRecoveryRequested") else []),
        *(["-DNP_VISIBLE_RECOVERY_WINDOW=1", "-framework", "Security"] if report.get("visibleRecoveryRequested") else []),
        *(["-DNP_FIXTURE_VISUAL_WINDOW=1", "-framework", "QuartzCore"] if report.get("fixturePixelWitnessRequested") else []),
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
def registered_window(pre, challenge, work, fixture, exe, digest, report, reader=None):
    corner = report.get("cornerReadbackRequested") is True
    visible_recovery = report.get("visibleRecoveryRequested") is True
    internal = report.get("internalGuardianSurvival") is True or corner or visible_recovery
    if internal:
        gates = internal_survival_gates(pre, guardian=not corner)
        report["admissionChecks"] = gates
        if any(status != "PASS" for status in gates.values()):
            report["fixtureAdmission"] = "ordinaryFixtureAdmissionIncomplete"
            yield None
            return
        work.mkdir(mode=0o700)
        fixture, exe, digest = prepare_fixture(work, report)
    elif not preflight_allows(pre):
        report["fixtureAdmission"] = "HostScopeOrOwnAuthorizationUnavailable"
        yield None
        return
    survival = report.get("requestedGuardianSurvival") is True or corner or visible_recovery
    if survival:
        guard = pre.get("survivalContinuity", {})
        if guard.get("inputQuiet") is not True or guard.get("currentFocus", {}).get("sameOriginalAX") is not True:
            report["fixtureAdmission"] = "foregroundOrHIDChanged"
            yield None
            return
    first = None
    with (work / "launch.log").open("xb") as log:
        args = ["/usr/bin/open", "-g", "-W", "-a", fixture, "--args", "--read-membership", challenge]
        if report["requestedSpacesCycle"]:
            args.append("--enrolled-spaces-cycle")
        elif survival:
            args.append("--visible-recovery" if visible_recovery else "--ordinary-window" if corner else "--guardian-survival")
        report["fixtureLaunchRequested"] = True
        process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
        try:
            first = read_when_ready(work / "owner-start.json", process, time.monotonic() + 5)
            report["ownerStart"] = first
            if report.get("fixturePixelWitnessRequested"):
                drawing = read_when_ready(work / "owner-drawing.json", process, time.monotonic() + 1)
                report["ownerDrawing"] = drawing
                if (not isinstance(drawing, dict) or drawing.get("layerPublished") is not True
                        or drawing.get("width") != 220 or drawing.get("height", 0) < 80):
                    report["fixtureAdmission"] = "ownerMarkerSurfaceUnavailable"
                    yield None
                    return
            if not eligible(first, survival):
                report["fixtureAdmission"] = "backgroundOrdinaryFixtureDidNotEnroll"
                yield None
            else:
                report["fixtureAdmission"] = "registeredSignedBackgroundWindow"
                registration = json.dumps(dict(pid=first["pid"], birth=first["birth"], window=first["window"],
                                               executable=str(exe), cdhash=digest)).encode()
                if report["requestedSpacesCycle"]:
                    baseline = read_fixture(reader, challenge, first, digest)
                    report["independentBefore"] = baseline
                    if baseline["status"] != "PASS":
                        report["fixtureAdmission"] = "independentFocusDockOrMembershipUnavailable"
                        yield None
                        return
                    home = baseline["scope"]["nativeID"]
                    with membership_trace.observe(reader, work, challenge, first, digest, home, report) as ready:
                        if not ready:
                            report["fixtureAdmission"] = "independentTraceCouldNotBind"
                            yield None
                            return
                        report.update(backendSafeToRollback=False, retainedForRecovery=True)
                        yield registration
                else:
                    yield registration
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
                for key, file in (("ownerPreflight","owner-preflight.json"), ("ownerSession","owner-session.json"),
                                  ("ownerPublication","owner-published.json"), ("fixtureDisplaced","owner-displaced.json"),
                                  ("fixtureRestored","owner-returned.json"), ("visibleGuardianReceipt","guardian-receipt.json"),
                                  ("visibleGuardianPrepare","guardian-prepared.json")):
                    if (work / file).is_file():
                        value = json.loads(scope_reader.read_private(work / file, 16384))
                        report[key] = scope_reader.public_scope(value) if key.startswith("visibleGuardian") else value
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


def confirmed_desktops(observed):
    """Both paired Host samplers must agree on every desktop and its display before and after."""
    original = observed.get("spaceScope", {}).get("scope")
    subject = observed.get("subject", {})
    scopes = [observed.get("spaceScope", {}), observed.get("postCanarySpaceScope", {})]
    order = None
    for scope in scopes:
        samples = scope.get("samples")
        if (not original or original.get("status") != "PASS" or scope.get("scope") != original
                or scope.get("readOnly") is not True or scope.get("workspace", {}).get("notificationsObserved") != 0
                or not isinstance(samples, list) or len(samples) != 2):
            return None
        for sample in samples:
            if (sample.get("hostPID") != subject.get("pid") or sample.get("hostBirth") != subject.get("birth")
                    or sample.get("directCurrent") != original["nativeID"] or sample.get("directCurrentAfter") != original["nativeID"]
                    or sample.get("session") != scopes[0]["samples"][0].get("session")
                    or sample.get("display") != scopes[0]["samples"][0].get("display")):
                return None
            rows = sample.get("managedRows")
            if not isinstance(rows, list) or len(rows) != 1:
                return None
            row = rows[0]
            desktops = row.get("orderedDesktops")
            if not isinstance(desktops, list) or not desktops or row.get("rosterCount") != len(desktops):
                return None
            ids = []
            for item in desktops:
                number = item.get("id64") if item.get("id64") is not None else item.get("managedID")
                if (type(number) is not int or number <= 0 or item.get("managedID") not in (None, number)
                        or type(item.get("type")) is not int or not item.get("uuid") or item.get("malformed") is not False):
                    return None
                ids.append(number)
            if len(set(ids)) != len(ids) or ids.count(original["nativeID"]) != 1:
                return None
            if order is not None and order != rows:
                return None
            order = rows
    return ids


def released_before_dispatch(observed, archive, challenge):
    """Recognize the terminal open/close-only path. This cannot qualify a backend."""
    c, subject = observed.get("installedSpacesCanary", {}), observed.get("subject", {})
    exit_proof = observed.get("hostExit", {})
    if not (observed.get("status") == "PASS" and c.get("status") == "UNKNOWN"
            and c.get("challenge") == challenge and c.get("trial") == archive.get("scopeOfTrial") == "ownPanelOnly"
            and archive.get("challenge") == challenge and archive.get("status") == "ARCHIVED_CLEAN"
            and c.get("engineInvoked") is True and c.get("safeToRollback") is True and c.get("canaryUnresolved") is False
            and all(type(c.get(k)) is int and c[k] == v for k, v in (("heldSpaces", 0), ("heldWindows", 0), ("endInventoryAndFocusReads", 2)))
            and exit_proof.get("status") == "PASS" and exit_proof.get("sameIdentifierRunning") == 0
            and exit_proof.get("pid") == subject.get("pid") == archive.get("hostPID")
            and exit_proof.get("birth") == subject.get("birth") == archive.get("hostBirth")
            and c.get("fixture", {}).get("status") == "NOT_RUN"):
        return False
    for part in ("canary", "fixture"):
        counts = c.get(part, {}).get("dispatchAttempts")
        if not isinstance(counts, dict) or set(counts) != {"create", "hide", "return", "destroy"} or not all(
                type(v) is int and v == 0 for v in counts.values()):
            return False
    desktops = confirmed_desktops(observed)
    actions = archive.get("knownActions")
    if not desktops or desktops != archive.get("managedDesktopIDs") or not isinstance(actions, list) or len(actions) != 5:
        return False
    if not all(isinstance(row, dict) for row in actions):
        return False
    window = actions[1].get("window")
    if type(window) is not int or window <= 0:
        return False
    expected = [("willOpenCanary", 0, 0), ("openedCanaryResponse", window, 1), ("willCloseCanary", window, 0),
                ("closedCanaryResponse", window, 1), ("terminalClean", 0, 1)]
    previous = archive.get("startUptime")
    for row, (event, target, response) in zip(actions, expected):
        now = row.get("uptime")
        if (row.get("event") != event or row.get("owner") != "installedHostCanary" or
            any(type(row.get(k)) is not int or row[k] != v for k, v in (("window", target), ("space", 0), ("response", response))) or
            type(now) not in (float, int) or type(previous) not in (float, int) or not math.isfinite(now) or
            not math.isfinite(previous) or previous < 0 or now < previous):
            return False
        previous = now
    return True


def panel_actions(window, home, parking):
    return [
        ("willOpenCanary", 0, 0, 0), ("openedCanaryResponse", window, 0, 1),
        ("willCreateSpace", 0, 0, 0), ("createdSpaceResponse", 0, parking, 1),
        ("willHideWindow", window, parking, 0), ("hideResponse", window, parking, 1),
        ("twoMembershipReads", window, parking, 1),
        ("willReturnWindow", window, home, 0), ("returnResponse", window, home, 1),
        ("twoMembershipReads", window, home, 0),
        ("willCloseCanary", window, 0, 0), ("closedCanaryResponse", window, 0, 1),
        ("willDestroySpace", 0, parking, 0), ("destroyResponse", 0, parking, 1),
        ("canaryFullyRecovered", window, parking, 1), ("terminalClean", 0, 0, 1),
    ]


def panel_archive(observed, challenge):
    """Read the specific Host's durable archive only after its correlated response."""
    verdict = panel_verdict(observed, challenge)
    if verdict != "PASS":
        canary = observed.get("installedSpacesCanary", {})
        scope = observed.get("spaceScope", {}).get("scope", {})
        reason = scope.get("reason") if canary.get("engineInvoked") is False else canary.get("reason")
        result = dict(status=verdict, archiveRead=False, reason=reason or "hostCycleNotConfirmed")
        if canary.get("status") == "UNKNOWN" and canary.get("safeToRollback") is True:
            try:
                archived = journal.inspect(uuid.UUID(challenge))
                same_boot = uuid.UUID(archived.pop("boot")) == uuid.UUID(scope_reader.command("sysctl", "-n", "kern.bootsessionuuid").strip())
                result.update(archiveRead=True, archive=archived, sameBoot=same_boot,
                              releasedBeforeDispatch=same_boot and released_before_dispatch(observed, archived, challenge))
            except (OSError, KeyError, ValueError, TypeError, subprocess.SubprocessError):
                pass
        return result
    try:
        archive = journal.inspect(uuid.UUID(challenge))
    except (OSError, KeyError, ValueError, IndexError, TypeError) as error:
        return dict(status="UNKNOWN", archiveRead=False, reason="cycleArchiveUnavailable", error=type(error).__name__)
    # Boot UUID is needed locally to reject replay, never included in the public receipt.
    boot = archive.pop("boot", None)
    try:
        same_boot = uuid.UUID(boot) == uuid.UUID(scope_reader.command("/usr/sbin/sysctl", "-n", "kern.bootsessionuuid").strip())
    except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
        same_boot = False
    panel = observed["installedSpacesCanary"]["canary"]
    window, home, parking = (panel[k] for k in ("window", "originalSpace", "parkingID"))
    def whole(value):
        return type(value) is int and value > 0
    def clock(value):
        return type(value) in (float, int) and math.isfinite(value) and value >= 0
    before, managed = archive.get("initialSpaceInventory"), archive.get("managedDesktopIDs")
    origin = (archive.get("status") == "ARCHIVED_CLEAN" and same_boot and archive.get("challenge") == challenge
              and archive.get("scopeOfTrial") == "ownPanelOnly"
              and all(whole(archive.get(k)) and archive[k] == observed["subject"].get(s)
                      for k, s in (("hostPID", "pid"), ("hostBirth", "birth")))
              and all(type(archive.get(k)) is int and archive[k] == 0 for k in ("fixturePID", "fixtureBirth", "fixtureWindow"))
              and archive.get("originalSpace") == home and archive.get("originalFrame", False) is None
              and all(isinstance(ids, list) and all(whole(i) for i in ids)
                      and ids.count(home) == 1 and parking not in ids for ids in (before, managed))
              and len(set(managed)) == len(managed) and set(managed) <= set(before)
              and confirmed_desktops(observed) == managed)
    expected = panel_actions(window, home, parking)
    actions, previous = archive.get("knownActions"), archive.get("startUptime")
    matched = 0
    if origin and clock(previous) and isinstance(actions, list):
        for row, target in zip(actions, expected):
            if not isinstance(row, dict):
                break
            fields = tuple(row.get(k) for k in ("event", "window", "space", "response"))
            now = row.get("uptime")
            if (row.get("owner") != "installedHostCanary" or fields != target
                    or any(type(number) is not int for number in fields[1:]) or not clock(now) or now < previous):
                break
            previous = now
            matched += 1
    proven = origin and matched == len(expected) and len(actions) == len(expected)
    return dict(status="PASS" if proven else "UNKNOWN", archiveRead=True, sameBoot=same_boot,
                matchedActions=matched, expectedActions=len(expected), archive=archive,
                reason="boundPanelJournal" if proven else "incompleteOrConflictingPanelJournal")


def fixture_archive(observed, challenge, report, expected_trial="ownPanelAndEnrolledWindow"):
    """Reopen the completed Rust write-ahead journal independently of the Host transport."""
    try:
        archive = journal.inspect(uuid.UUID(challenge))
        same_boot = uuid.UUID(archive.pop("boot")) == uuid.UUID(scope_reader.command("/usr/sbin/sysctl", "-n", "kern.bootsessionuuid").strip())
        cycle, subject, owner = observed["installedSpacesFixtureCycle"], observed["subject"], report["ownerStart"]
        doc, panel = cycle["fixture"], cycle["canary"]
        window, home, parking = doc["window"], doc["homeID"], doc["parkingID"]
        canary = panel_actions(panel["window"], home, panel["parkingID"])[:-1]
        external = [
            ("willCreateSpace", 0, 0, 0), ("createdSpaceResponse", 0, parking, 1),
            ("willHideWindow", window, parking, 0), ("hideResponse", window, parking, 1),
            ("twoMembershipReads", window, parking, 1), ("willReturnWindow", window, home, 0),
            ("returnResponse", window, home, 1), ("twoMembershipReads", window, home, 0),
            ("willDestroySpace", 0, parking, 0), ("destroyResponse", 0, parking, 1),
            ("fixtureFullyRecovered", window, parking, 1),
        ]
        expected = ([("installedHostCanary", *event) for event in canary] +
                    [("signedOrdinaryFixture", *event) for event in external] +
                    [("installedHostCanary", "terminalClean", 0, 0, 1)])
        actions = archive["knownActions"]
        actual = [tuple(row[k] for k in ("owner","event","window","space","response")) for row in actions]
        times = [archive["startUptime"]] + [row["uptime"] for row in actions]
        origin = (same_boot and cycle["challenge"] == challenge == archive["challenge"] and
                  archive["status"] == "ARCHIVED_CLEAN" and archive["scopeOfTrial"] == expected_trial and
                  archive["hostPID"] == subject["pid"] and archive["hostBirth"] == subject["birth"] and
                  all(archive[k] == doc[s] == owner[s] for k, s in
                      (("fixturePID","pid"), ("fixtureBirth","birth"), ("fixtureWindow","window"))) and
                  archive["originalFrame"] == doc["originalCGAndAXFrame"] and archive["originalSpace"] == home and
                  home in archive["initialSpaceInventory"] and parking not in archive["initialSpaceInventory"] and
                  archive["managedDesktopIDs"] == [r["managedID"] for r in report["independentBefore"]["samples"][0]["managedRows"][0]["orderedDesktops"]])
        matched = origin and actual == expected and all(math.isfinite(n) for n in times) and times == sorted(times)
        return dict(status="PASS" if matched else "UNKNOWN", archive=archive, sameBoot=same_boot,
                    expectedActions=len(expected), observedActions=len(actions))
    except (OSError, ValueError, TypeError, AttributeError, KeyError, IndexError, subprocess.SubprocessError) as err:
        return dict(status="UNKNOWN", reason="fixtureArchiveUnconfirmed", error=type(err).__name__)


def independent_pair(before, after):
    try:
        if not all(r["status"] == "PASS" and r["scope"]["status"] == "PASS" and
                   r["membership"]["status"] == "PASS" and len(r["samples"]) == 2 for r in (before, after)):
            return False
        return (before["axFrame"] == before["cgFrame"] == after["axFrame"] == after["cgFrame"] and
                before["scope"] == after["scope"] and before["dock"] == after["dock"] and
                all(before["focus"][k] == after["focus"][k] for k in ("workspacePID", "birth", "cgWindowID")) and
                all(s["managedRows"] == before["samples"][0]["managedRows"] for s in before["samples"] + after["samples"]))
    except (KeyError, TypeError, IndexError):
        return False


def finish_membership_cycle(work, report):
    """The pinned fixture is transparent, ignores the mouse and never takes key focus."""
    trace = membership_trace.evaluate(work, report)
    report["independentMigration"] = trace
    verified = (trace["status"] == "PASS" and independent_pair(report.get("independentBefore"), report.get("independentAfter"))
                and report.get("fixtureJournal", {}).get("status") == "PASS")
    report["thirdPartyMembershipRoundTrip"] = "PASS" if verified else "UNKNOWN"
    if trace["status"] == "FAIL":
        report["thirdPartyMembershipRoundTrip"] = "FAIL"
    report["singleWindowHideRestore"] = "NOT_RUN"
    if not verified:
        report.update(status=report["thirdPartyMembershipRoundTrip"], reason="independentWindowDockFocusInventoryOrJournalUnconfirmed")
    else:
        report["reason"] = "transparentRegisteredMembershipRestored"


def read_fixture(reader, challenge, owner, digest):
    try:
        data = subprocess.check_output([reader,"--registered",challenge,str(owner["pid"]),str(owner["birth"]),
                                        str(owner["window"]),digest], timeout=6)
        return json.loads(data)
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as err:
        return dict(status="UNKNOWN", reason=type(err).__name__)


def overview_verdict(witness, expected):
    if not isinstance(witness, dict) or not isinstance(expected, list) or not expected:
        return "UNKNOWN"
    if witness.get("status") in ("BLOCKED", "FAIL", "UNKNOWN"):
        return witness["status"]
    counts = witness.get("tileCounts")
    totals = {"inputEventsPosted": 0, "presentations": 1, "dismissals": 1, "expectedCount": len(expected)}
    return "PASS" if (witness.get("status") == "PASS" and witness.get("stage") == "afterCanary"
                      and witness.get("restored") is True
                      and all(type(witness.get(k)) is int and witness[k] == count for k, count in totals.items()) and isinstance(counts, list)
                      and len(counts) == 2 and all(type(n) is int and n == len(expected) for n in counts)) else "UNKNOWN"


def own_panel_first(a, report):
    # Reuse the formal installed path, including its own launch/exit census. An archive
    # supplied by a caller never authorizes a later external action.
    path = a.out.with_name(a.out.stem + "-own-panel.json")
    with path.open("x"):
        pass
    own = dict(requestedOwnCanary=True, requestedSpacesCycle=False, productionQualified=False,
               osBuild=report["osBuild"], scope="physicalInstalledHostOwnPanelOnly", status="UNKNOWN")
    try:
        run(argparse.Namespace(**(vars(a) | dict(out=path, own_spaces_canary=True, enrolled_spaces_cycle=False))), own)
    finally:
        own["probeResources"] = resources(own)
        path.write_text(json.dumps(own, indent=2) + "\n")
        report["ownPanelPredecessor"] = dict(receipt=path.name, status=own["status"], challenge=own.get("challenge"),
            rawHostSHA256=own.get("rawHostSHA256"),
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(), resourcesClear=own["probeResources"]["clear"],
            missionControlUI=own.get("missionControlUI","NOT_RUN"))
    return own["status"] == "PASS" and own["probeResources"]["clear"] and own.get("missionControlUI") == "PASS"


def run(a, report):
    if a.installed and (a.enrolled_spaces_cycle or a.own_spaces_canary):
        try:
            p0, digest = overview_admission.load_receipt(getattr(a, "p0_receipt", None))
            host = p0.get("host", {})
            allowed = (digest == a.p0_sha256 and overview_admission.qualifies(
                p0, {"source": a.expected_source, "cdhash": a.expected_cdhash}, host.get("pid"), host.get("birth")))
        except (OSError, ValueError, TypeError, AttributeError):
            allowed = False
        if not allowed:
            report.update(status="BLOCKED", reason="physicalP0EvidenceRequiredBeforeAnyCanary")
            return
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
        if getattr(a, "internal_survival", False):
            admitted = (scope_reader.internal_survival_image(app, image) and os.uname().machine == "arm64"
                        and scope_reader.command("sw_vers", "-productVersion").strip() == "27.0"
                        and a.expected_source == image["source"] and a.expected_cdhash == image["CDHash"])
        else:
            admitted = legacy_matches(json.loads(a.preflight.read_bytes()), image)
    if getattr(a, "visible_recovery", False) and image.get("visibleFixtureRecoveryProtocol") != 1:
        admitted = False
    if getattr(a, "abrupt_visible_exit", False) and image.get("abruptFixtureExitProtocol") != 1:
        admitted = False
    if not admitted:
        report.update(status="BLOCKED", reason="installedImageOrPriorHostReceiptMismatch")
        return
    if a.enrolled_spaces_cycle:
        subprocess.run(["bash", HERE / "build-overview-witness.sh", a.independent_reader.parent], check=True, timeout=180)
        if not own_panel_first(a, report):
            report.update(status=report["ownPanelPredecessor"]["status"], reason="standalonePanelOrVisibleSystemStripNotConfirmed",
                          membershipStatus="NOT_RUN")
            if report["status"] == "PASS":
                report["status"] = "UNKNOWN"
            return
        # A newly started daily instance or replaced bundle invalidates the preceding launch.
        readiness = inspect_launch(scope_reader.identity(app), a.expected_source, a.expected_cdhash)
        report["afterCanaryLaunchReadiness"] = readiness
        if readiness["status"] != "PASS":
            report.update(status=readiness["status"], reason="launchConditionsChangedAfterCanary", membershipStatus="NOT_RUN")
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
        archived = panel_archive(observed, challenge)
        overview = observed.get("canaryMissionControl", {})
        visible = overview_verdict(overview, confirmed_desktops(observed)) if archived["status"] == "PASS" else "NOT_RUN"
        report.update(hostLaunchRequested=observed.get("launchRequested"), hostExit=observed.get("hostExit"),
                      preexistingSameID=observed.get("launchServices", {}).get("prelaunch", {}).get("pids", []),
                      subject=observed.get("subject"), permissions=observed.get("permissions"),
                      canary=observed.get("installedSpacesCanary"), rawHostSHA256=observed.get("rawSHA256"),
                      membershipStatus="NOT_RUN", panelJournal=archived, status=visible if archived["status"] == "PASS" else archived["status"],
                      missionControlUI=visible, overviewObservation=overview, thirdPartyWindow="NOT_RUN")
        report["reason"] = (observed.get("reason") if observed.get("status") != "PASS" else
                            overview.get("reason","visibleSystemStripUnconfirmed") if archived["status"] == "PASS" else archived["reason"])
        return
    work = Path("/private/tmp") / ("nearpane-membership." + challenge)
    if getattr(a, "internal_survival", False):
        fixture = exe = digest = None
    else:
        work.mkdir(mode=0o700)
        fixture, exe, digest = prepare_fixture(work, report)
    def enroll(pre):
        if a.enrolled_spaces_cycle:
            prior = report["ownPanelPredecessor"]
            nonce = str(uuid.UUID(prior["challenge"]))
            previous = scope_reader.read_private(Path("/private/tmp") / ("nearpane-host-scope." + nonce) / "response.json", 196608)
            if hashlib.sha256(previous).hexdigest() != prior["rawHostSHA256"]:
                raise ValueError("standalone Host response changed before fixture admission")
            prior_scope = json.loads(previous)["postCanarySpaceScope"]
            current = pre["spaceScope"]
            if (current["scope"] != prior_scope["scope"] or any(
                    current["samples"][0].get(key) != prior_scope["samples"][-1].get(key)
                    for key in ("session","display","managedRows"))):
                raise ValueError("console, display or managed Spaces changed before fixture admission")
        return registered_window(pre, challenge, work, fixture, exe, digest, report, getattr(a,"independent_reader",None))
    def inspect_final(raw):
        if a.enrolled_spaces_cycle:
            cycle = raw.get("installedSpacesFixtureCycle", {})
            report["backendSafeToRollback"] = cycle.get("safeToRollback") is True
            report["retainedForRecovery"] = not report["backendSafeToRollback"]
            report["spacesCycleStatus"] = cycle.get("status", "UNKNOWN")
            if cycle.get("status") == "PASS" and report["backendSafeToRollback"] and report.get("ownerStart"):
                report["independentAfter"] = read_fixture(a.independent_reader, challenge, report["ownerStart"], digest)
                report["fixtureJournal"] = fixture_archive(raw, challenge, report)
    report["hostObservationStarted"] = True
    observed = scope_reader.observe(app, challenge, channel, raw_output, enroll=enroll, expected_image=image,
                                    spaces_cycle=a.enrolled_spaces_cycle, inspect_final=inspect_final,
                                    guardian_survival=getattr(a, "guardian_survival", False),
                                    corner_readback=getattr(a, "corner_readback", False),
                                    visible_recovery=getattr(a, "visible_recovery", False),
                                    abrupt_visible_exit=getattr(a, "abrupt_visible_exit", False), visual_observer=getattr(a, "visual_observer", None))
    report["hostLaunchRequested"] = observed.get("launchRequested")
    report["preexistingSameID"] = observed.get("launchServices", {}).get("prelaunch", {}).get("pids", [])
    if getattr(a, "guardian_survival", False) or getattr(a, "visible_recovery", False):
        report["postExitGuardian"] = observed.get("postExitGuardian", {"status": "NOT_RUN"})
    source = observed if observed.get("subject") else observed.get("preflight", {})
    if getattr(a, "corner_readback", False):
        report["cornerParkAccess"] = (observed.get("preflight") or {}).get("cornerParkAccess")
        report["cornerWindowReadback"] = observed.get("cornerWindowReadback") or {"status": "NOT_RUN"}
        if getattr(a, "visual_observer", None):
            report["fixturePixelWitness"] = observed.get("fixturePixelWitness") or {"status":"NOT_RUN"}
            report["fixtureVisualPeer"] = observed.get("fixtureVisualPeer")
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
    elif not report.get("ownerClosed") or not eligible(report.get("ownerEnd"), getattr(a, "guardian_survival", False) or getattr(a, "corner_readback", False) or getattr(a, "visible_recovery", False)):
        report.update(status="UNKNOWN", reason="owningWindowOrFocusChangedBeforeCleanup")
    else:
        report.update(status="PASS", reason="oneHostOwnerAndTwoDirectionalHostReads")
    report["membershipStatus"] = report["status"]
    if getattr(a, "corner_readback", False):
        end = observed.get("survivalContinuity") or {}
        report["ownerCorroboratesProductReads"] = corroborate_corner_read(report, current.get("scope", {}).get("nativeID"))
        if report["status"] == "PASS" and (not report["ownerCorroboratesProductReads"] or
                end.get("inputQuiet") is not True or (end.get("currentFocus") or {}).get("sameOriginalAX") is not True):
            report.update(status="UNKNOWN", reason="productReadOrOriginalInputUnconfirmed")
    elif not a.enrolled_spaces_cycle:
        guardian = observed.get("guardianIndependent") or {}
        evidence = guardian.get("evidence") or {}
        report["guardianReadback"] = {k: guardian.get(k) for k in ("status","reason","childExit","park","mayPark","crashRecovery")}
        report["guardianReadback"]["temporaryRetention"] = evidence.get("temporaryRetention", "NOT_RUN")
    if getattr(a, "guardian_survival", False) and report["status"] == "PASS":
        report["status"] = report["postExitGuardian"].get("status", "UNKNOWN")
        report["reason"] = "postExitReadOnlyOriginalObject"
    if getattr(a, "visible_recovery", False):
        terminal = report.get("visibleGuardianReceipt") or {}
        report["scopeWindowWrites"] = terminal.get("issued")
        report["fixtureSelfMoves"] = 1 if report.get("fixtureDisplaced") else 0
        if report["status"] == "PASS":
            report["status"] = report["postExitGuardian"].get("status", "UNKNOWN")
            original = (report.get("ownerPublication") or {}).get("first")
            ended = report.get("fixtureRestored")
            displaced = report.get("fixtureDisplaced") or {}
            if (not original or ended != original or displaced.get("window") != original.get("window")
                    or displaced.get("pid") != original.get("pid") or displaced.get("frame") != terminal.get("displaced")
                    or terminal.get("original") != original.get("frame") or not report.get("visibleGuardianPrepare")):
                report["status"] = "UNKNOWN"
            report["reason"] = "visibleFixtureAfterHostExitAndIndependentOwnerRead"
    if getattr(a, "visual_observer", None) and report["status"] == "PASS":
        visual = report["fixturePixelWitness"]
        peer = report.get("fixtureVisualPeer") or {}
        if (peer.get("exit") != 0 or peer.get("socketRetired") is not True or
                (visual.get("status") == "PASS" and (visual.get("observerCDHash") != peer.get("cdhash") or
                 visual.get("raw", {}).get("observerPID") != peer.get("pid")))):
            report.update(status="UNKNOWN",reason="visualPeerIdentityOrExit")
        elif visual.get("status") in ("PASS", "FAIL", "BLOCKED", "UNKNOWN"):
            report.update(status=visual["status"],reason=visual.get("raw",{}).get("reason",visual.get("reason")))
        else:
            report.update(status="UNKNOWN",reason="registeredFixtureWasNotMeasured")
    if a.enrolled_spaces_cycle and report.get("spacesCycleStatus") != "PASS":
        report.update(status=report.get("spacesCycleStatus", "UNKNOWN"), reason="enrolledCycleRequiresSeparatePositiveReceipt")

    if a.enrolled_spaces_cycle and report["status"] == "PASS":
        finish_membership_cycle(work, report)


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
        canary = report.get("canary") or {}
        if (canary.get("engineInvoked") is False and canary.get("status") == "BLOCKED"
                and canary.get("reason") == "hostScopeOrRegistrationChanged" and canary.get("safeToRollback") is True):
            backend = "NOT_RUN"
        else:
            ledger = report.get("panelJournal", {})
            backend = "PASS" if ledger.get("status") == "PASS" or ledger.get("releasedBeforeDispatch") is True else "UNKNOWN"
    elif report["requestedSpacesCycle"] and report.get("fixtureAdmission") == "registeredSignedBackgroundWindow":
        backend = "PASS" if report.get("backendSafeToRollback") is True else "UNKNOWN"
    overview = report.get("overviewObservation", {})
    overview_clear = (not report.get("requestedOwnCanary") or backend == "NOT_RUN" or overview.get("restored") is True)
    watch = report.get("postExitGuardian")
    reader_clear = (not (report.get("requestedGuardianSurvival") or report.get("visibleRecoveryRequested")) or not report.get("fixtureLaunchRequested")
                    or (watch is not None and watch.get("readerExited") is True))
    preceding = report.get("ownPanelPredecessor")
    return dict(candidateExit=host, registeredWindowExit=fixture, backendCleanup=backend,
                clear=all(state in {"PASS", "NOT_RUN"} for state in (host, fixture, backend))
                and reader_clear and overview_clear and (preceding is None or preceding["resourcesClear"] is True))




def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("host", type=Path)
    p.add_argument("preflight", type=Path, nargs="?", help="existing Host receipt for legacy comparison mode")
    p.add_argument("out", type=Path)
    p.add_argument("--guardian-survival", action="store_true", help="observe one retained original after the diagnostic Host exits normally")
    p.add_argument("--internal-survival", "--internal-host", action="store_true", help="use the sealed internal Host independently of the installed process")
    p.add_argument("--visible-recovery", action="store_true", help="one on-screen fixture self-move and a guarded return after Host exit")
    p.add_argument("--abrupt-visible-exit", action="store_true", help="in the sealed internal fixture drill, exit without Host cleanup")
    p.add_argument("--corner-readback", action="store_true", help="read the real registered window twice through the shipping Corner worker")
    p.add_argument("--visual-observer", type=Path, help="already-authorized signed QA observer, limited to the nonce fixture")
    p.add_argument("--installed", action="store_true", help="bind the standard installed Alpha using the supplied release fingerprints")
    p.add_argument("--expected-source")
    p.add_argument("--expected-cdhash")
    p.add_argument("--p0-receipt", type=Path, help="private physical P0 receipt checked before the sole regular Host quit")
    p.add_argument("--p0-sha256", help="digest bound by the installed-stage supervisor")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--preflight-only", action="store_true", help="inspect the signed candidate, standard installation and process roster without launching either app")
    mode.add_argument("--own-spaces-canary", action="store_true", help="cycle only the installed Host's own panel, without preparing a fixture")
    mode.add_argument("--enrolled-spaces-cycle", action="store_true", help="also request the separately scoped installed fixture operation")
    a = p.parse_args()
    if a.abrupt_visible_exit and not (a.internal_survival and a.visible_recovery):
        p.error("--abrupt-visible-exit requires the internal signed visible fixture")
    if a.visual_observer and not (a.internal_survival and a.corner_readback):
        p.error("--visual-observer requires the sealed internal --corner-readback")
    if (sum((a.installed, a.internal_survival, bool(a.preflight))) != 1 or
            ((a.installed or a.internal_survival) and not (a.expected_source and a.expected_cdhash)) or
            (a.internal_survival and sum((a.guardian_survival, a.corner_readback, a.visible_recovery)) != 1)
            or ((a.corner_readback or a.visible_recovery) and not a.internal_survival)):
        p.error("choose one pinned installed/internal Host or a prior read-only receipt")
    if (a.enrolled_spaces_cycle or a.own_spaces_canary or a.preflight_only) and not a.installed:
        p.error("formal Host qualification requires --installed")
    if a.guardian_survival and (not (a.installed or a.internal_survival) or a.own_spaces_canary or a.enrolled_spaces_cycle or a.preflight_only):
        p.error("Guardian continuation requires a pinned read-only fixture session")
    with a.out.open("x"):
        pass
    report = dict(
        schema=2,
        scope="visibleFixtureDisplacementAndGuardedReturn" if a.visible_recovery else "physicalReadOnlyRegisteredWindowMembership",
        osBuild=scope_reader.command("sw_vers", "-buildVersion").strip(),
        observedUTC=datetime.now(timezone.utc).isoformat(),
        runnerSource=scope_reader.command("git", "-C", ROOT, "rev-parse", "HEAD").strip(),
        status="UNKNOWN",
        scopeWindowWrites=0,
        scopeSpaceWrites=0,
        scopePostedInput=0,
        requestedSpacesCycle=a.enrolled_spaces_cycle,
        requestedOwnCanary=a.own_spaces_canary,
        requestedGuardianSurvival=a.guardian_survival,
        visibleRecoveryRequested=a.visible_recovery,
        abruptVisibleExitRequested=a.abrupt_visible_exit,
        internalGuardianSurvival=a.internal_survival and a.guardian_survival,
        cornerReadbackRequested=a.corner_readback,
        fixturePixelWitnessRequested=bool(a.visual_observer),
        permissionPrompts=0,
        thirdPartyMembershipRoundTrip="NOT_RUN",
        singleWindowHideRestore="NOT_RUN",
        productionQualified=False,
    )
    try:
        if a.enrolled_spaces_cycle:
            with tempfile.TemporaryDirectory(prefix="nearpane-overview.",dir="/private/tmp") as scratch:
                # Build the observer only after the supervisor supplied a passing, fresh P0 receipt.
                a.independent_reader = Path(scratch) / "fixture-readback"
                run(a, report)
        else:
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
