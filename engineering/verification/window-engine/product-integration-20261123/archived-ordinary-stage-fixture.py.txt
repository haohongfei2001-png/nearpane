"""Borrow one new ordinary desktop via Apple's Mission Control, in the existing console session."""
import argparse
import importlib
import json
import os
from pathlib import Path
import subprocess
import time

stage = importlib.import_module("run-installed-stage")
up = stage.upgrade
from contract_workspace import Workspace, row


def regular_host(work, ws, candidate):
    mac = up.install.Mac()
    image = mac.inspect(mac.canonical, candidate)
    up.require(image == candidate, "Canonical signed image changed during the visit")
    stamp = mac.bound(mac.pid(), mac.daily, image)
    now = ws.read().get("host") or {}
    up.require(now.get("pid") == stamp[0] and now.get("codeHash") == candidate["cdhash"], "Fixture Host changed")
    ws.host = now
    ws.host_birth = stamp[1] * 1_000_000 + stamp[2]


def ordinary_foreground(work, focus):
    pid, window = focus
    if any(type(v) is not int or v <= 0 for v in focus):
        return False
    stamp = up.install.process_stamp(pid)
    birth = stamp[1] * 1_000_000 + stamp[2]
    samples = json.loads(subprocess.check_output(
        [work / "recovery-window", str(pid), str(birth), str(window)], timeout=8))
    return (len(samples) == 2 and all(r.get("regularForeground") is True and r.get("processBirthMatches") is True
            and r.get("exactWindowCount") == 1 for r in samples) and up.install.process_stamp(pid) == stamp)


def run(work, kit, directory, events, result):
    candidate = json.loads((work / "08-upgrade.json").read_bytes())["installed"]
    up.install.owned_dir(work)
    up.install.owned_dir(kit)
    up.require(kit.parent == Path("/private/tmp") and kit.name.startswith("nearpane-d01."), "Expected private system fixture kit")
    for name in ("observe", "system-workspace"):
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", kit / name], check=True)
    ws = Workspace(kit, directory, events)
    regular_host(work, ws, candidate)
    first = ws.original
    initial = row(first)
    focus = (first.get("frontmostPID"), first.get("focusedNumber"))
    fresh = ws.read()
    up.require(ordinary_foreground(work, focus) and row(fresh) == initial
               and focus == (fresh.get("frontmostPID"), fresh.get("focusedNumber"))
               and ws.hardware() == ws.hid and up.recoveries(work)["quitPermitted"],
               "A stable, ordinary foreground window and clear ownership are required")
    result.update(initialSpace=ws.home, originalFocus=list(focus), originalCount=len(initial["records"]), initialHID=ws.hid)
    baseline_input = None
    try:
        target = ws.create()
        result["setupDesktop"] = target
        up.require(ws.ids() == [target] and row(ws.read())["current"] in (target, ws.home), "Unowned desktop became active")
        active = ws.select(target)
        for _ in range(2):
            members = active["scopedMembers"][str(target)]
            up.require(members["unresolved"] == 0 and not members["ordinary"], "Ordinary fixture contains another real window")
            time.sleep(.16)
            active = ws.read()
            up.require(row(active)["current"] == target, "Fixture desktop is no longer active")
        baseline_input = ws.hardware()
        for name in ("spaces", "corner-readback"):
            if name == "corner-readback":
                space = json.loads((directory / "spaces.json").read_bytes())
                if space.get("probeResourcesClear") is not True:
                    result["corner"] = "BLOCKED"
                    break
            up.require(ws.hardware() == baseline_input and row(ws.read())["current"] == target, "User input or current desktop changed")
            stage.run(work, name, lambda s, **fields: events(name + "/" + s, **fields), result_dir=directory)
            regular_host(work, ws, candidate)
            outcome = json.loads((directory / (name + ".json")).read_bytes())
            result[name] = outcome["status"]
    finally:
        # Only the original full identity and the created, journalled desktop are selectable.
        # Rebind the normal process after diagnostic instances of this *same* installed image.
        regular_host(work, ws, candidate)
        if ws.ids():
            before = ws.read()
            active_id = row(before)["current"]
            up.require(up.recoveries(work)["quitPermitted"], "A WindowEngine recovery responsibility remains")
            if active_id != ws.home:
                up.require(active_id in ws.ids() and (baseline_input is None or ws.hardware() == baseline_input),
                           "Desktop or input changed before returning to the original Space")
                ws.select(ws.home)
            ws.recovering = True
            result["cleanup"] = ws.cleanup(inactive_system_surfaces=True)
        final = ws.read()
        result["inventoryRestored"] = row(final) == initial
        result["originalFocusRestored"] = (final.get("frontmostPID"), final.get("focusedNumber")) == focus
        result["remainingOwned"] = ws.ids()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("work", type=Path)
    p.add_argument("kit", type=Path)
    args = p.parse_args()
    os.umask(0o077)
    up.install.owned_dir(args.work)
    output = args.work / "ordinary-visit"
    output.mkdir(mode=0o700)
    result = dict(schema=1, scope="appleControlledOrdinaryDesktopFixture", status="UNKNOWN")
    with (output / "events.jsonl").open("x") as stream:
        def events(kind, **facts):
            stream.write(json.dumps(dict(event=kind, uptime=time.monotonic(), **facts)) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        try:
            with up.install.free_lock(up.install.Mac.root / "supervisor.lock"):
                run(args.work, args.kit, output, events, result)
            result["status"] = ("PASS" if result["inventoryRestored"] and result["originalFocusRestored"]
                                and result.get("cleanup", {}).get("errors") == [] and not result["remainingOwned"] else "UNKNOWN")
        except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
            result["reason"] = str(error)[:500]
    up.install.persist(output / "visit.json", result)
    return 0 if result["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
