#!/usr/bin/env python3
"""Package the complete independent R4 candidate, or a PID-scoped acceptance copy."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def package(source: Path, destination: Path, revision: str, *, mode="workspace") -> Path:
    if mode not in ("workspace", "acceptance"):
        raise ValueError("unknown candidate mode")
    if destination.exists():
        raise FileExistsError(destination)
    shutil.copytree(source, destination, symlinks=True)
    plist = destination / "Contents/Info.plist"
    data = plistlib.loads(plist.read_bytes())
    data.update(CFBundleIdentifier="com.holdsnow.nearpane.independent-stage-candidate",
                CFBundleName="Nearpane Independent Stage", NearpaneSourceRevision=revision)
    data.pop("NSServices", None)
    for key in ("NearpaneIndependentStageWorkspace", "NearpaneIndependentStageAcceptance"):
        data.pop(key, None)
    data["NearpaneIndependentStageWorkspace" if mode == "workspace" else "NearpaneIndependentStageAcceptance"] = 1
    plist.write_bytes(plistlib.dumps(data))
    identity = os.environ.get("NP_ENGINE_FIXTURE_SIGN_IDENTITY", "-")
    executable = destination / "Contents/MacOS" / data["CFBundleExecutable"]
    subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", "--identifier",
                    data["CFBundleIdentifier"], executable], check=True, capture_output=True)
    subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", destination], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--strict", "--deep", destination], check=True, capture_output=True)
    return executable


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--mode", choices=("workspace", "acceptance"), default="workspace")
    args = parser.parse_args()
    print(package(args.source.resolve(strict=True), args.destination.resolve(), args.revision, mode=args.mode))
