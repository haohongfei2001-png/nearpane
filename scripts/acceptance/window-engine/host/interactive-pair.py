#!/usr/bin/env python3
"""One exclusive nonce on the installed NearpaneHost. Leaves an existing app or user session alone."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


scope = module("pair_scope", HERE / "observe-scope.py")
fixture = module("pair_fixture", HERE.parent / "corner/interactive/build.py")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def signed_image(image, revision, pin):
    return (image.get("Identifier") == "com.holdsnow.nearpane.alpha" and image.get("TeamIdentifier") == fixture.TEAM
            and image.get("sourceState") == "clean" and image.get("multipleInstancesProhibited") is True
            and image.get("version") == "5.22" and image.get("build") == "90" and image.get("engineABI") == 1
            and re.fullmatch(r"[a-f0-9]{40}", revision or "") and image.get("source") == revision
            and re.fullmatch(r"[a-f0-9]{40}", image.get("CDHash", "")) and (pin is None or image["CDHash"] == pin))


def may_remove(result):
    if result.get("launchRequested") is False:
        return True
    if result.get("hostExit", {}).get("status") != "PASS":
        return False
    pair = result.get("pair", {})
    return (pair.get("fixtureLaunchRequested") is False or
            (result.get("verifiedUnopenedFixtureExit") is True and pair.get("openRequestAttempted") is False
             and pair.get("cleanup", {}).get("fixtureExited") is True) or
            pair.get("cleanup", {}).get("fixtureExited") is True and
            pair["cleanup"].get("exactWindowsGone") is True and pair["cleanup"].get("ownCloseAcknowledged") is True)


def unopened_exit(row, pair, host, nonce):
    """The signed peer's first-sequence EOF receipt complements the Host's pre-send veto."""
    close_host = row.get("host", {})
    owner = row.get("owner", {})
    return (pair.get("openRequestAttempted") is False and pair.get("cleanup", {}).get("fixtureExited") is True
            and row.get("schema") == 1 and row.get("challenge") == nonce and row.get("op") == "close" and row.get("seq") == 1
            and row.get("reason") == "hostDisconnected" and type(row.get("ownWindowsCreated")) is int
            and row["ownWindowsCreated"] == 0 and row.get("ownWindowsClosed") is True and row.get("beforeClose") == []
            and "unfinished" not in row and owner.get("identifier") == fixture.IDENTIFIER
            and isinstance(owner.get("pid"), int) and owner["pid"] > 1 and owner["pid"] == pair.get("fixturePID")
            and isinstance(owner.get("birth"), int) and owner["birth"] > 0 and owner["birth"] == pair.get("fixtureBirth")
            and isinstance(owner.get("cdhash"), str) and owner["cdhash"] == pair.get("fixtureCDHash")
            and all(key in host and host[key] == close_host.get(key) for key in ("pid", "birth", "cdhash")))


def write(path, value):
    with os.fdopen(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600), "w") as f:
        json.dump(value, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())


def run(args):
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    nonce = str(uuid.uuid4())
    directory = Path("/private/tmp/nearpane-host-scope." + nonce)
    workspace = Path("/private/tmp/nearpane-membership." + nonce)
    created = []
    result = {"schema": 1, "challenge": nonce, "status": "BLOCKED", "launchRequested": False,
              "physicalHitTesting": "NOT_RUN", "actualSystemKeyboardRouting": "NOT_RUN",
              "engineVisibilityRoundTrip": "NOT_RUN", "productionQualified": False}
    try:
        image = scope.identity(scope.DAILY)
        result["installedImage"] = image
        require(signed_image(image, args.revision, args.cdhash), "installedSignedCandidateMismatch")
        with scope.exclusive(image["Identifier"]):
            for path in (directory, workspace):
                path.mkdir(mode=0o700)
                created.append(path)
            launcher = scope.build_launcher(directory)
            roster = json.loads(scope.command(launcher, scope.DAILY, "--roster"))
            require(roster.get("complete") is True and roster.get("pids") == [] and
                    roster.get("session", {}).get("qualified") is True, "existingHostOrUnqualifiedConsole")
            prepared = fixture.prepare(args.kit, nonce)
            signature = prepared["signature"]
            require(signature["identifier"] == fixture.IDENTIFIER and signature["team"] == fixture.TEAM
                    and signature["strictDeveloperIDVerification"] is True, "signedFixtureUnavailable")
            result["fixture"] = signature
            scope.publish(directory, "fixture.json", json.dumps(
                {"kind": "interactiveWindowPair", "challenge": nonce, "cdhash": signature["cdhash"]}).encode())
            version = scope.command("/usr/bin/sw_vers", "-productVersion").strip()
            build = scope.command("/usr/bin/sw_vers", "-buildVersion").strip()
            sip = scope.command("/usr/bin/csrutil", "status").strip()
            require(build == "26A428" and os.uname().machine == "arm64" and
                    sip == "System Integrity Protection status: enabled.", "wrongPhysicalBuildOrSIP")
            if args.preflight_only:
                result.update(status="READY_FOR_HOST_PREFLIGHT", reason="signatureAndConsoleOnly")
                return result
            result["launchRequested"] = None
            exit_subject = {}
            try:
                reply = json.loads(scope.command(launcher, scope.DAILY, nonce, "--interactive-window-pair"))
                require(isinstance(reply, dict), "malformedLaunchServicesReply")
                launch = reply
                prelaunch = launch.get("prelaunch", {})
                if (launch.get("launched") is False and launch.get("exactLaunchPath") is False
                        and type(launch.get("pid")) is int and launch["pid"] == 0
                        and isinstance(prelaunch,dict) and type(prelaunch.get("complete")) is bool
                        and isinstance(prelaunch.get("pids"),list) and isinstance(prelaunch.get("session"),dict)
                        and type(prelaunch["session"].get("qualified")) is bool
                        and (not prelaunch["complete"] or prelaunch["pids"] or not prelaunch["session"]["qualified"])
                        and launch.get("reason") == "singleInstanceOrLoginUnavailable"):
                    result["launchRequested"] = False
                    raise ValueError("singleInstanceOrLoginUnavailable")
                if launch.get("launched") is True:
                    result["launchRequested"] = True
                require(result["launchRequested"] is True and launch.get("exactLaunchPath") is True
                        and type(launch.get("pid")) is int and launch["pid"] > 1
                        and type(launch.get("birth")) is int and launch["birth"] > 0
                        and launch.get("kernelExecutable") == str(scope.DAILY / "Contents/MacOS/NearpaneHost"),
                        "exclusiveInstalledHostNotConfirmed")
                exit_subject = {"pid":launch["pid"],"birth":launch["birth"]}
                scope.publish(directory, "launched")
                pre, _ = scope.response(directory, "preflight.json", 12)
                scope.validate(pre, nonce, image, launch, scope.DAILY, build, version, sip)
                raw, digest = scope.response(directory, "response.json", 84)
                scope.validate(raw, nonce, image, launch, scope.DAILY, build, version, sip)
                require(raw["subject"] == pre["subject"], "hostGenerationChangedDuringTrial")
                pair = raw["interactiveWindowPair"]
                require(pair["productionQualified"] is False and pair["physicalMouseHit"] == "NOT_RUN"
                        and pair["physicalKeyboardRouting"] == "NOT_RUN"
                        and pair["windowEngineRoundTrip"]["status"] == "NOT_RUN", "unsupportedInferenceInHostResponse")
                data = scope.read_private(directory / "response.json", 196608)
                require(hashlib.sha256(data).hexdigest() == digest, "responseChanged")
                scope.publish(args.output, "host-raw.json", data)
                result.update(pair=scope.public_scope(pair), status=pair["status"], rawSHA256=digest,
                              reason=pair.get("reason", "seeHostEvidence"))
                if pair.get("fixtureLaunchRequested") is True and pair.get("openRequestAttempted") is False:
                    try:
                        close = scope.read_private(workspace / "interactive-closed.json", 16384)
                        if unopened_exit(json.loads(close), pair, raw["subject"], nonce):
                            scope.publish(args.output, "unopened-fixture-close.json", close)
                            result["verifiedUnopenedFixtureExit"] = True
                    except (ValueError, OSError, AttributeError, TypeError):
                        pass  # Keep this nonce until the exit and zero-window claims can be corroborated.
            finally:
                if result["launchRequested"] is not False:
                    try:
                        scope.publish(directory, "abort")
                        result["abortPublished"] = True
                    except OSError:
                        result["abortPublished"] = False
                    try:
                        result["hostExit"] = scope.await_exit(launcher, scope.DAILY, exit_subject)
                    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
                        result["hostExit"] = {"status":"UNKNOWN","reason":"exitCensusUnavailable"}
                    if not result["abortPublished"] or result["hostExit"]["status"] != "PASS":
                        result.update(status="UNKNOWN", reason="abortOrHostExitUnconfirmed")
            require(scope.identity(scope.DAILY) == image, "installedImageChanged")
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        result.update(status="BLOCKED" if result["launchRequested"] is False else "UNKNOWN",
                      reason=str(error)[:250])
    finally:
        if may_remove(result):
            for path in reversed(created):
                shutil.rmtree(path)
        else:
            result["retainedNonceDirectories"] = [str(path) for path in created]
        write(args.output / "result.json", result)
    return result


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("output", type=Path, help="new private output directory under an existing parent")
    p.add_argument("--kit", type=Path, required=True, help="signed Interactive Windows fixture kit")
    p.add_argument("--revision", default=subprocess.check_output(["git", "-C", ROOT, "rev-parse", "HEAD"], text=True).strip())
    p.add_argument("--cdhash", help="expected installed candidate CDHash")
    p.add_argument("--preflight-only", action="store_true", help="no Host or fixture launch")
    args = p.parse_args()
    row = run(args)
    print(json.dumps({key: row.get(key) for key in ("status", "reason", "launchRequested")}))
    sys.exit(0 if row["status"] in {"PASS", "READY_FOR_HOST_PREFLIGHT"} else 2)
