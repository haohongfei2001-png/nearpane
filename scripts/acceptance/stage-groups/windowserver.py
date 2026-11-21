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


def run(build, receipt, comparison=None):
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
                        Path(__file__).with_suffix(".swift"), Path(__file__).with_name("visibility.swift"),
                        Path(__file__).with_name("comparison.swift"), *inputs, "-o", binary], check=True)
        if comparison:
            from comparison import run_comparison
            run_comparison(binary, comparison)
            return
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
                failures = [json.loads(path.read_bytes()) for path in root.glob("*-failure.json")]
                result.update(status="BLOCKED" if failures and all(r["status"] == "BLOCKED" for r in failures) else "UNKNOWN",
                              reason="registeredOwnersUnavailable", ownerResults=failures)
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
            if result["status"] == "PASS":
                probe = subprocess.run([binary, "visibility", root], capture_output=True, text=True, timeout=24)
                observed = root / "visibility.json"
                result["singleWindowVisibility"] = (json.loads(observed.read_bytes()) if observed.exists() else
                    {"status": "UNKNOWN", "reason": probe.stderr[-300:] or "missingVisibilityReceipt"})
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
        qualification = result.get("singleWindowVisibility", {}).get("status", "NOT_RUN")
        print("Directory and exact fixture geometry:", result["status"], "| Public single-window AX qualification:", qualification)
        if qualification in ("FAIL", "UNKNOWN"):
            print("::warning::Single-window visibility qualification recorded " + qualification)
        if result["status"] not in ("PASS", "BLOCKED"):
            raise SystemExit(1)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("build", type=Path)
    mode = cli.add_mutually_exclusive_group(required=True)
    mode.add_argument("--compile-only", action="store_true")
    mode.add_argument("--hosted-receipt", type=Path)
    mode.add_argument("--hosted-comparison", type=Path)
    args = cli.parse_args()
    destination = args.hosted_receipt or args.hosted_comparison
    if destination:
        keys = ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS")
        if [os.getenv(k) for k in keys] != ["true", "github-hosted", "macOS"] or destination.exists():
            cli.error("Live tests require a disposable hosted Mac and a new receipt")
    run(args.build.resolve(strict=True), args.hosted_receipt, args.hosted_comparison)
