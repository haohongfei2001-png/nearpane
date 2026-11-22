"""Validate the shipping StageGroupStore against two ordinary registered apps on a disposable Mac."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import tempfile
import time


def lifecycle(binary, root, old_owner, launch_owner):
    inspector = subprocess.Popen([binary, "lifecycle", root], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 23
    relaunched = False
    try:
        while inspector.poll() is None and time.monotonic() < deadline:
            if not relaunched and (root / "lifecycle-retired").exists():
                if old_owner.wait(timeout=3) != 0:
                    raise RuntimeError("fixtureOwnerExit")
                launch_owner("b")
                relaunched = True
            time.sleep(0.08)
        _, detail = inspector.communicate(timeout=2)
        path = root / "lifecycle.json"
        result = json.loads(path.read_bytes()) if path.exists() else {"status": "UNKNOWN", "reason": "missingLifecycleReceipt"}
        if inspector.returncode or not relaunched:
            result.update(status="FAIL" if result.get("status") == "FAIL" else "UNKNOWN", inspectorExit=inspector.returncode,
                          detail=detail.strip()[-350:])
        return result
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        return {"status": "UNKNOWN", "reason": type(error).__name__}
    finally:
        if inspector.poll() is None:
            inspector.terminate()
            inspector.wait(timeout=3)


def preserve_delivery_media(binary, root, receipt, result):
    out = receipt.parent / (receipt.stem + "-delivery")
    out.mkdir(mode=0o700)
    media = {"screen": "NOT_RUN", "video": "NOT_RUN"}
    region = result.get("captureRegion")
    if result.get("screenCapturePreflight") is not True or not isinstance(region, list) or len(region) != 4:
        return {**media, "reason": "fixtureRegionOrCapturePermissionUnavailable"}
    if not all(type(n) is int for n in region) or not (0 < region[2] <= 4096 and 0 < region[3] <= 2160):
        return {**media, "reason": "invalidFixtureRegion"}
    screen = out / "three-windows.png"
    grab = subprocess.run(["/usr/sbin/screencapture", "-x", "-R" + ",".join(map(str, region)), screen],
                          capture_output=True, timeout=6)
    if grab.returncode == 0 and screen.is_file():
        raw = screen.read_bytes()
        if raw.startswith(b"\x89PNG\r\n\x1a\n") and len(raw) >= 24:
            media.update(screen="PASS", pixels=list(struct.unpack(">II", raw[16:24])))
    if media["screen"] != "PASS":
        media["screen"] = "UNKNOWN"
    movie = root / "interactive.mov"
    if movie.is_file():
        probe = subprocess.run([binary, "movie", movie], capture_output=True, text=True, timeout=6)
        shutil.copy2(movie, out / "real-input.mov")
        media["video"] = "PASS" if result.get("recordingExitedSuccessfully") is True and probe.returncode == 0 else "UNKNOWN"
        if probe.returncode == 0:
            media["seconds"] = float(probe.stdout.strip())
    return media


def run(build, receipt, comparison=None, lifecycle_only=False, desktop_items_only=False):
    with tempfile.TemporaryDirectory(prefix="nearpane-group-fixture.") as tmp:
        root = Path(tmp).resolve()
        targets = {"NearpaneCore.build", "WindowGeometryCore.build", "CReadOnlySpaces.build"}
        inputs = [build / "CReadOnlySpaces.build/ReadOnlySpaces.c.o"]
        for target in ("NearpaneCore.build", "WindowGeometryCore.build"):
            mapping = json.loads((build / target / "output-file-map.json").read_bytes())
            inputs.extend(Path(row["object"]) for row in mapping.values() if "object" in row)
        if {p.parent for p in inputs} != {build / target for target in targets}:
            raise RuntimeError("Missing production dependencies")
        binary = root / "StageFixture"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", platform.machine() + "-apple-macos26.0",
                        "-I", build / "Modules", "-Xcc", "-fmodule-map-file=" + str(build / "CReadOnlySpaces.build/module.modulemap"),
                        Path(__file__).with_suffix(".swift"), Path(__file__).with_name("visibility.swift"),
                        Path(__file__).with_name("comparison.swift"), Path(__file__).with_name("recording.swift"),
                        Path(__file__).with_name("wallpaper.swift"), Path(__file__).with_name("lifecycle.swift"),
                        Path(__file__).with_name("desktop-items.swift"), Path(__file__).with_name("interactive-delivery.swift"),
                        Path(__file__).resolve().parents[3] / "Sources/NearpaneUI/WallpaperRevealMonitor.swift",
                        Path(__file__).resolve().parents[3] / "Sources/NearpaneUI/DesktopItemsSetting.swift",
                        *inputs, "-o", binary], check=True)
        if comparison:
            from comparison import run_comparison
            run_comparison(binary, comparison, desktop_items_only=desktop_items_only)
            return
        if receipt is None:
            return
        result = {"status": "UNKNOWN", "profileRemoved": False, "installedHost": "NOT_RUN",
                  "groupVisibilitySwitch": "NOT_RUN", "physicalMultiDisplay": "NOT_RUN", "nativeWrites": 0,
                  "sourceRevision": os.environ["GITHUB_SHA"], "scope": "two registered ordinary fixture apps and two independent directory readers"}
        apps, processes = {}, []
        def launch_owner(name):
            proc = subprocess.Popen(["/usr/bin/open", "-g", "-n", "-W", "--env", "RUNNER_ENVIRONMENT=github-hosted",
                                     "-a", apps[name], "--args", name, root])
            processes.append(proc)
            return proc

        try:
            if not lifecycle_only:
                (root / "delivery-mode").touch(exist_ok=False)
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
                launch_owner(name)
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
            if result["status"] == "PASS" and lifecycle_only:
                result["processLifecycle"] = lifecycle(binary, root, processes[1], launch_owner)
                result["status"] = result["processLifecycle"]["status"]
            elif result["status"] == "PASS":
                delivery = subprocess.run([binary, "delivery", root], capture_output=True, text=True, timeout=13)
                delivery_path = root / "delivery.json"
                result["interactiveDelivery"] = (json.loads(delivery_path.read_bytes()) if delivery_path.exists() else
                    {"status": "UNKNOWN", "reason": "deliveryReceiptMissing", "exit": delivery.returncode})
                try:
                    result["deliveryMedia"] = preserve_delivery_media(binary, root, receipt, result["interactiveDelivery"])
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    result["deliveryMedia"] = {"screen": "UNKNOWN", "video": "UNKNOWN", "reason": type(error).__name__}
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
        delivery = result.get("interactiveDelivery", {}).get("status")
        if delivery in {"FAIL", "UNKNOWN"}:
            raise SystemExit("Isolated three-window receiver verification: " + delivery)
        if qualification in ("FAIL", "UNKNOWN"):
            print("::warning::Single-window visibility qualification recorded " + qualification)
        if result["status"] not in ("PASS", "BLOCKED") or result.get("processLifecycle", {}).get("status") in ("FAIL", "UNKNOWN"):
            raise SystemExit(1)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("build", type=Path)
    mode = cli.add_mutually_exclusive_group(required=True)
    mode.add_argument("--compile-only", action="store_true")
    mode.add_argument("--hosted-receipt", type=Path)
    mode.add_argument("--hosted-lifecycle", type=Path)
    mode.add_argument("--hosted-comparison", type=Path)
    mode.add_argument("--hosted-desktop-items", type=Path)
    args = cli.parse_args()
    comparison = args.hosted_comparison or args.hosted_desktop_items
    destination = args.hosted_receipt or args.hosted_lifecycle or comparison
    if destination:
        keys = ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS")
        if [os.getenv(k) for k in keys] != ["true", "github-hosted", "macOS"] or destination.exists():
            cli.error("Live tests require a disposable hosted Mac and a new receipt")
    run(args.build.resolve(strict=True), args.hosted_receipt or args.hosted_lifecycle, comparison,
        lifecycle_only=args.hosted_lifecycle is not None, desktop_items_only=args.hosted_desktop_items is not None)
