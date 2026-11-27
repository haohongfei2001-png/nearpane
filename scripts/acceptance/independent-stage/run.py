#!/usr/bin/env python3
"""One entry for source checks, cross-process Spaces trials and isolated R4 acceptance.

Nothing installs, stops or replaces the daily Nearpane. Runtime writes are confined
to two freshly launched fixture apps. Receipts preserve NOT_RUN/BLOCKED explicitly.
"""
import argparse
from contextlib import ExitStack
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

from build import build, ROOT
from evaluate import LIFECYCLE_CHECKS, SYSTEM_CHECKS, attach_lifecycle, evaluate
from host_crash import run_host_crash
from package import package

HERE = Path(__file__).resolve().parent
HOST_SAMPLE_REASONS = {
    "host-startup-main-thread": "hostExitedBeforeStartupSample",
    "host-main-thread": "successfulR4PressNotObserved",
    "host-selection-preparation-main-thread": "groupSelectionJobNotObserved",
    "host-read-queue-main-thread": "noObservedR4ReadQueueDelay",
}


def select_toolchain(env):
    """Reuse an installed Cargo; a linked worktree may share its checkout's toolchain."""
    found = shutil.which("cargo", path=env.get("PATH", ""))
    if found:
        return {"status": "AVAILABLE", "cargo": found, "source": "PATH"}
    candidates = [(ROOT / "build/window-engine/toolchain/portable/bin", "repository"),
                  (Path.home() / ".cargo/bin", "user")]
    try:
        common = Path(subprocess.check_output(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=ROOT, text=True).strip())
        # Only the actual common Git directory establishes this relationship.
        # Do not search unrelated checkouts or change an installed toolchain.
        if common.name == ".git" and common.parent != ROOT:
            candidates.append((common.parent / "build/window-engine/toolchain/portable/bin", "commonCheckout"))
    except (OSError, subprocess.SubprocessError):
        pass
    for directory, source in candidates:
        cargo = directory / "cargo"
        if cargo.is_file() and os.access(cargo, os.X_OK):
            env["PATH"] = str(directory) + os.pathsep + env.get("PATH", "")
            return {"status": "AVAILABLE", "cargo": str(cargo), "source": source}
    return {"status": "BLOCKED", "reason": "installedCargoUnavailable", "cargo": None}


def atomic(path, value):
    pending = path.with_suffix(".next")
    pending.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    pending.replace(path)


def json_object(path):
    try:
        if not 0 < path.stat().st_size <= 262144:
            return None
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def positive_time(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def confirmed_r4_press(directory, host_pid, request_observed):
    """A result path exists before discovery. Only a complete successful receipt is input evidence."""
    configuration = json_object(directory / "config.json")
    if not configuration or not isinstance(configuration.get("nonce"), str) or not configuration["nonce"]:
        return None
    confirmed = []
    for path in directory.glob("r4-press-*.request.json"):
        observed = request_observed.setdefault(path.name, time.monotonic())
        request = json_object(path)
        if not request or request.get("schema") != 1 or request.get("nonce") != configuration.get("nonce"):
            continue
        host = request.get("host")
        result_path = path.with_name(path.name.replace(".request.json", ".result.json"))
        destination = request.get("result")
        if not isinstance(host, dict) or host.get("pid") != host_pid or not isinstance(destination, str) or Path(destination).resolve() != result_path.resolve():
            continue
        result = json_object(result_path)
        if not result or result.get("schema") != 1 or result.get("nonce") != request["nonce"]:
            continue
        if result.get("status") != "ISSUED" or result.get("issued") is not True or type(result.get("axError")) is not int or result["axError"] != 0:
            continue
        pressed, returned = result.get("inputUptime"), result.get("uptime")
        if not positive_time(pressed) or not positive_time(returned) or returned < pressed:
            continue
        confirmed.append({"requestFile": path.name, "receiptFile": result_path.name, "nonce": request["nonce"],
                          "requestObservedMonotonic": observed, "actualPressUptime": pressed, "pressReceiptUptime": returned,
                          "receiptObservedMonotonic": time.monotonic()})
    return min(confirmed, key=lambda value: value["actualPressUptime"]) if confirmed else None


def selection_preparation_start(reader, partial, on_event=None):
    """Consume complete Host lines once, including task events after the first selection."""
    lines = (partial + reader.read()).split("\n")
    partial = lines.pop()
    selected = None
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict) or event.get("event") != "independentStageProduct":
            continue
        if on_event is not None:
            on_event(event)
        if selected is None and event.get("phase") == "group-job-start" and positive_time(event.get("uptime")):
            selected = {"selectionStartUptime": event["uptime"], "selectionObservedMonotonic": time.monotonic(),
                        "selectionWindow": event.get("window"), "selectionCurrentAtEntry": event.get("current")}
    return partial, selected


