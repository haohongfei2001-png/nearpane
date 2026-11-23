"""Run one qualification on the sole installed version and return its regular Host to the same login."""
import argparse
from datetime import datetime, timezone
import importlib
import json
import mmap
from pathlib import Path
import subprocess
import sys
import overview_admission

upgrade = importlib.import_module("upgrade-installed")
install, cycle, require = upgrade.install, upgrade.cycle, upgrade.require
HERE = Path(__file__).resolve().parent


def summarize_trial(name, trial):
    result = dict(qualification=trial["status"], reason=trial.get("reason"))
    if name == "corner-readback":
        result.update(membershipReadback=trial["status"], guardianReadback=trial.get("guardianReadback"),
                      singleWindowHideRestore="NOT_RUN", productionQualified=False)
        if trial["status"] == "PASS":
            result["qualification"] = "NOT_RUN"
        return result
    membership = trial.get("thirdPartyMembershipRoundTrip", "UNKNOWN")
    isolation = trial.get("singleWindowHideRestore", "UNKNOWN")
    result.update(thirdPartyMembershipRoundTrip=membership, singleWindowHideRestore=isolation)
    if trial["status"] == "PASS" and (membership != "PASS" or isolation != "PASS"):
        result["qualification"] = "BLOCKED" if membership == "PASS" and isolation == "NOT_RUN" else "UNKNOWN"
    return result


def advertises_interactive_entry(executable, name):
    # These exact command-line literals are shared by the signed Host and launch-scope.
    # This check can veto an obsolete image. Only the signed socket handshake can enroll a window.
    option = b"--interactive-spaces-cycle" if name == "interactive-spaces" else b"--interactive-window-pair"
    with executable.open("rb") as file:
        with mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as image:
            return image.find(option) >= 0


