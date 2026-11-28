#!/usr/bin/env python3
"""Drive the signed P4.2 fixture and external AX controller on the isolated secondary display."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
APPS = Path.home() / "Library/Caches/org.nearpane.window-lab/P4.2"


class NotVerified(Exception):
    pass


def need(value, message):
    if not value:
        raise NotVerified(message)


def read(path):
    return json.loads(path.read_bytes())


def save(path, value):
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as tmp:
        json.dump(value, tmp, sort_keys=True)
        tmp.flush()
        os.fsync(tmp.fileno())
    os.replace(tmp.name, path)


def until(f, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = f()
        if result:
            return result
        time.sleep(.04)
    raise NotVerified("timed out waiting for the fixture checkpoint")


def frames(rows):
    return {r["member"]["index"]: r["cg"] for r in rows}


class Trial:
    def __init__(self, out, apps=APPS):
        self.dir = Path(tempfile.mkdtemp(prefix="device-", dir=out))
        self.owner = None
        self.sequence = self.count = self.enrollments = self.generation = 0
        self.events = []
        self.phase = "preflight"
        self.executables = {}
        for name in ("NearpaneFrameController", "NearpaneFixtureWindows"):
            app = apps / (name + ".app")
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
            path = app / "Contents/MacOS" / name
            self.executables[name] = path
        self.controller = self.executables["NearpaneFrameController"]
        save(self.dir / "executables.json", {n: hashlib.sha256(p.read_bytes()).hexdigest() for n, p in self.executables.items()})

    def event(self, name, **data):
        item = dict(name=name, monotonic=time.monotonic(), **data)
        self.events.append(item)
        with (self.dir / "events.jsonl").open("a") as f:
            f.write(json.dumps(item, sort_keys=True) + "\n")
            f.flush()
            os.fsync(f.fileno())

    def command(self, name, *, refuse=None):
        if getattr(self, "passive_source", False):
            need(name in ("preflight", "observe", "confirm-exit"), "passive source command refused")
        self.count += 1
        stem = self.dir / f"{self.count:03d}-{name}"
        tries = len(list(self.dir.glob("attempt-*.json")))
        args = [self.controller, name] + ([] if name == "preflight" else [self.dir])
        bracket = getattr(self, "study_focus", False) and self.owner and self.owner.poll() is None
        def checkpoint():
            trace = self.dir / f"focus-{self.owner.pid}.jsonl"
            def latest():
                if self.owner.poll() is not None:
                    raise NotVerified("focus observer exited")
                rows = trace.read_bytes().splitlines() if trace.exists() else []
                if rows and rows[-1].endswith(b"}"):
                    r = json.loads(rows[-1])
                    if r["uptime"] > mark and r["event"] == "sample":
                        need(r["sameAXFocusedWindow"] and not r["active"] and not any(w["key"] or w["main"] for w in r["windows"]), "unsafe focus")
                        return r["uptime"]
            mark = read(self.dir / "owner.json")["uptime"]
            return until(latest, 2)
        if bracket:
            self.event("before", command=name, focus=checkpoint())
        result = subprocess.run(args, capture_output=True, timeout=30)
        stem.with_suffix(".stdout").write_bytes(result.stdout)
        stem.with_suffix(".stderr").write_bytes(result.stderr)
        attempts = len(list(self.dir.glob("attempt-*.json"))) - tries
        detail = result.stderr.decode("utf-8", "replace").strip()
        self.event(name, rc=result.returncode, attempts=attempts, phase=self.phase, detail=detail)
        if bracket and self.owner.poll() is None:
            self.event("after", command=name, focus=checkpoint())
        if refuse:
            need(result.returncode != 0 and refuse in detail and attempts == 0, f"{name} refusal not proven: {detail}")
            return
        need(result.returncode == 0, f"{name}: {detail}")
        return json.loads(result.stdout)

    def membership(self, action, index):
        if getattr(self, "passive_source", False):
            need(action in ("create", "gate-read", "close") and index == 1, "unexpected passive fixture command")
        self.sequence += 1
        save(self.dir / "command.json", dict(sequence=self.sequence, action=action, index=index))

        def acknowledged():
            need(self.owner.poll() is None, "fixture exited; see fixture stderr")
            p = self.dir / "owner.json"
            if p.exists():
                state = read(p)
                if state["command"] == self.sequence and state["owner"]["pid"] == self.owner.pid:
                    need(not state["keyOrMain"] and state["activations"] == 0, "fixture focus guard")
                    return state
        ticket = until(acknowledged, 5)
        save(self.dir / "ticket.json", ticket)
        self.enrollments += 1
        save(self.dir / f"enroll-{self.enrollments:02d}.json", ticket)
        return ticket

    def start_owner(self):
        self.generation += 1
        self.sequence = 0
        (self.dir / "command.json").unlink(missing_ok=True)
        with (self.dir / f"owner-{self.generation}.stderr").open("wb") as err:
            self.owner = subprocess.Popen([self.executables["NearpaneFixtureWindows"], self.dir],
                                         stdout=subprocess.DEVNULL, stderr=err)

    def stop_owner(self):
        child = self.owner
        self.sequence += 1
        save(self.dir / "command.json", dict(sequence=self.sequence, action="quit", index=0))
        try:
            code = child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.terminate()
            code = child.wait(timeout=5)
        self.event("owned-fixture-exit", rc=code)
        self.owner = None
        need(code == 0, "fixture did not exit normally")
        self.event("CG-cleanup", **self.command("confirm-exit"))

    def observe_source(self, session, display, source):
        """Witness a single nonactivating fixture using the two installed, signed lab helpers."""
        ticket = self.membership("create", 1)
        member, = ticket["members"]
        owner_frame, = ticket["frames"]
        snapshots = []
        for _ in range(2):
            row, = self.command("observe")
            need(row["member"] == member and row["onScreen"] and row["cg"] == row["ax"] == owner_frame,
                 "the enrolled window's AX and CG frames do not match its owner's frame")
            self.membership("gate-read", 1)
            sample = read(self.dir / f"native-gate-{self.sequence}.json")
            verify_source_sample(sample, session, self.sequence, display, source, member["id"], owner_frame)
            snapshots.append(sample)
        first, second = snapshots
        need(first["scopes"] == second["scopes"] and first["topologyFingerprint"] == second["topologyFingerprint"]
             and first["sourceBuild"] == second["sourceBuild"] and first["native"]["endedUptime"] < second["native"]["beganUptime"],
             "unstable independent source observations")
        state = self.membership("close", 1)
        need(not state["members"], "owned window did not close")
        def closed_focus():
            trace = self.dir / f"focus-{self.owner.pid}.jsonl"
            for line in reversed(trace.read_bytes().splitlines()):
                if not line.endswith(b"}"):
                    continue
                event = json.loads(line)
                if event["event"] == "sample" and event["uptime"] > state["uptime"]:
                    need(event["sameAXFocusedWindow"] and not event["active"] and not event["windows"],
                         "original focus missing after close")
                    return event
        focused = until(closed_focus, 2)
        self.event("passive-source", display=display, record=source, member=member["id"], frame=owner_frame,
                   revisions=[s["revision"] for s in snapshots], sameAXFocus=focused["sameAXFocusedWindow"],
                   frontPID=focused["frontPID"])

    def exercise(self, suite, read_gate, source=None, display=None):
        self.passive_source = suite == "passive-source"
        pre = self.command("preflight")
        need(pre["controllerID"] == "org.nearpane.lab.NearpaneFrameController" and pre["parent"]["pid"] == os.getpid(), "control subject")
        run = dict(session=str(uuid.uuid4()), parent=pre["parent"], deadline=pre["uptime"] + 480, screens=pre["screens"])
        self.study_focus = suite == "focus-study" or self.passive_source
        if suite == "focus-study":
            need(pre.get("visibilityProtocolVersion") == 1 and pre.get("virtualSwitchAvailable") is False, "expected focus-only capability")
        if suite == "including-parking":
            need(pre.get("virtualSwitchAvailable") is True, "no device-verified Virtual parking mechanism")
        run["parkingStudy"] = self.study_focus
        if self.passive_source:
            need(pre["trusted"] and pre["screens"]["separateSpaces"] and pre["screens"]["secondary"] == display and source,
                 "missing AX permission or the specified independent secondary display")
            run["deadline"] = pre["uptime"] + 35
        save(self.dir / "run.json", run)
        self.start_owner()
        self.phase = "enroll"
        if self.passive_source:
            self.observe_source(run["session"], display, source)
            return
        self.membership("create", 1)
        self.command("inspect")
        if not pre["trusted"]:
            self.membership("create", 2)
            self.command("inspect")
            raise NotVerified("USER ACTION REQUIRED: Accessibility unavailable to the signed controller")
        if suite == "controls":
            ticket_path = self.dir / "ticket.json"
            original, stale = read(ticket_path), read(ticket_path)
            stale["frames"][0]["x"] -= 1
            save(ticket_path, stale)
            try:
                self.command("canary", refuse="new fixture changed since enrollment")
            finally:
                save(ticket_path, original)
        self.phase = "single-canary"
        initial = frames(self.command("observe"))
        moved = self.command("canary")
        need(moved["setters"] == 1 and frames(moved["observations"]) != initial, "single external move not proven")
        restored = self.command("recover")
        need(restored["setters"] == 1 and frames(restored["observations"]) == initial, "canary not restored")
        need(self.command("recover")["setters"] == 0, "duplicate recovery write")
        self.event("single-canary-restored")
        if read_gate:
            for _ in range(2):
                self.membership("gate-read", 1)
                sample = read(self.dir / f"native-gate-{self.sequence}.json")
                need(sample["freshness"] == "fresh" and sample["native"]["population"] == "markedFixture"
                     and sample["native"]["spaces"] == "observed" and not sample["capabilities"]["spaceSwitching"],
                     "read-only gate sample incomplete")
                self.event("native-source-observation", confirmedRows=len(sample["native"]["rows"]))
        if suite == "focus-study":
            self.phase = "focus-crash"
            self.crash(initial, onscreen=True)
            self.command("refuse-minimum", refuse="minimum size")
            self.panel()
            self.command("mini-read")
            return
        if suite == "canary":
            return
        if suite in ("controls", "panel", "refusals"):
            if suite == "controls":
                self.controls()
            if suite in ("controls", "panel"):
                self.panel()
            if suite in ("controls", "refusals"):
                self.refusals()
            return
        self.phase = "workrect"
        docked = self.command("docked")
        self.command("presentation")
        floating = self.command("floating")
        reserved = self.command("reserve")
        need(docked["workRect"] != floating["workRect"] and floating["workRect"] == pre["screens"]["usable"]
             and docked["workRect"] != reserved["workRect"], "persistent reservation did not change")
        self.command("docked")
        self.command("refuse-minimum", refuse="minimum size")
        self.membership("create", 2)
        pair = self.command("docked")
        custom = self.command("custom-pair")
        need(frames(pair["observations"]) != frames(custom["observations"]), "manual pair ratio and slots not changed")
        self.membership("create", 3)
        three = self.command("docked")
        a, b, c = [frames(three["observations"])[i] for i in (1, 2, 3)]
        need(c["x"] < a["x"] == b["x"] and a["y"] < b["y"] and a["width"] == b["width"], "W3 template")
        self.membership("close", 3)
        returned = self.command("docked")
        need(frames(returned["observations"]) == frames(custom["observations"]), "pair history did not restore actual frames")
        self.event("same-pair-custom-history-restored")
        old = read(self.dir / "ticket.json")
        self.membership("create", 3)
        for n in (3, 4, 5):
            if n > 3:
                self.membership("create", n)
            self.command("docked")
        self.command("original")
        for n in (5, 4, 3):
            self.membership("close", n)
        current = read(self.dir / "ticket.json")
        save(self.dir / "ticket.json", old)
        self.command("docked", refuse="stale enrollment")
        save(self.dir / "ticket.json", current)
        self.command("original")
        if suite == "workrect":
            return
        # Honor a failed first parking/restoration on this setup. No further real parking in this evidence series.
        for prior in (ROOT / "build/verification").glob("*/device-*/journal.json"):
            if prior.parent == self.dir:
                continue
            record = read(prior)
            if (record.get("parked") and record["status"] in ("prepared", "recovering", "parked")
                    and record["display"] == run["screens"]["secondary"]):
                raise NotVerified("parking stopped after a prior unsettled transaction on this display")
        self.phase = "virtual-canary"
        originals = frames(self.command("observe"))
        parked = self.command("park")
        need(parked["setters"] == 1 and frames(parked["observations"])[2] == originals[2], "single parking not confirmed")
        r = self.command("recover")
        need(frames(r["observations"]) == originals and self.command("recover")["setters"] == 0, "first parking restoration failed")
        self.event("first-parking-restored")
        self.phase = "virtual-switch"
        switched = self.command("switch")
        need(switched["setters"] == 3 and switched["journal"]["status"] == "parked", "both virtual groups not confirmed")
        need(frames(self.command("recover")["observations"]) == originals, "switch normal restoration failed")
        self.phase = "virtual-sigkill"
        self.crash(originals)
        self.refusals()

    def controls(self):
        self.phase = "onscreen-crash"
        initial = frames(self.command("observe"))
        self.crash(initial, onscreen=True)
        self.phase = "restore-refusals"
        trial = self.command("canary")
        pending = read(self.dir / "journal.json")
        self.command("recover-denied", refuse="Accessibility denied")
        need(read(self.dir / "journal.json") == pending, "permission refusal changed the recovery journal")
        need(frames(self.command("observe")) == frames(trial["observations"]), "permission refusal changed geometry")
        self.command("recover")
        adjusted = self.command("reserve")
        current = read(self.dir / "journal.json")
        # Install an earlier authentic record in the private lab to exercise a stale recovery against a later real frame.
        save(self.dir / "journal.json", pending)
        self.command("recover", refuse="unrecognized frame")
        need(frames(self.command("observe")) == frames(adjusted["observations"]), "stale restore overwrote newer layout")
        save(self.dir / "journal.json", current)
        self.command("original")

    def panel(self):
        self.phase = "physical-panel"
        self.membership("create", 2)
        docked = self.command("docked")
        before = frames(docked["observations"])
        for action in ("panel-show", "panel-hide", "panel-show", "panel-expand", "panel-collapse", "panel-tools-off", "panel-hide"):
            ticket = self.membership(action, 0)
            seen = self.command("panel-observe")
            need(seen["action"] == action and seen["visible"] == (action != "panel-hide"), "wrong panel checkpoint")
            if action in ("panel-expand", "panel-collapse"):
                need(seen["expanded"] == (action == "panel-expand"), "module expansion checkpoint")
            need(frames(self.command("observe")) == before, "physical panel changed an ordinary window")
            self.event("panel-checkpoint", action=action, revision=ticket["revision"], visible=seen["visible"])
        self.command("original")

    def refusals(self):
        self.phase = "incarnation-refusals"
        if len(read(self.dir / "ticket.json")["members"]) == 1:
            self.membership("create", 2)
        old = read(self.dir / "ticket.json")
        self.membership("close", 2)
        fresh = self.membership("create", 2)
        need(fresh["members"][1]["id"]["element"] != old["members"][1]["id"]["element"], "fixture window incarnation reused")
        for invalid in (old, dict(fresh, members=[fresh["members"][0]] * 2)):
            save(self.dir / "ticket.json", invalid)
            self.command("docked", refuse="stale enrollment")
        save(self.dir / "ticket.json", fresh)
        self.stop_owner()
        self.start_owner()
        renewed = self.membership("create", 1)
        need(renewed["owner"] != fresh["owner"], "fixture process was not reincarnated")
        save(self.dir / "ticket.json", fresh)
        self.command("docked", refuse="stale enrollment")
        save(self.dir / "ticket.json", renewed)
        self.command("observe")
        self.event("old-process-and-window-rejected")

    def crash(self, initial, onscreen=False):
        with (self.dir / "killed.stderr").open("wb") as err:
            verb = "canary-and-hold" if onscreen else "switch-and-hold"
            witness = "kill-witness.json" if onscreen else "parked-witness.json"
            child = subprocess.Popen([self.controller, verb, self.dir], stdout=subprocess.DEVNULL, stderr=err)
            try:
                def ready():
                    need(child.poll() is None, "test writer exited before kill checkpoint")
                    return (self.dir / witness).exists()
                until(ready, 15)
                receipt = read(self.dir / witness)
                need(frames(self.command("observe")) == frames(receipt["observations"]), "independent parking witness disagrees")
                if onscreen:
                    j = read(self.dir / "journal.json")["changes"][0]
                    need(j["confirmed"] == j["original"] and j["inFlight"] == receipt["observations"][0]["cg"],
                         "death boundary not between AX write and journal acknowledgement")
                self.command("recover", refuse="lease")
                child.send_signal(signal.SIGKILL)
                need(child.wait(timeout=4) == -signal.SIGKILL, "test controller did not exit by SIGKILL")
                self.event("SIGKILL", child=child.pid, transaction=receipt["journal"]["transaction"])
            finally:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=4)
        r = self.command("recover")
        need(r["setters"] == 1 and frames(r["observations"]) == initial and self.command("recover")["setters"] == 0,
             "crash recovery not independently verified")
        self.event("sigkill-restored", onscreen=onscreen)

    def finish(self):
        try:
            visibility = self.dir / "visibility.json"
            if self.owner and self.owner.poll() is None and visibility.exists() and not read(visibility)["settled"]:
                try:
                    self.command("mini-recover")
                except (NotVerified, subprocess.SubprocessError) as e:
                    self.event("visibility-recovery-unresolved", reason=str(e))
            journal = self.dir / "journal.json"
            if self.owner and self.owner.poll() is None and journal.exists() and read(journal)["status"] in ("prepared", "recovering", "parked"):
                try:
                    # One identity-checked recovery; never retry the original input or retarget a missing window.
                    self.command("recover")
                except (NotVerified, subprocess.SubprocessError) as e:
                    self.event("recovery-unresolved", reason=str(e))
        finally:
            if self.owner and self.owner.poll() is None:
                self.stop_owner()
            elif self.owner:
                self.event("fixture-early-exit", rc=self.owner.returncode)
                if (self.dir / "ticket.json").is_file():
                    self.event("CG-cleanup-after-stop", **self.command("confirm-exit"))
                raise NotVerified("fixture stopped early; see fixture stderr")


def verify_source_sample(sample, session, revision, display, source, identity, frame):
    need(sample["sessionID"].lower() == session.lower() and sample["revision"] == revision
         and sample["freshness"] == "fresh" and sample["topologyConsistent"] and sample["separateSpaces"]
         and sample["native"]["population"] == "markedFixture" and sample["native"]["spaces"] == "observed"
         and sample["native"]["accessibility"] == "available" and not sample["native"]["windowLimitReached"],
         "incomplete source sample")
    row, = sample["native"]["rows"]
    scope, = [s for s in sample["scopes"] if s["displayID"] == display]
    need([r["id"] for r in scope["records"] if r["isCurrent"]] == [source]
         and row["scopeID"] == scope["id"] and row["displayID"] == display and row["recordID"] == source
         and row["anchor"] == dict(displayID=display, witness="ownedWindow", number=identity["number"], globalFrame=frame),
         "source desktop is not the enrolled secondary window's current desktop")
    window, = sample["windows"]
    meta = window["metadata"]
    need(window["displayID"] == display and window["confidence"] == "corroboratedMetadata"
         and window["membership"] == {"known": {"recordIDs": [source]}}
         and meta["pid"] == identity["pid"] and meta["number"] == identity["number"]
         and meta["launchMicroseconds"] == identity["launch"] and meta["globalFrame"] == meta["axFrame"] == frame
         and meta["axStandardWindowNumber"] == identity["number"] and meta["isOnscreen"]
         and not meta["minimized"] and not meta["fullScreen"],
         "source window identity, presentation or exclusive membership is unproven")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--suite", choices=("passive-source", "focus-study","canary", "workrect", "controls", "panel", "refusals", "including-parking"), default="workrect")
    parser.add_argument("--source", help="ordinary source record already confirmed by the console preflight")
    parser.add_argument("--display", help="physical secondary display UUID for passive-source")
    parser.add_argument("--read-gate", action="store_true", help="sample only the first owned window with the bundled read-only reader")
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.relative_to(ROOT / "build/verification")
    evidence.mkdir(parents=True, exist_ok=True)
    trial = Trial(evidence)
    print(trial.dir, flush=True)
    failure = []
    try:
        trial.exercise(args.suite, args.read_gate, args.source, args.display)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, NotVerified) as e:
        failure.append(str(e))
    finally:
        try:
            trial.finish()
        except (OSError, ValueError, subprocess.SubprocessError, NotVerified) as e:
            failure.append(str(e))
    status = dict(completed=not failure, suite=args.suite, lastPhase=trial.phase, failure=failure)
    save(trial.dir / "result.json", status)
    print(json.dumps(status, ensure_ascii=False), flush=True)
    return int(bool(failure))


if __name__ == "__main__":
    raise SystemExit(main())
