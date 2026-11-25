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
              "CoreFoundation", "Carbon", "ImageIO", "ScreenCaptureKit", "ColorSync")


def build(archive: Path, out: Path, *, controller_only=False, stdout=None, stderr=None):
    out.mkdir(parents=True, exist_ok=False)
    apps = {}
    def execute(command):
        return subprocess.run(command, check=True, stdout=stdout, stderr=stderr)
    for name, bundle, source in (("FixtureA", "com.holdsnow.nearpane.independent-stage-fixture-a", "fixture.m"),
                                  ("FixtureB", "com.holdsnow.nearpane.independent-stage-fixture-b", "fixture.m"),
                                  ("Controller", "com.holdsnow.nearpane.independent-stage-controller", "controller.m")):
        if controller_only and name != "Controller":
            continue
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
        execute(command + ["-lc++", "-o", str(executable)])
        execute(["codesign", "--force", "--sign", os.environ.get("NP_ENGINE_FIXTURE_SIGN_IDENTITY", "-"),
                 "--timestamp=none", "--identifier", bundle, str(app)])
        execute(["codesign", "--verify", "--strict", "--deep", str(app)])
        apps[name] = {"bundle": bundle, "app": str(app), "executable": str(executable),
                      "sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
    if not controller_only:
        native = HERE.parent / "native-spaces"
        reader, source, helper = out / "reader.o", out / "SplitViewHelper.swift", out / "SplitViewHelper"
        source.write_text((HERE / "split-view-helper.swift").read_text() + "\n" + (native / "lifecycle-menu.swift").read_text())
        read_only = ROOT / "Sources/CReadOnlySpaces"
        execute(["xcrun", "clang", "-c", str(read_only / "ReadOnlySpaces.c"), "-I", str(read_only / "include"),
                 "-o", str(reader)])
        execute(["xcrun", "swiftc", "-parse-as-library", "-D", "SECONDARY_FOCUS_OBSERVER", "-import-objc-header",
                        str(read_only / "include/ReadOnlySpaces.h"), str(source), str(native / "split-picker-geometry.swift"),
                        str(native / "split-picker.swift"), str(HERE.parent / "observe-secondary-space-controls.swift"),
                        str(reader), "-framework", "ColorSync", "-o", str(helper)])
        identifier = "com.holdsnow.nearpane.independent-stage-split-helper"
        execute(["codesign", "--force", "--sign", os.environ.get("NP_ENGINE_FIXTURE_SIGN_IDENTITY", "-"),
                 "--timestamp=none", "--identifier", identifier, str(helper)])
        execute(["codesign", "--verify", "--strict", str(helper)])
        apps["SplitViewHelper"] = {"bundle": identifier, "executable": str(helper),
                                   "sha256": hashlib.sha256(helper.read_bytes()).hexdigest()}
        workspace = out / "CIWorkspace"
        execute(["xcrun", "swiftc", "-parse-as-library", "-D", "SECONDARY_FOCUS_OBSERVER", "-import-objc-header",
                 str(read_only / "include/ReadOnlySpaces.h"), str(HERE / "ci-workspace.swift"),
                 str(HERE.parent / "observe-secondary-space-controls.swift"), str(reader),
                 "-framework", "ColorSync", "-o", str(workspace)])
        identifier = "com.holdsnow.nearpane.independent-stage-ci-workspace"
        execute(["codesign", "--force", "--sign", os.environ.get("NP_ENGINE_FIXTURE_SIGN_IDENTITY", "-"),
                 "--timestamp=none", "--identifier", identifier, str(workspace)])
        execute(["codesign", "--verify", "--strict", str(workspace)])
        apps["CIWorkspace"] = {"bundle": identifier, "executable": str(workspace),
                               "sha256": hashlib.sha256(workspace.read_bytes()).hexdigest()}
    (out / "build.json").write_text(json.dumps({"schema": 1, "apps": apps,
        "archiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest()}, indent=2) + "\n")
    return apps


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("archive", type=Path)
    p.add_argument("output", type=Path)
    a = p.parse_args()
    print(json.dumps(build(a.archive.resolve(strict=True), a.output.resolve()), indent=2))
