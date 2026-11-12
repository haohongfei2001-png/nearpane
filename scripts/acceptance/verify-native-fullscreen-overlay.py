#!/usr/bin/env python3
"""Observe the actual Alpha overlay during one explicitly enrolled native fullscreen trial."""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import runpy
import stat
import subprocess as sp
import sys
import tempfile
import time
import uuid

import session_evidence as se

ROOT = Path(__file__).resolve().parents[2]
SESSIONS = ROOT / "build/native-acceptance"
CONTROL_SOURCE = Path(__file__).with_name("fullscreen-controls.swift")
CHECKPOINT = runpy.run_path(str(Path(__file__).with_name("space-checkpoint.py")))
read = CHECKPOINT["load"]
need = se.require
OPEN = "np.fullscreen.open.voice"
CLOSE = "np.fullscreen.close"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish(path, data):
    """Publish complete bytes exactly once, including across competing controllers."""
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as tmp:
        name = Path(tmp.name)
        try:
            tmp.write(json.dumps(data, sort_keys=True).encode() + b"\n")
            tmp.flush()
            os.fsync(tmp.fileno())
            os.link(name, path)
        finally:
            name.unlink(missing_ok=True)


def offline():
    return runpy.run_path(str(Path(__file__).with_name("verify-size-reset.py")))["offline_command"]()


def signed_alpha(app):
    host = app/"Contents/MacOS/NearpaneHost"
    info = plistlib.loads((app/"Contents/Info.plist").read_bytes())
    need(info.get("CFBundleIdentifier") == "com.holdsnow.nearpane.alpha" and
         info.get("NearpaneNativeAcceptanceSchema") == 2 and
         info.get("CFBundleExecutable") == host.name, "expected the isolated-profile capable Alpha")
    sp.run(["codesign","--verify","--strict","--deep",app],check=True,timeout=8)
    need(b"--native-acceptance-secondary-fullscreen" in host.read_bytes(), "freeze an Alpha with the scoped native trial entry")
    return host


def prepare(app):
    signed_alpha(app)
    command = [*offline(), sys.executable, "-B", ROOT / "scripts/native-acceptance.py",
               "prepare", "--empty-draft", "--app", app]
    result = sp.run(command, cwd=ROOT, text=True, capture_output=True, timeout=180)
    need(result.returncode == 0, "empty Alpha fixture preparation failed: " + result.stderr[-500:])
    paths = [Path(line) for line in result.stdout.splitlines() if line.startswith(str(SESSIONS) + "/")]
    need(len(paths) == 1 and paths[0].parent == SESSIONS, "prepared session was not uniquely identified")
    path = paths[0]
    tool = path / "native-fullscreen-controls"
    sp.run(["xcrun", "swiftc", "-module-cache-path", path/"compiler-cache", CONTROL_SOURCE, "-o", tool],
           check=True, timeout=120, cwd=ROOT)
    publish(path/"native-fullscreen-control.json", dict(source=digest(CONTROL_SOURCE), binary=digest(tool)))
    print(path)


def consent_for(folder, run, now):
    need(not (folder/"stopped.json").exists() and not (folder/"completed.json").exists(), "witness trial ended")
    c = read(folder / "unattended-consent.ready")
    need(c["run"] == run and c["permitsSingleWindowFullscreen"] is True and c["permitsFullscreenToolObservation"] is True
         and c["permitsCalibrationAndThreeRoundTrips"] is False and not c["target"], "no matching overlay-only consent")
    start, end = (CHECKPOINT["utc"](c[k]) for k in ("starts", "ends"))
    need(start <= now < end and end-start <= dt.timedelta(minutes=15), "outside the authorized interval")
    return c


def challenge_matches(c, consent, seals, uptime):
    need(c["run"] == consent["run"] and c["boot"] == consent["boot"] and
         c["display"] == consent["secondaryDisplay"] and c["source"] == consent["source"] and
         c["source"] != c["fullscreenCurrent"] and c["fullscreenCurrent"] and c["build"], "mismatched system transition")
    uuid.UUID(c["run"])
    uuid.UUID(c["token"])
    need(all(type(c[k]) is int and c[k] > 0 for k in ("pid", "launch", "number", "revision")), "invalid enrolled identity")
    need(math.isfinite(c["expiresUptime"]) and uptime < c["expiresUptime"] <= uptime + 91, "expired or unbounded challenge")
    need(c["witnessSHA256"] == seals[0] and c["readerSHA256"] == seals[1], "challenge from another frozen kit")


