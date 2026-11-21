"""Link the production cover into an ordinary AppKit fixture and launch only on a disposable hosted Mac."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bin_path", type=Path, help="SwiftPM foundation-only debug directory")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--compile-only", action="store_true")
    mode.add_argument("--hosted-receipt", type=Path)
    args = parser.parse_args()
    keys = ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS")
    if args.hosted_receipt and [os.getenv(k) for k in keys] != ["true", "github-hosted", "macOS"]:
        parser.error("Visible mode requires a GitHub-hosted Mac")
    if args.hosted_receipt and args.hosted_receipt.exists():
        parser.error("Expected a fresh receipt")
    build = args.bin_path.resolve(strict=True)
    root = Path(__file__).resolve().parents[3]
    archive_path = os.environ.get("NEARPANE_ENGINE_ARCHIVE")
    if not archive_path:
        archive_path = subprocess.check_output(["bash", root/"scripts/build-window-engine.sh"], cwd=root, text=True).strip()
    archive = Path(archive_path).resolve(strict=True)
    target_dirs = {"NearpaneUI.build", "NearpaneCore.build", "NearpaneWindowEngine.build", "NearpaneOrdinaryWindowRuntime.build", "CReadOnlySpaces.build", "WindowGeometryCore.build"}
    link_file = build / "NearpanePackageTests.product/Objects.LinkFileList"
    objects = [Path(p) for p in link_file.read_text().splitlines() if Path(p).parent.name in target_dirs]
    if {p.parent for p in objects} != {build / d for d in target_dirs}:
        parser.error("Missing the production UI or its dependencies")
    with tempfile.TemporaryDirectory(prefix="nearpane-hosted-switch.") as directory:
        app = Path(directory).resolve() / "Window Switch Fixture.app"
        binary = app / "Contents/MacOS/SwitchFixture"
        binary.parent.mkdir(parents=True)
        info = dict(CFBundleName="Window Switch Fixture", CFBundlePackageType="APPL", CFBundleExecutable=binary.name,
                    CFBundleVersion="1", CFBundleIdentifier="net.example.nearpane.hosted-window-switch",
                    NSPrincipalClass="NSApplication", LSUIElement=False)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        source = Path(__file__).with_suffix(".swift")
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", platform.machine() + "-apple-macos14.0",
                        "-I", build / "Modules", "-I", root/"Engine/nearpane-window-engine/include",
                        "-Xcc", "-fmodule-map-file=" + str(build / "CReadOnlySpaces.build/module.modulemap"),
                        source, *objects, archive, "-lobjc", "-framework", "Carbon", "-framework", "Security",
                        "-framework", "ApplicationServices", "-o", binary], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", app], check=True, capture_output=True)
        subprocess.run(["codesign", "--verify", "--strict", app], check=True)
        if subprocess.check_output([binary, "--verify-link"], text=True).strip() != "0.16":
            raise ValueError("Signed fixture did not link the expected production cover")
        if args.compile_only:
            return
        receipt = args.hosted_receipt.absolute()
        subprocess.run(["/usr/bin/open", "-n", "-W", *(arg for k in keys for arg in ("--env", k + "=" + os.environ[k])),
                        "-a", app, "--args", "--run-hosted", receipt], check=True, timeout=28)
        row = json.loads(receipt.read_bytes())
        print(json.dumps(row, sort_keys=True))
        if row.get("status") not in ("BLOCKED", "PASS"):
            raise RuntimeError("WindowServer fixture did not complete its ordering and editing checks")
        pixels = row.get("presentedPixels")
        if isinstance(pixels, dict) and pixels.get("status") == "FAIL":
            raise RuntimeError("The presented fixture colors reversed")


if __name__ == "__main__":
    main()
