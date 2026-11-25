#!/usr/bin/env python3
"""Package the complete independent R4 candidate, or a PID-scoped acceptance copy."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
AUTOMATION_FILES = (
    "Helpers/NearpaneAutomation", "Resources/Automation/stdlib.zip",
    "Resources/Profile/profile-migration.py", "Resources/Profile/profile_domains.py",
    "Resources/WorkRect/window-management.py",
)


def workspace_tools(destination: Path, metadata: dict) -> dict:
    """Reuse the existing sealed profile runtime; build it only when the donor lacks it."""
    contents = destination / "Contents"
    if "NearpaneAutomationSHA256" not in metadata:
        if (contents / "Helpers/NearpaneAutomation").exists() or (contents / "Resources/Automation").exists():
            raise ValueError("Unsealed automation runtime in the supplied application")
        for folder, names in (("Profile", ("profile-migration.py", "profile_domains.py")),
                              ("WorkRect", ("window-management.py",))):
            target = contents / "Resources" / folder
            target.mkdir(parents=True, exist_ok=True)
            for name in names:
                shutil.copy2(ROOT / "scripts" / name, target / name)
        subprocess.run([sys.executable, "-B", str(ROOT / "scripts/build-helper-runtime.py"), str(destination)],
                       cwd=ROOT, check=True)
        metadata = plistlib.loads((contents / "Info.plist").read_bytes())
    seals = metadata.get("NearpaneAutomationSHA256")
    if not isinstance(seals, dict) or set(seals) != set(AUTOMATION_FILES):
        raise ValueError("Incomplete workspace automation seal")
    for relative in AUTOMATION_FILES:
        path = contents / relative
        if path != path.resolve() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != seals[relative]:
            raise ValueError("Workspace automation integrity mismatch: " + relative)
    return metadata


def package(source: Path, destination: Path, revision: str, *, mode="workspace") -> Path:
    if mode not in ("workspace", "acceptance"):
        raise ValueError("unknown candidate mode")
    if destination.exists():
        raise FileExistsError(destination)
    data = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if (not re.fullmatch(r"[0-9a-f]{40}", revision) or
            data.get("NearpaneStageEngineSourceRevision") != revision or
            data.get("NearpaneStageEngineSourceState") != "clean"):
        raise ValueError("The supplied application must be built from the requested clean source revision")
    if data.get("NearpaneReadOnlyGuardianProtocol") is not None or data.get("NearpaneNativeMergeFixtureProtocol") is not None:
        raise ValueError("A diagnostic-only host cannot be packaged as the interactive workspace")
    shutil.copytree(source, destination, symlinks=True)
    plist = destination / "Contents/Info.plist"
    if mode == "workspace":
        for resource in ("Nearpane_SaytileKit.bundle", "Riftlet_RiftletAdapters.bundle"):
            if not (destination / "Contents/Resources" / resource).is_dir():
                raise ValueError("Workspace mode requires the complete embedded application: " + resource)
        data = workspace_tools(destination, data)
    worker = destination / "Contents/Helpers/NearpaneSpacesEngine"
    if (worker != worker.resolve() or not worker.is_file() or
            hashlib.sha256(worker.read_bytes()).hexdigest() != data.get("NearpaneSpacesEngineSHA256")):
        raise ValueError("Spaces engine helper integrity mismatch")
    identity = os.environ.get("NP_ENGINE_FIXTURE_SIGN_IDENTITY", "-")
    subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", "--options", "runtime",
                    "--identifier", "com.holdsnow.nearpane.spaces-engine", worker], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--strict", worker], check=True, capture_output=True)
    # Signing changes bytes, so the final parent seal must describe this exact helper.
    data["NearpaneSpacesEngineSHA256"] = hashlib.sha256(worker.read_bytes()).hexdigest()
    data.update(CFBundleIdentifier="com.holdsnow.nearpane.independent-stage-candidate",
                CFBundleName="Nearpane Independent Stage", CFBundleDisplayName="Nearpane Independent Stage",
                LSMultipleInstancesProhibited=True, NearpaneSourceRevision=revision)
    data.pop("NSServices", None)
    for key in ("NearpaneIndependentStageWorkspace", "NearpaneIndependentStageAcceptance"):
        data.pop(key, None)
    data["NearpaneIndependentStageWorkspace" if mode == "workspace" else "NearpaneIndependentStageAcceptance"] = 1
    plist.write_bytes(plistlib.dumps(data))
    executable = destination / "Contents/MacOS" / data["CFBundleExecutable"]
    signing = ["codesign", "--force", "--sign", identity, "--timestamp=none", "--entitlements",
               str(ROOT / "Resources/NearpaneHost.entitlements"), "--identifier", data["CFBundleIdentifier"]]
    subprocess.run([*signing, executable], check=True, capture_output=True)
    subprocess.run([*signing, destination], check=True, capture_output=True)
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
