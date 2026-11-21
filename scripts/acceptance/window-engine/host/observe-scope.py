#!/usr/bin/env python3
"""Read the signed Host's physical scope once, before any fixture or window operation."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
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
    return public_scope({key: observation[key] for key in ("spaceScope", "guardianFixture") if key in observation})


def observe(app, challenge, directory, output, registration=None):
    image = identity(app)
    before = identity(DAILY)
    result = dict(schema=1, scope="oneHostReadOnly", recordedUTC=datetime.now(timezone.utc).isoformat(),
                  os=command("sw_vers", "-productVersion").strip(), osBuild=command("sw_vers", "-buildVersion").strip(),
                  sip=command("csrutil", "status").strip(), image=image, dailyBefore=before, spaceWrites=0,
                  windowWrites=0, inputEvents=0, productionQualified=False, status="BLOCKED")
    try:
        if image["engineABI"] != 1 or image["sourceState"] != "clean":
            result["reason"] = "installedImageDoesNotContainCleanScopeCapableEngine"
            return result
        if image["Identifier"] not in {"com.holdsnow.nearpane.host", "com.holdsnow.nearpane.alpha"} or image["TeamIdentifier"] != "ZB9D4T66QB":
            result["reason"] = "expectedProductSignatureUnavailable"
            return result
        launcher = directory / "launch-scope"
        command("xcrun", "clang", "-fobjc-arc", Path(__file__).with_name("launch-scope.m"), "-framework", "AppKit", "-o", launcher)
        args = [launcher, app, challenge]
        if registration:
            with registration.open("rb") as stream:
                content = stream.read(4097)
            if not 0 < len(content) <= 4096:
                raise ValueError("invalid registration size")
            fd = os.open(directory / "fixture.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(content)
            args.append("--registered-window")
        launch = json.loads(command(*args))
        result["launchServices"] = launch
        if not launch["exactLaunchPath"] or launch["pid"] <= 0:
            result["reason"] = "launchServicesDidNotStartRequestedHost"
            return result
        stdout = directory / "response.json"
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if stdout.is_file() and stdout.read_bytes().endswith(b"\n"):
                break
            time.sleep(.05)
        raw = stdout.read_bytes()
        observation = json.loads(raw)
        subject = observation["subject"]
        if (str(uuid.UUID(observation["challenge"])) != challenge or subject["identifier"] != image["Identifier"]
                or subject["cdhash"] != image["CDHash"] or subject["source"] != image["source"]
                or subject["pid"] != launch["pid"] or subject["sourceState"] != "clean"
                or subject["atDailyInstallPath"] != (app == DAILY)):
            raise ValueError("scope response could not be linked to the requested signed image")
        scope = observation["spaceScope"]
        if (len(scope["samples"]) != 2 or not scope["readOnly"] or scope["spaceWrites"] or scope["windowWrites"]
                or any(s["hostPID"] != subject["pid"] or s["hostBirth"] != subject["birth"] for s in scope["samples"])):
            raise ValueError("scope samples came from different or incomplete Host observations")
        result.update(status="PASS", reason="correlatedReadOnlyObservation", subject=subject, permissions=observation["permissions"],
                      launch="background Launch Services", rawSHA256=hashlib.sha256(raw).hexdigest(), abi=observation["abi"],
                      redaction="Display/Space UUIDs consistently tokenized in the public copy.", **public_observation(observation))
        if registration and "guardianFixture" not in result:
            raise ValueError("registered observation lacks the ownership readback")
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