def binds(row, c, host_pid, host_run):
    return (all(row.get(k) == c[k] for k in ("run", "token", "pid", "launch", "number", "display"))
            and row.get("acceptanceRun", "").lower() == host_run and row.get("hostPID") == host_pid)


def surface(row, c, host_pid, host_run):
    need(binds(row, c, host_pid, host_run), "Host receipt cannot be attributed to this run and window")
    need(row.get("frontPID") == c["pid"] and all(row.get(k) is False for k in ("hostKey","hostMain","hostActive")),
         "Host or another window acquired unexpected focus")
    return (row.get("phase") == "native" and row.get("edgeVisible") is False and type(row.get("tool")) is int and row["tool"] > 0
            and type(row.get("revision")) is int and row["revision"] >= c["revision"])


def same_domains(states):
    if not states:
        return False
    first = states[0]
    hashes = (first.get("voiceInstance"), first.get("trayInstance"))
    return (all(isinstance(k, str) and len(k) == 64 and set(k) <= set("0123456789abcdef") for k in hashes)
            and hashes[0] != hashes[1] and all((s.get("voiceInstance"), s.get("trayInstance")) == hashes
            and s.get("recordings") == [] and s.get("trayCount") == 0 for s in states))


def controls_match(details, *, expanded):
    shown, hidden = (CLOSE, OPEN) if expanded else (OPEN, CLOSE)
    ids = details["controls"]
    matches = [r for r in details["details"] if r["id"] == shown]
    return (ids.count(shown) == 1 and hidden not in ids and len(matches) == 1 and matches[0]["role"] == "AXButton"
            and matches[0]["enabled"] is True and "AXPress" in matches[0]["actions"])


def checked_host_events(rows, host_pid, witness_pid):
    need(rows and rows[0].get("kind") == "opened", "missing real Host opening event")
    for event in rows:
        state = event["state"]
        need(state["pid"] == host_pid and state["foreground"] == witness_pid and
             not state["active"] and not state["key"] and
             event["kind"] not in ("panelBecameKey", "appActivated", "drained"), "unexpected Host focus or lifecycle event")
        need(state["voice"] == "paused" and state["recordings"] == [] and state["trayCount"] == 0,
             "isolated voice or tray changed during tool interaction")


def complete(receipt):
    return (receipt["result"] == "observed" and receipt.get("ordinaryPanelReturn") is not None and
            receipt.get("normalHostDrain") is True and receipt.get("postExitDomainUnchanged") is True)


def wait(callback, deadline):
    while time.monotonic() < deadline:
        try:
            hit = callback()
            if hit:
                return hit
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.08)
    raise ValueError("timed out waiting for the native observation")


def frozen(kit, manifest_sha):
    manifest = kit / "SHA256SUMS"
    need(digest(manifest) == manifest_sha, "independently supplied frozen manifest SHA-256 mismatch")
    expected = {name: sha for sha, name in (line.split("  ", 1) for line in manifest.read_text().splitlines())}
    bundle = kit/"NearpaneSpaceWitness.app"
    paths = [bundle/"Contents/MacOS/NearpaneSpaceWitness", bundle/"Contents/Helpers/NearpaneDesktopReader"]
    for path in paths:
        need(path.resolve(strict=True) == path and digest(path) == expected[path.relative_to(kit).as_posix()],
             "unexpected frozen executable")
    sp.run(["codesign","--verify","--strict","--deep",bundle],check=True,timeout=8)
    return paths[0], tuple(expected[path.relative_to(kit).as_posix()] for path in paths)


