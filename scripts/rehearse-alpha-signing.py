#!/usr/bin/env python3
"""Exercise nested signing and helper repinning on a disposable copy. No identity or upload option."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from candidate_signing import gate, seal_components, sha


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
        refreshed = seal_components(temp, sign)
        after = gate.inspect(temp)
        if (temp / "Contents/Helpers/NearpaneAutomation").exists():
            gate.cmd(str(temp / "Contents/MacOS/NearpaneHost"), "--check-helper-runtime")
        if set(original["binaries"]) != set(after["binaries"]):
            raise ValueError("Binary inventory changed")
        for rel in after["binaries"]:
            meta = gate.cmd("/usr/bin/codesign", "-dvvv", str(temp / "Contents" / rel))
            if "(adhoc,runtime)" not in meta and "(runtime,adhoc)" not in meta:
                raise ValueError("Expected only a hardened rehearsal signature: " + rel)
        if signed_tree != {p.relative_to(source): sha(p) for p in source.rglob("*") if p.is_file()}:
            raise ValueError("Input candidate changed")
        return dict(inputUnchanged=True, sealedBinaries=len(after["binaries"]), refreshedHelperPins=refreshed,
                    developerIDUsed=False, uploaded=False, notarization="NOT_TESTED", outcome="LOCAL_REHEARSAL_ONLY")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("app", type=Path)
    try:
        print(json.dumps(rehearse(p.parse_args().app)))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as err:
        p.exit(1, str(err) + "\n")
