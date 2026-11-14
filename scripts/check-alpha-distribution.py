#!/usr/bin/env python3
"""Inspect the entire frozen Alpha without launching it, changing TCC or contacting Apple."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

MAGICS = {bytes.fromhex(hexstr) for hexstr in ("feedfacf", "cffaedfe", "feedface", "cefaedfe",
                                              "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def cmd(*args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout


def version(value):
    return tuple((list(map(int, value.split("."))) + [0, 0, 0])[:3])


def inspect(app):
    app = app.resolve(strict=True)
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != "com.holdsnow.nearpane.alpha" or info.get("LSMultipleInstancesProhibited") is not True:
        raise ValueError("Not the stable, single-instance Nearpane Alpha")
    cmd("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    deployment = info["LSMinimumSystemVersion"]
    issues, inventory = [], {}
    for path in sorted(contents.rglob("*")):
        if path.is_symlink() and contents not in path.resolve(strict=True).parents:
            raise ValueError("Link leaves the signed bundle: " + str(path))
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in MAGICS:
                continue
        rel = str(path.relative_to(contents))
        arches = cmd("/usr/bin/lipo", "-archs", str(path)).strip().split()
        if "arm64" not in arches:
            raise ValueError("No arm64 slice: " + rel)
        load = cmd("/usr/bin/otool", "-arch", "arm64", "-l", str(path))
        target = re.findall(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (?:1|MACOS)\s+minos (\S+)", load)
        if len(target) != 1 or version(target[0]) > version(deployment):
            raise ValueError("Missing/incompatible macOS arm64 slice: " + rel)
        sign = cmd("/usr/bin/codesign", "-dvvv", str(path))
        cmd("/usr/bin/codesign", "--strict", "--verify", str(path))
        release = ("Authority=Developer ID Application:" in sign and "Timestamp=" in sign
                   and re.search(r"flags=0x[\da-f]+\([^)]*runtime", sign) is not None)
        if not release:
            issues.append(rel)
        inventory[rel] = dict(sha256=hashlib.sha256(path.read_bytes()).hexdigest(), architectures=arches,
                              minimumOS=target[0], distributionSignatureFields=release)
    if "MacOS/" + info["CFBundleExecutable"] not in inventory:
        raise ValueError("Host missing from inventory")
    automation = contents / "Helpers/NearpaneAutomation"
    if version(info["CFBundleShortVersionString"]) >= (5, 8, 0):
        bound = info.get("NearpaneAutomationSHA256", {})
        required = {"Helpers/NearpaneAutomation", "Resources/Automation/stdlib.zip",
                    "Resources/Profile/profile-migration.py", "Resources/Profile/profile_domains.py",
                    "Resources/WorkRect/window-management.py"}
        if set(bound) != required:
            raise ValueError("Incomplete bundled automation identity")
        for relative, expected in bound.items():
            item = contents / relative
            if item.resolve() != item or hashlib.sha256(item.read_bytes()).hexdigest() != expected:
                raise ValueError("Automation fingerprint mismatch: " + relative)
        deps = cmd("/usr/bin/otool", "-L", str(automation)).splitlines()[1:]
        allowed = ("/usr/lib/libSystem.B.dylib", "/usr/lib/libsqlite3.dylib", "/usr/lib/libz.1.dylib",
                   "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation")
        if any(line.strip().split(" (", 1)[0] not in allowed for line in deps):
            raise ValueError("Automation depends on an external runtime")
        for name in ("source.json", "build.json", "PYTHON-LICENSE.txt", "PYTHON-THIRD-PARTY-NOTICES.rst"):
            if not (contents / "Resources/Automation" / name).is_file():
                raise ValueError("Missing runtime provenance: " + name)
    return dict(bundle=info["CFBundleIdentifier"], version=info["CFBundleShortVersionString"],
                minimumOS=deployment, binaries=inventory, missingDistributionSignatures=issues,
                notarization="NOT_TESTED", cleanMacInstall="NOT_TESTED", publicRelease="NOT_ADMITTED")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--require-distribution-signatures", action="store_true",
                        help="Fail when even the preliminary Developer ID/timestamp/runtime checks are unmet")
    args = parser.parse_args()
    try:
        report = inspect(args.app)
    except subprocess.CalledProcessError as exc:
        parser.exit(1, f"{exc}\n{(exc.stdout or '').strip()}\n")
    except (OSError, ValueError, KeyError) as exc:
        parser.exit(1, str(exc) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))
    if args.require_distribution_signatures and report["missingDistributionSignatures"]:
        parser.exit(2, "Development code signatures: distribution not admitted.\n")
