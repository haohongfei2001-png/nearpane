#!/usr/bin/env python3
"""Run the WindowEngine's Rust, Swift and C ABI checks without opening a graphical session."""

import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from hosted_scope import build_reader

ROOT = Path(__file__).resolve().parents[4]
CRATE = ROOT / "Engine/nearpane-window-engine"
ACCEPTANCE = ROOT / "scripts/acceptance/window-engine"
FRAMEWORKS = (
    "Foundation",
    "AppKit",
    "ApplicationServices",
    "CoreGraphics",
    "CoreFoundation",
    "Security",
    "Carbon",
    "ImageIO",
)


def rust_count(log):
    counts = re.findall(r"^test result: ok\. (\d+) passed; 0 failed;", log, re.M)
    if (
        not counts
        or not sum(map(int, counts))
        or not all(
            re.search(r"^test " + prefix + r".+ \.\.\. ok$", log, re.M) for prefix in ("corner::", "spaces::")
        )
    ):
        raise ValueError("missingRustEngineTestResults")
    return {"passed": sum(map(int, counts))}


def swift_count(xml, suites):
    completed = {}
    for case in ET.parse(xml).findall(".//testcase"):
        suite = case.get("classname", "").split(".")[-1]
        name = case.get("name")
        if (
            not suite
            or not name
            or any(case.find(tag) is not None for tag in ("failure", "error", "skipped"))
        ):
            raise ValueError("incompleteSwiftTestCase")
        tests = completed.setdefault(suite, set())
        if name in tests:
            raise ValueError("duplicateSwiftTestCase " + suite + "." + name)
        tests.add(name)
    if set(completed) != set(suites):
        raise ValueError("unexpectedSwiftSuites " + ",".join(sorted(set(completed) ^ set(suites))))
    return {
        "passed": sum(len(cases) for cases in completed.values()),
        "suites": sorted(completed),
        "xunit": xml.name,
    }


def python_count(log):
    match = re.search(r"^Ran ([1-9]\d*) tests? in .+\n\nOK\s*$", log, re.M)
    if not match:
        raise ValueError("missingPythonTestResults")
    return {"passed": int(match[1])}


