#!/usr/bin/env python3
"""Read the signed Host's physical scope once, before any fixture or window operation."""
import argparse
from contextlib import contextmanager, nullcontext
import fcntl
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import time
import uuid

DAILY = Path("/Applications/Nearpane.app")


def command(*args):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT, timeout=45)


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
    return public_scope({key: observation[key] for key in ("spaceScope", "guardianFixture", "guardianIndependent",
                                                          "installedSpacesFixtureCycle") if key in observation})


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
    while time.monotonic() < deadline:
        try:
            raw = read_private(directory / name, 196608)
        except FileNotFoundError:
            raw = b""
        if raw.endswith(b"\n"):
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


def observe(app, challenge, directory, output, registration=None, enroll=None, expected_image=None,
            spaces_cycle=False, inspect_final=None):
    image = identity(app)
    before = identity(DAILY)
    result = dict(schema=2, scope="oneHostScopeAndEnrolledCycle" if spaces_cycle else "oneHostReadOnlyScope",
                  recordedUTC=datetime.now(timezone.utc).isoformat(),
                  os=command("/usr/bin/sw_vers", "-productVersion").strip(), osBuild=command("/usr/bin/sw_vers", "-buildVersion").strip(),
                  sip=command("/usr/bin/csrutil", "status").strip(), independentSystemSource="sw_vers + csrutil",
                  image=image, dailyBefore=before, scopeWindowWrites=0, scopeSpaceWrites=0, scopeInputEvents=0,
                  productionQualified=False, launchRequested=False, status="BLOCKED")
    try:
        if (expected_image is not None and image != expected_image) or (spaces_cycle and (app != DAILY or not enroll)):
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
        launcher = directory / "launch-scope"
        command("xcrun", "clang", "-fobjc-arc", Path(__file__).with_name("launch-scope.m"),
                "-framework", "AppKit", "-framework", "Security", "-framework", "CoreGraphics", "-o", launcher)
        with exclusive(image["Identifier"]):
            args = [launcher, app, challenge]
            if registration:
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
                    timeout = min(78, deadline - time.monotonic() - 8) if spaces_cycle else 18
                    raw, digest = response(directory, "response.json", timeout)
                    result["responseRawSHA256"] = digest
                    validate(raw, challenge, image, launch, app, result["osBuild"], result["os"], result["sip"])
                    if inspect_final:
                        inspect_final(raw)
                    if pre:
                        confirm_continuity(pre, raw)
                    if (enroll or registration) and "guardianFixture" not in raw:
                        raise ValueError("registered observation lacks the ownership readback")
                    result.update(status="PASS", reason="correlatedReadOnlyObservation", subject=raw["subject"],
                                  permissions=raw["permissions"], system=raw["system"], launch="background Launch Services",
                                  rawSHA256=digest, abi=raw["abi"], permissionSource=raw["permissionSource"],
                                  redaction="Display and Space UUIDs consistently tokenized across each Host report.",
                                  **public_observation(raw))
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