def observe_directory_task(event, pending):
    phase, session, revision = event.get("phase"), event.get("readSession"), event.get("requestRevision")
    if not isinstance(session, str) or not session or type(revision) is not int or revision <= 0:
        return
    key = (session, revision)
    if phase == "desktop-read-task-created" and event.get("dispatching") is True and positive_time(event.get("taskCreatedUptime")):
        pending.setdefault(key, {"readSession": session, "requestRevision": revision,
                                 "taskCreatedUptime": event["taskCreatedUptime"],
                                 "taskCreatedObservedMonotonic": time.monotonic(),
                                 "creatorPriority": event.get("creatorPriority")})
    elif phase == "desktop-read-task-started" and positive_time(event.get("taskStartedUptime")):
        task = pending.get(key)
        if task is not None and event["taskStartedUptime"] >= task["taskCreatedUptime"]:
            pending.pop(key)
            # A report retains this dictionary after a late sampler starts, so
            # the eventual start remains evidence of the same task's queue wait.
            task.update(taskStartedUptime=event["taskStartedUptime"], taskStartedObservedMonotonic=time.monotonic(),
                        taskStartPriority=event.get("taskPriority"),
                        taskQueueMS=(event["taskStartedUptime"] - task["taskCreatedUptime"]) * 1000)


def delayed_directory_task(pending, now):
    delayed = [task for task in pending.values() if now - task["taskCreatedObservedMonotonic"] >= .25]
    if not delayed:
        return None
    task = min(delayed, key=lambda value: value["taskCreatedObservedMonotonic"])
    task.setdefault("queueDelayObservedMonotonic", now)
    task["pendingForObservedMS"] = (now - task["taskCreatedObservedMonotonic"]) * 1000
    return task


def observe_capture_markers(reader, partial, report):
    """These are marker observation times, never inferred capture-end times."""
    lines = (partial + reader.read()).split("\n")
    partial = lines.pop()
    for line in lines:
        if line.startswith("Sampling process "):
            report.setdefault("captureStartObservedMonotonic", time.monotonic())
        elif line.strip() == "Sampling completed, processing symbols...":
            report.setdefault("captureCompletionObservedMonotonic", time.monotonic())
    return partial