def run(work, name, update, result_dir=None, p0_receipt=None, kit=None):
    result_dir = result_dir or work
    mac = install.Mac()
    previous = json.loads((work / "08-upgrade.json").read_bytes())
    require(previous["status"] == "PASS" and previous["stage"] == "running", "An admitted installed version is required")
    expected = previous["installed"]
    writes = name in {"spaces", "interactive-spaces"}
    admission_stage = "p0RequiredBeforeQuit" if writes else "ordinaryDesktopRequiredBeforeQuit"
    update("checkingAdmission", missionControlPresentationRequired=writes,
           scopeOfEvidence="nativeSpacesResearch" if writes else "sameDesktopFixtureReadOnly")
    try:
        observation, digest = overview_admission.load_receipt(p0_receipt)
    except (OSError, ValueError) as error:
        update(admission_stage, qualification="BLOCKED", admissionReason=str(error), quitRequests=0)
        return
    interactive = name in {"interactive-spaces", "interactive-roster"}
    if writes and observation.get("status") != "PASS":
        update(admission_stage, qualification="BLOCKED", observationStatus=observation.get("status"),
               admissionReason=observation.get("reason"), observationSHA256=digest, quitRequests=0)
        return
    current = mac.inspect(mac.canonical, expected)
    require(current == expected, "Installed image changed after admission")
    pid = mac.pid()
    require(pid is not None, "No running canonical Host")
    generation = install.process_stamp(pid)
    birth = generation[1] * 1_000_000 + generation[2]
    qualifies = overview_admission.qualifies if writes else overview_admission.qualifies_read_only
    if not qualifies(observation, current, pid, birth):
        update(admission_stage, qualification="BLOCKED", admissionReason="physicalEvidenceOrHostBindingIncomplete",
               observationSHA256=digest, quitRequests=0)
        return
    if interactive:
        pair_runner = importlib.import_module("interactive-pair")
        require(kit is not None, "signedInteractiveFixtureKitRequired")
        owners = pair_runner.reviewed_owners(kit)
        advertised = advertises_interactive_entry(mac.canonical / "Contents/MacOS/NearpaneHost", name)
        update("interactiveImagePreflight", installedImage=current, registeredFixtureImages=owners,
               interactiveEntryAdvertised=advertised, operatingPID=pid, operatingBirth=birth, observationSHA256=digest)
        if not advertised:
            update("interactiveEntryUnavailableBeforeQuit", qualification="BLOCKED",
                   admissionReason="installedImageLacksInteractiveProtocol", quitRequests=0,
                   windowsCreated=0, windowWrites=0, spaceWrites=0)
            return
    permissions = cycle.backup.permissions.sample()
    install.persist(result_dir / (name + "-before-permissions.json"), permissions)
    require(permissions["status"] == "PASS" and permissions["installed"]["CDHash"] == current["cdhash"]
            and permissions.get("subject", {}).get("pid") == pid and permissions["subject"].get("birth") == birth
            and all(permissions["permissions"].get(key) is True for key in
                    ("accessibility", "listenEvent", "postEvent", "screenCapture")), "Host permissions are incomplete")
    roster = upgrade.census(work, mac.canonical)
    before = upgrade.recoveries(work)
    require(cycle.admit_daily(dict(roster=roster, leases=before), mac.pid()), "A process or recovery responsibility changed")
    stamp = mac.bound(mac.pid(), mac.daily, current)
    out = result_dir / (name + ".json")
    require(not out.exists(), "Do not replay a real qualification")
    expected_hid = observation["measurement"]["hidAfter"] if writes else observation["hidAfterPassiveRead"]
    hid = overview_admission.current_hid()
    if hid["pressed"] or hid["secure"] or hid["counts"] != expected_hid or not qualifies(observation, current, stamp[0], birth):
        update(admission_stage, qualification="BLOCKED", admissionReason="physicalInputOrAdmissionChangedBeforeQuit",
               observationSHA256=digest, preQuitInput=hid, quitRequests=0)
        return
    update("requestNormalQuit", previous=stamp, configurationBefore=mac.config(), beforeQuitRecovery=before)
    mac.quit(stamp)
    diagnostic_started = False
    try:
        mac.wait_stopped([mac.canonical])
        empty = upgrade.census(work, mac.canonical)
        require(empty["pids"] == [] and cycle.stamp_is_gone(stamp), "Previous Host still running")
        update("soleInstalledImageReady", emptyRoster=empty)
        now = overview_admission.current_hid()
        if now["pressed"] or now["secure"] or now["counts"] != expected_hid:
            update("inputChangedBeforeDiagnosticLaunch", qualification="BLOCKED", preLaunchInput=now)
            return  # finally returns the ordinary Host; no fixture or Space has been created.
        args = [sys.executable, "-B", HERE / "sample-membership.py", mac.canonical, out, "--installed",
                "--expected-source", current["source"], "--expected-cdhash", current["cdhash"]]
        if name == "spaces":
            args.extend(["--enrolled-spaces-cycle", "--p0-receipt", str(p0_receipt), "--p0-sha256", digest])
        if interactive:
            folder = result_dir / (name + "-evidence")
            require(not folder.exists(), "interactiveNonceAlreadyUsed")
            args = [sys.executable, "-B", HERE / "interactive-pair.py", folder, "--kit", kit,
                    "--revision", current["source"], "--cdhash", current["cdhash"]]
            if writes:
                args.extend(["--spaces-cycle", "--p0-receipt", str(p0_receipt), "--p0-sha256", digest])
        with subprocess.Popen(args) as child:
            diagnostic_started = True
            exit_code = child.wait()
        if interactive:
            trial = json.loads((folder / "result.json").read_bytes())
            install.persist(out, trial)
            update("qualificationReturned", trialExit=exit_code, qualification=trial["status"],
                   trioRegistration=trial.get("pair", {}).get("trioRegistration", "NOT_RUN"),
                   inputs=trial.get("pair", {}).get("inputs", []), membershipRoundTrip=trial.get("engineVisibilityRoundTrip"),
                   productionQualified=False)
            return
        trial = json.loads(out.read_bytes())
        update("qualificationReturned", trialExit=exit_code, cleanup=trial["probeResources"], **summarize_trial(name, trial))
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
    p.add_argument("scope", choices=["spaces", "corner-readback", "interactive-roster", "interactive-spaces"])
    p.add_argument("--kit", type=Path, help="reviewed two-application signed fixture kit for the interactive paths")
    observation = p.add_mutually_exclusive_group()
    observation.add_argument("--desktop-receipt", type=Path, help="fresh passive ordinary desktop, original focus and HID observation")
    observation.add_argument("--p0-receipt", type=Path, help="Mission Control evidence for the native Spaces research paths; legacy alias for passive reads")
    p.add_argument("--result-dir", type=Path, help="fresh private directory for this stage's receipts")
    args = p.parse_args()
    if args.desktop_receipt is not None and args.scope in {"spaces", "interactive-spaces"}:
        p.error("native Spaces research requires its own Mission Control evidence")
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
            run(args.work, args.scope, update, result_dir=directory, p0_receipt=args.desktop_receipt or args.p0_receipt, kit=args.kit)
        if record.get("stage") in {"p0RequiredBeforeQuit", "ordinaryDesktopRequiredBeforeQuit", "interactiveEntryUnavailableBeforeQuit"}:
            record["status"] = "BLOCKED"
        elif record.get("stage") == "regularHostRunning":
            verdict = record.get("membershipReadback", record.get("qualification", "UNKNOWN"))
            record["status"] = verdict if record["configurationBefore"] == record["configurationAfter"] else "UNKNOWN"
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        record["error"] = str(error)[:400]
    install.persist(out, record)
    return 0 if record["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
