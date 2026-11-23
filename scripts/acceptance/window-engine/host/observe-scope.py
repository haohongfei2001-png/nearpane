#!/usr/bin/env python3
"""Read the signed Host's physical scope once, before any fixture or window operation."""
import argparse
from contextlib import closing, contextmanager, ExitStack, nullcontext
import fcntl
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import select
import stat
import subprocess
import time
import uuid

DAILY = Path("/Applications/Nearpane.app")


def command(*args):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT, timeout=45)


def build_launcher(directory):
    launcher = directory / "launch-scope"
    command("xcrun", "clang", "-fobjc-arc", Path(__file__).with_name("launch-scope.m"),
            "-framework", "AppKit", "-framework", "Security", "-framework", "CoreGraphics", "-o", launcher)
    return launcher


def identity(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    command("/usr/bin/codesign", "--verify", "--strict", "--deep", app)
    fields = dict(re.findall(r"^(CDHash|Identifier|TeamIdentifier)=(.+)$", command("/usr/bin/codesign", "-dvvv", app), re.M))
    return dict(fields, version=info["CFBundleShortVersionString"], build=info["CFBundleVersion"],
                source=info.get("NearpaneStageEngineSourceRevision") or info.get("NearpaneSourceRevision"),
                sourceState=info.get("NearpaneStageEngineSourceState"), engineABI=info.get("NearpaneStageEngineABI"),
                multipleInstancesProhibited=info.get("LSMultipleInstancesProhibited", False))


def public_scope(raw):
    """Preserve equality across raw API fields and both samples without publishing stable hardware identifiers."""
    identifiers = {}
    pattern = re.compile(r"(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b")
    def redact(x):
        if isinstance(x, dict):
            return {k: redact(v) for k, v in x.items()}
        if isinstance(x, list):
            return [redact(v) for v in x]
        if isinstance(x, str):
            return pattern.sub(lambda m: identifiers.setdefault(m.group().upper(), f"uuid-{len(identifiers)+1}"), x)
        return x
    return redact(raw)


def public_observation(observation):
    # One token table for the whole Host response. Both samplers use the same physical identities.
    result = public_scope({key: observation[key] for key in ("spaceScope", "postCanarySpaceScope", "canaryMissionControl", "guardianFixture", "guardianIndependent",
                                                            "installedSpacesFixtureCycle","installedSpacesCanary") if key in observation})
    # This nonce is issued by the runner for one invocation. Only restore the
    # verified field itself; a display or Space UUID elsewhere must stay redacted.
    for key in ("installedSpacesCanary", "installedSpacesFixtureCycle"):
        if key in result and "challenge" in observation[key]:
            if not isinstance(observation[key]["challenge"], str):
                raise ValueError("invalid engine invocation challenge")
            nonce = uuid.UUID(observation[key]["challenge"])
            if nonce != uuid.UUID(observation["challenge"]):
                raise ValueError("engine receipt belongs to another Host invocation")
            result[key]["challenge"] = str(nonce)
    return result


CHECKS = {"accessibility", "listenEvent", "postEvent", "screenCapture"}


@contextmanager
def exclusive(identifier):
    if identifier not in {"com.holdsnow.nearpane.host", "com.holdsnow.nearpane.alpha"}:
        raise ValueError("unexpected bundle identifier")
    path = Path("/private/tmp") / f"nearpane-host-observation-{os.getuid()}-{identifier}.lock"
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not (stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
                and info.st_uid == os.getuid() and info.st_nlink == 1):
            raise ValueError("unsafe observation lock")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)  # Keep one stable inode for all observing processes.


def publish(directory, name, payload=b""):
    # The Host never sees a partially written registration or acknowledgment.
    part = directory / (name + ".next")
    fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    if (directory / name).exists():
        raise FileExistsError(name)
    part.rename(directory / name)