def observe(args):
    run = str(args.run).upper()
    folder = Path.home()/"Library/Caches"/("Nearpane-P431-" + run)
    st = folder.lstat()
    need(folder.resolve() == folder and stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid()
         and st.st_mode & 0o077 == 0, "expected the witness's private trial directory")
    exe, seals = frozen(args.kit.resolve(strict=True), args.manifest_sha256)
    app = args.app.resolve(strict=True)
    host = signed_alpha(app)
    session = SESSIONS / str(args.session)
    se.verify_manifest(ROOT, session, host, read(session/"manifest.json"))
    tool = session/"native-fullscreen-controls"
    need(read(session/"native-fullscreen-control.json") == dict(source=digest(CONTROL_SOURCE), binary=digest(tool)),
         "unverified or outdated controls")
    need(not list(session.glob("events-*.jsonl")) and not (session/"target-binding.json").exists(), "fresh fixture required")
    before = se.durable(session)
    need(not before["attempts"] and not before["starts"] and not before["assetOrder"] and not before["voiceRecords"],
         "fixture contains earlier work")
    run_host = str(uuid.uuid4())
    claim = dict(run=run, acceptanceRun=run_host, session=session.name)
    consent = consent_for(folder, run, dt.datetime.now(dt.timezone.utc))
    def await_challenge():
        consent_for(folder, run, dt.datetime.now(dt.timezone.utc))
        return read(folder/"fullscreen-tools-challenge.json")
    c = wait(await_challenge, time.monotonic()+120)
    challenge_matches(c, consent, seals, time.monotonic())
    need(se.process_path(c["pid"]).resolve() == exe, "unexpected witness process")
    cfg_path = session/"support/Nearpane/host-configuration.json"
    need(cfg_path.resolve(strict=True) == cfg_path, "unexpected configuration path")
    cfg = read(cfg_path)
    need(cfg.get("preferredDisplayID") == c["display"] and not cfg.get("displays"), "unexpected initial display settings")
    need(sp.run(["pgrep","-x","NearpaneHost"],stdout=sp.DEVNULL).returncode == 1,"another Host is running")
    env = {k:v for k,v in os.environ.items() if not k.startswith("NEARPANE_")}
    env.update(NEARPANE_ACCEPTANCE_RUN=run_host, NEARPANE_SPACE_WITNESS_RUN=run,
               NEARPANE_SPACE_WITNESS_SHA256=seals[0], NEARPANE_SPACE_READER_SHA256=seals[1],
               NEARPANE_SPACE_WITNESS_EXECUTABLE=str(exe))
    offline_command = offline()
    helper_target = [c[k] for k in ("pid","launch","number","run","display","expiresUptime")]
    host_file = session/("fullscreen-tools-host-" + run_host + ".json")
    events = session/("events-" + run_host + ".jsonl")
    deadline = min(time.monotonic()+70,c["expiresUptime"]-2)
    receipt = dict(**claim, token=c["token"], states=[], actions=[], domainBefore=before, result="inconclusive")
    consent_for(folder,run,dt.datetime.now(dt.timezone.utc))
    need(time.monotonic() < deadline, "challenge expired during validation")
    publish(folder/"fullscreen-tools-controller.json", claim)
    publish(session/"native-fullscreen-controller.json", claim)
    cfg["displays"] = {c["display"]: {"fullscreenTools":{"enabled":True,"voice":True,"capture":False,"corner":"topRight"}}}
    cfg_path.write_text(json.dumps(cfg))

    with (session/("overlay-" + run_host + ".log")).open("xb") as log:
        child = sp.Popen([*offline_command, host, "--native-acceptance-secondary-fullscreen", session.name],
                         cwd=ROOT,env=env,stdout=log,stderr=log)
        try:
            def active():
                consent_for(folder,run,dt.datetime.now(dt.timezone.utc))
                need(child.poll() is None and time.monotonic() < deadline and read(folder/"fullscreen-tools-challenge.json") == c,
                     "Host, time window or challenge changed")
            def inspect(expanded):
                active()
                row = read(host_file)
                if not row.get("token") or not surface(row, c, child.pid, run_host):
                    return None
                cmd = [*offline_command, tool, child.pid, row["tool"], host, "read", *helper_target]
                info = json.loads(sp.check_output(list(map(str,cmd)),cwd=ROOT,timeout=3))
                need(info["frontPID"] == c["pid"], "foreground changed")
                if not controls_match(info,expanded=expanded):
                    return None
                return dict(host=row, controls=info["controls"], uptime=time.monotonic())
            for phase, expanded, command in [("strip",False,OPEN),("voice",True,CLOSE),("closed",False,None)]:
                state = wait(lambda: inspect(expanded), deadline)
                receipt["states"].append(dict(phase=phase, **state))
                if command:
                    active()
                    row = read(host_file)
                    need(surface(row, c, child.pid, run_host) and row["tool"] == state["host"]["tool"], "tool replaced")
                    receipt["actions"].append(dict(control=command, before=time.monotonic()))
                    publish(session/("ax-intent-"+phase+".json"),dict(**claim,token=c["token"],window=row["tool"],control=command))
                    cmd = [*offline_command, tool, child.pid, row["tool"], host, command, *helper_target]
                    sp.run(list(map(str,cmd)),cwd=ROOT,check=True,timeout=3)
                    receipt["actions"][-1]["apiReturned"] = True
            need(same_domains([x["host"] for x in receipt["states"]]), "domain instance or recording/queue state changed")
            history = se.events(events)
            checked_host_events(history, child.pid, c["pid"])
            receipt["hostEventsThroughClose"] = len(history)
            receipt["domainAfterClose"] = se.durable(session)
            need(receipt["domainAfterClose"] == before, "domain contents or dispatch counters changed")
            receipt["result"] = "observed"
        except (OSError, KeyError, ValueError, sp.SubprocessError) as error:
            receipt["error"] = str(error)
        finally:
            try:
                receipt["hostPID"] = child.pid
                evidence = folder/"fullscreen-tools-receipt.json"
                publish(evidence, receipt)
                response = {k:c[k] for k in ("run","token","pid","launch","number","display")}
                publish(folder/"fullscreen-tools-response.json",
                        dict(**response,hostPID=child.pid,receiptSHA256=digest(evidence),result=receipt["result"]))
                def ordinary():
                    row = read(host_file)
                    return row if (binds(row,c,child.pid,run_host) and row.get("phase")=="ordinaryReturned" and
                                   row.get("edgeVisible") is True and row.get("tool")==0 and
                                   all(row.get(k) is False for k in ("hostKey","hostMain","hostActive"))) else None
                try:
                    until = CHECKPOINT["utc"](consent["ends"])
                    remaining = (until - dt.datetime.now(dt.timezone.utc)).total_seconds()
                    authorized_end = time.monotonic() + max(0, remaining)
                    def returned():
                        marker = read(folder/"fullscreen-exit-confirmed.json")
                        need(marker["run"] == run and marker["source"] == c["source"] == marker["returned"] and
                             int(marker["revision"]) > c["revision"], "system return belongs to another transition")
                        return marker
                    receipt["systemReturn"] = wait(returned, min(authorized_end, time.monotonic()+15))
                    publication = wait(ordinary, min(authorized_end, time.monotonic()+2))
                except (ValueError,OSError):
                    publication = None
                if publication and (publication["frontPID"] != c["pid"] or not receipt["states"] or
                                    not same_domains([receipt["states"][0]["host"], publication])):
                    publication = None
                    receipt["ordinaryPanelError"] = "focus or domain continuity could not be confirmed"
                receipt["ordinaryPanelReturn"] = publication
            finally:
                (session/("finish-"+run_host)).touch(exist_ok=False)
                try:
                    child.wait(timeout=6)
                except sp.TimeoutExpired:
                    child.terminate()
                    try:
                        child.wait(timeout=3)
                    except sp.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=3)
                receipt["hostExit"] = child.returncode
                history = se.events(events)
                receipt["normalHostDrain"] = bool(child.returncode == 0 and history and history[-1]["kind"] == "drained"
                                                  and history[-1]["state"]["pid"] == child.pid)
                receipt["postExitDomainUnchanged"] = se.durable(session) == before
                receipt["complete"] = complete(receipt)
                publish(session/("overlay-result-"+run_host+".json"), receipt)
    print(session/("overlay-result-"+run_host+".json"))
    need(receipt["complete"], f"overlay={receipt['result']}, ordinary panel return={bool(receipt.get('ordinaryPanelReturn'))}, "
         f"Host drained={receipt['normalHostDrain']}, domain unchanged={receipt['postExitDomainUnchanged']}")


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest="action",required=True)
    prep=sub.add_parser("prepare",help="prepare an empty session and compile the controls without opening windows")
    trial=sub.add_parser("observe",help="wait for a permitted real fullscreen checkpoint before launching the secondary Host")
    for item in (prep,trial):
        item.add_argument("--app",type=Path,required=True)
    trial.add_argument("--session",type=uuid.UUID,required=True)
    trial.add_argument("--run",type=uuid.UUID,required=True)
    trial.add_argument("--kit",type=Path,required=True)
    trial.add_argument("--manifest-sha256",required=True,help="independent freeze receipt hash of SHA256SUMS")
    args=parser.parse_args()
    try:
        prepare(args.app.resolve(strict=True)) if args.action == "prepare" else observe(args)
    except (OSError,KeyError,ValueError,sp.SubprocessError) as error:
        sys.exit(str(error))
