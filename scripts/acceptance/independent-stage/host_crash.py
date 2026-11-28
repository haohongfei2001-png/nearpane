"""Crash the disposable Host, then verify recovery and real R4 reuse of its unchanged profile."""
import hashlib
import json
from pathlib import Path
import subprocess
import time


def atomic(path, value):
    temporary = path.with_suffix(".next")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def readback_configuration(engine, checkpoint, executable, mode, worker=None):
    enrolled = engine.get("enrolledWindows", [])
    inventory = engine.get("originalSpaceInventory", [])
    if len(enrolled) != 3 or not inventory or not engine.get("ordinaryHome"):
        raise ValueError("originalForeignBaselineMissing")
    rows = checkpoint.get("observations", [{}])[-1].get("windows", [])
    by_number = {row["number"]: row for row in rows}
    if mode == "held" and (len(by_number) != 3 or set(by_number) != {row["number"] for row in enrolled}):
        raise ValueError("crashCheckpointWindowMismatch")
    windows = []
    for original in enrolled:
        target = {key: original[key] for key in ("pid", "birth", "number", "executable", "frame")}
        target["home"] = engine["ordinaryHome"]
        target["expectedSpace"] = engine["ordinaryHome"] if mode == "home" else by_number[target["number"]]["space"]
        target["expectedOnScreen"] = True if mode == "home" else by_number[target["number"]]["onScreen"]
        windows.append(target)
    return {"schema": 1, "nonce": engine["nonce"], "mode": mode, "seconds": 20 if mode == "home" else 3,
            "originalSpaceInventory": inventory, "windows": windows,
            **({"host": {"pid": checkpoint["hostPID"], "birth": checkpoint["hostBirth"],
                         "executable": str(executable)}} if mode == "held" else {}),
            **({"worker": worker} if worker is not None else {})}


def retained_profile(profile, checkpoint, executable, directory):
    """Read and preserve the real journal/owner; never clear or rewrite a ledger."""
    files = list(profile.rglob("stage-visibility-v1.json"))
    if len(files) != 1 or files[0].is_symlink() or not files[0].resolve().is_relative_to(profile.resolve()):
        raise ValueError("crashedHostLedgerAmbiguous")
    ledger_path = files[0]
    content = ledger_path.read_bytes()
    ledger = json.loads(content)
    owner = ledger.get("owner")
    if not isinstance(owner, dict) or not ledger.get("owned"):
        raise ValueError("crashedHostRetainedOwnerMissing")
    expected_host = {"pid": checkpoint["hostPID"], "birth": checkpoint["hostBirth"],
                     "executable": str(Path(executable).resolve())}
    expected_worker = Path(executable).resolve().parent.parent / "Helpers/NearpaneSpacesEngine"
    matches = []
    for path in profile.rglob("spaces-lifecycle-*.json"):
        if path.is_symlink() or not path.resolve().is_relative_to(profile.resolve()):
            continue
        data = path.read_bytes()
        value = json.loads(data)
        if value.get("schema") != 1 or value.get("owner") != owner or value.get("host") != expected_host:
            continue
        worker = value.get("worker", {})
        if (type(worker.get("pid")) is int and worker["pid"] > 1
                and type(worker.get("birth")) is int and worker["birth"] > 0
                and worker.get("executable") == str(expected_worker)):
            matches.append((path, data, worker))
    if len(matches) != 1:
        raise ValueError("crashedHostWorkerLifecycleUnconfirmed")
    lifecycle_path, lifecycle, worker = matches[0]
    with (directory / "ledger-before-crash.json").open("xb") as saved:
        saved.write(content)
    with (directory / "worker-before-crash.json").open("xb") as saved:
        saved.write(lifecycle)
    return ledger_path, content, worker, {"ledger": str(ledger_path.relative_to(profile)),
        "ledgerSHA256": hashlib.sha256(content).hexdigest(),
        "workerLifecycle": str(lifecycle_path.relative_to(profile)),
        "workerLifecycleSHA256": hashlib.sha256(lifecycle).hexdigest()}


