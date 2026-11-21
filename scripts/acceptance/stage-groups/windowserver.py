"""Validate the shipping StageGroupStore against two ordinary registered apps on a disposable Mac."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time


def run(build, receipt):
    with tempfile.TemporaryDirectory(prefix="nearpane-group-fixture.") as tmp:
        root = Path(tmp).resolve()
        objects = (build / "NearpanePackageTests.product/Objects.LinkFileList").read_text().splitlines()
        targets = {"NearpaneCore.build", "WindowGeometryCore.build", "CReadOnlySpaces.build"}
        inputs = [Path(p) for p in objects if Path(p).parent.name in targets]
        if {p.parent for p in inputs} != {build / target for target in targets}:
            raise RuntimeError("Missing production dependencies")
        binary = root / "StageFixture"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", platform.machine() + "-apple-macos26.0",
                        "-I", build / "Modules", "-Xcc", "-fmodule-map-file=" + str(build / "CReadOnlySpaces.build/module.modulemap"),
                        Path(__file__).with_suffix(".swift"), *inputs, "-o", binary], check=True)
        if receipt is None:
            return
        result = {"status": "UNKNOWN", "profileRemoved": False, "installedHost": "NOT_RUN",
                  "groupVisibilitySwitch": "NOT_RUN", "physicalMultiDisplay": "NOT_RUN", "nativeWrites": 0,
                  "sourceRevision": os.environ["GITHUB_SHA"], "scope": "two registered ordinary fixture apps and two independent directory readers"}
        apps, processes = {}, []
        try:
            for name in ("a", "b"):
                app = root / ("Stage Fixture " + name + ".app")
                executable = app / "Contents/MacOS/StageFixture"
                executable.parent.mkdir(parents=True)
                shutil.copy2(binary, executable)
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundleName=app.stem, CFBundlePackageType="APPL",
                    CFBundleExecutable=executable.name, CFBundleIdentifier="net.example.nearpane.stage-group-" + name,
                    CFBundleVersion="1", NSPrincipalClass="NSApplication", LSUIElement=False)))
                subprocess.run(["codesign", "-s", "-", "--force", app], check=True)
                subprocess.run(["codesign", "--verify", "--strict", app], check=True)
                apps[name] = app
                processes.append(subprocess.Popen(["/usr/bin/open", "-g", "-n", "-W", "--env", "RUNNER_ENVIRONMENT=github-hosted",
                                                   "-a", app, "--args", name, root]))
            deadline = time.monotonic() + 10
            while not all((root / (n + ".json")).exists() for n in apps) and time.monotonic() < deadline:
                if any(p.poll() is not None for p in processes):
                    break
                time.sleep(0.1)
            if not all((root / (n + ".json")).exists() for n in apps):
                result.update(status="BLOCKED", reason="registeredOwnersUnavailable")
            else:
                for phase in ("record", "reopen"):
                    check = subprocess.run([binary, phase, root], capture_output=True, text=True, timeout=10)
                    row = root / (phase + ".json")
                    if row.exists():
                        result[phase] = json.loads(row.read_bytes())
                    if check.returncode:
                        result.update(status="FAIL", reason=check.stderr[-300:])
                        break
                else:
                    a, b = result["record"], result["reopen"]
                    if (a["inspectorPID"] != b["inspectorPID"] and a["groupIDs"] == b["groupIDs"]
                            and a["nativeMembership"] == b["nativeMembership"] and b["oldBindingsIneligible"]):
                        result["status"] = "PASS"
                    else:
                        result.update(status="FAIL", reason="independentReaderMismatch")
        finally:
            (root / "stop").touch()
            result["fixtureProcessesExited"] = all([proc.wait(timeout=12) == 0 for proc in processes])
            if not result["fixtureProcessesExited"]:
                result.update(status="FAIL", reason="fixtureCleanupFailed")
            profile = root / "profile"
            if profile.exists():
                shutil.rmtree(profile)
            result["profileRemoved"] = not profile.exists()
            receipt.write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result, sort_keys=True))
        if result["status"] not in ("PASS", "BLOCKED"):
            raise SystemExit(1)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("build", type=Path)
    mode = cli.add_mutually_exclusive_group(required=True)
    mode.add_argument("--compile-only", action="store_true")
    mode.add_argument("--hosted-receipt", type=Path)
    args = cli.parse_args()
    if args.hosted_receipt:
        keys = ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS")
        if [os.getenv(k) for k in keys] != ["true", "github-hosted", "macOS"] or args.hosted_receipt.exists():
            cli.error("Live tests require a disposable hosted Mac and a new receipt")
    run(args.build.resolve(strict=True), args.hosted_receipt)