def execute(command, out, name, env, timeout=900, reap_children=(), sample_host=None):
    with ExitStack() as sampling_files, (out / (name + ".log")).open("x") as stdout, (out / (name + ".stderr.log")).open("x") as stderr:
        samplers, sampler_readers, pending_tasks = {}, {}, {}
        sample_reports = {stem: {"status": "NOT_RUN", "reason": reason, "diagnosticOnly": True}
                          for stem, reason in HOST_SAMPLE_REASONS.items()}
        request_observed = {}
        actual_press = selection_start = None
        log_partial = ""
        late_sample_attempted = False
        trace_reader = sampling_files.enter_context((out / (name + ".stderr.log")).open(errors="replace")) if sample_host is not None else None

        def update_capture(stem):
            if "captureCompletionObservedMonotonic" not in sample_reports[stem]:
                reader, partial = sampler_readers[stem]
                sampler_readers[stem] = (reader, observe_capture_markers(reader, partial, sample_reports[stem]))

        def launch_sample(stem, trigger, duration, evidence, share=True, observed_at=None):
            started = time.monotonic()
            report = {"status": "STARTED", "pid": running.pid, "diagnosticOnly": True,
                      "durationSeconds": duration, "intervalMilliseconds": 10, "trigger": trigger,
                      "triggerObservedMonotonic": started if observed_at is None else observed_at,
                      "sampleFile": stem + ".sample.txt", "sampleLaunchMonotonic": started,
                      "startedAfterHostSeconds": started - host_started, **evidence}
            sample_reports[stem] = report
            if share and duration == 3:
                shared = next((owner for owner, sampler in samplers.items()
                               if sample_reports[owner]["durationSeconds"] == 3 and sampler.poll() is None
                               and "captureCompletionObservedMonotonic" not in sample_reports[owner]), None)
                if shared is not None:
                    # Share the active capture, not a live process that has
                    # already moved on to processing symbols.
                    owner_report = sample_reports[shared]
                    report.update(status="SHARED", sharedWith=shared, sampleFile=owner_report["sampleFile"],
                                  sampleLaunchMonotonic=owner_report["sampleLaunchMonotonic"],
                                  startedAfterHostSeconds=owner_report["startedAfterHostSeconds"])
                    return
            try:
                sample_log = sampling_files.enter_context((sample_host / (stem + "-sample.log")).open("x"))
                error_path = sample_host / (stem + "-sample.stderr.log")
                sample_error = sampling_files.enter_context(error_path.open("x"))
                sampler_readers[stem] = (sampling_files.enter_context(error_path.open(errors="replace")), "")
                samplers[stem] = subprocess.Popen(["/usr/bin/sample", str(running.pid), str(duration), "10", "-file",
                                                  str(sample_host / (stem + ".sample.txt"))],
                                                 stdout=sample_log, stderr=sample_error)
            except OSError as error:
                report.update(status="BLOCKED", reason=type(error).__name__ + ": " + str(error))

        try:
            if reap_children or sample_host is not None:
                # The lifecycle Host must observe a positively exited fixture
                # generation. Reap only these direct children so a zombie cannot
                # masquerade as a still-live AX owner while the Host is running.
                with subprocess.Popen([str(x) for x in command], cwd=ROOT, env=env, stdout=stdout, stderr=stderr) as running:
                    host_started = time.monotonic()
                    deadline = host_started + timeout
                    while running.poll() is None and time.monotonic() < deadline:
                        for child in reap_children:
                            child.poll()
                        if sample_host is not None:
                            if actual_press is None:
                                actual_press = confirmed_r4_press(sample_host, running.pid, request_observed)
                            log_partial, next_selection = selection_preparation_start(
                                trace_reader, log_partial, lambda event: observe_directory_task(event, pending_tasks))
                            if selection_start is None:
                                selection_start = next_selection
                            for stem in samplers:
                                update_capture(stem)
                            # The controller creates its result file before looking
                            # for a button. Request discovery is not actual input.
                            # Job-start evidence can arrive before the press receipt;
                            # sample it immediately without gating the Host.
                            triggers = (
                                ("host-startup-main-thread", "startup", 1, {} if time.monotonic() - host_started >= .5 else None),
                                ("host-main-thread", "firstConfirmedExternalAXPress", 3, actual_press),
                                ("host-selection-preparation-main-thread", "firstGroupSelectionJob", 3, selection_start),
                            )
                            for stem, trigger, duration, evidence in triggers:
                                if evidence is None or sample_reports[stem]["status"] != "NOT_RUN":
                                    continue
                                launch_sample(stem, trigger, duration, evidence)
                            if actual_press is not None and not late_sample_attempted:
                                queued = delayed_directory_task(pending_tasks, time.monotonic())
                                stem = "host-read-queue-main-thread"
                                if queued is not None:
                                    capturing = [owner for owner, sampler in samplers.items()
                                                 if sampler.poll() is None
                                                 and "captureCompletionObservedMonotonic" not in sample_reports[owner]]
                                    sample_reports[stem] = {"status": "WAITING", "diagnosticOnly": True,
                                                            "reason": "existingCaptureStillRunning", "queueObservation": queued,
                                                            "waitingForCaptures": capturing}
                                    if not capturing:
                                        late_sample_attempted = True
                                        launch_sample(stem, "directoryReadQueuedAtLeast250MS", 3,
                                                      {**actual_press, "queueObservation": queued}, share=False,
                                                      observed_at=queued["queueDelayObservedMonotonic"])
                                elif sample_reports[stem]["status"] == "WAITING":
                                    sample_reports[stem].update(status="NOT_RUN", reason="queuedReadStartedBeforeAdditionalSample")
                        time.sleep(.05)
                    if running.poll() is None:
                        running.kill()
                        running.wait()
                        raise subprocess.TimeoutExpired(command, timeout)
                    code = running.returncode
            else:
                run = subprocess.run([str(x) for x in command], cwd=ROOT, env=env, stdout=stdout, stderr=stderr, timeout=timeout)
                code = run.returncode
            report = {"status": "PASS" if code == 0 else "FAIL", "exit": code}
        except subprocess.TimeoutExpired:
            report = {"status": "UNKNOWN", "reason": "timeout"}
        except FileNotFoundError as error:
            stderr.write(str(error) + "\n")
            report = {"status": "BLOCKED", "reason": "requiredExecutableUnavailable", "executable": str(command[0])}
        finally:
            if trace_reader is not None:
                # Collect terminal start events written after the final live poll;
                # the exited Host never triggers another sampling process here.
                log_partial, final_selection = selection_preparation_start(
                    trace_reader, log_partial, lambda event: observe_directory_task(event, pending_tasks))
                if selection_start is None:
                    selection_start = final_selection
            for stem, sampler in samplers.items():
                sample_report = sample_reports[stem]
                try:
                    sampler.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    sample_report["reason"] = "samplerDeadline"
                    sampler.terminate()
                    try:
                        sampler.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        sampler.kill()
                        try:
                            sampler.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            sample_report["reason"] = "samplerReapUnavailable"
                sample_report.update(status="COMPLETE" if sampler.returncode == 0 else "INCOMPLETE", exit=sampler.returncode,
                                     reapedMonotonic=time.monotonic())
                update_capture(stem)
                # Only physical subprocesses are waited for. Logical reports
                # reference the same file and final process receipt explicitly.
                for shared_report in sample_reports.values():
                    if shared_report.get("sharedWith") == stem:
                        shared_report.update({key: sample_report[key] for key in ("status", "exit", "reapedMonotonic", "reason",
                                              "captureStartObservedMonotonic", "captureCompletionObservedMonotonic")
                                              if key in sample_report})
            if sample_host is not None:
                late_report = sample_reports["host-read-queue-main-thread"]
                if late_report["status"] == "WAITING":
                    reason = ("queuedReadStartedBeforeAdditionalSample" if "taskStartedUptime" in late_report["queueObservation"]
                              else "hostExitedBeforeAdditionalQueueSample")
                    late_report.update(status="NOT_RUN", reason=reason)
                if actual_press is not None and selection_start is not None and actual_press["actualPressUptime"] <= selection_start["selectionStartUptime"]:
                    sample_reports["host-selection-preparation-main-thread"].update(actual_press)
                for stem, sample_report in sample_reports.items():
                    atomic(sample_host / (stem + "-sample.json"), sample_report)
    report.update(log=name + ".log", stderr=name + ".stderr.log")
    atomic(out / (name + ".json"), report)
    print(name, report["status"], flush=True)
    if report["status"] != "PASS" and name in ("rust", "swift", "build-engine", "build-product", "build-spaces-worker"):
        # Expose a short useful CI failure while retaining the complete original logs.
        for suffix in (".stderr.log", ".log"):
            lines = (out / (name + suffix)).read_text(errors="replace").splitlines()
            relevant = list(dict.fromkeys(line for line in lines if re.search(r"error(?:\[|:)|fatal:|\bfailed\b", line, re.IGNORECASE)))
            if relevant:
                print("\n".join(relevant[:30]), flush=True)
    return report