def independent_readback(controller, config, directory, name, env):
    request, receipt = directory / (name + "-config.json"), directory / (name + ".json")
    atomic(request, config)
    with (directory / (name + ".log")).open("x") as stdout, (directory / (name + ".stderr.log")).open("x") as stderr:
        process = subprocess.run([controller, "--readback", str(request), str(receipt)], env=env,
                                 stdout=stdout, stderr=stderr, timeout=30)
    if not receipt.is_file():
        return {"status": "UNKNOWN", "reason": "independentReadbackReceiptMissing", "exit": process.returncode}
    result = json.loads(receipt.read_text())
    if (process.returncode != 0 or result.get("nonce") != config["nonce"] or result.get("mode") != config["mode"]
            or result.get("windowWrites") != 0 or len(result.get("observations", [])) != 2):
        result["status"] = "UNKNOWN"
    return result


def restart_same_profile(executable, controller, config, engine, checkpoint, worker,
                         ledger_path, original_ledger, directory, env):
    result = {"status": "BLOCKED", "reason": "sameProfileRestartNotStarted", "started": False,
              "actualR4Inputs": 0, "afterReadback": "NOT_RUN", "cleanup": False}
    child = None
    try:
        # A successful worker return does not authorize discarding its old Host's
        # journal. Production cold-start reconciliation must consume these bytes.
        retained = ledger_path.read_bytes()
        result["ledgerBeforeRestartSHA256"] = hashlib.sha256(retained).hexdigest()
        result["originalLedgerUnchanged"] = retained == original_ledger
        if retained != original_ledger:
            raise ValueError("oldLedgerChangedBeforeRestart")
        config = dict(config, purpose="hostRestart")
        atomic(directory / "config.json", config)
        with (directory / "restart.log").open("x") as stdout, (directory / "restart.stderr.log").open("x") as stderr:
            child = subprocess.Popen([str(executable), "--independent-spaces-candidate", "--independent-stage-acceptance",
                                      str(directory / "config.json")], env=env, stdout=stdout, stderr=stderr,
                                     start_new_session=True)
            result.update(started=True, hostPID=child.pid, profile=config["profile"])
            code = child.wait(timeout=65)
            result["hostExit"] = code
        receipt = directory / "product-result.json"
        product = json.loads(receipt.read_text()) if receipt.is_file() else {}
        if receipt.is_file():
            with (directory / "restart-product-result.json").open("xb") as saved:
                saved.write(receipt.read_bytes())
        result["productStatus"] = product.get("status", "UNKNOWN")
        result["productReason"] = product.get("reason", "terminalReceiptMissing")
        result["actualR4Inputs"] = product.get("actualR4Inputs", 0)
        selected = (code == 0 and product.get("status") == "HOST_RESTART_R4_PASS"
                    and product.get("hostPID") == child.pid and product.get("hostBirth", 0) > 0
                    and product.get("profile") == str(Path(config["profile"]).resolve())
                    and product.get("actualR4Inputs", 0) > 0
                    and product.get("foreignWindowReadback") is True and product.get("cleanup") is True)
        result.update(status="PASS" if selected else "UNKNOWN",
                      reason="sameProfileRealR4SelectionConfirmed" if selected else "sameProfileR4SelectionUnconfirmed")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        result.update(status="UNKNOWN", reason=type(error).__name__ + ": " + str(error))
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                result.update(status="UNKNOWN", reason="restartedDisposableHostStillRunning")
        try:
            final = independent_readback(controller, readback_configuration(engine, checkpoint, executable, "home", worker),
                                         directory, "after-restart", env)
            clean = final.get("status") == "INDEPENDENT_READBACK_PASS" and final.get("cleanup") is True
            result.update(afterReadback=final.get("status", "UNKNOWN"), cleanup=clean)
            if not clean:
                result.update(status="UNKNOWN", reason="restartFinalPhysicalReturnUnconfirmed")
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            result.update(status="UNKNOWN", reason="restartFinalReadback: " + str(error), cleanup=False)
        atomic(directory / "restart-result.json", result)
    return result


