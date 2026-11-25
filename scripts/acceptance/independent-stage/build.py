#!/usr/bin/env python3
"""Build three distinct ordinary apps; neither build nor signing launches them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ENGINE = ROOT / "Engine/nearpane-window-engine"
FRAMEWORKS = ("AppKit", "Foundation", "CoreGraphics", "ApplicationServices", "Security", "QuartzCore",
              "CoreFoundation", "Carbon", "ImageIO", "ScreenCaptureKit")


def build(archive: Path, out: Path):
    out.mkdir(parents=True, exist_ok=False)
    apps = {}
    for name, bundle, source in (("FixtureA", "com.holdsnow.nearpane.independent-stage-fixture-a", "fixture.m"),
                                  ("FixtureB", "com.holdsnow.nearpane.independent-stage-fixture-b", "fixture.m"),
                                  ("Controller", "com.holdsnow.nearpane.independent-stage-controller", "controller.m")):
        app = out / (name + ".app")
        executable = app / "Contents/MacOS" / name
        executable.parent.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundlePackageType": "APPL", "CFBundleIdentifier": bundle, "CFBundleExecutable": name,
            "CFBundleName": name, "CFBundleVersion": "1", "NSPrincipalClass": "NSApplication",
            "LSUIElement": name == "Controller",
        }))
        command = ["xcrun", "clang", "-fobjc-arc", "-O1", "-Wall", "-Wextra", "-Werror",
                   "-I", str(ENGINE / "include"), "-I", str(ENGINE / "src/spaces"), str(HERE / source)]
        if name == "Controller":
            command += [str(archive)]
        command += [x for framework in FRAMEWORKS for x in ("-framework", framework)]
        subprocess.run(command + ["-lc++", "-o", str(executable)], check=True)
        subprocess.run(["codesign", "--force", "--sign", os.environ.get("NP_ENGINE_FIXTURE_SIGN_IDENTITY", "-"),
                        "--timestamp=none", "--identifier", bundle, str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", "--deep", str(app)], check=True)
        apps[name] = {"bundle": bundle, "app": str(app), "executable": str(executable),
                      "sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
    (out / "build.json").write_text(json.dumps({"schema": 1, "apps": apps,
        "archiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest()}, indent=2) + "\n")
    return apps


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("archive", type=Path)
    p.add_argument("output", type=Path)
    a = p.parse_args()
    print(json.dumps(build(a.archive.resolve(strict=True), a.output.resolve()), indent=2))
