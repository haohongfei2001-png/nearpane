"""Run one qualification on the sole installed version and return its regular Host to the same login."""
import argparse
from datetime import datetime, timezone
import importlib
import json
from pathlib import Path
import subprocess
import sys
import overview_admission

upgrade = importlib.import_module("upgrade-installed")
install, cycle, require = upgrade.install, upgrade.cycle, upgrade.require
HERE = Path(__file__).resolve().parent


def run(work, name, update, result_dir=None, p0_receipt=None):
    result_dir = result_dir or work
    mac = install.Mac()
    previous = json.loads((work / "08-upgrade.json").read_bytes())
    require(previous["status"] == "PASS" and previous["stage"] == "running", "An admitted installed version is required")
    expected = previous["installed"]
    if name == "spaces":
        try:
            observation, digest = overview_admission.load_receipt(p0_receipt)
        except (OSError, ValueError) as error:
            update("p0RequiredBeforeQuit", qualification="BLOCKED", p0Reason=str(error), quitRequests=0)
            return
        if observation.get("status") != "PASS":
            update("p0RequiredBeforeQuit", qualification="BLOCKED", p0Status=observation.get("status"),
                   p0Reason=observation.get("reason"), p0SHA256=digest, quitRequests=0)
            return
    current = mac.inspect(mac.canonical, expected)
    require(current == expected, "Installed image changed after admission")
    permissions = json.loads((work / "09-running-permissions.json").read_bytes())
    pid = mac.pid()
    require(pid is not None, "No running canonical Host")
    generation = install.process_stamp(pid)
    birth = generation[1] * 1_000_000 + generation[2]
    if name == "spaces" and not overview_admission.qualifies(observation, current, pid, birth):
        update("p0RequiredBeforeQuit", qualification="BLOCKED", p0Reason="physicalEvidenceOrHostBindingIncomplete",
               p0SHA256=digest, quitRequests=0)
        return
    if (permissions.get("subject", {}).get("pid") != pid or
            permissions.get("subject", {}).get("birth") != generation[1] * 1_000_000 + generation[2]):
        permissions = cycle.backup.permissions.sample()
        install.persist(result_dir / (name + "-before-permissions.json"), permissions)
    require(permissions["status"] == "PASS" and permissions["installed"]["CDHash"] == current["cdhash"]
            and all(permissions["permissions"].get(key) is True for key in
                    ("accessibility", "listenEvent", "postEvent", "screenCapture")), "Host permissions are incomplete")
    roster = upgrade.census(work, mac.canonical)
    before = upgrade.recoveries(work)
    require(cycle.admit_daily(dict(roster=roster, leases=before), mac.pid()), "A process or recovery responsibility changed")
    stamp = mac.bound(mac.pid(), mac.daily, current)
    if name == "corner-readback":
        preceding = json.loads((result_dir / "spaces-session.json").read_bytes())
        require(preceding.get("status") == "PASS" and preceding.get("qualification") == "PASS"
                and preceding.get("cleanup", {}).get("clear") is True, "P1 installed round trip and regular Host return required")
    out = result_dir / (name + ".json")
    require(not out.exists(), "Do not replay a real qualification")
    update("requestNormalQuit", previous=stamp, configurationBefore=mac.config(), beforeQuitRecovery=before)
    mac.quit(stamp)
    diagnostic_started = False
    try:
        mac.wait_stopped([mac.canonical])
        empty = upgrade.census(work, mac.canonical)
        require(empty["pids"] == [] and cycle.stamp_is_gone(stamp), "Previous Host still running")
        update("soleInstalledImageReady", emptyRoster=empty)
        args = [sys.executable, "-B", HERE / "sample-membership.py", mac.canonical, out, "--installed",
                "--expected-source", current["source"], "--expected-cdhash", current["cdhash"]]
        if name == "spaces":
            args.extend(["--enrolled-spaces-cycle", "--p0-receipt", str(p0_receipt), "--p0-sha256", digest])
        with subprocess.Popen(args) as child:
            diagnostic_started = True
            exit_code = child.wait()
        trial = json.loads(out.read_bytes())
        qualification = trial["status"]
        if name == "spaces" and qualification == "PASS" and trial.get("singleWindowHideRestore") != "PASS":
            qualification = "UNKNOWN"
        update("qualificationReturned", trialExit=exit_code, qualification=qualification,
               cleanup=trial["probeResources"], reason=trial.get("reason"))
    finally:
        remaining = upgrade.census(work, mac.canonical)
        leases = upgrade.recoveries(work)
        update("normalHostReturnCheck", remainingRoster=remaining, afterTrialRecovery=leases)
        resources_clear = not diagnostic_started or (out.is_file() and json.loads(out.read_bytes()).get("probeResourcesClear") is True)
        require(not remaining["pids"] and leases["quitPermitted"] and resources_clear,
                "Unresolved probe, live Host or recovery responsibility")
        require(mac.inspect(mac.canonical, current) == current, "Installed image changed during qualification")
        mac.open_daily()
        stamp = mac.wait_owner(mac.daily, current)
        end = upgrade.census(work, mac.canonical)
        require(end["pids"] == [stamp[0]], "Regular Host is not unique")
        update("regularHostRunning", currentProcess=stamp, returnedRoster=end, configurationAfter=mac.config())


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("work", type=Path)
    p.add_argument("scope", choices=["spaces", "corner-readback"])
    p.add_argument("--p0-receipt", type=Path, help="private observation of the running regular Host before any trial")
    p.add_argument("--result-dir", type=Path, help="fresh private directory for this stage's receipts")
    args = p.parse_args()
    install.owned_dir(args.work)
    directory = args.result_dir or args.work
    install.owned_dir(directory)
    out = directory / (args.scope + "-session.json")
    with out.open("x"):
        pass
    record = dict(schema=1, events=[], status="UNKNOWN", scope=args.scope)

    def update(stage, **facts):
        record.update(facts, stage=stage)
        record["events"].append(dict(stage=stage, utc=datetime.now(timezone.utc).isoformat()))
        install.persist(out, record)

    try:
        with install.free_lock(install.Mac.root / "supervisor.lock"):
            run(args.work, args.scope, update, result_dir=directory, p0_receipt=args.p0_receipt)
        if record.get("stage") == "p0RequiredBeforeQuit":
            record["status"] = "BLOCKED"
        elif record.get("stage") == "regularHostRunning":
            record["status"] = (record.get("qualification", "UNKNOWN") if
                                record["configurationBefore"] == record["configurationAfter"] else "UNKNOWN")
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        record["error"] = str(error)[:400]
    install.persist(out, record)
    return 0 if record["status"] == "PASS" and record.get("qualification") == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
