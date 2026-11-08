#!/usr/bin/env python3
"""Offline-only verification. Every invocation gets a new, non-overwritable receipt directory."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    package = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", required=True, help="New directory under this package's evidence/ directory")
    args = parser.parse_args()
    output = (package / "evidence" / args.receipt).resolve()
    if not output.is_relative_to(package / "evidence"):
        parser.error("Receipt must be under evidence/")
    output.mkdir(parents=True, exist_ok=False)
    build = package / ".build"
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(build / "clang-module-cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(build / "swift-module-cache")
    env["SWIFT_MODULECACHE_PATH"] = str(build / "swift-module-cache")
    env["LC_ALL"] = "C"
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    commands = []

    def run(label, command):
        log = output / f"{label}.log"
        print(f"Running {label}; receipt: {log.relative_to(package)}", flush=True)
        with log.open("xb") as stream:
            result = subprocess.run(command, cwd=package, env=env, stdout=stream, stderr=subprocess.STDOUT, check=False)
        commands.append({"label": label, "argv": command, "cwd": str(package), "exitCode": result.returncode,
                         "log": str(log.relative_to(package))})
        print(f"{label}: exit {result.returncode}", flush=True)
        if result.returncode:
            print(log.read_text(errors="replace")[-14000:], flush=True)
        return result.returncode, log.read_text(errors="replace")

    run("environment", ["/usr/bin/sw_vers"])
    run("architecture", ["/usr/bin/uname", "-m"])
    run("swift-version", ["/usr/bin/xcrun", "swift", "--version"])
    _, compiler_path = run("swift-compiler-path", ["/usr/bin/xcrun", "--find", "swiftc"])
    _, head = run("input-head", ["/usr/bin/git", "rev-parse", "HEAD"])
    source_paths = sorted([package / "Package.swift", Path(__file__).resolve(), package / ".gitignore"]
                          + list((package / "Sources").rglob("*.swift"))
                          + list((package / "Tests").rglob("*.swift")))
    source_hashes = {str(p.relative_to(package)): digest(p) for p in source_paths}
    (output / "source-sha256.json").write_text(json.dumps(source_hashes, indent=2, sort_keys=True) + "\n")

    # A static guard, not a claim that metadata observation or activation works live.
    forbidden = r"AXUIElementPerformAction|AXUIElementSetAttributeValue|AXIsProcessTrustedWithOptions|" \
                r"AXMakeProcessTrusted|CGRequestScreenCaptureAccess|CGWindowListCreateImage|" \
                r"ScreenCaptureKit|SkyLight|SLSCopy|CGSSet|NSApplication\.shared|" \
                r"\.activate\s*\(|makeKeyAndOrderFront|orderFront|setFrame\s*\("
    violations = []
    for path in (package / "Sources").rglob("*.swift"):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if re.search(forbidden, line):
                violations.append(f"{path.relative_to(package)}:{number}")
    static = {"forbiddenCallPattern": forbidden, "violations": violations,
              "scope": "Sources/*.swift textual guard; not semantic or live verification"}
    (output / "static-boundary.json").write_text(json.dumps(static, indent=2) + "\n")

    common = ["--disable-sandbox", "--build-system", "native",
              "--package-path", str(package), "--scratch-path", str(build),
              "--cache-path", str(build / "package-cache"), "--config-path", str(build / "configuration"),
              "--security-path", str(build / "security"), "-Xswiftc", "-warnings-as-errors"]
    # CLT Swift 6.4 includes Testing but swiftbuild does not automatically resolve its macro plugin.
    # Explicitly load the installed toolchain library; no downloads or system configuration edits.
    testing_plugin = Path(compiler_path.strip()).parent.parent / "lib/swift/host/plugins/testing/libTestingMacros.dylib"
    plugin_flags = ["-Xswiftc", "-load-plugin-library", "-Xswiftc", str(testing_plugin)] if testing_plugin.is_file() else []
    # Native SwiftPM also needs the CLT-only framework layout made explicit.
    developer_library = Path(compiler_path.strip()).parents[2] / "Library/Developer"
    frameworks = developer_library / "Frameworks"
    if (frameworks / "Testing.framework").is_dir():
        plugin_flags += ["-Xswiftc", "-F", "-Xswiftc", str(frameworks),
                         "-Xlinker", "-F", "-Xlinker", str(frameworks),
                         "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                         "-Xlinker", "-rpath", "-Xlinker", str(developer_library / "usr/lib")]
    test_code, tests = run("swift-test", ["/usr/bin/xcrun", "swift", "test", *common,
                                        "--disable-xctest", "--enable-swift-testing", *plugin_flags])
    build_code = None
    if test_code == 0:
        build_code, _ = run("swift-build-release", ["/usr/bin/xcrun", "swift", "build", *common, "-c", "release"])
    metric_lines = re.findall(r"^GEOMETRY_METRICS (.+)$", tests, flags=re.MULTILINE)
    metrics = json.loads(metric_lines[0]) if len(metric_lines) == 1 else None
    if metrics:
        (output / "geometry-metrics.json").write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n")
    test_counts = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", tests)
    test_summary = {"executed": int(test_counts[-1]), "failures": 0} if test_counts else None
    unchanged = source_hashes == {str(p.relative_to(package)): digest(p) for p in source_paths}
    passed = (all(c["exitCode"] == 0 for c in commands) and not violations and metrics is not None
              and unchanged and test_summary is not None and test_summary["executed"] > 0)
    receipt = {
        "schema": 1, "startedUTC": started, "finishedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "inputGitHEAD": head.strip(), "note": "Input HEAD plus source-sha256.json identifies the tested uncommitted payload.",
        "status": "PASS" if passed else "FAIL", "commands": commands,
        "tests": test_summary,
        "sourceUnchangedDuringVerification": unchanged,
        "matrix": {"pureGeometryAndIdentity": "PASS" if test_code == 0 and metrics else "FAIL",
                   "releaseBuild": "NOT_RUN" if build_code is None else ("PASS" if build_code == 0 else "FAIL"),
                   "staticBoundary": "PASS" if not violations else "FAIL",
                   "liveAXCGMatching": "NOT_TESTED", "liveGeometryCalibration": "NOT_TESTED",
                   "activation": "NOT_TESTED", "SpacesSwitching": "NOT_TESTED",
                   "visibleTestWindowFixture": "NOT_BUILT_NOT_LAUNCHED"},
        "releaseArtifactsSHA256": {str(p.relative_to(package)): digest(p)
            for p in sorted(list(build.glob("*/release/Modules/*.swiftmodule"))
                            + list(build.glob("*/release/WindowGeometryCore.build/*.o"))
                            + list(build.glob("*/release/ReadOnlyWindowMetadata.build/*.o")))},
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    manifest = "".join(f"{digest(p)}  {p.relative_to(package)}\n" for p in sorted(output.iterdir()) if p.is_file())
    (output / "SHA256SUMS.txt").write_text(manifest)
    print(json.dumps({"status": receipt["status"], "tests": receipt["tests"], "metrics": metrics}, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
