#!/usr/bin/env python3
"""Prepare/inspect one separately signed, background-only Corner fixture. Never change TCC."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
ENGINE = ROOT / "Engine/nearpane-window-engine"
ARTIFACTS = ROOT / "build/window-engine"
BUNDLES = {
    "Lease Controller": ("LeaseController", "com.holdsnow.nearpane.engine-fixture", "controller.m"),
    "Lease Window": ("LeaseWindow", "com.holdsnow.nearpane.engine-fixture.a", "owner.m"),
}
FORBIDDEN_CALLS = {
    "_CGEventPost", "_CGEventPostToPid", "_CGEventPostToPSN", "_AXUIElementPostKeyboardEvent",
    "_CGRequestListenEventAccess", "_CGRequestPostEventAccess", "_CGRequestScreenCaptureAccess",
    "_CGWarpMouseCursorPosition", "_CGDisplayMoveCursorToPoint", "_AXIsProcessTrustedWithOptions",
    "_CFPreferencesSetAppValue", "_CFPreferencesSetValue",
}


def command(*args, env=None):
    return subprocess.run([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, check=True, env=env, timeout=180).stdout


def save(path, obj):
    with path.open("x") as out:
        json.dump(obj, out, ensure_ascii=False, indent=2)
        out.write("\n")


def inspect_kit(path):
    kit = path.resolve(strict=True)
    if (path.is_symlink() or kit.parent != Path("/private/tmp")
            or not re.fullmatch(r"nearpane-corner-single\.[a-z0-9_]{8}", kit.name)
            or kit.stat().st_uid != os.getuid() or kit.stat().st_mode & 0o077):
        raise ValueError("kitNotInOwnExclusiveTemporaryDirectory")
    facts = {}
    for name, (exe, bundle_id, _) in BUNDLES.items():
        app = kit / (name + ".app")
        binary = app / "Contents/MacOS" / exe
        if app.is_symlink() or not binary.is_file() or any(p.is_symlink() or p.stat().st_uid != os.getuid()
                                                           for p in app.rglob("*")):
            raise ValueError("unexpectedBundleFileOrOwner")
        metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if not (metadata.get("LSUIElement") is True and metadata.get("CFBundleIdentifier") == bundle_id
                and metadata.get("CFBundleExecutable") == exe):
            raise ValueError("agentBundleIdentityMismatch")
        req = (f'=anchor apple generic and identifier "{bundle_id}" and certificate 1[field.1.2.840.113635.'
               '100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
               'certificate leaf[subject.OU] = "ZB9D4T66QB"')
        command("/usr/bin/codesign", "--verify", "--strict", "--deep", "-R" + req, app)
        signature = command("/usr/bin/codesign", "-dvvv", app)
        cdhash = re.search(r"^CDHash=([0-9a-f]{40,64})$", signature, re.M)
        imports = {line.split()[-1] for line in command("/usr/bin/nm", "-u", binary).splitlines() if line.split()}
        if not cdhash or "runtime" not in signature or not imports.isdisjoint(FORBIDDEN_CALLS):
            raise ValueError("signingRuntimeOrNonInteractiveImportsUnverified")
        facts[name] = {"identifier": bundle_id, "cdhash": cdhash[1],
                       "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    return facts


def build(output):
    sys.path.insert(0, str(ROOT / "scripts"))
    from candidate_signing import product_fingerprint
    cert = product_fingerprint(command("/usr/bin/security", "find-identity", "-v", "-p", "codesigning"))
    env = os.environ.copy()
    rust = ARTIFACTS / "toolchain/portable/bin"
    if rust.is_dir():
        env["PATH"] = str(rust) + os.pathsep + env["PATH"]
    kit = Path(tempfile.mkdtemp(prefix="nearpane-corner-single.", dir="/private/tmp"))
    try:
        with (output / "build.log").open("x") as log:
            target = ARTIFACTS / "corner-single-rust"
            log.write(command("cargo", "build", "--locked", "--offline", "--release", "--features", "corner,isolated-fixtures",
                              "--manifest-path", ENGINE / "Cargo.toml", "--target-dir", target, env=env))
            for name, (exe, bundle_id, src) in BUNDLES.items():
                app = kit / (name + ".app")
                (app / "Contents/MacOS").mkdir(parents=True)
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": bundle_id, "CFBundleExecutable": exe, "CFBundlePackageType": "APPL",
                    "CFBundleVersion": "1", "CFBundleName": name, "LSUIElement": True,
                    "LSMinimumSystemVersion": "14.0", "NSPrincipalClass": "NSApplication",
                }))
                libs = [target / "release/libnearpane_window_engine.a"] if src == "controller.m" else []
                frameworks = [argument for f in ("AppKit", "ApplicationServices", "Foundation", "Security",
                                                   "Carbon", "CoreGraphics", "CoreFoundation") for argument in ("-framework", f)]
                log.write(command("/usr/bin/xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror", "-I", ENGINE / "include",
                                  "-I", ENGINE / "src/corner", HERE / "single" / src, *libs,
                                  *frameworks, "-o", app / "Contents/MacOS" / exe))
                log.write(command("/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none",
                                  "--sign", cert, app))
        signatures = inspect_kit(kit)
        command(kit / "Lease Controller.app/Contents/MacOS/LeaseController", "--self-test")
        manifest = {"schema": 1, "kit": str(kit), "binaries": signatures}
        save(kit / "build.json", manifest)
        return {**manifest, "status": "NOT_RUN", "build": "PASS", "source": command("git", "-C", ROOT, "rev-parse", "HEAD").strip(),
                "offlineNumericSelfTest": "PASS", "opensWindowOrEventTapDuringBuild": False}
    except Exception:
        shutil.rmtree(kit)
        raise


def verified_terminal(mode, rows):
    terms = [r for r in rows if r.get("event") == "terminal"]
    if len(terms) != 1 or rows[-1] != terms[0] or terms[0].get("mode") != mode:
        raise ValueError("missingOrUncorrelatedTerminalReceipt")
    final = terms[0]
    if final.get("qualification") != "UNQUALIFIED" or final.get("fullCycle") != "NOT_RUN":
        raise ValueError("improperFixtureQualification")
    if final.get("status") not in ("BLOCKED", "UNKNOWN", "FAIL", "PASS"):
        raise ValueError("invalidTerminalDecision")
    if final["status"] != "PASS":
        return final
    checks = [r for r in rows if r.get("event") == "preflight"]
    if (len(checks) != 1 or not all(checks[0].get(k) is True for k in ("signed", "launchdParent", "ownResponsibilitySubject", "console",
            "accessibilityAlreadyGranted", "postEventAlreadyGranted", "stableFocus", "stableHID14", "stablePhysicalScope"))
            or checks[0].get("stage") != "OFF" or checks[0].get("secureInput") is not False or checks[0].get("blockingReasons") != []
            or final.get("preflightPassed") is not True
            or any(final.get(k) != 0 for k in ("globalEventsPosted", "thirdPartyWindowWrites", "preferenceWrites"))):
        raise ValueError("missingPositivePhysicalPreflight")
    scopes = [r.get("scope", {}) for r in rows if r.get("event") in ("scope1", "scope2")]
    if len(scopes) != 2 or not scopes[0] or scopes[0] != scopes[1]:
        raise ValueError("twoStablePhysicalScopeReadbacksRequired")
    submissions = [r.get("operation") for r in rows if r.get("event") == "submitted"]
    if mode == "preflight":
        if final.get("windowRequested") is not False or submissions:
            raise ValueError("unexpectedWindowDuringPreflight")
        return final
    if (submissions != [3, 5] or final.get("engineClose") != 0
            or not all(final.get(k) is True for k in ("parkSubmitted", "restoreSubmitted", "originalGeometryRestored",
                    "fixtureExited", "ownedWindowGone", "externalExactFocusPreserved", "originalDisplaySpacePreserved", "originalHIDUnchanged"))):
        raise ValueError("singleRoundTripOrCleanupEvidenceMissing")
    owned = [r for r in rows if r.get("event") == "ownedWindow"]
    if ([r.get("phase") for r in owned] != ["admission", "original", "original", "parked", "parked", "restored", "restored"]
            or len({r.get("window") for r in owned}) != 1
            or any(r.get("exactOwnedWindow") is not True or r.get("listedWithZeroAlpha") is not True for r in owned)):
        raise ValueError("missingWindowServerAndOwnerReadbacks")
    receipts = [r for r in rows if r.get("event") == "engine"]
    required = [(2, 45, 0), (2, 45, 0), (6, 80, 0), (3, 190, 1), (2, 190, 1), (2, 190, 1),
                (5, 45, 0), (2, 45, 0), (2, 45, 0)]
    if (len(receipts) != len(required) or any((r.get("operation"), r.get("status"), r.get("owned")) != (op, 0, count)
            or int(r.get("flags", 0)) & mask != mask for r, (op, mask, count) in zip(receipts, required))):
        raise ValueError("engineReceiptMissingOrFailed")
    return final


def run(mode, output, kit):
    fingerprints = inspect_kit(kit)
    manifest = json.loads((kit / "build.json").read_bytes())
    if fingerprints != manifest["binaries"] or manifest.get("kit") != str(kit.resolve()):
        raise ValueError("signedKitChangedAfterBuild")
    # A private launch-stdio directory avoids exposing any user path or granting the controller Documents access.
    with tempfile.TemporaryDirectory(prefix="nearpane-corner-receipt.", dir="/private/tmp") as directory:
        stream = Path(directory) / "raw.jsonl"
        stream.touch(mode=0o600, exist_ok=False)
        args = ["/usr/bin/open", "-n", "-g", "-W", "-a", str(kit / "Lease Controller.app"),
                "--stdin", "/dev/null", "--stdout", str(stream), "--stderr", "/dev/null", "--args", mode, fingerprints["Lease Controller"]["cdhash"],
                fingerprints["Lease Window"]["cdhash"]]
        launch = "exited"
        try:
            completed = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=26)
            if completed.returncode != 0:
                launch = "launchServicesReturnedError"
        except subprocess.TimeoutExpired:
            launch = "launchServicesTimedOut"
        if stream.stat().st_size > 128 * 1024:
            raise ValueError("oversizeControllerReceipts")
        raw = stream.read_bytes()
        (output / "raw.jsonl").write_bytes(raw)
    if launch != "exited":
        return {"status": "UNKNOWN", "reason": launch, "qualification": "UNQUALIFIED",
                "fullCycle": "NOT_RUN", "raw": "raw.jsonl", "noAutomaticRedispatch": True}
    if inspect_kit(kit) != fingerprints:
        raise ValueError("signedKitChangedDuringObservation")
    rows = [json.loads(line) for line in raw.splitlines()]
    result = verified_terminal(mode, rows)
    checks = [r for r in rows if r.get("event") == "preflight"]
    owners = [r for r in rows if r.get("event") == "fixtureIdentity"]
    if (len(checks) != 1 or checks[0].get("controllerCDHash") != fingerprints["Lease Controller"]["cdhash"]
            or any(r.get("windowCDHash") != fingerprints["Lease Window"]["cdhash"] or r.get("directChild") is not True
                   for r in owners)
            or mode == "run" and result.get("windowRequested") and len(owners) != 1):
        raise ValueError("couldNotCorrelateRunningBinariesWithPreparedKit")
    return {**result, "binaries": fingerprints, "raw": "raw.jsonl", "rawSHA256": hashlib.sha256(raw).hexdigest()}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=("build", "preflight", "run"))
    p.add_argument("output", type=Path, help="a new directory for this one invocation")
    p.add_argument("--kit", type=Path)
    args = p.parse_args()
    if (args.mode == "build") == bool(args.kit):
        p.error("--kit is required only for preflight/run")
    os.umask(0o077)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    try:
        result = build(args.output) if args.mode == "build" else run(args.mode, args.output, args.kit)
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError) as e:
        result = {"status": "BLOCKED" if args.mode == "build" else "UNKNOWN", "reason": str(e),
                  "qualification": "UNQUALIFIED", "fullCycle": "NOT_RUN"}
        if isinstance(e, subprocess.CalledProcessError):
            (args.output / "error.log").write_text(e.stdout or "")
    save(args.output / "result.json", result)
    print(json.dumps(result, ensure_ascii=False))
    return int(result["status"] == "UNKNOWN" or args.mode == "build" and result.get("build") != "PASS")


if __name__ == "__main__":
    sys.exit(main())
