#!/usr/bin/env python3
"""Read-only routing preflight. A staged signature, TCC grant and delivered Service are distinct facts."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys

from acceptance import identity
from installed_profile import APP, CACHES, PROFILE, owns_profile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
from candidate_signing import gate

BUNDLE = "com.holdsnow.nearpane.alpha"
MESSAGE = "translateNearpaneSelection"
MENU = "在 Nearpane 翻译选词"


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def bundle_identity(app, revision):
    require(app.is_absolute() and app == app.resolve(strict=True) and app.name == "Nearpane.app",
            "Enter the real, absolute Nearpane.app path")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], capture_output=True, check=True)
    gate.verify_install_identity(app)
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    code = identity(app)
    require(code["Identifier"] == BUNDLE and code["TeamIdentifier"] == gate.PRODUCT_SIGNING_TEAM and
            re.fullmatch(r"[0-9a-f]{40,64}", code["CDHash"] or "") and
            info.get("CFBundleIdentifier") == BUNDLE and info.get("CFBundleExecutable") == "NearpaneHost" and
            info.get("CFBundleShortVersionString") == "5.22" and info.get("CFBundleVersion") == "90" and
            info.get("LSMultipleInstancesProhibited") is True and info.get("NearpaneSourceState") == "clean" and
            re.fullmatch(r"[0-9a-f]{40}", info.get("NearpaneSourceRevision", "")), "Unexpected signed product identity")
    host = (contents / "MacOS/NearpaneHost").read_bytes()
    services = [s for s in info.get("NSServices", []) if s.get("NSMessage") == MESSAGE]
    declared = len(services) == 1 and services[0].get("NSMenuItem", {}).get("default") == MENU and (
        services[0].get("NSPortName") == info.get("CFBundleName"))
    return {"path": str(app), "source": info["NearpaneSourceRevision"], "expectedSource": revision,
            "sourceMatches": info["NearpaneSourceRevision"] == revision, "version": "5.22", "build": "90",
            "team": code["TeamIdentifier"], "cdhash": code["CDHash"], "singleInstance": True,
            "hostSHA256": hashlib.sha256(host).hexdigest(), "declaresService": declared,
            "declaresAppleEvents": bool(info.get("NSAppleEventsUsageDescription")),
            "p3GrantOnlyProbePackaged": b"draft-qualification-read-only-v1" in host,
            "p4RequestBoundPanelPackaged": b"nearpane-translation-content-" in host}


def system_snapshot(app):
    # Read only the current user's executable paths; restrict output to the product and never read process arguments.
    processes = subprocess.check_output(["/bin/ps", "-U", str(os.getuid()), "-ww", "-o", "pid=,comm="], text=True)
    candidates = []
    for row in processes.splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and fields[1].endswith("/Contents/MacOS/NearpaneHost"):
            candidates.append(fields[0])
    reader = Path(__file__).with_name("installed-route.swift")
    raw = subprocess.check_output(["/usr/bin/swift", reader, app, *candidates], timeout=25)
    return json.loads(raw)


def services(directory, app):
    # pbs's description format uses an eight-space opening line for each top-level provider.
    blocks = re.split(r"(?m)^        \{\s*$", directory)
    require(directory.startswith("(\n") and directory.rstrip().endswith(")") and len(blocks) > 1,
            "Unrecognized macOS Service directory format")
    matching = []
    for record in blocks[1:]:
        decoded = re.sub(r"\\U([a-fA-F0-9]{4})", lambda m: chr(int(m[1], 16)), record)
        by_message = re.search(r"(?m)^        NSMessage = \"?translateNearpaneSelection\"?;$", decoded) is not None
        by_menu = re.search(r'(?m)^\s+(?:default|\w+) = "' + re.escape(MENU) + r'";$', decoded) is not None
        if by_message or by_menu:
            bundle = re.search(r'(?m)^        NSBundleIdentifier = "([^"]+)";$', decoded)
            path = re.search(r'(?m)^        NSBundlePath = "([^"]+)";$', decoded)
            matching.append({"message": by_message, "menu": by_menu, "identifier": bool(bundle and bundle[1] == BUNDLE),
                             "selectedPath": bool(path and path[1] == str(app)),
                             "canonicalPath": bool(path and path[1] == str(APP))})
    return matching


def read_service_directory(app):
    raw = subprocess.check_output(["/System/Library/CoreServices/pbs", "-dump_pboard"], text=True, timeout=12)
    return services(raw, app)


def private_home(raw):
    require(raw.is_absolute() and raw == raw.resolve(strict=True) and raw.name == "home" and raw.parent.parent == CACHES
            and raw.parent.name.startswith("nearpane-native-acceptance."), "Expected the existing isolated acceptance home")
    for directory in (raw.parent, raw):
        info = directory.stat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077,
                "Isolated acceptance directory ownership changed")
    lock = raw / PROFILE / "writer.lock"
    require(lock.resolve(strict=True) == lock and lock.is_file() and lock.stat().st_uid == os.getuid(),
            "Missing isolated writer lock")
    return raw / PROFILE


def classify(app, signed, before, after, first_reg, last_reg, isolated, daily):
    reasons = []
    if not signed["sourceMatches"]: reasons.append("candidateSourceMismatch")
    if str(app) != str(APP): reasons.append("existingAcceptanceRunnersRequireCanonicalInstall")
    if before != after: reasons.append("launchServicesOrProcessGenerationChanged")
    if not after["pidSourcesAgree"]: reasons.append("kernelAndLaunchServicesDisagree")
    if after["preferred"] != "selected" or after["registered"] != ["selected"]:
        reasons.append("selectedBundleIsNotTheUniqueLaunchServicesRoute")
    procs = after["processes"]
    exact = len(procs) == 1 and procs[0].get("verified") is True and procs[0].get("location") == "selected" and (
        procs[0].get("identifierMatches") is True and procs[0].get("kernelExecutableMatches") is True and
        procs[0].get("team") == signed["team"] and procs[0].get("cdhash") == signed["cdhash"])
    if not exact: reasons.append("oneRunningSelectedHostGenerationRequired")
    if not isolated: reasons.append("selectedPIDDoesNotHoldAnEnrolledPrivateProfile")
    if daily: reasons.append("selectedPIDHoldsDailyWriterLock")
    service_reasons = list(reasons)
    unique = first_reg == last_reg and len(last_reg) == 1 and all(
        last_reg[0][key] for key in ("message", "menu", "identifier", "selectedPath"))
    if not signed["declaresService"] or not unique: service_reasons.append("systemServiceDoesNotSelectThisExactBundle")
    if not signed["p4RequestBoundPanelPackaged"]: service_reasons.append("requestBoundTranslationPanelMissing")
    grant_reasons = list(reasons)
    if not (signed["declaresAppleEvents"] and signed["p3GrantOnlyProbePackaged"]):
        grant_reasons.append("nonpromptingHostGrantProbeMissing")
    def result(items):
        return {"status": "BLOCKED" if items else "READY_FOR_EXISTING_RUNNER", "reasons": items}
    return {"p3HostGrantReadback": result(grant_reasons), "p4ServiceReadback": result(service_reasons)}


def main(args):
    app = args.app
    require(re.fullmatch(r"[a-f0-9]{40}", args.expected_source), "Expected a full source revision")
    signed = bundle_identity(app, args.expected_source)
    first = system_snapshot(app)
    first_reg = read_service_directory(app)
    pid = next((row["pid"] for row in first["processes"] if row.get("location") == "selected" and row.get("verified")), None)
    root = private_home(args.home) if args.home else None
    isolated = bool(root and owns_profile(pid, root))
    daily = owns_profile(pid, Path.home() / PROFILE)
    last_reg = read_service_directory(app)
    last = system_snapshot(app)
    require(identity(app)["CDHash"] == signed["cdhash"], "Selected signed file changed during preflight")
    isolated = isolated and owns_profile(pid, root)
    daily = daily or owns_profile(pid, Path.home() / PROFILE)
    return {"schema": 1, "mode": "readOnly", "checkedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "candidate": signed, "launchAndProcessBefore": first, "launchAndProcessAfter": last,
            "serviceDirectoryBefore": first_reg, "serviceDirectoryAfter": last_reg,
            "holdsPrivateWriterLock": isolated, "holdsDailyWriterLock": daily,
            **classify(app, signed, first, last, first_reg, last_reg, isolated, daily),
            "p0LiveSidebarControl": "NOT_INSPECTED", "appleEventsGrant": "NOT_QUERIED", "serviceRequests": 0,
            "applicationLaunches": 0, "systemOrProductInputs": 0}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--expected-source", required=True)
    parser.add_argument("--home", type=Path, help="existing isolated acceptance home, for read-only PID/lock binding")
    args = parser.parse_args()
    try:
        print(json.dumps(main(args), ensure_ascii=False, indent=2, sort_keys=True))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "UNKNOWN", "error": str(error)[:230], "systemOrProductInputs": 0}))
        raise SystemExit(2)