def read_private(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(fd)
        if not (stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600 and info.st_uid == os.getuid()
                and info.st_nlink == 1 and info.st_size <= limit):
            raise ValueError("unsafe private receipt")
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError("receipt grew during read")
        return data


def response(directory, name, seconds):
    deadline = time.monotonic() + seconds
    # The Guardian fsyncs a private file and atomically renames it without a newline.
    atomic_guardian = name == "guardian-post-exit.json"
    while time.monotonic() < deadline:
        try:
            raw = read_private(directory / name, 4095 if atomic_guardian else 196608)
        except FileNotFoundError:
            pass
        else:
            if atomic_guardian or raw.endswith(b"\n"):
                return json.loads(raw), hashlib.sha256(raw).hexdigest()
        time.sleep(.04)
    raise TimeoutError("missing Host " + name)


def validate(raw, challenge, image, launch, app, os_build, version, sip):
    subject = raw["subject"]
    system = raw["system"]
    components = [int(v) for v in version.split(".")]
    components += [0] * (3 - len(components))
    executable = (app / "Contents/MacOS/NearpaneHost").resolve(strict=False)
    if not (raw["schema"] == 2 and raw["abi"] == image["engineABI"] == 1
            and str(uuid.UUID(raw["challenge"])) == challenge
            and subject["identifier"] == image["Identifier"] and subject["cdhash"] == image["CDHash"]
            and subject["teamIdentifier"] == image["TeamIdentifier"] == "ZB9D4T66QB"
            and subject["source"] == image["source"] and subject["sourceState"] == image["sourceState"] == "clean"
            and subject["version"] == image["version"] and subject["build"] == image["build"]
            and subject["atDailyInstallPath"] is (app == DAILY)
            and launch["exactLaunchPath"] is True and launch["launched"] is True
            and subject["pid"] == launch["pid"] > 1 and subject["birth"] == launch["birth"] > 0
            and Path(subject["kernelExecutable"]).resolve() == Path(launch["kernelExecutable"]).resolve() == executable
            and system["version"] == components and system["build"] == os_build
            and set(raw["permissions"]) == CHECKS and all(type(value) is bool for value in raw["permissions"].values())
            and raw["permissionSource"] == "Host/self nonprompt preflight"):
        raise ValueError("Host identity, authority or system correlation failed")
    state = system["sip"]
    if (state.get("status") != "OBSERVED" or type(state.get("bits")) is not int or state.get("returnCode") != 0
            or state.get("source") != "Host/csr_get_active_config"):
        raise ValueError("Host SIP posture unavailable")
    if (state.get("enabled") is not (state["bits"] == 0) or
            (sip == "System Integrity Protection status: enabled." and not state["enabled"]) or
            (sip == "System Integrity Protection status: disabled." and state["enabled"])):
        raise ValueError("SIP readers disagree")
    pre, live = launch["prelaunch"], launch["postlaunch"]
    if not (pre["complete"] is True and pre["pids"] == [] and live["complete"] is True and live["pids"] == [subject["pid"]]
            and pre["session"] == live["session"] and live["session"]["qualified"] is True
            and live["session"]["securitySessionID"] > 0):
        raise ValueError("unconfirmed single instance or console session")
    scope = raw["spaceScope"]
    if (len(scope["samples"]) != 2 or scope["readOnly"] is not True or scope["spaceWrites"] or scope["windowWrites"]
            or any(s["hostPID"] != subject["pid"] or s["hostBirth"] != subject["birth"] or s["session"]["qualified"] is not True
                   or s["session"]["securitySessionID"] != live["session"]["securitySessionID"] for s in scope["samples"])):
        raise ValueError("unstable Host, physical login, or incomplete readback")


def confirm_continuity(first, final):
    if (first["subject"] != final["subject"] or first["permissions"] != final["permissions"]
            or first["system"] != final["system"] or first["spaceScope"]["scope"] != final["spaceScope"]["scope"]
            or first["spaceScope"]["samples"][-1]["display"] != final["spaceScope"]["samples"][0]["display"]):
        raise ValueError("Host, permissions, system, display or Space changed after registration")


def await_exit(launcher, app, launch):
    end = time.monotonic() + 3
    while True:
        roster = json.loads(command(launcher, app, "--roster"))
        if roster["complete"] is True and not roster["pids"]:
            return dict(status="PASS", sameIdentifierRunning=0, pid=launch.get("pid", 0), birth=launch.get("birth", 0))
        if time.monotonic() >= end:
            return dict(status="UNKNOWN", reason="nonemptyOrIncompleteRoster", lastRoster=roster)
        time.sleep(.06)


# Darwin sys/event.h: NOTE_EXIT | NOTE_EXITSTATUS. The latter has no Python constant.
EXIT_STATUS_FLAGS = 0x80000000 | 0x04000000


def arm_exit_status(queue, pid):
    queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                 flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                 fflags=EXIT_STATUS_FLAGS)], 0, 0)


