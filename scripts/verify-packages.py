#!/usr/bin/env python3
"""Verify independent full packages, including their upstream notices, with source caches inaccessible."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

from domain_resources import source_receipt, verify_resources

ROOT = Path(__file__).resolve().parents[1]
_icon_spec = importlib.util.spec_from_file_location("app_icon", ROOT / "scripts/prepare-app-icon.py")
app_icon = importlib.util.module_from_spec(_icon_spec)
_icon_spec.loader.exec_module(app_icon)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_engine_boundary(contents, plist, binary, host_image, sandbox):
    private_names = (b"SkyLight.framework/", b"SLSCopySpacesForWindows", b"SLSCopyManagedDisplaySpaces",
                     b"SLSMainConnectionID", b"_AXUIElementGetWindow")
    abi = plist.get("NearpaneStageEngineABI")
    if abi is None:
        if any(symbol in host_image for symbol in private_names):
            raise ValueError("Private desktop entry point in legacy Host")
        return
    if abi != 1:
        raise ValueError("Unrecognized StageGroup engine ABI")
    bundled = contents / "Resources/Upstream/window-engine"
    source = ROOT / "Engine/nearpane-window-engine"
    provenance = json.loads((bundled/"source.json").read_bytes())
    if (digest(bundled/"source.json") != digest(source/"upstream.json") or provenance["abi"] != abi
            or digest(bundled/"LICENSE") != provenance["licenseSHA256"]):
        raise ValueError("Unexpected StageGroup source or license")
    origin_files = {p.name: digest(p) for p in (source/"origins").glob("*.json")}
    if {p.name: digest(p) for p in (bundled/"origins").glob("*.json")} != origin_files:
        raise ValueError("Incomplete StageGroup upstream file origins")
    guardian = contents / "Helpers/NearpaneCornerGuardian"
    if guardian.resolve() != guardian or digest(guardian) != plist.get("NearpaneCornerGuardianSHA256"):
        raise ValueError("Unexpected Corner recovery helper")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", '-R=identifier "com.holdsnow.nearpane.alpha.corner-guardian"',
                    str(guardian)], check=True)
    if b"com.holdsnow.nearpane.engine-guardian.fixture" in guardian.read_bytes():
        raise ValueError("Packaged recovery helper includes a fixture identity")
    imports = subprocess.check_output(["/usr/bin/nm", "-u", str(binary)], text=True).splitlines()
    if any(line.split() and re.match(r"^(_(?:SLS|CGS)[A-Z]|__AXUIElementGetWindow$)", line.split()[-1]) for line in imports):
        raise ValueError("Host imports private WindowServer symbols directly")
    if any(marker in host_image for marker in (b"SLSOrderWindow", b"np_is_enrolled_fixture",
                                               b'identifier "com.holdsnow.nearpane.engine-fixture')):
        raise ValueError("Host contains an unqualified ordering route or experimental fixture code")
    for module in ("NearpaneCore", "NearpaneHost", "NearpaneUI", "NearpaneWindowEngine"):
        for path in (ROOT/"Sources"/module).rglob("*.swift"):
            if any(symbol in path.read_bytes() for symbol in private_names):
                raise ValueError("Private window calls outside the engine shim: " + path.name)
    reply = json.loads(subprocess.check_output(sandbox + [str(binary), "--verify-stage-window-engine"], timeout=12))
    gates = reply.get("engines", [])
    if (reply.get("abi") != abi or reply.get("closed") is not True or len(gates) != 2
            or {r["backend"] for r in gates} != {"corner", "spaces"}
            or any(r.get("unqualifiedWriteRefused") is not True for r in gates)):
        raise ValueError("Unqualified production engine accepted window writes")


def verify_ordinary_window_actions(writer, imports):
    if "_AXUIElementSetAttributeValue" not in imports or imports & {"_CGEventPost", "_CGEventPostToPid"}:
        raise ValueError("Unexpected ordinary window controller capabilities")
    if "_AXUIElementPerformAction" not in imports:
        return
    # The existing focused-window operation raises precisely its bound AX element.
    # Check the shipping binary's call site as well as its source argument. Other
    # ordinary-controller operations must never be able to press buttons or menus.
    program = subprocess.check_output(["/usr/bin/otool", "-arch", "arm64", "-tvV", str(writer)], text=True)
    label = None
    sites = []
    for line in program.splitlines():
        if line.endswith(":") and line.startswith("_"):
            label = line[:-1].removeprefix("_")
        elif "symbol stub for: _AXUIElementPerformAction" in line:
            sites.append(label)
    if len(sites) != 1 or not sites[0]:
        raise ValueError("Unexpected AX action call sites")
    function = subprocess.check_output(["/usr/bin/xcrun", "swift-demangle", "--compact", sites[0]], text=True)
    if not function.strip().startswith("NearpaneOrdinaryWindowController.focusCurrentWindow("):
        raise ValueError("AX action outside the verified window focus path")
    calls = [line.strip() for path in (ROOT / "Sources/NearpaneOrdinaryWindowController").rglob("*.swift")
             for line in path.read_text().splitlines() if "AXUIElementPerformAction" in line]
    if len(calls) != 1 or "AXUIElementPerformAction(element, kAXRaiseAction as CFString)" not in calls[0]:
        raise ValueError("Unexpected ordinary AX action or target")


def verify(app, lock, sandbox):
    contents = app / "Contents"
    plist = plistlib.loads((contents/"Info.plist").read_bytes())
    package_version = tuple(int(part) for part in plist["CFBundleShortVersionString"].split("."))
    if (plist["CFBundleIdentifier"] == "com.holdsnow.nearpane.host"
            or package_version >= (5, 10) or "NearpaneVisualAssetRevision" in plist):
        app_icon.verify(app)
    if plist["LSMinimumSystemVersion"] != "26.0" or plist["NearpaneNativeAcceptanceSchema"] != 2:
        raise ValueError("Unexpected full package metadata")
    binary = contents / "MacOS" / plist["CFBundleExecutable"]
    load = subprocess.check_output(["/usr/bin/otool","-l",str(binary)],text=True)
    if not re.search(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (?:1|MACOS)\s+minos 26\.0\b",load):
        raise ValueError("Unexpected Mach-O deployment target")
    helper = contents / "Helpers/NearpaneDesktopReader"
    if helper.resolve() != helper or digest(helper) != plist.get("NearpaneDesktopReaderSHA256"):
        raise ValueError("Unexpected desktop reader identity")
    # codesign treats Contents/MacOS/<CFBundleExecutable> as the enclosing bundle. These development
    # packages seal their exact Mach-O and resource inventory independently (no distribution signature).
    host_image = binary.read_bytes()
    if plist["CFBundleIdentifier"] in ("com.holdsnow.nearpane.candidate", "com.holdsnow.nearpane.candidate.p45", "com.holdsnow.nearpane.candidate.p46", "com.holdsnow.nearpane.candidate.p47", "com.holdsnow.nearpane.candidate.p48", "com.holdsnow.nearpane.candidate.p481", "com.holdsnow.nearpane.candidate.p49", "com.holdsnow.nearpane.candidate.p50", "com.holdsnow.nearpane.candidate.p51", "com.holdsnow.nearpane.candidate.p52", "com.holdsnow.nearpane.alpha"):
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    elif (contents/"_CodeSignature/CodeResources").is_file():
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    else:
        with tempfile.TemporaryDirectory(prefix="verify-macho-", dir=ROOT/"build") as tmp:
            standalone = Path(tmp)/binary.name
            standalone.write_bytes(host_image)
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(standalone)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(helper)], check=True)
    writer = contents / "Helpers/NearpaneOrdinaryWindowController"
    if writer.resolve() != writer or digest(writer) != plist.get("NearpaneOrdinaryWindowControllerSHA256"):
        raise ValueError("Ordinary window controller fingerprint mismatch")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(writer)], check=True)
    writer_imports = {line.split()[-1] for line in subprocess.check_output(
        ["/usr/bin/nm", "-u", str(writer)], text=True).splitlines() if line.split()}
    verify_ordinary_window_actions(writer, writer_imports)
    space_action = contents / "Helpers/NearpaneSpaceAction"
    if package_version >= (5, 21) or "NearpaneSpaceActionSHA256" in plist:
        if space_action.resolve() != space_action or digest(space_action) != plist.get("NearpaneSpaceActionSHA256"):
            raise ValueError("Native Space action fingerprint mismatch")
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(space_action)], check=True)
        for notice in ("InstantSpaceSwitcher-LICENSE", "yabai-LICENSE", "SOURCES.md"):
            if not (contents / "Resources/NativeSpaceActions" / notice).is_file():
                raise ValueError("Missing Native Space action source notice: " + notice)
    for exe in (binary, helper, writer):
        if "SkyLight.framework" in subprocess.check_output(["/usr/bin/otool", "-L", str(exe)], text=True):
            raise ValueError("Private desktop framework linked directly: " + exe.name)
    verify_engine_boundary(contents, plist, binary, host_image, sandbox)
    # The admission observer can read attributes and test their writability. It must
    # not acquire the setter or AX action entry points of the separate frame controller.
    imports = subprocess.check_output(["/usr/bin/nm", "-u", str(helper)], text=True).splitlines()
    banned = {"_AXUIElementSetAttributeValue", "_AXUIElementPerformAction", "_CGEventPost", "_CGEventPostToPid"}
    if any(line.split() and line.split()[-1] in banned for line in imports):
        raise ValueError("Desktop reader imports an external input or window-writing API")
    if subprocess.check_output(sandbox + [str(helper), "--self-check"], text=True).strip() != "Nearpane desktop reader 1":
        raise ValueError("Desktop reader protocol unavailable")
    result = subprocess.check_output(sandbox + [str(binary), "--verify-bundled-resources"],text=True)
    if "Packaged Saytile and Riftlet resources verified." not in result:
        raise ValueError("Missing full packaged resource verification")
    root = contents / "Resources"
    if not digest(root/"AcceptanceTargetGuard.js") == digest(ROOT/"Resources/AcceptanceTargetGuard.js") == plist.get("NearpaneDraftGuardSHA256"):
        raise ValueError("Unexpected acceptance guard in packaged resources")
    if plist["CFBundleIdentifier"] == "com.holdsnow.nearpane.alpha":
        for name in ("profile-migration.py", "profile_domains.py"):
            bundled = root / "Profile" / name
            if bundled.resolve() != bundled or digest(bundled) != digest(ROOT / "scripts" / name):
                raise ValueError("Unexpected profile migration resource: " + name)
    for name,pin in lock["domains"].items():
        provenance = json.loads((root/"Upstream"/name/"source.json").read_text())
        expected = source_receipt(pin)
        if name == "saytile" and lock.get("saytileUpdates"):
            updates = lock["saytileUpdates"]
            expected["updates"] = updates
            for notice in updates["notices"]:
                if digest(root/"Upstream"/name/"updates"/notice) != updates["files"][notice]:
                    raise ValueError("Incorrect packaged Saytile update notice: "+notice)
        if provenance != expected:
            raise ValueError("Incorrect packaged provenance: "+name)
        verify_resources(root, name, pin)
        checks = {n: "Upstream/"+name+"/"+n for n in pin["notices"]}
        for src,out in checks.items():
            if digest(root/out) != pin["files"][src]:
                raise ValueError("Packaged checksum mismatch: "+out)
    inventory = {}
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != ".DS_Store":
            if root not in path.resolve().parents:
                raise ValueError("Packaged resource escapes its bundle")
            inventory[path.relative_to(root).as_posix()] = digest(path)
    resource_hash = hashlib.sha256(json.dumps(inventory, sort_keys=True, separators=(",",":")).encode()).hexdigest()
    print(f"{app}: {len(inventory)} resources, SHA-256 {resource_hash}; executable {digest(binary)}")
    return resource_hash


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apps", nargs="+", type=Path)
    parser.add_argument("--deny-cache", action="append", type=Path, default=[])
    args = parser.parse_args()
    deny = [ROOT/".build", ROOT.parent/"saytile", ROOT.parent/"Riftlet", *args.deny_cache]
    support = Path.home()/"Library/Application Support"
    deny.extend(support/name for name in ("Nearpane","Saytile","Riftlet"))
    params = []
    for index,path in enumerate(deny):
        params.extend(["-D", f"C{index}={path.resolve()}"])
    paths = " ".join(f'(subpath (param "C{i}"))' for i in range(len(deny)))
    profile = f"(version 1)(allow default)(deny file-read* file-write* {paths})(deny network-outbound (remote tcp) (remote udp))"
    sandbox = ["/usr/bin/sandbox-exec", *params, "-p", profile]
    lock = json.loads((ROOT/"Dependencies/domains.lock.json").read_text())
    hashes = {verify(app.resolve(), lock, sandbox) for app in args.apps}
    if len(hashes) != 1:
        raise ValueError("Packages contain different resource files or bytes")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit(f"Package verification: {error}")
