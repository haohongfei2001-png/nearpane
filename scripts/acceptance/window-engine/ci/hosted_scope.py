#!/usr/bin/env python3
"""Record the disposable runner's desktop eligibility. This job never dispatches a window trial."""

import argparse
import json
import os
from pathlib import Path
import pwd
import subprocess
import tempfile
from uuid import UUID

ROOT = Path(__file__).resolve().parents[4]


def requested(event, enabled, message):
    if enabled != "1":
        return False
    if event == "workflow_dispatch":
        return True
    lines = message.rstrip("\n").splitlines()
    return event == "push" and bool(lines) and lines[-1] == "[window-engine-hosted-scope]"


def build_reader(binary):
    return [
        "xcrun",
        "clang",
        "-fobjc-arc",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-I",
        ROOT / "Engine/nearpane-window-engine/src/corner",
        Path(__file__).with_name("hosted-scope.m"),
        "-framework",
        "Foundation",
        "-framework",
        "AppKit",
        "-framework",
        "CoreGraphics",
        "-o",
        binary,
    ]


def uuid(value):
    try:
        parsed = UUID(value) if isinstance(value, str) else None
        return str(parsed) if parsed and parsed.int else None
    except ValueError:
        return None


def stable_display_home(row):
    home = row.get("directWindowServerHome")
    display = uuid(row.get("physicalDisplayUUID"))
    ids = [row[key] for key in ("currentID64", "currentManagedID") if row.get(key) is not None]
    if (
        not display
        or type(home) is not int
        or home <= 0
        or not ids
        or not all(type(n) is int and n == home for n in ids)
        or row.get("singleCGMainDisplay") is not True
        or not row.get("connectionAvailable")
        or not row.get("displayQuerySucceeded")
        or not row.get("inventoryAvailable")
        or any(
            row.get(k) != 1
            for k in ("cgDisplayCount", "appKitScreenCount", "managedDisplayCount", "matchedRecords")
        )
    ):
        return None
    return display, home


def confirmed_space(row, display, home):
    bound = row.get("bound")
    if (
        row.get("reason") != "confirmed"
        or not isinstance(bound, dict)
        or uuid(bound.get("display")) != display
        or bound.get("native") != home
    ):
        return None
    actual = uuid(bound.get("space"))
    matched = False
    for key in ("currentUUID", "matchedUUID"):
        if key not in row or row.get(key + "Field") != ("valid" if row[key] is not None else "missing"):
            return None
        if row[key] is not None:
            if not actual or uuid(row[key]) != actual:
                return None
            matched = True
    return actual if matched else None