def read_exit_status(queue, pid):
    try:
        events = queue.control([], 1, 1)
    except OSError as error:
        return {"pid": pid, "status": "UNKNOWN", "kernelError": error.errno}
    if len(events) == 1:
        event = events[0]
        if (event.ident == pid and event.filter == select.KQ_FILTER_PROC and not event.flags & select.KQ_EV_ERROR
                and event.fflags & EXIT_STATUS_FLAGS == EXIT_STATUS_FLAGS and 0 <= event.data <= 0xffff):
            return {"pid": pid, "fflags": event.fflags, "waitStatus": event.data,
                    "status": "PASS" if event.data == 0 else "FAIL"}
    return {"pid": pid, "status": "UNKNOWN"}


def guardian_survival_result(row, host, nonce, exited):
    """Only a read-only retained-object drill. A PASS here cannot admit a hide or a restore."""
    watch = host.get("guardianIndependent", {})
    evidence = watch.get("evidence") or {}
    child, parent = evidence.get("guardian", {}), evidence.get("host", {})
    expected = {"hostPID": parent.get("pid"), "hostBirth": parent.get("birth"), "hostHash": parent.get("cdhash"),
                "childPID": child.get("pid"), "childBirth": child.get("birth"), "childHash": child.get("cdhash")}
    def frame(value):
        return isinstance(value, list) and len(value) == 4 and all(type(n) in (int, float) and abs(n) < 1e9 for n in value) and min(value[2:]) > 0
    pre = evidence.get("samples", [])
    termination = exited.get("kernelTermination") or {}
    def measured(key):
        rect = pre[-1].get(key) if pre and isinstance(pre[-1], dict) else None
        if not isinstance(rect, dict):
            return []
        return [rect.get(k) for k in ("x", "y", "width", "height")]
    if not (isinstance(row, dict) and isinstance(pre, list) and watch.get("postExitWatchArmed") is True and watch.get("mayPark") is False
            and evidence.get("matchesHostRegisteredGeometry") is True and len(pre) == 2
            and str(row.get("challenge", "")).lower() == str(nonce).lower() == str(evidence.get("challenge", "")).lower()
            and all(v and row.get(k) == v for k, v in expected.items())
            and host.get("subject", {}).get("pid") == parent.get("pid") == exited.get("pid")
            and host["subject"].get("birth") == parent.get("birth") == exited.get("birth") and exited.get("status") == "PASS"
            and host["subject"].get("cdhash") == parent.get("cdhash")
            and termination.get("pid") == exited["pid"] and termination.get("status") == "PASS"
            and type(termination.get("waitStatus")) is int and termination["waitStatus"] == 0
            and type(termination.get("fflags")) is int
            and termination["fflags"] & EXIT_STATUS_FLAGS == EXIT_STATUS_FLAGS
            and all(evidence.get(k) and row.get(k) == evidence[k] for k in ("window", "fixtureHash", "nativeID", "display", "space"))
            and row.get("schema") == 1 and row.get("scope") == "readOnlyOriginalObjectAcrossHostExit"
            and row.get("mayPark") is False and all(type(row.get(k)) is int and row[k] == 0 for k in ("windowWrites", "spaceWrites"))):
        return "UNKNOWN"
    # A signed, correlated negative measurement is different from a lost or contradictory receipt.
    if not (row.get("kernelExit") is True and row.get("inputStable") is True and row.get("originalReleased") is True
            and frame(measured("ax")) and frame(measured("cg"))
            and measured("ax") == row.get("originalAX") and measured("cg") == row.get("originalCG")
            and row.get("responsibleBefore") == evidence.get("responsibleAfter")
            and row.get("responsibleBefore") in (parent["pid"], child["pid"])
            and type(row.get("responsibleAfter")) is int):
        return "UNKNOWN"
    if row.get("status") == "UNKNOWN" and row.get("exactOriginalRetained") is False and row.get("geometryReturned") is False:
        if type(row.get("sampleCode")) is int:
            if (row.get("postExitAXTrusted") is False and row["sampleCode"] == -1
                    and row.get("firstPostReadNS") == row.get("secondPostReadNS") == 0
                    and row.get("postAX") == row.get("postCG") == [0, 0, 0, 0]):
                return "FAIL"
            # Observation ABI v1 returns nonzero for invalid arguments or a failed identity/signature read.
            if row.get("postExitAXTrusted") is True and row["sampleCode"] in (1, 2):
                return "FAIL"
    if row["responsibleAfter"] <= 0:
        return "UNKNOWN"
    flags = ("kernelExit", "postExitAXTrusted", "exactOriginalRetained", "geometryReturned", "inputStable", "originalReleased")
    timing = (all(type(row.get(k)) is int for k in ("firstPostReadNS", "secondPostReadNS"))
              and type(evidence.get("ended")) is int and 0 < evidence["ended"] < row["firstPostReadNS"] < row["secondPostReadNS"])
    frames = all(frame(row.get(k)) for k in ("originalAX", "originalCG", "postAX", "postCG"))
    returned = row.get("originalAX") == row.get("postAX") and row.get("originalCG") == row.get("postCG")
    sampled = type(row.get("sampleCode")) is int and row["sampleCode"] == 0
    if (row.get("status") == "UNKNOWN" and row.get("geometryReturned") is False and not returned
            and row.get("postExitAXTrusted") is True and row.get("exactOriginalRetained") is True and timing and frames and sampled):
        return "FAIL"
    valid = row.get("status") == "PASS" and all(row.get(k) is True for k in flags) and sampled and timing and frames and returned
    return "PASS" if valid else "UNKNOWN"


