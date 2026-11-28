#!/usr/bin/env python3
"""Exercise the real Settings buttons in a fresh secondary-only Alpha session, with management off."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import time
import uuid

import session_evidence as se

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/verification/product-closeout/settings"
SESSIONS = ROOT / "build/native-acceptance"
CLOCK = "com.holdsnow.nearpane.clock-sample"


def read(path):
    return json.loads(path.read_bytes())


def put(path, value):
    stage = path.with_suffix(".pending")
    stage.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    os.replace(stage, path)


def compile_tools():
    OUT.mkdir(parents=True, mode=0o700, exist_ok=True)
    for name in ("admission-controls", "fullscreen-controls"):
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", OUT / "compiler-cache",
                        ROOT / f"scripts/acceptance/{name}.swift", "-o", OUT / name], check=True)


def offline_command():
    runner = runpy.run_path(str(ROOT / "scripts/acceptance/verify-product-capture.py"))["offline_command"](ROOT)
    idx = runner.index("-p")
    runner[idx:idx] = ["-D", "ALPHA=" + str(Path.home() / "Library/Application Support/Nearpane Alpha Profiles")]
    runner[runner.index("-p")+1] += '(deny file-read* file-write* (subpath (param "ALPHA")))'
    return runner


def prepare(app):
    # The existing schema-2 prepare entry writes only a uniquely marked synthetic
    # session and exits before constructing the AppKit application.
    proc = subprocess.run([*offline_command(), sys.executable, "-B", ROOT/"scripts/native-acceptance.py", "prepare",
                           "--app", app], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=ROOT, timeout=120)
    paths = [Path(line) for line in proc.stdout.splitlines() if line.startswith(str(SESSIONS) + "/")]
    log = OUT/("prepare-" + str(uuid.uuid4()) + ".log")
    log.write_text(proc.stdout)
    se.require(proc.returncode == 0 and len(paths) == 1, "Session prepare failed; see " + str(log))
    return str(uuid.UUID(paths[0].name))


def await_value(callback, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            result = callback()
            if result:
                return result
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.1)
    raise ValueError(f"Checkpoint timed out at line {callback.__code__.co_firstlineno}")


def verify(app, sid):
    binary = app / "Contents/MacOS/NearpaneHost"
    folder = SESSIONS / str(uuid.UUID(sid))
    se.verify_manifest(ROOT, folder, binary, read(folder / "manifest.json"))
    se.require(not list(folder.glob("startup-*.json")) and not (folder / "target-binding.json").exists(), "Fresh unbound session required")
    se.require(subprocess.run(["pgrep", "-x", "NearpaneHost"], stdout=subprocess.DEVNULL).returncode == 1, "Another Host is running")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
    out = OUT / sid
    out.mkdir(mode=0o700)
    offline = offline_command()

    def run(*args):
        return subprocess.check_output([*offline, *map(str, args)], text=True, timeout=12).strip()

    def preflight():
        return run(OUT / "fullscreen-controls", "preflight-displays").splitlines()

    main, front, side = preflight()
    cfg = folder / "support/Nearpane/host-configuration.json"
    prefs = read(cfg)
    se.require(prefs["preferredDisplayID"] == side != main and not prefs["displays"], "Fresh secondary display profile required")
    seeded = {"placement": "docked", "policy": "onDemand", "anchor": "top", "spacesDismissed": False}
    def pt(value):
        return {"unit":"pt", "value":value}
    # Only generated fixture settings are modified. The distinct main setting is a sentinel.
    prefs["displays"] = {
        side: {**seeded, "measures": ["modulePadding", pt(17), "reservedWidth", pt(119), "panelWidth", pt(173), "rowGap", pt(5)]},
        main: {**seeded, "placement": "floating", "measures": ["panelWidth", pt(204)]},
    }
    prefs["modules"] = [m for m in prefs["modules"] if m["id"] != CLOCK]
    prefs["modules"].append({"id": CLOCK, "enabled": True, "pinned": True})
    put(cfg, prefs)
    initial = se.durable(folder)
    se.require(not initial["attempts"] and not initial["starts"], "External inputs exist in fixture")
    sequence = 0
    epoch = pid = None
    receipt = {"session":sid, "sha256":hashlib.sha256(binary.read_bytes()).hexdigest(), "checks":{}}
    checks = receipt["checks"]
    work = folder / "support/WorkRect"

    def measures(display):
        values = read(cfg)["displays"][display].get("measures", [])
        return dict(zip(values[::2], values[1::2]))

    def check_work():
        se.require(not list(work.rglob("attempt-*.json")) and not list(work.rglob("journal.json")),
                   "Unexpected window action or journal in fresh unmanaged fixture")
        state = work / "status.json"
        if state.exists():
            sample = read(state)
            se.require(sample.get("mode") == "off" and sample.get("members") == 0, "Management changed from off")
        se.require(measures(main) == {"panelWidth":pt(204)}, "Main display settings changed")

    def controls(window, action="read"):
        se.require(se.process_path(pid) == binary, "Host executable changed")
        if action != "read":
            before = json.loads(run(OUT / "admission-controls", pid, window, binary, "read", "--sizes-secondary"))
            se.require(str(before["frontPID"]) == front, "Foreground changed before Settings action")
            if action.startswith("sizes-reset-"):
                candidates = [n for n in before["nodes"] if n["id"] == action]
                se.require(len(candidates) == 1 and candidates[0]["enabled"], "Missing or disabled Settings control " + action)
                if not candidates[0]["contained"]:
                    run(OUT / "admission-controls", pid, window, binary, "scroll-settings-end", "--sizes-secondary")
        result = run(OUT / "admission-controls", pid, window, binary, action, "--sizes-secondary")
        if action == "read":
            value = json.loads(result)
            se.require(str(value["frontPID"]) == front, "Foreground changed")
            return value

    def observed(window, control):
        value = controls(window)
        return value if any(n["id"] == control and n["enabled"] for n in value["nodes"]) else None

    def capture(name, window):
        run(folder / "capture-panel", pid, window, binary, out / (name + ".png"), "--secondary-only")

    def command(name):
        nonlocal sequence
        sequence += 1
        put(folder / "management-request.json", {"run":epoch, "sequence":sequence, "action":name})

    proc = None
    try:
        with (out / "launch.log").open("w") as log:
            proc = subprocess.Popen([*offline, sys.executable, "-B", ROOT/"scripts/native-acceptance.py", "launch",
                                     "--session", sid, "--app", app, "--secondary-only"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                    env=dict(os.environ, NEARPANE_MANAGEMENT_ACCEPTANCE=sid, NEARPANE_SIZE_ACCEPTANCE=sid,
                                             NEARPANE_MODULE_SIZE_ACCEPTANCE=sid), start_new_session=True)
        def startup():
            se.require(proc.poll() is None, "Fixture stopped during admission")
            files = list(folder.glob("startup-*.json"))
            return read(files[0]) if len(files) == 1 else None
        stamp = await_value(startup, 15)
        pid = stamp["pid"]
        epoch = str(uuid.UUID(stamp["run"].removeprefix("events-")))
        panel = await_value(lambda: read(folder / ("management-panel-" + epoch + ".json")))
        events = folder / (stamp["run"] + ".jsonl")
        edge = await_value(lambda: next((e["state"]["windowID"] for e in reversed(se.events(events))
                                         if e["state"]["visible"] and e["state"]["windowID"]), None))
        check_work()
        original = measures(side)
        initial_view = controls(panel)
        put(out/"settings-start.json", initial_view)
        # The two workflows below click exclusive, uniquely identified native AX controls.
        controls(panel, "sizes-reset-group")
        preview = await_value(lambda: observed(panel, "sizes-reset-cancel"))
        se.require(measures(side) == original, "Preview wrote configuration")
        checks["groupPreview"] = True
        capture("group-preview", panel)
        controls(panel, "sizes-reset-cancel")
        await_value(lambda: all(n["id"] != "sizes-reset-cancel" for n in controls(panel)["nodes"]))
        check_work()
        se.require(measures(side) == original, "Cancel wrote configuration")
        checks["groupCancel"] = True
        controls(panel, "sizes-reset-group")
        await_value(lambda: observed(panel, "sizes-reset-apply"))
        controls(panel, "sizes-reset-apply")
        await_value(lambda: measures(side) == {k:v for k,v in original.items() if k != "modulePadding"})
        check_work()
        checks["groupApply"] = measures(side)
        controls(panel, "sizes-reset-display")
        await_value(lambda: observed(panel, "sizes-reset-cancel"))
        controls(panel, "sizes-reset-cancel")
        se.require(measures(side)["reservedWidth"] == pt(119), "Cancelled all reset changed WorkRect")
        controls(panel, "sizes-reset-display")
        await_value(lambda: observed(panel, "sizes-reset-apply"))
        controls(panel, "sizes-reset-apply")
        await_value(lambda: not measures(side))
        check_work()
        checks["displayApply"] = True
        put(out/"settings-final.json", controls(panel))
        capture("settings-final", panel)
        await_value(lambda: observed(edge, CLOCK))
        capture("clock-compact", edge)
        controls(edge, CLOCK)
        clock = await_value(lambda: observed(edge, "nearpane-module-close"))
        se.require(any(n["id"] == "clock-local-time" for n in clock["nodes"]), "No real local time readout")
        put(out/"clock-expanded.json", clock)
        capture("clock-expanded", edge)
        controls(edge, "nearpane-module-close")
        checks["clockOpenedAndClosed"] = True
    except Exception as exc:
        receipt["error"] = str(exc)
        raise
    finally:
        if proc is not None and proc.poll() is None:
            if epoch:
                command("quit")
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(timeout=8)
        receipt["exitCode"] = proc.returncode if proc else None
        receipt["foregroundRestored"] = preflight() == [main, front, side]
        receipt["dataUnchanged"] = se.durable(folder) == initial
        receipt["windowWrites"] = len(list(work.rglob("attempt-*.json")))
        put(out/"result.json", receipt)
    se.require(proc.returncode == 0 and receipt["dataUnchanged"] and receipt["foregroundRestored"] and
               receipt["windowWrites"] == 0, "Cleanup or domain invariant failed")
    print(out/"result.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path)
    parser.add_argument("--session")
    parser.add_argument("--new-session", action="store_true")
    parser.add_argument("--compile-only", action="store_true")
    args = parser.parse_args()
    if args.compile_only:
        compile_tools()
    elif args.app and (bool(args.session) != args.new_session):
        app = args.app.resolve(strict=True)
        verify(app, args.session or prepare(app))
    else:
        parser.error("Choose --compile-only or provide a frozen --app and fresh --session")