def abi_result(log):
    report = json.loads(log)
    for key in (
        "unreviewedEvidenceRefused",
        "wrongExecutableCannotCreateProbeToken",
        "closedWithoutOwnedResources",
    ):
        if report.get(key) is not True:
            raise ValueError("invalidABIReadback " + key)
    for key in ("passiveHostLaunch", "passiveHostCleanup"):
        result = report.get(key, {})
        if not (
            result.get("refusedWithoutOwnership") is True
            and all(
                type(result.get(k)) is int and result[k] == v
                for k, v in {"submit": 0, "poll": 0, "status": 3, "flags": 0, "owned": 0}.items()
            )
        ):
            raise ValueError("invalidABIReadback " + key)
    if report.get("physicalWindowOperations") != 0:
        raise ValueError("unexpectedPhysicalABIActivity")
    return {"readback": report}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new evidence directory")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    env = dict(os.environ, NEARPANE_FOUNDATION_ONLY="1", PYTHONDONTWRITEBYTECODE="1")
    if not shutil.which("cargo"):
        portable = ROOT / "build/window-engine/toolchain/portable/bin"
        if (portable / "cargo").is_file():
            env["PATH"] = str(portable) + os.pathsep + env["PATH"]
    phases = (
        "rust",
        "release",
        "c-abi-link",
        "c-abi",
        "product-guardian-build",
        "guardian-exit-build",
        "guardian-exit",
        "corner-witness-build",
        "corner-witness",
        "interactive-fixture-build",
        "held-input-build",
        "held-input",
        "swift",
        "hosted-reader-build",
        "overview-witness-build",
        "spaces-tests",
        "performance-tests",
        "corner-lease-tests",
        "installed-host-tests",
        "installed-supervisor-tests",
        "ci-tests",
    )
    checks = {name: {"status": "NOT_RUN"} for name in phases}
    report = {
        "schema": 1,
        "scope": "automatedSourceTests",
        "status": "UNKNOWN",
        "checkout": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "architecture": os.uname().machine,
        "macOSBuild": subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"], text=True).strip(),
        "physicalQualification": "NOT_RUN",
        "checks": checks,
    }

    def save():
        tmp = out / "source-result.next"
        tmp.write_text(json.dumps(report, indent=2) + "\n")
        tmp.replace(out / "source-result.json")

    def run(name, command, verify=None):
        path = out / (name + ".log")
        errors = out / (name + ".stderr.log")
        files = {"log": path.name, "stderr": errors.name}
        checks[name] = {"status": "UNKNOWN", "reason": "startedWithoutTerminalResult", **files}
        save()
        try:
            with path.open("x") as stream, errors.open("x") as err:
                proc = subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=err)
            stdout = path.read_text(errors="replace")
            log = errors.read_text(errors="replace") + "\n" + stdout
            entry = {
                "status": "FAIL" if proc.returncode else "PASS",
                "exit": proc.returncode,
                **files,
            }
            if proc.returncode:
                print(log[-6500:], flush=True)
            elif verify:
                entry.update(verify(stdout if name in ("release", "c-abi") else log))
        except (OSError, ValueError, ET.ParseError) as exc:
            entry = {"status": "FAIL", "reason": str(exc), **files}
        checks[name] = entry
        print(name, entry["status"], entry.get("passed", entry.get("reason", "")), flush=True)
        save()
        return entry["status"] == "PASS"

    save()
    # The production wrappers use the unique standalone directory for both the canonical hash path
    # and SwiftPM's cache. Reopening this immutable archive for Swift reuses the first release build.
    (ROOT / "build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="standalone.window-engine-ci-", dir=ROOT / "build") as scratch:
        work = Path(scratch)
        env["NEARPANE_RUN_ID"] = work.name.removeprefix("standalone.")
        env["CARGO_TARGET_DIR"] = str(work / "cargo")
        cargo = [
            "--manifest-path",
            str(CRATE / "Cargo.toml"),
            "--locked",
            "--offline",
            "--no-default-features",
        ]
        run("rust", ["cargo", "test", *cargo, "--features", "corner,spaces,isolated-fixtures"], rust_count)
        exit_watch = work / "guardian-exit"
        if run("guardian-exit-build", ["xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror",
                "-I", CRATE / "src/corner", ACCEPTANCE / "corner/guardian-exit-test.m",
                "-framework", "Foundation", "-framework", "Security", "-o", exit_watch]):
            run("guardian-exit", [exit_watch], lambda log: {"readback": json.loads(log)})
        witness = work / "corner-witness"
        if run("corner-witness-build", ["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                "-I", CRATE / "src/corner", ACCEPTANCE / "corner/patch-input-test.m",
                "-framework", "AppKit", "-framework", "CoreGraphics", "-framework", "CoreFoundation",
                "-framework", "ImageIO", "-o", witness]):
            run("corner-witness", [witness, work / "fixture.png"], lambda log: {"readback": json.loads(log)})
        run("interactive-fixture-build", ["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
            "-mmacosx-version-min=26.0", "-DNP_HOST_INTERACTIVE_FIXTURE=1", "-I", CRATE / "src/corner",
            ACCEPTANCE / "corner/owner.m", "-framework", "AppKit", "-framework", "Security", "-framework", "CoreGraphics",
            "-lbsm", "-o", work / "interactive-fixture-compile-only"])
        input_test = work / "held-input"
        if run("held-input-build", ["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-I", CRATE / "src",
                ACCEPTANCE / "ci/input-state-test.m", "-o", input_test]):
            run("held-input", [input_test], lambda log: {"readback": json.loads(log)})
        archive = None

        def archive_result(log):
            nonlocal archive
            paths = log.rstrip().splitlines()
            if not paths:
                raise ValueError("productionArchivePathMissing")
            archive = Path(paths[-1]).resolve()
            if work not in archive.parents or archive.name != "libnearpane_window_engine.a":
                raise ValueError("unexpectedProductionArchivePath")
            return {"features": ["corner", "spaces"], "sha256": sha256(archive.read_bytes()).hexdigest()}

        if run("release", ["bash", "scripts/build-window-engine.sh"], archive_result):
            env["NEARPANE_ENGINE_ARCHIVE"] = str(archive)
            run("product-guardian-build", ["bash", ACCEPTANCE / "corner/build-guardian.sh",
                                          work / "NearpaneCornerGuardian", archive])
            link = [part for name in FRAMEWORKS for part in ("-framework", name)]
            exe = work / "passive-c-abi"
            if run(
                "c-abi-link",
                [
                    "xcrun",
                    "clang",
                    "-fobjc-arc",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I",
                    CRATE / "include",
                    "-I",
                    CRATE / "src/spaces",
                    ACCEPTANCE / "spaces/launch-passive.m",
                    archive,
                    *link,
                    "-lc++",
                    "-o",
                    exe,
                ],
            ):
                run("c-abi", [exe], abi_result)
            suites = sorted(
                {p.stem for p in (ROOT / "Tests/NearpaneWindowEngineTests").glob("*Tests.swift")}
                | {p.stem for p in (ROOT / "Tests").glob("*/Stage*Tests.swift")}
            )
            xml = out / "swift.xml"
            run(
                "swift",
                [
                    "bash",
                    "scripts/test.sh",
                    "--jobs",
                    "4",
                    "--filter",
                    "|".join(suites),
                    "--xunit-output",
                    xml,
                ],
                lambda _: swift_count(xml, suites),
            )
        run("hosted-reader-build", build_reader(work / "hosted-reader-compile-only"))
        with tempfile.TemporaryDirectory(dir="/private/tmp", prefix="nearpane-overview.") as kit:
            run("overview-witness-build", ["bash", ACCEPTANCE / "host/build-overview-witness.sh", kit])
        run("installed-supervisor-tests", ["python3", "-B", "-m", "unittest", "discover", "-s",
            ACCEPTANCE.parent / "native-spaces", "-p", "test_private_installed_trials.py"], python_count)
        for name, folder in (
            ("spaces-tests", "spaces"),
            ("performance-tests", "performance"),
            ("corner-lease-tests", "corner/single"),
            ("installed-host-tests", "host"),
            ("ci-tests", "ci"),
        ):
            run(
                name,
                ["python3", "-B", "-m", "unittest", "discover", "-s", ACCEPTANCE / folder, "-p", "test_*.py"],
                python_count,
            )
    passed = all(check["status"] == "PASS" for check in checks.values())
    report["status"] = "PASS" if passed else "FAIL"
    save()
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
