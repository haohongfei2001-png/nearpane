#!/usr/bin/env python3
"""Exercise nested signing and helper repinning on a disposable copy. No identity or upload option."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

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


def sign(path, identifier):
    gate.cmd("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime",
             "--identifier", identifier, str(path))


def rehearse(source):
    original = gate.inspect(source)
    source = source.resolve(strict=True)
    signed_tree = {p.relative_to(source): sha(p) for p in source.rglob("*") if p.is_file()}
    with tempfile.TemporaryDirectory(prefix="nearpane-signing-") as work:
        temp = Path(work) / "Nearpane Signing Rehearsal.app"
        gate.cmd("/usr/bin/ditto", "--norsrc", "--noextattr", str(source), str(temp))
        helpers = temp / "Contents/Helpers"
        fixture = helpers / "NearpaneFixtureWindows.app"
        ctl = helpers / "NearpaneFrameController.app"
        readers = (helpers / "NearpaneDesktopReader", fixture / "Contents/Helpers/NearpaneDesktopReader")
        writer = helpers / "NearpaneOrdinaryWindowController"
        automation = helpers / "NearpaneAutomation"
        additional = [automation] if automation.exists() else []
        for binary in (*readers, writer, *additional):
            if binary.is_symlink() or not binary.is_file():
                raise ValueError("Expected regular helper binary")
            # Keep the existing designated identifier of each standalone executable.
            fields = gate.cmd("/usr/bin/codesign", "-dv", str(binary)).splitlines()
            identifiers = [s.split("=", 1)[1] for s in fields if s.startswith("Identifier=")]
            if len(identifiers) != 1:
                raise ValueError("Helper lacks a signing identifier")
            sign(binary, identifiers[0])
        pin(fixture, "NearpaneDesktopReaderSHA256", readers[1])
        pin(temp, "NearpaneDesktopReaderSHA256", readers[0])
        pin(temp, "NearpaneOrdinaryWindowControllerSHA256", writer)
        if additional:
            plist = temp / "Contents/Info.plist"
            info = plistlib.loads(plist.read_bytes())
            info["NearpaneAutomationSHA256"]["Helpers/NearpaneAutomation"] = sha(automation)
            plist.write_bytes(plistlib.dumps(info))
        for bundle in (fixture, ctl, temp):
            identifier = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
            sign(bundle, identifier)
        after = gate.inspect(temp)
        if additional:
            gate.cmd(str(temp / "Contents/MacOS/NearpaneHost"), "--check-helper-runtime")
        if set(original["binaries"]) != set(after["binaries"]):
            raise ValueError("Binary inventory changed")
        for bundle, key, executable in ((temp, "NearpaneDesktopReaderSHA256", readers[0]),
                                       (temp, "NearpaneOrdinaryWindowControllerSHA256", writer),
                                       (fixture, "NearpaneDesktopReaderSHA256", readers[1])):
            if plistlib.loads((bundle / "Contents/Info.plist").read_bytes())[key] != sha(executable):
                raise ValueError("Nested signing invalidated helper binding")
        for rel in after["binaries"]:
            meta = gate.cmd("/usr/bin/codesign", "-dvvv", str(temp / "Contents" / rel))
            if "(adhoc,runtime)" not in meta and "(runtime,adhoc)" not in meta:
                raise ValueError("Expected only a hardened rehearsal signature: " + rel)
        if signed_tree != {p.relative_to(source): sha(p) for p in source.rglob("*") if p.is_file()}:
            raise ValueError("Input candidate changed")
        return dict(inputUnchanged=True, sealedBinaries=len(after["binaries"]), refreshedHelperPins=3+len(additional),
                    developerIDUsed=False, uploaded=False, notarization="NOT_TESTED", outcome="LOCAL_REHEARSAL_ONLY")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("app", type=Path)
    try:
        print(json.dumps(rehearse(p.parse_args().app)))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as err:
        p.exit(1, str(err) + "\n")