def await_guardian_exit(pid):
    if type(pid) is not int or pid <= 1:
        return False
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)  # existence query only
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        time.sleep(.04)
    return False


def observe(app, challenge, directory, output, registration=None, enroll=None, expected_image=None,
            spaces_cycle=False, inspect_final=None, own_canary=False, guardian_survival=False):
    image = identity(app)
    before = identity(DAILY)
    result = dict(schema=2, scope="ownPanelOnly" if own_canary else "oneHostScopeAndEnrolledCycle" if spaces_cycle else "oneHostReadOnlyScope",
                  recordedUTC=datetime.now(timezone.utc).isoformat(),
                  os=command("/usr/bin/sw_vers", "-productVersion").strip(), osBuild=command("/usr/bin/sw_vers", "-buildVersion").strip(),
                  sip=command("/usr/bin/csrutil", "status").strip(), independentSystemSource="sw_vers + csrutil",
                  image=image, dailyBefore=before, scopeWindowWrites=0, scopeSpaceWrites=0, scopeInputEvents=0,
                  productionQualified=False, launchRequested=False, status="BLOCKED")
    try:
        if ((expected_image is not None and image != expected_image) or (spaces_cycle and (app != DAILY or not enroll))
                or (own_canary and (app != DAILY or expected_image is None or registration or enroll or spaces_cycle))
                or (guardian_survival and (app != DAILY or expected_image is None or not enroll or spaces_cycle or own_canary or registration))):
            result["reason"] = "pinnedImageOrRegisteredSessionUnavailable"
            return result
        if image["engineABI"] != 1 or image["sourceState"] != "clean":
            result["reason"] = "installedImageDoesNotContainCleanScopeCapableEngine"
            return result
        if (image["Identifier"] not in {"com.holdsnow.nearpane.host", "com.holdsnow.nearpane.alpha"}
                or image["TeamIdentifier"] != "ZB9D4T66QB" or (app == DAILY and (image["Identifier"] != "com.holdsnow.nearpane.alpha"
                or image["multipleInstancesProhibited"] is not True))):
            result["reason"] = "expectedProductSignatureUnavailable"
            return result
        launcher = build_launcher(directory)
        with exclusive(image["Identifier"]), ExitStack() as resources:
            if guardian_survival:
                publish(directory, "guardian-survival.request")
            args = [launcher, app, challenge]
            if own_canary:
                args.append("--installed-spaces-canary")
            elif registration:
                publish(directory, "fixture.json", read_private(registration, 4096))
                args.append("--registered-window")
            elif enroll:
                args.append("--await-registered-window")
                if spaces_cycle:
                    args.append("--enrolled-spaces-cycle")
            deadline = time.monotonic() + 90
            result["launchRequested"] = None  # A lost launcher reply cannot prove non-delivery.
            launch = json.loads(command(*args))
            result["launchRequested"] = launch.get("launched")
            result["launchServices"] = launch
            if not launch["exactLaunchPath"] or launch["pid"] <= 0:
                result["reason"] = launch.get("reason", "launchServicesDidNotStartRequestedHost")
                if launch.get("launched"):
                    publish(directory, "abort")
                    result["hostExit"] = await_exit(launcher, app, launch)
                else:
                    result["hostExit"] = dict(status="NOT_RUN", reason="noLaunchRequested")
                return result
            try:
                if guardian_survival:
                    # Arm before the nonce-bound preflight from the very same process generation.
                    # A later empty roster alone cannot distinguish normal termination from a crash.
                    queue = resources.enter_context(closing(select.kqueue()))
                    try:
                        arm_exit_status(queue, launch["pid"])
                    except OSError as error:
                        result.update(reason="hostNormalExitObserverUnavailable", kernelError=error.errno,
                                      postExitGuardian={"status": "BLOCKED", "childStarted": False, "readerExited": True})
                        return result
                publish(directory, "launched")
                pre = None
                if enroll:
                    pre, digest = response(directory, "preflight.json", 7)
                    result["preflightRawSHA256"] = digest
                    validate(pre, challenge, image, launch, app, result["osBuild"], result["os"], result["sip"])
                    result["preflight"] = dict(subject=pre["subject"], permissions=pre["permissions"], system=pre["system"],
                                               rawSHA256=digest, **public_observation(pre))
                with (enroll(pre) if enroll else nullcontext()) as registration_data:
                    if enroll:
                        if not registration_data:
                            result["reason"] = "signedFixtureNotAdmitted"
                            return result
                        publish(directory, "fixture.json", registration_data)
                    timeout = min(78, deadline - time.monotonic() - 8) if spaces_cycle or own_canary else 18
                    raw, digest = response(directory, "response.json", timeout)
                    result["responseRawSHA256"] = digest
                    validate(raw, challenge, image, launch, app, result["osBuild"], result["os"], result["sip"])
                    if inspect_final:
                        inspect_final(raw)
                    if pre:
                        confirm_continuity(pre, raw)
                    if (enroll or registration) and not spaces_cycle and "guardianFixture" not in raw:
                        raise ValueError("registered observation lacks the ownership readback")
                    result.update(status="PASS", reason="correlatedReadOnlyObservation", subject=raw["subject"],
                                  permissions=raw["permissions"], system=raw["system"], launch="background Launch Services",
                                  rawSHA256=digest, abi=raw["abi"], permissionSource=raw["permissionSource"],
                                  redaction="Display and Space UUIDs consistently tokenized across each Host report.",
                                  **public_observation(raw))
                    if guardian_survival:
                        # Keep the fixture alive until after the signed diagnostic Host naturally exits.
                        probe = raw.get("guardianIndependent", {})
                        if probe.get("postExitWatchArmed") is True:
                            exited = await_exit(launcher, app, launch)
                            exited["kernelTermination"] = read_exit_status(queue, launch["pid"])
                            child = probe["evidence"]["guardian"]["pid"]
                            continuation = {"status": "UNKNOWN", "readerExited": False}
                            result["postExitGuardian"] = continuation
                            try:
                                terminal, digest = response(directory, "guardian-post-exit.json", 10)
                                continuation.update(status=guardian_survival_result(terminal, raw, challenge, exited),
                                                    raw=public_scope(terminal), receiptSHA256=digest, hostExit=exited)
                            finally:
                                continuation["readerExited"] = await_guardian_exit(child)
                                if not continuation["readerExited"]:
                                    continuation["status"] = "UNKNOWN"
                        else:
                            result["postExitGuardian"] = {"status": "BLOCKED", "reason": "retainedOriginalWatchNotArmed",
                                "readerExited": probe.get("childExit") == 0, "childStarted": probe.get("evidence") is not None}
            finally:
                publish(directory, "abort")
                result["hostExit"] = await_exit(launcher, app, launch)
                if result["hostExit"]["status"] != "PASS":
                    result.update(status="UNKNOWN", reason="hostExitUnconfirmed")
    except BlockingIOError:
        result.update(status="BLOCKED", reason="observationAlreadyOwned")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        result.update(status="UNKNOWN", reason=type(error).__name__, error=str(error)[:320])
    finally:
        result["dailyAfter"] = identity(DAILY)
        if result["dailyAfter"] != before:
            result.update(status="UNKNOWN", reason="dailyImageChanged")
        output.write_text(json.dumps(result, indent=2)+"\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--registration", type=Path, help="private registration issued for a signed test window")
    a = parser.parse_args()
    app = a.app.resolve(strict=True)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    # A fresh path prevents a failed read from overwriting an earlier result.
    with a.output.open("x"):
        pass
    challenge = str(uuid.uuid4())
    directory = Path("/private/tmp") / ("nearpane-host-scope." + challenge)
    directory.mkdir(mode=0o700)
    try:
        result = observe(app, challenge, directory, a.output, a.registration)
    except (KeyError, OSError, subprocess.SubprocessError, ValueError) as error:
        prior = json.loads(a.output.read_text() or "{}")
        prior.update(status="UNKNOWN", reason=type(error).__name__, error=str(error)[:320])
        a.output.write_text(json.dumps(prior, indent=2)+"\n")
        return 2
    print(directory)
    return 0 if result["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
