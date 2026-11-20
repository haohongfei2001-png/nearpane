#!/usr/bin/env python3
"""Replay the real Riftlet adapter patch and exercise it in isolated headless Chrome and Edge."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
LOCK = ROOT / "Dependencies/riftlet-draft-qualification"
UPSTREAM_SOURCES = [
    "Sources/CSQLite",
    "Sources/RiftletCore",
    "Sources/RiftletAdapters",
    "Tests/RiftletAdaptersTests/DraftQualificationRouteTests.swift",
]


def run(args, *, env=None, data=None, timeout=180, diagnostics=False):
    process = subprocess.run(args, cwd=ROOT, env=env, input=data, capture_output=True, timeout=timeout)
    if process.returncode:
        message = (process.stderr + process.stdout)[-5200:].decode(errors="replace")
        print(message, file=sys.stderr)
        raise RuntimeError(f"{Path(args[0]).name} exited {process.returncode}")
    return process.stdout + process.stderr if diagnostics else process.stdout


def sha(blob):
    return hashlib.sha256(blob).hexdigest()


def materialize(repo, work, lock):
    common_dir = run(["git", "-C", str(repo), "rev-parse", "--git-common-dir"]).decode().strip()
    common = (repo / common_dir).resolve()
    base = lock["qualificationBase"]
    tree = lock["qualificationTree"]
    patch = LOCK / "scoped-drafts.patch"
    if sha(patch.read_bytes()) != lock["patchSHA256"]:
        raise ValueError("upstream patch digest mismatch")
    objects = work / "git-objects"
    objects.mkdir()
    env = dict(
        os.environ,
        GIT_OBJECT_DIRECTORY=str(objects),
        GIT_ALTERNATE_OBJECT_DIRECTORIES=str(common / "objects"),
        GIT_INDEX_FILE=str(work / "qualification.index"),
        GIT_OPTIONAL_LOCKS="0",
    )

    def git(*args):
        return run(["git", "--git-dir", str(common), *args], env=env)

    if git("rev-parse", base + "^{commit}").decode().strip() != base:
        raise ValueError("upstream base commit unavailable")
    git("read-tree", base)
    apply = ["apply", "--cached", "--unidiff-zero", "--whitespace=error"]
    git(*apply, "--check", str(patch))
    git(*apply, str(patch))
    if git("write-tree").decode().strip() != tree:
        raise ValueError("patched Git tree differs from the upstream qualification commit")
    for name, sums in lock["files"].items():
        existed = bool(git("ls-tree", "--name-only", base, "--", name))
        before = sha(git("cat-file", "blob", f"{base}:{name}")) if existed else None
        after = sha(git("cat-file", "blob", f"{tree}:{name}"))
        if before != sums["from"] or after != sums["to"]:
            raise ValueError(f"source digest mismatch for {name}")

    checkout = work / "package"
    checkout.mkdir()
    archive = git("archive", "--format=tar", tree, *UPSTREAM_SOURCES)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for entry in tar:
            rel = PurePosixPath(entry.name)
            if rel.is_absolute() or ".." in rel.parts or not (entry.isfile() or entry.isdir()):
                raise ValueError("unrecognized archive member")
            if entry.isdir():
                continue
            if not any(entry.name == name or entry.name.startswith(name + "/") for name in UPSTREAM_SOURCES):
                raise ValueError("unrequested source")
            if rel.parts[0] == "Tests":
                rel = PurePosixPath("Tests/RiftletQualificationTests") / rel.name
            out = checkout / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            with out.open("xb") as target:
                shutil.copyfileobj(tar.extractfile(entry), target)
    shutil.copyfile(HERE / "Package.swift", checkout / "Package.swift")
    driver = checkout / "Sources/DraftQualificationDriver"
    driver.mkdir()
    tray = ROOT / "Sources/NearpaneTray"
    for source in [HERE / "Driver.swift", HERE / "ColdRestart.swift", tray / "DraftCapability.swift", tray / "DraftAttachmentQualification.swift"]:
        shutil.copyfile(source, driver / source.name)
    return checkout


def build_driver(checkout):
    developer = Path(run(["xcode-select", "-p"]).decode().strip())
    frameworks = developer / "Library/Developer/Frameworks"
    native = ["--build-system", "native", "--package-path", str(checkout)]
    test = ["swift", "test", *native, "--filter", "DraftQualificationRouteTests"]
    if (frameworks / "Testing.framework").exists() and not (frameworks / "XCTest.framework").exists():
        compiler = Path(run(["xcrun", "--find", "swiftc"]).decode().strip()).parent
        plugins = str(compiler / "../lib/swift/host/plugins/testing") + "#" + str(compiler / "swift-plugin-server")
        test += [
            "--enable-swift-testing", "--disable-xctest",
            "-Xswiftc", "-F", "-Xswiftc", str(frameworks),
            "-Xlinker", "-F", "-Xlinker", str(frameworks),
            "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
            "-Xswiftc", "-external-plugin-path", "-Xswiftc", plugins,
        ]
    result = run(test, timeout=300, diagnostics=True).decode(errors="replace")
    if not re.search(r"Executed 1 test, with 0 failures|Test run with 1 test in 1 suite passed", result):
        raise ValueError("native destination tests did not produce a passing result")
    bins = run(["swift", "build", *native, "--show-bin-path"]).decode().strip()
    driver = Path(bins) / "DraftQualificationDriver"
    if not driver.is_file():
        run(["swift", "build", *native, "--product", driver.name], timeout=300)
    return driver


def exercise_browser(browser, driver, work, record):
    request = {"qualificationBrowser": browser, "qualificationScratch": str(work)}
    result = json.loads(run(
        ["node", "scripts/acceptance/local-browser.mjs", str(driver)],
        data=json.dumps(request).encode(), timeout=185,
    ))
    private = Path(result.pop("directory"))
    if private.parent != work or not private.name.startswith("local-browser-") or not private.is_dir():
        raise ValueError("unexpected fixture directory")
    if (private / "user-data").exists():
        raise ValueError("private headless profile was retained")
    result["privateProfileRemoved"] = True
    record["browsers"][browser] = result
    rows = result["rows"]
    if len(rows) != 48 or len({(row["host"], row["scenario"]) for row in rows}) != 48:
        raise ValueError("incomplete browser and scenario matrix")
    if any(row["result"] != "PASS_FIXTURE" or not row["counts"] for row in rows):
        raise ValueError("one or more fixture rows failed or remain inconclusive")
    if any(row["counts"][key] for row in rows for key in ["send", "submit", "enter"]):
        raise ValueError("independent draft observer saw a send action")


def exercise_restart(browser, driver, work, record):
    intent = str(uuid.uuid4())
    trial = {"intentID": intent, "status": "UNKNOWN"}
    record["coldRestarts"][browser] = trial
    original_run = None
    for stage in ["original", "successor"]:
        options = {"intentID": intent, "stage": stage}
        if original_run:
            options["from"] = original_run.name
        request = {"qualificationBrowser": browser, "qualificationScratch": str(work), "qualificationRestart": options}
        result = json.loads(run(["node", "scripts/acceptance/local-browser.mjs", str(driver)],
                                data=json.dumps(request).encode(), timeout=60))
        folder = Path(result.pop("directory"))
        trial[stage] = result
        if result["status"] == "FAIL_FIXTURE":
            trial["status"] = "FAIL_FIXTURE"
        if (folder.parent != work or not folder.name.startswith("local-browser-") or not folder.is_dir() or
                (folder / "user-data").exists()):
            raise ValueError("unexpected or retained cold-restart browser profile")
        if (result["status"] != "PASS_FIXTURE" or not result["reaped"] or not result["privateProfileRemoved"] or
                not result["isolatedProcessGroupGone"] or result["requestedTermination"] != ("SIGTERM" if stage == "original" else "Browser.close")):
            raise ValueError(f"{browser} {stage} did not finish cleanly")
        if any(result[phase]["counts"][key] for phase in ["before", "after"] for key in ["setter", "input", "change", "foreignSetter", "send", "submit", "enter"]):
            raise ValueError("independent draft observer saw input or sending")
        if not original_run:
            original_run = folder
    old = trial["original"]["driver"]
    new = trial["successor"]["driver"]
    if (not old["signedPIDVerified"] or not new["signedPIDVerified"] or old["observedUptime"] >= new["observedUptime"] or
            old["pid"] == new["pid"] or old["processSession"] == new["processSession"] or
            (old["kernelBirthSeconds"], old["kernelBirthMicroseconds"]) == (new["kernelBirthSeconds"], new["kernelBirthMicroseconds"])):
        raise ValueError("distinct process births were not independently established")
    for key in ["intentID", "assetID", "operationID", "invocationID", "attempt", "windowID", "tabID"]:
        if old[key] != new[key]:
            raise ValueError(f"cold restart changed {key}")
    if (not old["currentLeaseValidatedByPage"] or not new["currentLeaseValidatedByPage"] or
            new["oldLeaseValidInSuccessorPage"] or old["documentID"] == new["documentID"] or
            not new["dispatchRearmRefused"] or not new["originalProcessGone"] or new["oldSessionMatchesSuccessor"] or
            new["oldSessionMatchesSuccessorReadOnly"] or old["phase"] != "dispatchIntent" or new["phase"] != "unknown" or
            new["assetVisibility"] != "visible" or old["sourceSHA256"] != new["sourceSHA256Before"] or
            old["sourceSHA256"] != new["sourceSHA256After"]):
        raise ValueError("invalid recovery state or original asset readback")
    trial["status"] = "PASS_FIXTURE"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, help="existing read-only Riftlet clone with the public base")
    parser.add_argument("--output", type=Path, required=True, help="new receipt path")
    parser.add_argument("--cold-restart-only", action="store_true", help="run only the Chrome and Edge cold restart cases")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output must be a new file")
    lock = json.loads((LOCK / "lock.json").read_bytes())
    ordinary = json.loads((ROOT / "Dependencies/domains.lock.json").read_bytes())["domains"]["riftlet"]
    if lock["productionEnabled"] or ordinary["commit"] != lock["ordinaryProductionPin"]:
        raise ValueError("ordinary dependency or production admission changed; qualification needs a new baseline")
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    record = {
        "schema": 1,
        "suite": "cold-restart" if args.cold_restart_only else "matrix-and-cold-restart",
        "startedUTC": datetime.now(timezone.utc).isoformat(),
        "macOSBuild": run(["sw_vers", "-buildVersion"]).decode().strip(),
        "nearpaneSourceCommit": run(["git", "rev-parse", "HEAD"]).decode().strip(),
        "sourceSHA256": {
            str(path.relative_to(ROOT)): sha(path.read_bytes()) for path in [
                ROOT / "Sources/NearpaneTray/DraftAttachmentQualification.swift",
                ROOT / "Sources/NearpaneTray/DraftCapability.swift", ROOT / "scripts/acceptance/local-browser.mjs",
                HERE / "Driver.swift", HERE / "ColdRestart.swift", HERE / "Package.swift", HERE / "cases.mjs", HERE / "verify.py",
            ]
        },
        "productionPin": ordinary["commit"],
        "productionTreeSHA256": ordinary["treeSHA256"],
        "qualificationBase": lock["qualificationBase"],
        "qualificationCommit": lock["qualificationCommit"],
        "qualificationTree": lock["qualificationTree"],
        "patchSHA256": lock["patchSHA256"],
        "ordinaryProductionEnabledForQualification": False,
        "liveAuthenticatedAcceptance": "BLOCKED_NO_AUTHORIZED_ISOLATED_PROFILE",
        "liveUploadCompleted": None,
        "liveSendEvents": None,
        "nativeAppleEvents": "NOT_RUN_HEADLESS_PIPE",
        "safariQualification": "BLOCKED_STABLE_TAB_WITNESS_UNAVAILABLE",
        "failures": {},
        "browsers": {},
        "coldRestarts": {},
    }
    with tempfile.TemporaryDirectory(dir=build, prefix="p3-qualified-") as scratch:
        work = Path(scratch)
        try:
            repo = args.upstream.resolve() if args.upstream else work / "upstream.git"
            if not args.upstream:
                run(["git", "init", "--bare", "-q", str(repo)])
                remote = "https://github.com/" + lock["repository"] + ".git"
                run(["git", "-C", str(repo), "remote", "add", "origin", remote])
                # Fetch the base once into the disposable repository. No source from a moving branch enters the build.
                run(["git", "-C", str(repo), "fetch", "--depth=1", "--no-tags", "origin", lock["qualificationBase"]])
            checkout = materialize(repo, work, lock)
            record["sourceReplay"] = "MATCH"
            driver = build_driver(checkout)
            record["upstreamNativeRouteTest"] = "PASS"
            for browser in ["chrome", "edge"]:
                if not args.cold_restart_only:
                    try:
                        exercise_browser(browser, driver, work, record)
                    except Exception as error:
                        record["failures"][browser] = str(error).replace(str(work), "<scratch>")
                try:
                    exercise_restart(browser, driver, work, record)
                except Exception as error:
                    record["failures"][browser + "ColdRestart"] = str(error).replace(str(work), "<scratch>")
        except Exception as error:
            record["failures"]["build"] = str(error).replace(str(work), "<scratch>")
    record["scratchRemoved"] = not work.exists()
    if not record["scratchRemoved"]:
        record["failures"]["cleanup"] = "private qualification workspace retained"
    rows = [row for browser in record["browsers"].values() for row in browser["rows"]]
    record["outcomes"] = dict(Counter(row["result"] for row in rows))
    record["coldRestartOutcomes"] = dict(Counter(trial["status"] for trial in record["coldRestarts"].values()))
    record["finishedUTC"] = datetime.now(timezone.utc).isoformat()
    record["result"] = "FAIL" if record["failures"] else "PASS_SYNTHETIC_ONLY"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as output:
        json.dump(record, output, indent=2)
        output.write("\n")
    print(record["result"], args.output)
    return int(bool(record["failures"]))


if __name__ == "__main__":
    raise SystemExit(main())