def source_checks(out, env):
    out.mkdir()
    env = dict(env, NEARPANE_FOUNDATION_ONLY="1")
    checks = {}
    checks["rust"] = execute(["cargo", "test", "--manifest-path", ROOT / "Engine/nearpane-window-engine/Cargo.toml",
        "--locked", "--offline", "--no-default-features", "--features", "corner,spaces,isolated-fixtures"], out, "rust", env)
    archive_build = execute(["bash", "scripts/build-window-engine.sh"], out, "build-engine", env)
    checks["spacesWorkerBuild"] = archive_build
    if archive_build["status"] == "PASS":
        archive = Path((out / "build-engine.log").read_text().splitlines()[-1])
        worker = out / "NearpaneSpacesEngine"
        checks["spacesWorkerBuild"] = execute(["bash", "Engine/nearpane-window-engine/build-spaces-worker.sh", worker, archive],
                                              out, "build-spaces-worker", env)
        if checks["spacesWorkerBuild"]["status"] == "PASS":
            checks["spacesWorkerProtocol"] = execute([worker, "--protocol-selftest"], out, "spaces-worker-protocol", env, 30)
        try:
            with (out / "probe-build.log").open("x") as stdout, (out / "probe-build.stderr.log").open("x") as stderr:
                # Compile every acceptance executable without launching its windows
                # or system actions. Only Controller's read-only context runs here.
                probe = build(archive, out / "controller-kit",
                              stdout=stdout, stderr=stderr)["Controller"]["executable"]
            checks["readOnlyContext"] = execute([probe, "--inspect-context", out / "windowserver-context.json"],
                                                out, "read-only-context", dict(env, NP_SPACES_TOPOLOGY_TRACE="1"), 30)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            checks["readOnlyContext"] = {"status": "FAIL", "reason": type(error).__name__ + ": " + str(error)}
    # The filtered run uses real Core/Host/UI code. It does not grant WindowServer qualification.
    pattern = "|".join(("IndependentStage", "StageGroup", "StageWindow", "StageHost", "EngineABI",
                        "NativeMinimize", "AppleStageMinimize", "OrdinaryDesktopMembership", "StageCreationFocus",
                        "SpaceInventoryTests", "SpacesWorkerLifecycleTests", "NativeSidebarNavigationTests",
                        "DesktopPreviewContinuityTests"))
    checks["swift"] = execute(["bash", "scripts/test.sh", "--jobs", "4", "--filter", pattern,
                                "--xunit-output", out / "swift.xml"], out, "swift", env, 1200)
    if checks["swift"]["status"] == "PASS":
        try:
            cases = ET.parse(out / "swift.xml").findall(".//testcase")
            passed = [c for c in cases if all(c.find(tag) is None for tag in ("skipped", "failure", "error"))]
            if not passed:
                raise ValueError("noCompletedSwiftCases")
            checks["swift"].update(passed=len(passed), skipped=len(cases)-len(passed))
        except (OSError, ValueError, ET.ParseError) as error:
            checks["swift"].update(status="FAIL", reason=str(error))
    if checks["rust"]["status"] == "PASS":
        counts = re.findall(r"test result: ok\. (\d+) passed; 0 failed;", (out / "rust.log").read_text())
        count = sum(map(int, counts))
        checks["rust"].update(passed=count)
        if not count:
            checks["rust"].update(status="FAIL", reason="noCompletedRustCases")
    checks["evidence"] = execute(["python3", "-B", "-m", "unittest", "discover", "-s", HERE, "-p", "test_*.py"],
                                  out, "evidence", env, 30)
    checks["nativeDiagnostic"] = execute(["python3", "-B", "-m", "unittest", "discover", "-s",
        ROOT / "tools/native-stage-decoupling", "-p", "test_*.py"], out, "native-diagnostic", env, 30)
    result = {"schema": 1, "status": "PASS" if all(x["status"] == "PASS" for x in checks.values()) else "FAIL",
              "checks": checks, "windowServer": "READ_ONLY_CONTEXT", "foreignWindowDispatch": "NOT_RUN", "productR4": "NOT_RUN"}
    atomic(out / "summary.json", result)
    return result


