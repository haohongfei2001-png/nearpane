#!/usr/bin/env python3
"""Build/inspect the signed ordinary owner; prepare an existing membership nonce without launching any app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
CORNER = HERE.parent
ROOT = HERE.parents[4]
sys.path.insert(0, str(ROOT / "scripts"))
from candidate_signing import product_fingerprint

TMP = Path("/private/tmp")
APP = "Interactive Windows.app"
EXE = Path("Contents/MacOS/InteractiveWindows")
IDENTIFIER = "com.holdsnow.nearpane.stage-interactive-fixture"
BYSTANDER_APP = "Interactive Bystander.app"
BYSTANDER_EXE = Path("Contents/MacOS/InteractiveBystander")
BYSTANDER_ID = "com.holdsnow.nearpane.stage-interactive-bystander"
TEAM = "ZB9D4T66QB"
GESTURES = ROOT / "Engine/nearpane-window-engine/src/corner/gesture_witness.h"
SOURCES = [CORNER / "owner.m", GESTURES, GESTURES.with_name("scope_binding.h"), HERE / "session.inc", HERE / "admission.h",
           HERE / "evidence.h", HERE / "self-test.inc", Path(__file__).resolve()]
FORBIDDEN = {"_CGEventPost", "_CGEventPostToPSN", "_CGEventPostToPid", "_CGEventTapCreate", "_CGEventTapCreateForPid",
             "_CGWindowListCopyWindowInfo", "_CGWindowListCreateImage", "_CGDisplayCreateImage", "_CGWarpMouseCursorPosition",
             "_CGRequestListenEventAccess", "_CGRequestPostEventAccess", "_CGRequestScreenCaptureAccess",
             "_AXUIElementCreateApplication", "_AXUIElementPerformAction", "_AXUIElementSetAttributeValue",
             "_AXUIElementPostKeyboardEvent", "_AXIsProcessTrustedWithOptions", "_CFPreferencesSetAppValue", "_CFPreferencesSetValue"}


def command(*args):
    return subprocess.run([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, check=True, timeout=75).stdout


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    with path.open("x", encoding="utf8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def private(path):
    st = path.lstat()
    need(path == path.resolve(strict=True) and path.parent == TMP and stat.S_ISDIR(st.st_mode)
         and stat.S_IMODE(st.st_mode) == 0o700 and st.st_uid == os.getuid(), "unsafe private fixture directory")


def verify(app):
    bystander = app.name == BYSTANDER_APP
    need(bystander or app.name == APP, "unexpected fixture bundle name")
    executable = BYSTANDER_EXE if bystander else EXE
    identifier = BYSTANDER_ID if bystander else IDENTIFIER
    folders = {Path("."): {"Contents"}, Path("Contents"): {"Info.plist", "MacOS", "_CodeSignature"},
               Path("Contents/MacOS"): {executable.name}, Path("Contents/_CodeSignature"): {"CodeResources"}}
    for relative, names in folders.items():
        p = app / relative
        st = p.lstat()
        need(stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and not st.st_mode & 0o022,
             "unexpected directory in fixture")
        need({child.name for child in p.iterdir()} == names, "unexpected component in fixture")
    for relative in (executable, Path("Contents/Info.plist"), Path("Contents/_CodeSignature/CodeResources")):
        st = (app / relative).lstat()
        need(stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid() and st.st_nlink == 1 and
             not st.st_mode & 0o022 and 0 < st.st_size <= 2 * 1024 * 1024, "unexpected file in fixture")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    need(info["CFBundlePackageType"] == "APPL" and info["CFBundleIdentifier"] == identifier and
         info["CFBundleExecutable"] == executable.name and info["LSUIElement"] is False and info["NSPrincipalClass"] == "NSApplication",
         "ordinary fixture metadata mismatch")
    rule = (f'=anchor apple generic and identifier "{identifier}" and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
            f'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU]="{TEAM}"')
    command("/usr/bin/codesign", "--verify", "--strict", "--deep", "-R" + rule, app)
    raw = command("/usr/bin/codesign", "-dvvv", app)
    hashes = re.findall(r"^CDHash=([0-9a-f]{40})$", raw, re.M)
    need(len(hashes) == 1 and f"TeamIdentifier={TEAM}" in raw and "(runtime)" in raw, "signed app identity mismatch")
    imports = {s.split()[-1] for s in command("/usr/bin/nm", "-u", app / executable).splitlines() if s.split()}
    need(imports.isdisjoint(FORBIDDEN), "unexpected external observation or system action imported")
    return {"identifier": identifier, "team": TEAM, "cdhash": hashes[0], "executableSHA256": digest(app / executable),
            "regularApplicationBundle": True, "strictDeveloperIDVerification": True, "auditedForbiddenImportCount": len(FORBIDDEN)}


def build_owner(kit, bystander, signing):
    app = kit / (BYSTANDER_APP if bystander else APP)
    exe = app / (BYSTANDER_EXE if bystander else EXE)
    exe.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundlePackageType="APPL",
        CFBundleIdentifier=BYSTANDER_ID if bystander else IDENTIFIER, CFBundleName="Nearpane interactive windows", CFBundleExecutable=exe.name,
        CFBundleVersion="1", LSUIElement=False, NSPrincipalClass="NSApplication", LSMinimumSystemVersion="26.0")))
    flags = ["-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror", "-I", GESTURES.parent]
    if bystander:
        flags.append("-DNP_INTERACTIVE_BYSTANDER=1")
    command("/usr/bin/xcrun", "clang", *flags, "-mmacosx-version-min=26.0", "-DNP_HOST_INTERACTIVE_FIXTURE=1",
            CORNER / "owner.m", "-framework", "AppKit", "-framework", "Security", "-framework", "CoreGraphics",
            "-lbsm", "-o", exe)
    command("/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", signing, app)
    signed = verify(app)
    # A signed executable process, before NSApplication initialization; never open the .app via Launch Services here.
    result = subprocess.run([str(exe), "--self-test"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=8)
    tests = json.loads(result.stdout)
    need(result.returncode == 0 and tests["status"] == "PASS" and tests["cdhash"] == signed["cdhash"] and
         tests["windowCount"] == 0 and tests["appKitApplicationInitialized"] is False,
         "headless signed fixture regression failed: " + json.dumps({"exit": result.returncode,
            "application": tests["appKitApplicationInitialized"], "windows": tests["windowCount"], "status": tests["status"],
            "sameHash": tests["cdhash"] == signed["cdhash"], "failedChecks": [k for k, v in tests["checks"].items() if not v]}))
    return signed, tests


def build():
    kit = Path(tempfile.mkdtemp(prefix="nearpane-interactive-kit.", dir=TMP))
    try:
        signing = product_fingerprint(command("/usr/bin/security", "find-identity", "-v", "-p", "codesigning"))
        command("/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", GESTURES.parent,
                "-fsyntax-only", CORNER / "owner.m")
        signed, tests = build_owner(kit, False, signing)
        bystander, bystander_tests = build_owner(kit, True, signing)
        receipt = {"schema": 1, "status": "PASS", "scope": "signedFixtureBuildAndHeadlessReceiverTests",
                   "gitBase": command("git", "-C", ROOT, "rev-parse", "HEAD").strip(),
                   "sourceSHA256": {str(p.relative_to(ROOT)): digest(p) for p in SOURCES},
                   "bystander": bystander, "bystanderTests": bystander_tests,
                   "osBuild": command("sw_vers", "-buildVersion").strip(), "signature": signed, "tests": tests,
                   "hostedOriginalOwnerCompile": "PASS", "launchServicesOpen": "NOT_RUN",
                   "ordinaryWindowsAndAppKitInput": "NOT_RUN", "realHostHideSiblingRestore": "NOT_RUN",
                   "productionQualification": "UNQUALIFIED"}
        save(kit / "build.json", receipt)
        return kit, receipt
    except BaseException:
        shutil.rmtree(kit)
        raise


def prepare(kit, challenge, *, bystander=False):
    private(kit)
    need(bool(re.fullmatch(r"nearpane-interactive-kit\.[a-z0-9_]{8}", kit.name)), "unrecognized build kit")
    need(str(uuid.UUID(challenge)) == challenge, "expected a canonical existing membership challenge")
    session = TMP / ("nearpane-membership." + challenge)
    private(session)
    origin = (kit / "build.json").lstat()
    need(stat.S_ISREG(origin.st_mode) and origin.st_nlink == 1 and origin.st_uid == os.getuid() and
         not origin.st_mode & 0o022 and 0 < origin.st_size < 65536, "unverified build receipt")
    manifest = json.loads((kit / "build.json").read_bytes())
    name = BYSTANDER_APP if bystander else APP
    expected = verify(kit / name)
    need(manifest["status"] == "PASS" and manifest["bystander" if bystander else "signature"] == expected and
         manifest["bystanderTests" if bystander else "tests"]["cdhash"] == expected["cdhash"], "kit fingerprint mismatch")
    dest = session / name
    dest.mkdir(mode=0o700)  # Exclusive reservation; never replace a running or previously enrolled fixture.
    # A failed copy leaves this reservation in place. A second session cannot overwrite it.
    command("/usr/bin/ditto", kit / name, dest)
    need(verify(dest) == expected, "staged executable fingerprint mismatch")
    return {"schema": 1, "status": "PREPARED", "challenge": challenge, "bundle": str(dest), "signature": expected,
            "arguments": ["--interactive-fixture", challenge], "socket": str(session / ("bystander.sock" if bystander else "interactive.sock")), "launched": False}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    modes = p.add_subparsers(dest="mode", required=True)
    modes.add_parser("build").add_argument("--receipt", type=Path, help="write a new portable receipt")
    stage = modes.add_parser("prepare")
    stage.add_argument("kit", type=Path)
    stage.add_argument("challenge")
    args = p.parse_args()
    if args.mode == "build":
        kit, receipt = build()
        if args.receipt:
            save(args.receipt, receipt)
        print(json.dumps({"kit": str(kit), "signature": receipt["signature"], "tests": len(receipt["tests"]["checks"])}))
    else:
        print(json.dumps(prepare(args.kit, args.challenge)))


if __name__ == "__main__":
    main()
