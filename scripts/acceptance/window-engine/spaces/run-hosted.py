#!/usr/bin/env python3
"""Measure each requested route once in a disposable hosted macOS GUI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def received(rows, code):
    end = rows[-1] if rows else {}
    cleanup = end.get("originalMembershipAndCleanup") is True and end.get("originalSpaceSetRestored") is True
    status = end.get("status", "UNKNOWN")
    passed = status == "OWN_FIXTURE_PASS" and code == 0 and cleanup
    return {
        "status": status if passed or status in ("BLOCKED", "FAIL", "UNKNOWN") else "UNKNOWN",
        "rawStatus": status,
        "exit": code,
        "reason": end.get("reason", "missingTerminalReceipt"),
        "cleanup": cleanup,
        "receipts": sum(row.get("event") == "engineReceipt" for row in rows),
        "target": next((row for row in rows if row.get("event") == "targetPreflight"), None),
    }


def completed(routes, requested):
    return set(routes) == set(requested) and all(
        routes[name]["status"] == "OWN_FIXTURE_PASS"
        and routes[name]["exit"] == 0
        and routes[name]["cleanup"] is True
        for name in requested
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--route", choices=("bridged", "classic", "both"), default="both")
    args = parser.parse_args()
    os.umask(0o077)
    out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    requested = ["bridged", "classic"] if args.route == "both" else [args.route]
    summary = dict(gate="Gate 2", status="BLOCKED", hostedOwnWindowTrial="NOT_RUN",
                   physicalInstalledHost="NOT_RUN", foreignAppAcceptance="NOT_RUN",
                   qualificationGranted=False, requestedRoutes=requested, routes={})

    def save():
        pending = out / "summary.next"
        pending.write_text(json.dumps(summary, indent=2) + "\n")
        pending.replace(out / "summary.json")

    save()
    keys = ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS", "NP_RUN_HOSTED_SPACES_TRIAL")
    if [os.getenv(key) for key in keys] != ["true", "github-hosted", "macOS", "1"]:
        summary["reason"] = "disposableHostedMacOptInRequired"
        save()
        return 2
    work = Path(__file__).resolve().parent
    try:
        archive = args.archive.resolve(strict=True)
        build = subprocess.run([work / "build-fixture.sh", archive, out / "fixture"], check=True,
                               capture_output=True, text=True, timeout=90)
        executable = Path(build.stdout.rstrip()) / "Contents/MacOS/SpacesGate"
        summary["fixtureSHA256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
        summary["archiveSHA256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        for route in requested:
            packet = out / (route + ".jsonl")
            with packet.open("xb") as journal:
                try:
                    proc = subprocess.run([executable, route], stdin=subprocess.DEVNULL, stdout=journal,
                                          stderr=subprocess.DEVNULL, timeout=75)
                    code = proc.returncode
                except subprocess.TimeoutExpired:
                    code = None
            rows = []
            invalid = False
            for line in packet.read_bytes().splitlines():
                try:
                    row = json.loads(line)
                    if not isinstance(row, dict):
                        raise ValueError("malformed lifecycle row")
                    rows.append(row)
                except (ValueError, UnicodeDecodeError):
                    invalid = True
                    break
            report = received(rows, code)
            if code is None or invalid:
                report.update(status="UNKNOWN", cleanup=False,
                              reason="hostedFixtureTimedOut" if code is None else "invalidLifecycleReceipt")
            report["raw"] = packet.name
            summary["routes"][route] = report
            if report["receipts"]:
                summary["hostedOwnWindowTrial"] = "UNCONFIRMED"
            save()
            if report["status"] != "OWN_FIXTURE_PASS":
                summary.update(status=report["status"], reason=report["reason"])
                break
        if completed(summary["routes"], requested):
            summary.update(status="OWN_FIXTURE_PASS", hostedOwnWindowTrial="PASS")
    except (OSError, subprocess.SubprocessError) as error:
        summary.update(status="UNKNOWN", reason=type(error).__name__)
    save()
    return 0 if summary["status"] == "OWN_FIXTURE_PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