def candidate_copy(source, output, revision):
    return package(source, output / "NearpaneIndependentStage.app", revision, mode="acceptance")


def build_candidate(out, env, revision):
    out.mkdir()
    result = execute(["bash", "scripts/build-app.sh", "release"], out, "build-product",
                     dict(env, NEARPANE_FOUNDATION_ONLY="0"), 1800)
    if result["status"] != "PASS":
        return result, None
    run_id = env.get("NEARPANE_RUN_ID", "")
    products = ROOT / "build" / ("standalone." + run_id) / "products" if run_id else ROOT / "build"
    source = products / "release/Nearpane.app"
    workspace = out / "NearpaneIndependentStage.app"
    try:
        if not (source / "Contents/MacOS/NearpaneHost").is_file():
            raise FileNotFoundError("completeReleaseBundleMissing")
        executable = package(source, workspace, revision, mode="workspace")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        result.update(status="FAIL", reason=type(error).__name__ + ": " + str(error))
        return result, None
    result.update(completeApp=str(source), workspaceCandidate=str(workspace), executable=str(executable),
                  signature="codesign --verify --strict --deep", launched=False)
    atomic(out / "candidate.json", result)
    return result, source


def wait_fixture(directory, process, nonce, count):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and process.poll() is None:
        try:
            value = json.loads((directory / "state.json").read_text())
            if (value.get("nonce") == nonce and value.get("pid") == process.pid
                    and len(value.get("windows", [])) == count and all(w.get("number", 0) > 0 for w in value["windows"])):
                return value
        except (OSError, ValueError):
            pass
        time.sleep(.05)
    raise RuntimeError("fixtureWindowsNotReady")


def close_fixture(directory, process, nonce):
    if process.poll() is not None:
        return {"exit": process.returncode, "command": "alreadyExited"}
    try:
        state = json.loads((directory / "state.json").read_text())
        atomic(directory / "command.json", {"nonce": nonce, "index": 0, "action": "quit",
                                             "sequence": state.get("commandSequence", 0) + 1})
        process.wait(timeout=4)
        return {"exit": process.returncode, "command": "ownedWindowQuit"}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        # This object is the direct child created above; no arbitrary PID is accepted.
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        return {"exit": process.returncode, "command": "directChildTermination"}


class PreflightBlocked(RuntimeError):
    pass


def ci_workspace(apps, out, env, operation, suffix=""):
    name = "ci-workspace-" + operation + suffix
    process = execute([apps["CIWorkspace"]["executable"], operation, out / "ci-workspace-state.json"],
                      out, name, env, 75)
    try:
        receipt = json.loads((out / (name + ".log")).read_text())
        if not isinstance(receipt, dict):
            raise ValueError("objectReceiptRequired")
    except (OSError, ValueError):
        receipt = {"status": "UNKNOWN", "reason": "ciWorkspaceReceiptUnavailable"}
    receipt["process"] = process
    atomic(out / (name + "-receipt.json"), receipt)
    return receipt


