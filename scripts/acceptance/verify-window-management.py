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
    def __init__(self, out):
        self.dir = Path(tempfile.mkdtemp(prefix="device-", dir=out))
        self.owner = None
        self.sequence = self.count = self.enrollments = self.generation = 0
        self.events = []
        self.phase = "preflight"
        self.executables = {}
        for name in ("NearpaneFrameController", "NearpaneFixtureWindows"):
            app = APPS / (name + ".app")
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
            path = app / "Contents/MacOS" / name
            self.executables[name] = path
        self.controller = self.executables["NearpaneFrameController"]
        save(self.dir / "executables.json", {n: hashlib.sha256(p.read_bytes()).hexdigest() for n, p in self.executables.items()})

    def event(self, name, **data):
        item = dict(name=name, **data)
        self.events.append(item)
        with (self.dir / "events.jsonl").open("a") as f:
            f.write(json.dumps(item, sort_keys=True) + "\n")
            f.flush()
            os.fsync(f.fileno())

    def command(self, name, *, refuse=None):
        self.count += 1
        stem = self.dir / f"{self.count:03d}-{name}"
        tries = len(list(self.dir.glob("attempt-*.json")))
        args = [self.controller, name] + ([] if name == "preflight" else [self.dir])
        result = subprocess.run(args, capture_output=True, timeout=30)
        stem.with_suffix(".stdout").write_bytes(result.stdout)
        stem.with_suffix(".stderr").write_bytes(result.stderr)
        attempts = len(list(self.dir.glob("attempt-*.json"))) - tries
        detail = result.stderr.decode("utf-8", "replace").strip()
        self.event(name, rc=result.returncode, attempts=attempts, phase=self.phase, detail=detail)
        if refuse:
            need(result.returncode != 0 and refuse in detail and attempts == 0, f"{name} refusal not proven: {detail}")
            return
        need(result.returncode == 0, f"{name}: {detail}")
        return json.loads(result.stdout)

    def membership(self, action, index):
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

    def exercise(self, suite, read_gate):
        pre = self.command("preflight")
        need(pre["controllerID"] == "org.nearpane.lab.NearpaneFrameController" and pre["parent"]["pid"] == os.getpid(), "control subject")
        run = dict(session=str(uuid.uuid4()), parent=pre["parent"], deadline=pre["uptime"] + 480, screens=pre["screens"])
        save(self.dir / "run.json", run)
        self.start_owner()
        self.phase = "enroll"
        self.membership("create", 1)
        self.command("inspect")
        if not pre["trusted"]:
            self.membership("create", 2)
            self.command("inspect")
            raise NotVerified("USER ACTION REQUIRED: Accessibility unavailable to the signed controller")
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
                raise NotVerified("fixture stopped early; see fixture stderr")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--suite", choices=("canary", "workrect", "controls", "panel", "refusals", "including-parking"), default="workrect")
    parser.add_argument("--read-gate", action="store_true", help="sample only the first owned window with the bundled read-only reader")
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.relative_to(ROOT / "build/verification")
    evidence.mkdir(parents=True, exist_ok=True)
    trial = Trial(evidence)
    print(trial.dir, flush=True)
    failure = []
    try:
        trial.exercise(args.suite, args.read_gate)
    except (OSError, ValueError, subprocess.SubprocessError, NotVerified) as e:
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
