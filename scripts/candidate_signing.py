"""Seal an explicitly selected local Alpha identity and compare upgrade code requirements."""
import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("alpha_gate", ROOT / "check-alpha-distribution.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pin(bundle, key, binary):
    plist = bundle / "Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    if key not in info:
        raise ValueError("Expected packaged helper fingerprint: " + key)
    info[key] = sha(binary)
    plist.write_bytes(plistlib.dumps(info))


def seal_components(temp, seal):
    helpers = temp / "Contents/Helpers"
    fixture = helpers / "NearpaneFixtureWindows.app"
    ctl = helpers / "NearpaneFrameController.app"
    readers = (helpers / "NearpaneDesktopReader", fixture / "Contents/Helpers/NearpaneDesktopReader")
    writer = helpers / "NearpaneOrdinaryWindowController"
    automation = helpers / "NearpaneAutomation"
    additional = [automation] if automation.exists() else []
    space_action = helpers / "NearpaneSpaceAction"
    action_helpers = [space_action] if space_action.exists() else []
    for binary in (*readers, writer, *additional, *action_helpers):
        if binary.is_symlink() or not binary.is_file():
            raise ValueError("Expected regular helper binary")
        # Standalone helpers retain the identifiers used by their earlier builds.
        fields = gate.cmd("/usr/bin/codesign", "-dv", str(binary)).splitlines()
        identifiers = [s.split("=", 1)[1] for s in fields if s.startswith("Identifier=")]
        if len(identifiers) != 1:
            raise ValueError("Helper lacks a signing identifier")
        seal(binary, identifiers[0])
    pin(fixture, "NearpaneDesktopReaderSHA256", readers[1])
    pin(temp, "NearpaneDesktopReaderSHA256", readers[0])
    pin(temp, "NearpaneOrdinaryWindowControllerSHA256", writer)
    if action_helpers:
        pin(temp, "NearpaneSpaceActionSHA256", space_action)
    if additional:
        plist = temp / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["NearpaneAutomationSHA256"]["Helpers/NearpaneAutomation"] = sha(automation)
        plist.write_bytes(plistlib.dumps(info))
    if (temp / gate.update_runtime.FRAMEWORK).exists():
        for relative, identifier in gate.update_runtime.COMPONENTS:
            seal(temp / relative, identifier)
    for bundle in (fixture, ctl, temp):
        identifier = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
        seal(bundle, identifier)
    for bundle, key, executable in ((temp, "NearpaneDesktopReaderSHA256", readers[0]),
                                   (temp, "NearpaneOrdinaryWindowControllerSHA256", writer),
                                   (fixture, "NearpaneDesktopReaderSHA256", readers[1])):
        if plistlib.loads((bundle / "Contents/Info.plist").read_bytes())[key] != sha(executable):
            raise ValueError("Nested signing invalidated helper binding")
    return 3 + len(additional) + len(action_helpers)


def check_continuity(previous, candidate):
    # Legacy ad-hoc installations need a one-time migration to a named identity.
    fields = gate.cmd("/usr/bin/codesign", "-dvv", str(previous)).splitlines()
    if "Signature=adhoc" in fields:
        return
    for subject in gate.PRODUCT_IDENTIFIERS:
        old, new = previous / subject, candidate / subject
        if not old.exists():
            continue
        for source, target in ((old, new), (new, old)):
            requirement = gate.designated_requirement(source)
            gate.cmd("/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, str(target))


def require_developer_team(fingerprint, listing):
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", fingerprint):
        raise ValueError("Specify the full SHA-1 fingerprint of the authorized Developer ID Application identity")
    pattern = rf'^\s*\d+\)\s+{fingerprint.upper()}\s+"Developer ID Application: [^"\n]+ \(([A-Z0-9]{{10}})\)"\s*$'
    matches = re.findall(pattern, listing, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError("Selected Developer ID Application identity is missing, invalid or ambiguous")
    return matches[0]


def product_fingerprint(listing):
    possible = re.findall(r'^\s*\d+\)\s+([A-F0-9]{40})\s+"Developer ID Application: [^"\n]+ '
                          rf'\({gate.PRODUCT_SIGNING_TEAM}\)"\s*$', listing, re.MULTILINE)
    if len(possible) != 1:
        raise ValueError("Select the authorized Nearpane Developer ID certificate by its full fingerprint")
    return possible[0]


def sign_staged(candidate, fingerprint):
    if (candidate.is_symlink() or candidate.parent.is_symlink()
            or not candidate.parent.name.startswith(".nearpane-stage.")
            or candidate.parent.stat().st_uid != os.getuid() or candidate.parent.stat().st_mode & 0o077):
        raise ValueError("Sign only a candidate inside its private, owned build staging directory")
    app = candidate.resolve(strict=True)
    original = gate.inspect(app)
    listing = gate.cmd("/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
    if fingerprint == "installed-product":
        fingerprint = product_fingerprint(listing)
    team = require_developer_team(fingerprint, listing)
    if team != gate.PRODUCT_SIGNING_TEAM:
        raise ValueError("Selected certificate belongs to a different Developer ID team")

    def seal(component, identifier):
        # Keep the current local package's hardened-runtime and entitlement semantics.
        metadata = gate.cmd("/usr/bin/codesign", "-dvvv", str(component))
        runtime = ["--options", "runtime"] if re.search(r"flags=0x[\da-f]+\([^)]*\bruntime\b", metadata) else []
        gate.cmd("/usr/bin/codesign", "--force", "--sign", fingerprint, "--timestamp=none",
                 "--preserve-metadata=entitlements", *runtime, "--identifier", identifier, str(component))

    seal_components(app, seal)
    after = gate.inspect(app)
    if set(original["binaries"]) != set(after["binaries"]):
        raise ValueError("Nested binary inventory changed during local signing")
    for relative, meta in after["binaries"].items():
        requirement = meta["designatedRequirement"]
        if (meta["signingTeam"] != team or "anchor apple generic" not in requirement
                or "certificate leaf[field.1.2.840.113635.100.6.1.13]" not in requirement):
            raise ValueError(f"Packaged component lacks the expected stable signing identity: {relative}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("staged_app", type=Path)
    parser.add_argument("--identity", required=True, help="Authorized local Developer ID Application fingerprint")
    args = parser.parse_args()
    try:
        sign_staged(args.staged_app, args.identity)
    except subprocess.CalledProcessError as error:
        parser.exit(1, f"{error}\n{error.stdout or ''}\n")
    except (KeyError, OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")
