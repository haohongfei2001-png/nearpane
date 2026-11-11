#!/usr/bin/env python3
"""Exercise real secondary panels with a synthetic loss/return of the preferred display."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess as sp
import sys
import time
import uuid

import session_evidence as se

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return json.loads(path.read_bytes())


def wait_for(sample, timeout=8):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = sample()
        if value:
            return value
        time.sleep(.08)
    raise ValueError(f"Checkpoint did not settle at line {sample.__code__.co_firstlineno}")


def verify(app, sid):
    folder = ROOT / "build/native-acceptance" / str(uuid.UUID(sid))
    binary = app / "Contents/MacOS/NearpaneHost"
    se.require(app.name == "Nearpane P5.2 Alpha.app" and folder.resolve() == folder, "Expected P5.2 marked checkout")
    se.verify_manifest(ROOT, folder, binary, read(folder / "manifest.json"))
    se.require(not list(folder.glob("startup-*.json")) and not (folder / "target-binding.json").exists(), "Fresh unbound session required")
    se.require(sp.run(["pgrep", "-x", "NearpaneHost"], stdout=sp.DEVNULL).returncode == 1, "Active Host or unavailable process list")
    sp.run(["codesign", "--verify", "--strict", "--deep", app], check=True)
    out = ROOT / "build/verification/p52" / sid
    out.mkdir(parents=True, mode=0o700)
    controls = out / "fullscreen-controls"
    sp.run(["xcrun", "swiftc", "-module-cache-path", str(out.parent / "module-cache"),
            ROOT / "scripts/acceptance/fullscreen-controls.swift", "-o", controls], check=True)
    offline = runpy.run_path(str(ROOT / "scripts/acceptance/verify-product-capture.py"))["offline_command"](ROOT)

    def control(*arguments):
        return sp.check_output([*offline, controls, *map(str, arguments)], text=True, timeout=9).strip()

    main, initial_front, side = control("preflight-displays").splitlines()
    config = folder / "support/Nearpane/host-configuration.json"
    prefs = read(config)
    se.require(side != main and prefs["preferredDisplayID"] == side and not prefs["displays"], "Unexpected display profile")
    prefs.update(preferredDisplayID=main, displays={side: {"placement":"floating", "policy":"pinned",
                 "floatingPosition":{"x":16,"y":32}, "fullscreenTools":{"enabled":True,"corner":"topRight","voice":True,"capture":True}}})
    config.write_text(json.dumps(prefs))
    baseline = se.durable(folder)
    se.require(len(baseline["assetOrder"]) == 5 and baseline["voiceRecords"] == 1 and baseline["attempts"] == 0,
               "Prepare with the isolated five images and edited note")
    env = dict(os.environ, NEARPANE_FULLSCREEN_ACCEPTANCE=sid, NEARPANE_TOPOLOGY_ACCEPTANCE=sid)
    runs = []
    observations = []
    with (out / "launch.log").open("w") as log:
        proc = sp.Popen([*offline, sys.executable, "-B", str(ROOT / "scripts/native-acceptance.py"), "launch",
                         "--session", sid, "--app", app, "--secondary-only", "--desktop-fixture"],
                        env=env, cwd=ROOT, stdout=log, stderr=sp.STDOUT)
    run = None
    try:
        def live():
            if run:
                failure = folder / f"fixture-stop-{run}.json"
                if failure.exists():
                    raise ValueError("Fixture stopped: " + json.dumps(read(failure), sort_keys=True))
            se.require(proc.poll() is None, "Secondary test exited; check focus and physical screen availability")

        def startup():
            live()
            files = list(folder.glob("startup-*.json"))
            return read(files[0]) if len(files) == 1 else None
        stamp = wait_for(startup, 15)
        pid = stamp["pid"]
        run = str(uuid.UUID(stamp["run"].removeprefix("events-")))
        se.require(se.process_path(pid) == binary, "Wrong Host executable")
        evidence = folder / f"fullscreen-{run}.json"
        topology = native = 0

        def checkpoint(label, role, edge, tool=False, expanded=False):
            last_edge = None
            def sample():
                nonlocal last_edge
                live()
                if not evidence.exists():
                    return None
                row = read(evidence)
                if not (row.get("topologyStep") == topology and row["step"] == native and row["role"] in role
                        and bool(row["edgeWindow"]) == edge and bool(row["tool"]) == tool):
                    return None
                if tool and (row["frame"][2] > 100) != expanded:
                    return None
                if edge:
                    probe = json.loads(control(pid, row["edgeWindow"], binary, "read-edge-frame"))
                    observations.append(dict(checkpoint=label, owner=row["edgeOwnerQuartzFrame"], probe=probe))
                    se.require(probe["front"] == int(initial_front), "Foreground changed while reading edge")
                    if (probe.get("ax", probe["cg"]) != probe["cg"] or probe["cg"] != row["edgeCGFrame"]
                            or probe["cg"] != row["edgeOwnerQuartzFrame"]):
                        last_edge = None
                        return None
                    if not last_edge or (probe["wid"], probe["cg"]) != (last_edge["wid"], last_edge["cg"]):
                        last_edge = probe
                        return None
                    if probe["uptime"] - last_edge["uptime"] < .25:
                        return None
                    row["externalEdgeSamples"] = [last_edge, probe]
                return row
            row = wait_for(sample)
            se.require(row["display"] == side and row["pid"] == pid and not any(row[k] for k in ("key","main","active")),
                       "Window or foreground evidence changed")
            se.require(int(initial_front) == row["frontPID"], "Foreground changed")
            se.require(se.durable(folder) == baseline, "Voice, queue or attempt state changed")
            runs.append(dict(row, checkpoint=label))
            return row

        def change(action):
            nonlocal topology, native
            if action in ("native","ordinary"):
                native += 1
                name = f"fullscreen-step-{run}-{native}"
            else:
                topology += 1
                name = f"topology-{run}-{topology}"
            pending = folder / (name + ".pending")
            with pending.open("x") as stream:
                stream.write(action)
            os.link(pending, folder / name)
            pending.unlink()

        solo = {"compact", "full"}
        first = checkpoint("secondary Space-only", {"spacesOnly"}, True)
        change("disconnect")
        promoted = checkpoint("fallback residence", solo, True)
        se.require(first["edgeWindow"] != promoted["edgeWindow"], "Supplemental window exposed as a domain owner")
        change("native")
        strip = checkpoint("fullscreen strip", {"hidden"}, False, tool=True)
        command = "np.fullscreen.open.voice"
        se.require(command in json.loads(control(pid, strip["tool"], binary, "read"))["controls"], "Missing explicit tool")
        control(pid, strip["tool"], binary, command)
        checkpoint("user-opened voice tool", {"hidden"}, False, tool=True, expanded=True)
        change("reconnect")
        checkpoint("preferred display returned while tool was open", {"hidden"}, False)
        change("ordinary")
        rejoined = checkpoint("Space-only restored", {"spacesOnly"}, True)
        se.require(first["edgeCGFrame"] == rejoined["edgeCGFrame"], "Floating configuration changed")
        change("disconnect")
        again = checkpoint("same residence controller reused", solo, True)
        se.require(again["edgeWindow"] == promoted["edgeWindow"], "Residence window replaced")
        change("hide")
        checkpoint("explicitly hidden", {"hidden"}, False)
        change("show")
        shown = checkpoint("shown", solo, True)
        se.require(shown["edgeCGFrame"] == promoted["edgeCGFrame"], "Frame changed across hide/show")
        change("reconnect")
        last = checkpoint("original role and frame", {"spacesOnly"}, True)
        se.require(last["edgeCGFrame"] == first["edgeCGFrame"], "Final secondary frame changed")
    except Exception as error:
        (out / "failure.json").write_text(json.dumps(dict(error=str(error), lastAccepted=runs[-1] if runs else None)))
        raise
    finally:
        (out / "checkpoints.json").write_text(json.dumps(runs, indent=2))
        (out / "edge-observations.json").write_text(json.dumps(observations, indent=2))
        if run and proc.poll() is None:
            (folder / f"fullscreen-finish-{run}").touch()
        se.require(proc.wait(timeout=75) == 0, "Host failed to drain")
    receipt = read(folder / f"process-{run}.json")
    se.require(receipt["exitCode"] == 0 and receipt["prelaunch"] == receipt["postExit"] == baseline, "Persistent state changed at exit")
    saved = read(config)
    se.require(saved["preferredDisplayID"] == main and saved["displays"][side]["placement"] == "floating"
               and not saved["surfaceHidden"], "User configuration changed")
    result = dict(session=sid, hostSHA256=hashlib.sha256(binary.read_bytes()).hexdigest(), pid=pid,
                  physicalTopologyChanged=False, nativeSpaceActions=0, checkpoints=runs, exitCode=receipt["exitCode"],
                  initial=baseline, final=receipt["postExit"])
    (out / "summary.json").write_text(json.dumps(result, indent=2))
    print(out / "summary.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session")
    parser.add_argument("--app", type=Path, default=Path.home()/"Applications/Nearpane P5.2/Nearpane P5.2 Alpha.app")
    args = parser.parse_args()
    verify(args.app.resolve(strict=True), args.session)