def run_host_crash(executable, controller, original_config, engine, directory, env):
    """Normal product acceptance and complete restore must have succeeded first."""
    directory.mkdir(mode=0o700)
    config = dict(original_config, output=str(directory), profile=str(directory / "profile"), purpose="hostCrash")
    atomic(directory / "config.json", config)
    result = {"schema": 1, "status": "BLOCKED", "reason": "realR4HeldCheckpointNotReady", "hostKilled": False,
              "beforeReadback": "NOT_RUN", "afterReadback": "NOT_RUN", "helperSignalSent": False,
              "sameProfileRestart": "NOT_RUN",
              "cleanup": False, "qualificationGranted": False}
    child = None
    try:
        with (directory / "host.log").open("x") as stdout, (directory / "host.stderr.log").open("x") as stderr:
            child = subprocess.Popen([str(executable), "--independent-spaces-candidate", "--independent-stage-acceptance",
                                      str(directory / "config.json")], env=env, stdout=stdout, stderr=stderr,
                                     start_new_session=True)
            ready_path = directory / "host-crash-ready.json"
            deadline = time.monotonic() + 50
            checkpoint = None
            while time.monotonic() < deadline and child.poll() is None:
                if ready_path.is_file():
                    value = json.loads(ready_path.read_text())
                    if (value.get("hostPID") == child.pid and value.get("hostBirth", 0) > 0
                            and value.get("nonce", "").lower() == config["nonce"].lower()
                            and value.get("actualR4Inputs", 0) > 0):
                        checkpoint = value
                        break
                time.sleep(.05)
            if checkpoint is not None:
                ledger_path, retained, worker, profile = retained_profile(Path(config["profile"]), checkpoint, executable, directory)
                result["retainedProfile"] = profile
                before = independent_readback(controller, readback_configuration(engine, checkpoint, executable, "held", worker),
                                              directory, "before-crash", env)
                result["beforeReadback"] = before.get("status", "UNKNOWN")
                if before.get("status") == "INDEPENDENT_READBACK_PASS" and child.poll() is None:
                    # This Popen is the direct, still-live child created immediately above.
                    # No PID from a file, process scan, daily Host or worker is signalled.
                    child.kill()
                    code = child.wait(timeout=5)
                    result.update(hostKilled=code == -9, hostExit=code, actualR4Inputs=checkpoint["actualR4Inputs"])
                    after = independent_readback(controller, readback_configuration(engine, checkpoint, executable, "home", worker),
                                                 directory, "after-crash", env)
                    result["afterReadback"] = after.get("status", "UNKNOWN")
                    restored = code == -9 and after.get("status") == "INDEPENDENT_READBACK_PASS" and after.get("cleanup") is True
                    result.update(status="PASS" if restored else "UNKNOWN", cleanup=restored,
                                  reason="workerReturnedExactForeignWindows" if restored else "workerRestorationUnconfirmed")
                    result["crashRecovery"] = {"status": result["status"], "reason": result["reason"], "cleanup": restored}
                    if restored:
                        restart = restart_same_profile(executable, controller, config, engine, checkpoint, worker,
                                                       ledger_path, retained, directory, env)
                        result["sameProfileRestart"] = restart["status"]
                        result["restartReceipt"] = restart
                        result.update(status="PASS" if restart["status"] == "PASS" else "UNKNOWN", cleanup=restart["cleanup"],
                                      reason="crashReturnAndSameProfileR4RestartConfirmed" if restart["status"] == "PASS"
                                      else "sameProfileRestartUnconfirmed")
                else:
                    result.update(status="UNKNOWN", reason="independentHeldCheckpointUnconfirmed")
            # If the checkpoint was blocked, let the bounded in-app path return its
            # own windows. A timeout is a failure, never permission to kill a worker.
            if child.poll() is None:
                try:
                    child.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    child.wait(timeout=10)
                    result.update(status="UNKNOWN", reason="disposableHostGracefulExitTimedOut")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        result.update(status="UNKNOWN", reason=type(error).__name__ + ": " + str(error))
    finally:
        if child is not None and child.poll() is None:
            # Only this isolated test Host can receive the termination signal.
            # Its pipe closes; its original worker remains responsible for release.
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                result.update(status="UNKNOWN", reason="disposableHostStillRunning")
        normal = directory / "product-result.json"
        if not result["hostKilled"] and normal.is_file():
            result["cleanup"] = json.loads(normal.read_text()).get("cleanup") is True
        result["workerDiagnostics"] = [str(p.relative_to(directory)) for p in (directory / "profile").rglob("spaces-worker-*.jsonl")]
        atomic(directory / "host-crash-result.json", result)
    return result