def runtime_checks(out, env, archive, host, iterations, revision, host_sampling=True):
    out.mkdir()
    env = dict(env, NP_SPACES_TOPOLOGY_TRACE="1", NP_SPACES_LAUNCH_TRACE="1")
    sampling_policy = "enabled" if host_sampling else "disabledByRequest"
    try:
        with (out / "kit-build.log").open("x") as stdout, (out / "kit-build.stderr.log").open("x") as stderr:
            apps = build(archive, out / "kit", stdout=stdout, stderr=stderr)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        result = {"schema": 1, "status": "FAIL", "phase": "runtimeToolsBuild",
                  "reason": type(error).__name__ + ": " + str(error),
                  "engine": "NOT_RUN", "R4ProductPath": "NOT_RUN", "platformForeignMechanism": "NOT_RUN",
                  "fixtureProcessesStarted": 0, "foreignWindowWrites": 0, "qualificationGranted": False,
                  "hostSampling": sampling_policy,
                  "buildLog": "kit-build.log", "buildStderr": "kit-build.stderr.log"}
        atomic(out / "summary.json", result)
        return result
    nonce = str(uuid.uuid4())
    config = {"schema": 1, "nonce": nonce, "output": str(out), "iterations": iterations, "fixtures": [],
              "systemHelper": apps["SplitViewHelper"]["executable"],
              "r4Controller": apps["Controller"]["executable"]}
    children, cleanup = [], []
    engine = {"status": "NOT_RUN", "reason": "fixturePreparationIncomplete"}
    product = None
    platform_diagnostic = None
    workspace = {"status": "NOT_RUN", "reason": "notGitHubHostedAcceptance"}
    workspace_cleanup = None
    workspace_before_fixtures = None
    hosted = env.get("GITHUB_ACTIONS") == "true" and env.get("GITHUB_REPOSITORY") == "haohongfei2001-png/nearpane"
    original_desktop_diagnostic = (hosted and env.get("RUNNER_ENVIRONMENT") != "self-hosted"
                                   and env.get("NEARPANE_HOSTED_PLATFORM_ONLY") == "1")
    if original_desktop_diagnostic:
        workspace = {"status": "NOT_RUN", "reason": "hostedPlatformMechanismUsesOriginalDesktop",
                     "desktopPreparationExecuted": False, "nativeDesktopInputs": 0, "workspaceUnchanged": True}
    phase = "fixturePreparation"
    with ExitStack() as files:
        try:
            if hosted and not original_desktop_diagnostic:
                phase = "ciWorkspacePreparation"
                workspace = ci_workspace(apps, out, env, "prepare")
                if workspace.get("status") != "READY":
                    # A system-UI preparation failure is not a failed platform
                    # experiment. First restore the native desktop, then create
                    # fresh controlled windows and let the unchanged production
                    # controller make its own current, physical admission read.
                    if workspace.get("status") == "BLOCKED":
                        workspace_before_fixtures = ci_workspace(apps, out, env, "cleanup", "-before-fixtures")
                    if (not workspace_before_fixtures or workspace_before_fixtures.get("status") != "READY"
                            or workspace_before_fixtures.get("cleanup") is not True):
                        raise PreflightBlocked("ciWorkspace: " + workspace.get("reason", "ordinaryIdentityUnavailable"))
            phase = "fixturePreparation"
            for name, count, offset in (("FixtureA", 2, 0), ("FixtureB", 1, 560)):
                directory = out / name
                directory.mkdir(mode=0o700)
                stdout = files.enter_context((directory / "stdout.log").open("x"))
                stderr = files.enter_context((directory / "stderr.log").open("x"))
                child = subprocess.Popen([apps[name]["executable"], str(directory), nonce, str(count), str(offset)],
                                         env=env, stdout=stdout, stderr=stderr, start_new_session=True)
                children.append((directory, child))
                state = wait_fixture(directory, child, nonce, count)
                config["fixtures"].append({"directory": str(directory), "executable": apps[name]["executable"],
                                           "pid": state["pid"], "birth": state["birth"], "windows": state["windows"]})
            atomic(out / "config.json", config)
            phase = "engineController"
            result = execute([apps["Controller"]["executable"], out / "config.json"], out, "engine", env, 210 + iterations * 12)
            path = out / "engine-result.json"
            engine = json.loads(path.read_text()) if path.exists() else {"status": "UNKNOWN", "reason": "controllerTerminalReceiptMissing",
                                                                       "process": result, "cleanup": False}
            if (hosted and engine.get("status") == "BLOCKED" and engine.get("nonce") == nonce
                    and type(engine.get("windowWrites")) is int and engine["windowWrites"] == 0
                    and engine.get("cleanup") is True):
                # Separate mechanism evidence only: no invented ordinary UUID,
                # no replacement engine and no promotion of the primary receipt.
                phase = "platformDiagnostic"
                process = execute([apps["Controller"]["executable"], "--platform-only", out / "config.json"],
                                  out, "platform", env, 90)
                try:
                    platform_diagnostic = json.loads((out / "platform-result.json").read_text())
                    if not isinstance(platform_diagnostic, dict) or platform_diagnostic.get("nonce") != nonce:
                        raise ValueError("platformNonceMismatch")
                except (OSError, ValueError):
                    platform_diagnostic = {"status": "UNKNOWN", "reason": "platformTerminalReceiptUnavailable", "cleanup": False}
                platform_diagnostic["process"] = process
            # A raw/API success never runs an unverified product: first require complete restore.
            if (host and engine.get("cleanup") is True
                    and (platform_diagnostic is None or platform_diagnostic.get("cleanup") is True)):
                phase = "productCandidate"
                product_dir = out / "product"
                product_dir.mkdir(mode=0o700)
                product_config = dict(config, output=str(product_dir), profile=str(product_dir / "profile"))
                atomic(product_dir / "config.json", product_config)
                if not host_sampling:
                    for stem in HOST_SAMPLE_REASONS:
                        atomic(product_dir / (stem + "-sample.json"),
                               {"status": "NOT_RUN", "reason": "diagnosticsDisabled", "diagnosticOnly": True})
                executable = candidate_copy(host, product_dir, revision)
                product_env = dict(env, NEARPANE_SPACES_CANDIDATE_PIDS=",".join(str(p.pid) for _, p in children))
                product_process = execute([executable, "--independent-spaces-candidate", "--independent-stage-acceptance",
                                           product_dir / "config.json"], out, "product", product_env, 240 + iterations * 20,
                                          sample_host=product_dir if host_sampling else None)
                receipt = product_dir / "product-result.json"
                product = json.loads(receipt.read_text()) if receipt.exists() else {
                    "status": "UNKNOWN", "reason": "productTerminalReceiptMissing", "process": product_process, "cleanup": False}
                product["hostSampling"] = sampling_policy
                product["hostCrashRecovery"] = "NOT_RUN"
                product.update({key: "NOT_RUN" for key in LIFECYCLE_CHECKS})
                product["lifecycleReceipt"] = {"status": "NOT_RUN", "reason": "mainR4AndCrashRestartCleanupRequired"}
                if product.get("status") == "PRODUCT_R4_PASS" and product.get("cleanup") is True:
                    phase = "productCrash"
                    crash = run_host_crash(executable, apps["Controller"]["executable"], config, engine,
                                           out / "product-crash", product_env)
                    product["hostCrashRecovery"] = crash["status"]
                    product["hostCrashReceipt"] = crash
                    if crash.get("status") == "PASS" and crash.get("cleanup") is True:
                        phase = "productLifecycle"
                        lifecycle_dir = out / "product-lifecycle"
                        lifecycle_dir.mkdir(mode=0o700)
                        lifecycle_config = dict(config, purpose="lifecycle", output=str(lifecycle_dir),
                                                profile=str(lifecycle_dir / "profile"))
                        atomic(lifecycle_dir / "config.json", lifecycle_config)
                        lifecycle_process = execute([executable, "--independent-spaces-candidate", "--independent-stage-acceptance",
                                                     lifecycle_dir / "config.json"], out, "product-lifecycle", product_env,
                                                    150, reap_children=tuple(p for _, p in children))
                        lifecycle_path = lifecycle_dir / "product-result.json"
                        lifecycle = json.loads(lifecycle_path.read_text()) if lifecycle_path.is_file() else {
                            "status": "UNKNOWN", "reason": "lifecycleTerminalReceiptMissing", "cleanup": False}
                        if (not isinstance(lifecycle, dict) or lifecycle.get("nonce") != nonce
                                or lifecycle.get("purpose") != "lifecycle"):
                            lifecycle = {"status": "UNKNOWN", "reason": "lifecycleReceiptIdentityUnconfirmed", "cleanup": False}
                        product = attach_lifecycle(product, lifecycle, lifecycle_process)
                        atomic(out / "product-with-lifecycle.json", product)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            failure = {"status": "BLOCKED" if isinstance(error, PreflightBlocked) else "UNKNOWN", "phase": phase,
                       "reason": type(error).__name__ + ": " + str(error)}
            if phase == "platformDiagnostic":
                platform_diagnostic = dict(failure, cleanup=False)
            elif phase == "productLifecycle":
                product = attach_lifecycle(product, dict(failure, cleanup=False), {})
            elif phase in ("productCandidate", "productCrash"):
                product = failure
            else:
                engine = dict(engine, **failure)
        finally:
            for directory, child in reversed(children):
                cleanup.append(close_fixture(directory, child, nonce))
            atomic(out / "fixture-cleanup.json", cleanup)
            if (out / "ci-workspace-state.json").is_file():
                workspace_cleanup = ci_workspace(apps, out, env, "cleanup")
    result = evaluate(engine, product, platform_diagnostic)
    result.update(engineReceipt=engine, productReceipt=product, fixtureCleanup=cleanup, hostSampling=sampling_policy,
                  platformDiagnosticReceipt=platform_diagnostic, ciWorkspacePreparation=workspace,
                  ciWorkspaceCleanup=workspace_cleanup, ciWorkspaceCleanupBeforeFixtures=workspace_before_fixtures)
    if platform_diagnostic and platform_diagnostic.get("cleanup") is not True:
        result.update(status="UNKNOWN", overall="INCOMPLETE", reason="platformDiagnosticCleanupUnconfirmed")
    if workspace_cleanup and (workspace_cleanup.get("status") != "READY" or workspace_cleanup.get("cleanup") is not True):
        result.update(status="UNKNOWN", overall="INCOMPLETE", reason="ciOwnedWorkspaceCleanupUnconfirmed")
    atomic(out / "summary.json", result)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("output", type=Path, help="new evidence directory")
    p.add_argument("--scope", choices=("source", "runtime", "all"), default="all")
    p.add_argument("--archive", type=Path, help="existing production Rust static archive; built if omitted")
    p.add_argument("--product-host", type=Path, help="reuse a complete Nearpane.app; --scope all builds it automatically when omitted")
    p.add_argument("--iterations", type=int, default=3, choices=range(1, 51), metavar="1..50")
    p.add_argument("--no-host-sampling", action="store_true",
                   help="run the unchanged product acceptance without diagnostic Host sampling")
    a = p.parse_args()
    os.umask(0o077)
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    env.setdefault("NEARPANE_RUN_ID", "independent-" + uuid.uuid4().hex[:12])
    toolchain = select_toolchain(env)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    summary = {"schema": 1, "revision": revision, "buildRunID": env["NEARPANE_RUN_ID"], "toolchain": toolchain,
               "hostSampling": "disabledByRequest" if a.no_host_sampling else "enabled",
               "source": "NOT_RUN", "runtime": "NOT_RUN",
               "candidate": {"status": "SUPPLIED", "completeApp": str(a.product_host)} if a.product_host else {"status": "NOT_RUN"}}
    print("revision", revision, "buildRunID", env["NEARPANE_RUN_ID"], "scope", a.scope, flush=True)
    if platform.system() != "Darwin":
        summary.update(status="BLOCKED", reason="macOSWindowServerRequired")
        atomic(out / "summary.json", summary)
        return 2
    if a.scope in ("source", "all"):
        summary["source"] = source_checks(out / "source", env)
    product_host = a.product_host
    if a.scope == "all" and product_host is None:
        if summary["source"].get("status") == "PASS":
            summary["candidate"], product_host = build_candidate(out / "candidate", env, revision)
        else:
            summary["candidate"] = {"status": "FAIL", "reason": "sourceChecksFailed", "fullBuild": "NOT_RUN"}
    if a.scope in ("runtime", "all"):
        archive = a.archive
        built = None
        if archive is None:
            built = execute(["bash", "scripts/build-window-engine.sh"], out, "build-engine", env)
            if built["status"] == "PASS":
                archive = Path((out / "build-engine.log").read_text().splitlines()[-1])
        if archive and archive.is_file():
            summary["runtime"] = runtime_checks(out / "runtime", env, archive.resolve(), product_host,
                                                  a.iterations, revision, host_sampling=not a.no_host_sampling)
        else:
            summary["runtime"] = {"status": "FAIL" if built and built["status"] != "PASS" else "BLOCKED",
                                  "reason": "engineArchiveUnavailable"}
    atomic(out / "summary.json", summary)
    print(json.dumps({k: v for k, v in summary.items() if k not in ("runtime", "source")}, indent=2))
    # Preserve blocked/not-run receipts, but a lane that explicitly supplied the
    # product Host cannot be green without a real R4 product result.
    source_failed = isinstance(summary["source"], dict) and summary["source"].get("status") != "PASS"
    candidate_failed = summary["candidate"].get("status") in ("FAIL", "UNKNOWN")
    runtime = summary["runtime"] if isinstance(summary["runtime"], dict) else {}
    runtime_failed = any(runtime.get(key) in ("FAIL", "UNKNOWN") for key in
                         ("status", "engine", "R4ProductPath", "platformForeignMechanism", *SYSTEM_CHECKS))
    if a.scope in ("runtime", "all") and product_host is not None and runtime.get("R4ProductPath") != "PASS":
        runtime_failed = True
    return 1 if source_failed or candidate_failed or runtime_failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