def disposition(raw):
    if not isinstance(raw, dict):
        return "UNKNOWN", "invalidReaderOutput"
    if raw.get("status") in ("FAIL", "UNKNOWN"):
        return raw["status"], "readerReported" + raw["status"]
    if raw.get("scope") != "readOnlyHostedDesktop" or raw.get("schema") != 1:
        return "UNKNOWN", "unexpectedReaderProtocol"
    if (
        type(raw.get("systemWrites")) is not int
        or raw["systemWrites"] != 0
        or raw.get("windowTrials") != "NOT_RUN"
    ):
        return "FAIL", "unexpectedActivityOutsideReadOnlyPreflight"
    rows = raw.get("reads")
    if (
        not isinstance(rows, list)
        or len(rows) != 2
        or not all(isinstance(r, dict) for r in rows)
        or [r.get("read") for r in rows] != [1, 2]
        or not all(type(r.get("uptime")) in (int, float) and r["uptime"] > 0 for r in rows)
        or not rows[0]["uptime"] < rows[1]["uptime"]
    ):
        return "UNKNOWN", "twoFreshIndependentReadsRequired"
    if all(r.get("console") is False for r in rows):
        return "BLOCKED", "noUnlockedHostedGUIForRunner"
    if not all(r.get("console") is True for r in rows):
        return "UNKNOWN", "consoleChangedBetweenReads"
    if all(
        r.get("displayQuerySucceeded") is True
        and r.get("cgDisplayCount") == 0
        and r.get("appKitScreenCount") == 0
        for r in rows
    ):
        return "BLOCKED", "noHostedDisplay"
    keys = [stable_display_home(r) for r in rows]
    if not keys[0] or keys[0] != keys[1]:
        return "UNKNOWN", "singleDisplayAndCurrentIDNotIndependentlyStable"
    if (
        rows[0].get("matchedType") == rows[1].get("matchedType")
        and type(rows[0].get("matchedType")) is int
        and rows[0]["matchedType"] > 0
        and all(
            r.get("currentType") in (None, r["matchedType"])
            and r.get("reason") == "currentRecordNotConfirmedOrdinary"
            for r in rows
        )
    ):
        return "BLOCKED", "currentDesktopIsNotOrdinary"
    if not all(
        type(r.get("matchedType")) is int and r["matchedType"] == 0 and r.get("currentType") in (None, 0)
        for r in rows
    ):
        return "UNKNOWN", "desktopTypeUnconfirmed"
    if all(
        r.get("reason") == "currentOrdinaryUUIDUnavailableOrContradictory"
        and r.get("currentUUIDField") == "missing"
        and r.get("matchedUUIDField") == "missing"
        and "currentUUID" in r
        and "matchedUUID" in r
        and r["currentUUID"] is None
        and r["matchedUUID"] is None
        for r in rows
    ):
        return "BLOCKED", "independentOrdinarySpaceUUIDMissingTwice"
    first, second = (confirmed_space(row, *keys[0]) for row in rows)
    if first and first == second:
        return "OBSERVED", "sameOrdinaryDisplaySpaceUUIDInBothReads"
    return "UNKNOWN", "ordinarySpaceIdentityInconclusive"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new evidence directory")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    report = {
        "schema": 1,
        "checkout": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "scope": "hostedEnvironmentOnly",
        "qualificationGranted": False,
        "productTrials": "NOT_RUN",
        "physicalInstalledHost": "NOT_RUN",
        "status": "UNKNOWN",
        "reason": "preflightDidNotComplete",
    }

    def save():
        pending = out / "summary.next"
        pending.write_text(json.dumps(report, indent=2) + "\n")
        pending.replace(out / "summary.json")

    def finish(status, reason):
        report.update(status=status, reason=reason)
        save()
        print(f"Hosted desktop preflight {status} ({reason}). Product trials NOT_RUN.", flush=True)
        return 0 if status in ("BLOCKED", "NOT_RUN", "OBSERVED") else 1

    save()
    event = os.getenv("GITHUB_EVENT_NAME")
    enabled = os.getenv("NP_HOSTED_SCOPE_ONLY")
    message = ""
    if event == "push" and enabled == "1":
        message = subprocess.check_output(["git", "show", "-s", "--format=%B", "HEAD"], cwd=ROOT, text=True)
    if not requested(event, enabled, message):
        return finish("NOT_RUN", "explicitHostedPreflightNotRequested")
    if (
        os.getenv("GITHUB_ACTIONS") != "true"
        or os.getenv("RUNNER_ENVIRONMENT") != "github-hosted"
        or os.getenv("RUNNER_OS") != "macOS"
        or os.getuid() == 0
        or pwd.getpwuid(os.getuid()).pw_name != "runner"
    ):
        return finish("BLOCKED", "disposableGitHubMacRunnerRequired")
    try:
        with tempfile.TemporaryDirectory(prefix="np-readonly-hosted-", dir=os.getenv("RUNNER_TEMP")) as temp:
            binary = Path(temp) / "scope"
            with (out / "build.log").open("x") as stream:
                build = subprocess.run(
                    build_reader(binary), stdout=stream, stderr=subprocess.STDOUT, timeout=90
                )
            report["buildExit"] = build.returncode
            if build.returncode:
                return finish("FAIL", "hostedScopeBuildFailed")
            save()
            with (out / "reads.json").open("x") as raw, (out / "reader-stderr.log").open("x") as err:
                read = subprocess.run([binary], stdout=raw, stderr=err, timeout=12)
            report["readerExit"] = read.returncode
            if read.returncode:
                return finish("UNKNOWN", "hostedReaderDidNotReturnCleanly")
            report["observations"] = "reads.json"
            return finish(*disposition(json.loads((out / "reads.json").read_bytes())))
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        report["error"] = type(exc).__name__
        return finish("UNKNOWN", "hostedEvidenceAcquisitionFailed")


if __name__ == "__main__":
    raise SystemExit(main())
