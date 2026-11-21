#!/usr/bin/env python3
"""Observe five independent signed ordinary windows and their cards on an already active, empty, enrolled desktop."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

from acceptance import identity, wait_state
from five_preview_metrics import expected_colors, measure_batch, phase_result, overall
from installed_profile import APP, PROFILE, installed_pid, owns_profile, validate_home

ERRORS = (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError)


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def query(args, payload=None, timeout=8):
    raw = subprocess.check_output([str(x) for x in args], input=json.dumps(payload), text=True, timeout=timeout)
    return json.loads(raw)


def persist(path, document):
    other = path.with_name(path.name + ".next")
    other.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    os.replace(other, path)


def signed(path, identifier=None):
    command = ["/usr/bin/codesign", "--verify", "--strict"]
    if identifier:
        command.append(f'-R=identifier "{identifier}"')
    subprocess.run([*command, str(path)], check=True, timeout=8, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return identity(path)["CDHash"]


def cleared(kit, item):
    state = query([kit / "process-generation", item["pid"]])
    return state.get("pid") == item["pid"] and (state.get("absent") is True or
            isinstance(state.get("birth"), int) and 0 < state["birth"] != item["birth"])


def run_case(kit, out, expected_space, expected_source, expected_display=None, expected_uuid=None):
    os.umask(0o077)
    out.mkdir(parents=True, mode=0o700, exist_ok=False)
    value = dict(status="BLOCKED", case="five signed ordinary fixture apps on one active display/Space",
                 scope="one physical installed Host buffer, five current cards, five independent sources; no saved pixels",
                 phases=[], checkpoints=[], cleanup={"status":"NOT_RUN"}, perCard=["NOT_RUN"] * 5)
    save = lambda: persist(out / "result.json", value)
    temp = None
    launched = []
    run = {}
    hardware = None
    profile = None
    save()

    def check():
        require(owns_profile(run["hostPID"], profile), "isolatedHostProfileLockChanged")
        result = query([kit / "five-scope", "compare-roster"], run)
        if hardware is not None:
            require(result.get("hardware") == hardware, result.get("reason", "physicalInputOrIdentityChanged"))
        return result

    def wait_scope(label, full, seconds):
        start = time.monotonic()
        checkpoint = dict(label=label, elapsed=0, reads=[], ready=False)
        value["checkpoints"].append(checkpoint)
        while True:
            proof = check()
            checkpoint["reads"].append(proof)
            checkpoint["elapsed"] = round(time.monotonic() - start, 3)
            checkpoint["ready"] = proof.get("ready" if full else "membership") is True
            save()
            if checkpoint["ready"] or checkpoint["elapsed"] >= seconds:
                return proof
            time.sleep(.25)

    try:
        require(kit.parent == Path("/private/tmp") and kit.name.startswith("nearpane-d01.") and kit.stat().st_uid == os.getuid()
                and kit.stat().st_mode & 0o077 == 0, "invalidPrivateKit")
        for tool in ("five-scope", "five-capture", "process-generation"):
            signed(kit / tool)
        test_home = os.environ.get("NEARPANE_TEST_HOME")
        require(test_home and os.environ.get("NEARPANE_TEST_GENERATION"), "isolatedInstalledHostSessionRequired")
        home = Path(test_home)
        require(home.is_dir(), "isolatedInstalledHostHomeMissing")
        validate_home(home)
        profile = home / PROFILE
        pid, host_hash = installed_pid(), signed(APP, "com.holdsnow.nearpane.alpha")
        require(pid and owns_profile(pid, profile), "isolatedInstalledHostLockUnavailable")
        info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
        revision = info.get("NearpaneSourceRevision", "")
        value["installed"] = dict(source=revision, build=info.get("CFBundleVersion"), cdhash=host_hash, pid=pid)
        require(len(expected_source) == 40 and all(c in "0123456789abcdef" for c in expected_source) and revision == expected_source and info.get("CFBundleVersion") == "90", "installedCandidateRevisionOrBuildMismatch")
        origin = query([kit / "five-scope", "compare-roster"], dict(operation="initialIdentity", pid=pid, hash=host_hash, space=expected_space))
        require(origin.pop("ready", False), origin.get("reason","installedScopeUnavailable"))
        run = origin
        require((not expected_display or run["display"] == expected_display.upper()) and
                (not expected_uuid or run["spaceUUID"] == expected_uuid.upper()), "unexpectedPhysicalDisplayOrSpaceUUID")
        value["run"] = run
        first = wait_scope("emptyBefore", True, 2)
        require(first.get("ready"), first.get("reason"))
        hardware = first["hardware"]
        time.sleep(.18)
        second = wait_scope("emptyConfirmed", True, 2)
        require(second.get("ready"), second.get("reason"))
        apps = []
        for slot in range(5):
            ident = f"net.example.nearpane-five-preview.{slot + 1}"
            app = kit / f"Five Notes {slot + 1}.app"
            apps.append((app, ident, signed(app, ident)))
        require(len(set(x[2] for x in apps)) == 5, "fiveDistinctSignedBundlesRequired")
        temp = Path(tempfile.mkdtemp(prefix="nearpane-five.", dir="/private/tmp")).resolve()
        (temp / "home").mkdir(mode=0o700)
        for slot, (app, ident, code_hash) in enumerate(apps):
            if slot:
                scoped = wait_scope(f"beforeLaunch{slot+1}", False, 4)
                require(scoped.get("membership"), scoped.get("reason"))
            folder = temp / str(uuid.uuid4())
            folder.mkdir(mode=0o700)
            item = {"dir":folder, "pid":None, "birth":None, "slot":slot}
            request = ["/usr/bin/open", "-n", "-W", "-a", str(app), "--env", f"HOME={temp/'home'}",
                       "--env", f"CFFIXED_USER_HOME={temp/'home'}", "--env", "NP_FIXTURE_PRESENTATION=five-preview",
                       "--args", str(folder), "1"]
            item["launcher"] = subprocess.Popen(request, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            launched.append(item)
            startup = wait_state(folder / "startup.json", lambda s: s.get("session") == folder.name and s.get("bundle") == ident
                                 and s.get("policy") == 0 and s.get("displayCount") == 1 and s.get("pid", 0) > 1
                                 and s.get("birth", 0) > 0, time.monotonic() + 5)
            require(startup, "fixturePrivateStartupUnavailableSlot"+str(slot))
            item.update(pid=startup["pid"], birth=startup["birth"])
            state = wait_state(folder / "windows.json", lambda s: s.get("session") == folder.name and s.get("bundle") == ident
                               and s.get("slot") == slot and s.get("phase") == 0 and s.get("presentation") == "five-preview"
                               and s.get("visible") == [True] and s.get("minimized") == [False] and len(s.get("numbers", [])) == 1,
                               time.monotonic() + 6)
            require(state and state["pid"] == item["pid"] and state["birth"] == item["birth"] and state["numbers"][0] > 0, "fixtureWindowDidNotEnrollSlot"+str(slot))
            owner = dict(slot=slot, pid=state["pid"], birth=state["birth"], number=state["numbers"][0], hash=code_hash)
            item.update(owner)
            run["owners"].append(owner)
            save()
        installed = wait_scope("allFiveCurrent", True, 8)
        value["membership"] = "PASS" if installed.get("membership") else "UNKNOWN"
        value["fiveCardInteriorsInSameViewport"] = "PASS" if installed.get("ready") else "UNKNOWN"
        require(installed.get("ready"), installed.get("reason"))
        value["status"] = "UNKNOWN"
        for step in range(6):
            proof = check()
            require(proof.get("ready"), proof.get("reason"))
            if step:
                item = launched[step-1]
                marker = {k:item[k] for k in ("slot","pid","birth","number")}
                marker.update(session=item["dir"].name, phase=1, issued=time.monotonic())
                persist(item["dir"] / "advance.json", marker)
                state = wait_state(item["dir"] / "windows.json", lambda s: s.get("session") == item["dir"].name and
                                   (s.get("pid"),s.get("birth"),s.get("numbers"),s.get("phase")) ==
                                   (item["pid"],item["birth"],[item["number"]],1), time.monotonic()+3)
                require(state, "fixtureDidNotAcknowledgeSingleChangeSlot"+str(step-1))
            phase = dict(step=step, changedSlot=step-1 if step else None, expected=expected_colors(step), samples=[], bySlot=["UNKNOWN"]*5)
            value["phases"].append(phase)
            start = time.monotonic()
            while True:
                require(owns_profile(pid,profile), "isolatedHostProfileLockChanged")
                try:
                    batch = query([kit / "five-capture"], run, timeout=12)
                except (subprocess.TimeoutExpired, subprocess.CalledProcessError, ValueError):
                    batch = dict(ready=False,reason="boundedPhysicalSamplerUnavailable")
                verdicts = measure_batch(batch, step, run, hardware)
                phase["samples"].append(dict(batch=batch,verdicts=verdicts))
                elapsed = time.monotonic()-start
                settled = elapsed >= 6
                phase["bySlot"] = phase_result(phase["samples"], settled)
                phase["elapsed"] = round(elapsed, 3)
                save()
                if all(s == "PASS" for s in phase["bySlot"]) or (settled and len(phase["samples"]) >= 2):
                    break
                time.sleep(.25)
        value["perCard"],value["status"] = overall(value["phases"])
    except ERRORS as e:
        value["reason"] = str(e)[:200]
        if launched:
            value["perCard"],value["status"] = overall(value["phases"])
    finally:
        if launched:
            cleanup = dict(status="UNKNOWN", fixtures=[])
            value["cleanup"] = cleanup
            # Only fixture-private commands are touched. These apps also have their own normal bounded expiry.
            for item in launched:
                (item["dir"] / "close").touch()
            deadline = time.monotonic()+9
            for item in launched:
                ended = False
                try:
                    if item["pid"]:
                        while True:
                            ended = cleared(kit,item)
                            if ended or time.monotonic() >= deadline: break
                            time.sleep(.15)
                    item["launcher"].wait(timeout=max(.15,deadline-time.monotonic()))
                except ERRORS:
                    pass
                cleanup["fixtures"].append(dict(slot=item["slot"],pid=item["pid"],birth=item["birth"],generationExited=ended,
                                               launcherExited=item["launcher"].poll() is not None))
            if all(x["generationExited"] and x["launcherExited"] for x in cleanup["fixtures"]):
                try:
                    run = dict(run,owners=[])
                    final = wait_scope("emptyAfter", True, 6)
                    if final.get("ready"):
                        time.sleep(.18)
                        final = wait_scope("emptyAfterConfirmed",True,2)
                    if final.get("ready"): cleanup["status"] = "PASS"
                except ERRORS as error:
                    cleanup["reason"] = str(error)[:160]
            if cleanup["status"] != "PASS":
                if value["status"] == "PASS": value["status"] = "UNKNOWN"
                if temp: cleanup["retainedFixtureDirectory"] = str(temp)
        if temp and (not launched or value["cleanup"]["status"] == "PASS"):
            shutil.rmtree(temp)
        save()
    return 0 if value["status"] == "PASS" else 2


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kit",type=Path)
    parser.add_argument("output",type=Path)
    parser.add_argument("--expected-space",type=int,required=True)
    parser.add_argument("--expected-display")
    parser.add_argument("--expected-space-uuid")
    parser.add_argument("--expected-source",required=True,help="full externally verified revision of the installed build 90 candidate")
    args=parser.parse_args()
    raise SystemExit(run_case(args.kit.resolve(),args.output.resolve(),args.expected_space,args.expected_source,args.expected_display,args.expected_space_uuid))
