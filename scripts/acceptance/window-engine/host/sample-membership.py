#!/usr/bin/env python3
"""Compare a physical Host's two membership reads with one ordinary signed app's own AppKit window."""

import argparse
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
            raw = path.read_bytes()
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


def run(a, report):
    if (
        scope_reader.command("sw_vers", "-buildVersion").strip() != "26A428"
        or scope_reader.command("csrutil", "status").strip()
        != "System Integrity Protection status: enabled."
    ):
        report.update(status="BLOCKED", reason="targetMacUnavailable")
        return
    app = a.host.resolve(strict=True)
    image = scope_reader.identity(app)
    pre = json.loads(a.preflight.read_bytes())
    verified = pre.get("subject", {})
    if (
        pre.get("status") != "PASS"
        or pre.get("osBuild") != "26A428"
        or pre.get("spaceScope", {}).get("scope", {}).get("status") != "PASS"
        or not pre.get("permissions", {}).get("accessibility")
        or not pre.get("permissions", {}).get("listenEvent")
        or image["source"] != verified.get("source")
        or image["CDHash"] != verified.get("cdhash")
        or image["Identifier"] != verified.get("identifier")
    ):
        report.update(status="BLOCKED", reason="ordinarySignedHostPreflightRequired")
        return
    report["host"] = image
    challenge = str(uuid.uuid4())
    work = Path("/private/tmp") / ("nearpane-membership." + challenge)
    work.mkdir(mode=0o700)
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
    raw_output = a.out.with_name(a.out.stem + "-host.json")
    if raw_output.exists():
        raise FileExistsError(raw_output)
    first = None
    with (work / "launch.log").open("xb") as log:
        process = subprocess.Popen(
            ["/usr/bin/open", "-g", "-W", "-a", fixture, "--args", "--read-membership", challenge],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        try:
            first = read_when_ready(work / "owner-start.json", process, time.monotonic() + 5)
            report["ownerStart"] = first
            if not eligible(first):
                report.update(status="BLOCKED", reason="backgroundOrdinaryFixtureDidNotEnroll")
                return
            reg = dict(
                pid=first["pid"],
                birth=first["birth"],
                window=first["window"],
                executable=str(exe),
                cdhash=fields["CDHash"],
            )
            registration = work / "registration.json"
            registration.write_text(json.dumps(reg))
            registration.chmod(0o600)
            result = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    HERE / "observe-scope.py",
                    app,
                    raw_output,
                    "--registration",
                    registration,
                ],
                capture_output=True,
                text=True,
                timeout=17,
            )
            (work / "host-launch.log").write_text(result.stdout + result.stderr)
            observed = json.loads(raw_output.read_bytes())
            report["hostReadback"] = raw_output.name
            report["rawHostSHA256"] = observed.get("rawSHA256")
            current = observed.get("spaceScope", {})
            member = current.get("fixtureMembership", {})
            valid = (
                result.returncode == 0
                and observed.get("permissions") == pre.get("permissions")
                and current.get("scope", {}).get("status") == "PASS"
                and all(
                    member.get(k, {}).get("status") == "PASS" for k in ("spaceToWindow", "windowToSpaces")
                )
                and member.get("status") == "PASS"
            )
            report.update(
                status="PASS" if valid else "UNKNOWN",
                reason="ownerAndTwoDirectionalHostReads" if valid else "scopeOrMembershipIncomplete",
            )
        finally:
            (work / "stop").touch(mode=0o600, exist_ok=False)
            last = read_when_ready(work / "owner-closed.json", process, time.monotonic() + 4)
            try:
                exit_code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                exit_code = None
            report.update(ownerEnd=last, launchExit=exit_code)
            for key, file in (
                ("ownerPreflight", "owner-preflight.json"),
                ("ownerSession", "owner-session.json"),
            ):
                if (work / file).is_file():
                    report[key] = json.loads((work / file).read_bytes())
            same = last and first and all(first.get(k) == last.get(k) for k in ("pid", "birth", "window"))
            gone = False
            pid = (first or report.get("ownerPreflight") or {}).get("pid")
            if isinstance(pid, int) and pid > 1:
                found = subprocess.run(
                    ["/bin/ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True
                )
                gone = found.returncode == 1 and not found.stdout.strip() and not found.stderr.strip()
            report["ownedProcessExited"] = gone
            retired = last and same and last["closed"] and last["stopSeen"] and exit_code == 0 and gone
            report["ownerClosed"] = bool(retired)
            if report["status"] == "PASS" and (not retired or not eligible(last)):
                report.update(status="UNKNOWN", reason="owningWindowOrFocusChangedBeforeCleanup")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("host", type=Path)
    p.add_argument("preflight", type=Path)
    p.add_argument("out", type=Path)
    a = p.parse_args()
    with a.out.open("x"):
        pass
    report = dict(
        schema=1,
        scope="physicalReadOnlyRegisteredWindowMembership",
        osBuild=scope_reader.command("sw_vers", "-buildVersion").strip(),
        observedUTC=datetime.now(timezone.utc).isoformat(),
        runnerSource=scope_reader.command("git", "-C", ROOT, "rev-parse", "HEAD").strip(),
        status="UNKNOWN",
        engineWindowWrites=0,
        engineSpaceWrites=0,
        postedInput=0,
        permissionPrompts=0,
        singleWindowHideRestore="NOT_RUN",
        productionQualified=False,
    )
    try:
        run(a, report)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError) as err:
        report.update(status="UNKNOWN", reason=type(err).__name__, error=str(err)[:300])
    finally:
        a.out.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
