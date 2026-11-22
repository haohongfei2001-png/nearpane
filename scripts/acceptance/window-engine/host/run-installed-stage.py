"""Run one qualification on the sole installed version and return its regular Host to the same login."""
import argparse
from datetime import datetime, timezone
import importlib
import json
from pathlib import Path
import subprocess
import sys

upgrade = importlib.import_module("upgrade-installed")
install, cycle, require = upgrade.install, upgrade.cycle, upgrade.require
HERE = Path(__file__).resolve().parent


def run(work, name, update, result_dir=None):
    result_dir = result_dir or work
    mac = install.Mac()
    previous = json.loads((work / "08-upgrade.json").read_bytes())
    require(previous["status"] == "PASS" and previous["stage"] == "running", "An admitted installed version is required")
    expected = previous["installed"]
    current = mac.inspect(mac.canonical, expected)
    require(current == expected, "Installed image changed after admission")
    permissions = json.loads((work / "09-running-permissions.json").read_bytes())
    pid = mac.pid()
    require(pid is not None, "No running canonical Host")
    generation = install.process_stamp(pid)
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
        preceding = json.loads((result_dir / "spaces.json").read_bytes())
        require(preceding["probeResourcesClear"] is True, "Cannot start another scope with outstanding Spaces resources")
    out = result_dir / (name + ".json")
    require(not out.exists(), "Do not replay a real qualification")
    update("requestNormalQuit", previous=stamp, configurationBefore=mac.config(), beforeQuitRecovery=before)
    mac.quit(stamp)
    mac.wait_stopped([mac.canonical])
    try:
        empty = upgrade.census(work, mac.canonical)
        require(empty["pids"] == [] and cycle.stamp_is_gone(stamp), "Previous Host still running")
        update("soleInstalledImageReady", emptyRoster=empty)
        args = [sys.executable, "-B", HERE / "sample-membership.py", mac.canonical, out, "--installed",
                "--expected-source", current["source"], "--expected-cdhash", current["cdhash"]]
        if name == "spaces":
            args.append("--enrolled-spaces-cycle")
        result = subprocess.run(args, check=False)
        trial = json.loads(out.read_bytes())
        update("qualificationReturned", trialExit=result.returncode, qualification=trial["status"],
               cleanup=trial["probeResources"], reason=trial.get("reason"))
    finally:
        remaining = upgrade.census(work, mac.canonical)
        leases = upgrade.recoveries(work)
        update("normalHostReturnCheck", remainingRoster=remaining, afterTrialRecovery=leases)
        require(not remaining["pids"] and leases["quitPermitted"]
                and out.is_file() and json.loads(out.read_bytes()).get("probeResourcesClear") is True,
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
    args = p.parse_args()
    install.owned_dir(args.work)
    out = args.work / (args.scope + "-session.json")
    with out.open("x"):
        pass
    record = dict(schema=1, events=[], status="UNKNOWN", scope=args.scope)

    def update(stage, **facts):
        record.update(facts, stage=stage)
        record["events"].append(dict(stage=stage, utc=datetime.now(timezone.utc).isoformat()))
        install.persist(out, record)

    try:
        with install.free_lock(install.Mac.root / "supervisor.lock"):
            run(args.work, args.scope, update)
        record["status"] = "PASS" if record.get("stage") == "regularHostRunning" else "UNKNOWN"
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        record["error"] = str(error)[:400]
    install.persist(out, record)
    return 0 if record["status"] == "PASS" and record.get("qualification") == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
