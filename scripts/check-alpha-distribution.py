#!/usr/bin/env python3
"""Inspect the entire frozen Alpha without launching it, changing TCC or contacting Apple."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess

_update_spec = importlib.util.spec_from_file_location("update_runtime", Path(__file__).with_name("prepare-update-runtime.py"))
update_runtime = importlib.util.module_from_spec(_update_spec)
_update_spec.loader.exec_module(update_runtime)
_icon_spec = importlib.util.spec_from_file_location("app_icon", Path(__file__).with_name("prepare-app-icon.py"))
app_icon = importlib.util.module_from_spec(_icon_spec)
_icon_spec.loader.exec_module(app_icon)

MAGICS = {bytes.fromhex(hexstr) for hexstr in ("feedfacf", "cffaedfe", "feedface", "cefaedfe",
                                              "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def cmd(*args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout


def version(value):
    return tuple((list(map(int, value.split("."))) + [0, 0, 0])[:3])


def requirement(output):
    # codesign prefixes a synthesized requirement (such as an ad-hoc cdhash) with "# ".
    values = re.findall(r"^(?:# )?designated => (.+)$", output, re.MULTILINE)
    if len(values) != 1:
        raise ValueError("The executable has no unambiguous designated requirement")
    return values[0]


# These executables can participate in a macOS permission decision.
def designated_requirement(path):
    output = cmd("/usr/bin/codesign", "-d", "-r-", str(path))
    return requirement(output)


# Stable shipping identifiers include the historical standalone helper identifiers.
PRODUCT_SIGNING_TEAM = "ZB9D4T66QB"
PRODUCT_IDENTIFIERS = {
    ".": "com.holdsnow.nearpane.alpha",
    "Contents/Helpers/NearpaneDesktopReader": "NearpaneDesktopReader",
    "Contents/Helpers/NearpaneOrdinaryWindowController": "NearpaneOrdinaryWindowController",
    "Contents/Helpers/NearpaneSpaceAction": "NearpaneSpaceAction",
    "Contents/Helpers/NearpaneAutomation": "com.holdsnow.nearpane.automation",
    "Contents/Helpers/NearpaneFrameController.app": "org.nearpane.lab.NearpaneFrameController",
    "Contents/Helpers/NearpaneFixtureWindows.app": "org.nearpane.lab.NearpaneFixtureWindows",
    "Contents/Helpers/NearpaneFixtureWindows.app/Contents/Helpers/NearpaneDesktopReader": "NearpaneDesktopReader",
}


def normalized_requirement(text):
    return " ".join(text.replace("/* exists */", "").replace('"', "").split())


def verify_install_identity(candidate):
    for relative, identifier in PRODUCT_IDENTIFIERS.items():
        subject = candidate / relative
        rule = (f'identifier "{identifier}" and anchor apple generic and '
                'certificate 1[field.1.2.840.113635.100.6.2.6] and '
                'certificate leaf[field.1.2.840.113635.100.6.1.13] and '
                f'certificate leaf[subject.OU] = "{PRODUCT_SIGNING_TEAM}"')
        cmd("/usr/bin/codesign", "--verify", "--strict", "-R=" + rule, str(subject))
        # The operating system records the designated requirement itself. A custom
        # requirement pinned to this binary or certificate would break the next update.
        actual = designated_requirement(subject)
        if normalized_requirement(actual) != normalized_requirement(rule):
            raise ValueError("Unstable permission identity: " + relative)


def inspect(app):
    app = app.resolve(strict=True)
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != "com.holdsnow.nearpane.alpha" or info.get("LSMultipleInstancesProhibited") is not True:
        raise ValueError("Not the stable, single-instance Nearpane Alpha")
    cmd("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    deployment = info["LSMinimumSystemVersion"]
    issues, inventory = [], {}
    icons = {}
    # Rollback packages keep their original resource contract; new bundles may not
    # silently fall back to the generic macOS icon, including bundled test helpers.
    if version(info["CFBundleShortVersionString"]) >= (5, 10, 0):
        icons["."] = app_icon.verify(app)
        for helper in sorted((contents / "Helpers").glob("*.app")):
            icons[str(helper.relative_to(app))] = app_icon.verify(helper)
    for path in sorted(contents.rglob("*")):
        if path.is_symlink() and contents not in path.resolve(strict=True).parents:
            raise ValueError("Link leaves the signed bundle: " + str(path))
        if path.is_symlink():
            continue
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
        sign = cmd("/usr/bin/codesign", "-dvvv", "-r-", str(path))
        cmd("/usr/bin/codesign", "--strict", "--verify", str(path))
        release = ("Authority=Developer ID Application:" in sign and "Timestamp=" in sign
                   and re.search(r"flags=0x[\da-f]+\([^)]*runtime", sign) is not None)
        if not release:
            issues.append(rel)
        team = re.search(r"^TeamIdentifier=(.+)$", sign, re.MULTILINE)
        inventory[rel] = dict(sha256=hashlib.sha256(path.read_bytes()).hexdigest(), architectures=arches,
                              minimumOS=target[0], distributionSignatureFields=release,
                              signingTeam=team[1] if team and team[1] != "not set" else None,
                              designatedRequirement=requirement(sign))
    if "MacOS/" + info["CFBundleExecutable"] not in inventory:
        raise ValueError("Host missing from inventory")
    if version(info["CFBundleShortVersionString"]) >= (5, 9, 0):
        update_runtime.validate_layout(app)
        for relative, identifier in update_runtime.COMPONENTS:
            signature = cmd("/usr/bin/codesign", "-dv", str(app / relative))
            if "Identifier=" + identifier not in signature.splitlines():
                raise ValueError("Wrong Sparkle signature identity: " + relative)
        required = {str(Path(item).relative_to("Contents")) for item in update_runtime.EXECUTABLES}
        actual = {item for item in inventory if item.startswith("Frameworks/")}
        if actual != required:
            raise ValueError("Unexpected embedded updater executable inventory")
        host = contents / "MacOS" / info["CFBundleExecutable"]
        linked = cmd("/usr/bin/otool", "-arch", "arm64", "-L", str(host))
        if "@rpath/Sparkle.framework/Versions/B/Sparkle" not in linked:
            raise ValueError("Host is not linked to embedded Sparkle")
        load = cmd("/usr/bin/otool", "-arch", "arm64", "-l", str(host))
        runpaths = set(re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", load))
        if "@executable_path/../Frameworks" not in runpaths or runpaths - {"@executable_path/../Frameworks", "/usr/lib/swift"}:
            raise ValueError("Host contains a development framework runpath")
        for key, expected in {"SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                              "SUSignedFeedFailureExpirationInterval": 0, "SUAllowsAutomaticUpdates": False,
                              "SUAutomaticallyUpdate": False, "SUScheduledCheckInterval": 86400}.items():
            if info.get(key) != expected:
                raise ValueError("Unsafe update setting: " + key)
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
                minimumOS=deployment, binaries=inventory, appIcons=icons, missingDistributionSignatures=issues,
                notarization="NOT_TESTED", cleanMacInstall="NOT_TESTED", publicRelease="NOT_ADMITTED")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--require-install-identity", action="store_true",
                        help="Require the stable Nearpane Developer ID identity for the Host and its permission helpers")
    parser.add_argument("--require-distribution-signatures", action="store_true",
                        help="Fail when even the preliminary Developer ID/timestamp/runtime checks are unmet")
    args = parser.parse_args()
    try:
        report = inspect(args.app)
        if args.require_install_identity or (args.require_distribution_signatures and not report["missingDistributionSignatures"]):
            verify_install_identity(args.app)
            report["permissionIdentity"] = dict(team=PRODUCT_SIGNING_TEAM, subjects=len(PRODUCT_IDENTIFIERS))
    except subprocess.CalledProcessError as exc:
        parser.exit(1, f"{exc}\n{(exc.stdout or '').strip()}\n")
    except (OSError, ValueError, KeyError) as exc:
        parser.exit(1, str(exc) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))
    if args.require_distribution_signatures and report["missingDistributionSignatures"]:
        parser.exit(2, "Development code signatures: distribution not admitted.\n")
