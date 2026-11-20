#!/usr/bin/env python3
"""S02 and R01 through installed sidebar AX controls. All input is opt-in via a fresh native scope receipt."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import time
import uuid

from acceptance import catalog_match, checked, identity, manifest, native_capabilities
from space_scope import load_scope, private_file, require, ScopeError, shape, validate_live


def observed_order(scope, snapshot):
    """Accept only permutations of the original *leased* slots. No system input."""
    trusted = scope["_shape"]
    live = shape(snapshot)
    display = scope["display"]
    require(set(live) == set(trusted) and all(live[k] == trusted[k] for k in live if k != display),
            "an untargeted display inventory changed")
    allowed = {s["id"] for s in scope["spaces"]}
    require(len(live[display]) == len(trusted[display]) and set(live[display]) == set(trusted[display])
            and all((old[0] in allowed and new[0] in allowed) or old == new
                    for old, new in zip(trusted[display], live[display])), "a non-test Space or identity changed")
    return live


def passive_system_observation(observer, lease, duration, output):
    """Independently observe a controlled system-initiated selection/reorder. Never sends an event."""
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    result = dict(S03="NOT_RUN", systemInputs=0, externalSwitchObserved=False, leasedReorderObserved=False)
    def read():
        return json.loads(checked([str(observer)], timeout=6))
    try:
        first = read()
        frozen = manifest(first)
        require(frozen["loadedMatchesInstalled"] and frozen["signatureValid"], "installed identity unavailable")
        require(lease and lease.exists(), "no positive test-Space creation manifest")
        scope = load_scope(lease, first, checked(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]).strip(), first["uptime"])
        origin = validate_live(scope, first, scope["host"])
        stop = time.monotonic() + duration
        previous = None
        samples = 0
        with (output/"inventory.jsonl").open("x") as stream:
            while time.monotonic() < stop:
                observed = read()
                order = observed_order(scope, observed)
                current = validate_live({**scope, "_shape":order}, observed, scope["host"], require_highlight=False)
                matches = catalog_match(observed)
                sample = dict(inventory=order, current=current, sidebar=matches)
                stream.write(json.dumps(dict(uptime=observed["uptime"], **sample))+"\n")
                stream.flush()
                if previous == sample and matches["rowIdentitiesMatch"] and matches["highlightMatchesSystem"]:
                    samples += 1
                    result["externalSwitchObserved"] |= current != origin
                    result["leasedReorderObserved"] |= order != scope["_shape"]
                previous = sample
                time.sleep(.08)
        result["stableReadbacks"] = samples
        if result["externalSwitchObserved"] or result["leasedReorderObserved"]:
            result["S03"] = "PARTIAL"
        result["reason"] = "Native change observation alone does not attest its initiator and the subsequent installed-sidebar return."
    except (OSError, KeyError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        result.update(S03="BLOCKED", reason=str(exc))
    (output/"results.json").write_text(json.dumps(result, indent=2)+"\n")
    return result


def prepare_scope(observer, receipts, fixture_files, output, *, scoped_members=False):
    """Build a private lease from existing system creation receipts. No system input."""
    require(len(receipts) in (2, 3), "two or three independent creation receipts required")
    observation = json.loads(checked([str(observer)], timeout=6))
    frozen = manifest(observation)
    require(frozen["loadedMatchesInstalled"] and frozen["signatureValid"], "cannot identify installed Host")
    boot = checked(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]).strip()
    spaces, witnesses, expiries = [], [], []
    for path in receipts:
        data = private_file(path)
        creation = json.loads(data)
        sid = creation["target"]
        spaces.append(dict(id=int(sid), uuid=creation["after"]["spaceUUIDs"][sid], receipt=str(path),
                           sha256=hashlib.sha256(data).hexdigest()))
        expiries.append(creation["intent"]["issuedUptime"] + 900)
    for raw_space, raw_path in fixture_files:
        path = Path(raw_path)
        require(path.name == "windows.json" and path.parent.parent.parent == Path("/private/tmp")
                and path.parent.parent.name.startswith(("nearpane-wp5.", "nearpane-d01.", "nearpane-space-trials.")),
                "not a disposable Field Notes fixture")
        state = json.loads(private_file(path))
        app = path.parent.parent / ("Route Notes.app" if state.get("bundle") == "net.example.spaces-route-witness" else "Field Notes.app")
        signature = identity(app)
        require(signature["Identifier"] in ("net.example.spaces-document","net.example.spaces-route-witness"), "fixture bundle signing mismatch")
        for number in state["numbers"]:
            witnesses.append(dict(number=number, pid=state["pid"], birth=state["birth"], space=int(raw_space),
                                  bundleID=signature["Identifier"], bundlePath=str(app),
                                  codeHash=signature["CDHash"], state=str(path)))
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    pending = output / "pending.json"
    fd = os.open(pending, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(dict(schema=1, session=str(uuid.uuid4()), host=observation["host"], display=creation["intent"]["display"],
                       spaces=spaces, witnesses=witnesses, boot=boot, expiresUptime=min(expiries), scopedMembership=scoped_members), f)
        f.flush()
        os.fsync(f.fileno())
    load_scope(pending.resolve(), observation, boot, observation["uptime"])
    pending.rename(output / "scope.json")


class Driver:
    def __init__(self, executable, scope, log):
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.log = log
        self.buffer = b""
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.write({**{k: v for k, v in scope.items() if not k.startswith("_")},
                    "baselineScopes": scope["_scopes"], "baselineDisplays": scope["_displays"]})

    def write(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def command(self, targets, allowed):
        self.log("intent", targets=targets, allowedSources=list(allowed))
        self.write({"targets": targets, "sources": list(allowed)})
        end = time.monotonic() + 8
        while True:
            while b"\n" not in self.buffer:
                remaining = end - time.monotonic()
                require(remaining > 0 and self.selector.select(remaining), "sidebar driver reply timed out")
                chunk = os.read(self.process.stdout.fileno(), 16384)
                require(chunk and len(self.buffer) + len(chunk) <= 65536, "sidebar driver exited or reply invalid")
                self.buffer += chunk
            data, self.buffer = self.buffer.split(b"\n", 1)
            item = json.loads(data)
            if "stage" in item:
                self.log(item["stage"], **{k: v for k, v in item.items() if k != "stage"})
                continue
            self.log("driver-result", **item)
            require(item.get("ok"), item.get("reason", "row input could not be proven"))
            return item["attempts"]

    def close(self):
        self.selector.close()
        self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=2)
        self.process.stdout.close()


def scenarios(ids):
    a, b, c = ids
    switches = [b, a, c, b, c, a] * 8 + [b, a]
    rapid, current = [], a
    for index in range(20):
        group = []
        for i in range(3 + index % 3):
            current = ids[(ids.index(current) + 1 + (i + index) % 2) % 3]
            group.append(current)
        # A final target equal to the pre-group current could "pass" with zero switching.
        initial = rapid[-1][-1] if rapid else a
        if group[-1] == initial:
            group[-1] = next(i for i in ids if i != initial and i != group[-2])
            current = group[-1]
        rapid.append(group)
    return switches, rapid


def run(observer, driver, lease, output, *, run_rapid=True):
    output.mkdir(parents=True, exist_ok=False)
    stream = (output / "actions.jsonl").open("x")
    result = {"S02": "NOT_RUN", "S03": "NOT_RUN", "R01": "NOT_RUN", "sent": 0, "prepared": 0, "unknown": 0, "attempts": []}
    scenario = None
    trial = None
    def log(event, **fields):
        if event == "before-press":
            result["attempts"].append(dict(scenario=scenario,trial=trial,source=fields["source"],target=fields["target"],
                                           inputAcknowledged=None,status="UNKNOWN"))
            result["prepared"] += 1
        if event == "after-press":
            attempt=result["attempts"][-1]
            attempt.update(inputAcknowledged=fields["axError"]==0,axError=fields["axError"])
            if fields["axError"]!=0:attempt["status"]="FAIL"
            result["sent"] += 1
        stream.write(json.dumps(dict(event=event, monotonic=time.monotonic(), **fields)) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    def read():
        return json.loads(checked([str(observer)], timeout=6))
    channel = None
    origin = None
    scope = None
    second = None
    try:
        first, second = read(), read()
        frozen = manifest(second)
        caps = native_capabilities(second.get("host"))
        cap = caps[-1] if caps else None
        initial = {"host": second.get("host"), "scopes": second.get("scopes"), "displays": second.get("displays"),
                   "sidebar": catalog_match(second), "capabilities": cap, "observerAX": second.get("observerAX"),
                   "loadedMatchesInstalled": frozen["loadedMatchesInstalled"], "signatureValid": frozen["signatureValid"],
                   "source": frozen["source"], "build": frozen["build"]}
        log("installed-preflight", **initial)
        reasons = []
        if not lease or not lease.exists():
            reasons.append("No fresh creation manifest for three owned ordinary test Spaces.")
        if not cap or not cap["ready"] or not cap["canSwitch"]:
            reasons.append("Installed Host lacks a current positive canSwitch probe.")
        if reasons:
            raise ScopeError(" ".join(reasons))
        require(first["host"] == second["host"] and first["scopes"] == second["scopes"] and
                first["displays"] == second["displays"], "unstable preflight")
        require(frozen["loadedMatchesInstalled"] and frozen["signatureValid"] and frozen["source"],
                "installed signing identity mismatch")
        boot = checked(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]).strip()
        scope = load_scope(lease, second, boot, second["uptime"])
        origin = validate_live(scope, second, scope["host"])
        ids = [s["id"] for s in scope["spaces"]]
        require(len(ids) == 3 and origin == ids[0], "expected initial tested A and three owned, consecutive A/B/C Spaces")
        require({w["space"] for w in scope["witnesses"]} == set(ids[:2]), "A and B need owned windows; C must be independently empty")
        require(second.get("frontmostPID") in {w["pid"] for w in scope["witnesses"] if w["space"] == origin}
                and second.get("focusedNumber") in {w["number"] for w in scope["witnesses"] if w["space"] == origin},
                "initial keyboard focus is not positively owned by test Space A")
        channel = Driver(driver, scope, log)
        def sample(target, trial, stable=False):
            deadline = time.monotonic() + 4
            seen, last = 0, None
            while time.monotonic() < deadline:
                o = read()
                current = validate_live(scope, o, scope["host"], require_highlight=False)
                status = catalog_match(o)
                last = {"currents": {s["scope"]:s["current"] for s in o["scopes"]}, "selectedMatchesCurrent": status["highlightMatchesSystem"],
                        "front": o["frontmostPID"], "focus": o["focusedNumber"]}
                if current == target and status["highlightMatchesSystem"]:
                    seen += 1
                elif seen:
                    raise ScopeError("desktop or sidebar selection rebounded after reaching target")
                if seen >= (3 if stable else 2):
                    channel.command([], [target])  # confirms physical input, real witnesses and permitted focus
                    log("independent-readback", trial=trial, **last, samples=seen)
                    return
                time.sleep(.08)
            log("arrival-timeout", trial=trial, last=last)
            raise ScopeError("target arrival and installed-sidebar highlight did not settle")
        channel.command([], [origin])
        singles, rapid = scenarios(ids)
        current = origin
        scenario = "S02"
        result["S02"] = "IN_PROGRESS"
        for i, target in enumerate(singles):
            trial=f"S02-{i+1}"
            if target == current:
                target = next(n for n in ids if n != current)
            channel.command([target], [current])
            try:
                sample(target,trial)
            except ScopeError as error:
                # Only a known, quiet, still-owned state admits the next independent trial.
                # An interrupted action or a changed user/Host/fixture identity suspends input.
                if str(error) != "target arrival and installed-sidebar highlight did not settle": raise
                first_read = read()
                actual=validate_live(scope,first_read,scope["host"],require_highlight=False)
                time.sleep(.25)
                second_read=read()
                require(validate_live(scope,second_read,scope["host"],require_highlight=False)==actual
                        and catalog_match(first_read)==catalog_match(second_read),"unsettled outcome after selection")
                channel.command([], [actual])
                result["attempts"][-1].update(status="FAIL",actual=actual,reason=str(error))
                log("confirmed-failure",trial=trial,actual=actual,target=target)
                current=actual
            else:
                result["attempts"][-1]["status"]="PASS"
                current=target
        result["S02"] = "PASS" if all(a["status"]=="PASS" for a in result["attempts"]) else "FAIL"
        if not run_rapid:
            return result
        # System-initiated switching and external reordering require their own witness;
        # independent readbacks of sidebar actions alone cannot satisfy S03.
        result["S03Readback"] = "Compared the actual WindowServer inventory and all current/highlight pairs for each S02 action."
        scenario = "R01"
        result["R01"] = "IN_PROGRESS"
        for i, group in enumerate(rapid):
            trial=f"R01-{i+1}"
            sent = channel.command(group, [current])
            require(len(sent) == len(group), "incomplete rapid group")
            gaps = [y["tPress"] - x["tPress"] for x, y in zip(sent, sent[1:])]
            log("rapid-group", group=i+1, gaps=gaps, last=group[-1])
            current = group[-1]
            sample(current,trial,True)
            result["attempts"][-1]["status"]="PASS"
            if not all(0 <= gap <= .25 for gap in gaps):
                if current != origin:
                    channel.command([origin], [current])
                    sample(origin, "return-after-timing-failure", True)
                    result["attempts"][-1]["status"]="PASS"
                raise ScopeError("input sequence did not exercise rapid selection")
        if current != origin:
            channel.command([origin], [current])
            sample(origin, "return-to-A", True)
            result["attempts"][-1]["status"]="PASS"
        final = read()
        result["focusRestored"] = (origin == validate_live(scope, final, scope["host"]) and
                                   second["frontmostPID"] == final["frontmostPID"] and second["focusedNumber"] == final["focusedNumber"])
        require(result["focusRestored"], "initial owned focus did not return")
        result["R01RapidGroups"] = "PASS"
        result["R01"] = "PARTIAL"
        result["R01Reason"] = "20 rapid groups have independent stable results. Closing a window during an in-flight request requires separate native evidence."
    except (OSError, TypeError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        result["reason"] = str(exc)
        for key in ("S02", "R01"):
            if result[key] == "IN_PROGRESS":
                result[key] = "FAIL" if result["sent"] else "BLOCKED"
            elif result[key] == "NOT_RUN":
                result[key] = "BLOCKED"
        log("stopped", reason=str(exc))
        if channel and origin and scope and second:
            # On an input/identity/ownership discrepancy take only a readback;
            # forcing a return could act on a user's new frontmost window.
            try:
                end = read()
                result["returnVerified"] = (validate_live(scope, end, scope["host"]) == origin and
                                             end.get("focusedNumber") == second.get("focusedNumber") and
                                             end.get("frontmostPID") == second.get("frontmostPID"))
            except (OSError, ValueError, KeyError, subprocess.SubprocessError):
                result["returnVerified"] = False
    finally:
        if channel:
            channel.close()
        stream.close()
        result["unknown"] = sum(a["status"]=="UNKNOWN" for a in result["attempts"])
        result["failed"] = sum(a["status"]=="FAIL" for a in result["attempts"])
        result["singles"] = sum(a["scenario"]=="S02" and "axError" in a for a in result["attempts"])
        result["S03Reason"] = "An independent system-initiated switch and a controlled native reorder are still required."
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--observer", required=True, type=Path)
    parser.add_argument("--driver", required=True, type=Path)
    parser.add_argument("--scope", type=Path)
    parser.add_argument("--created", type=Path, action="append", help="assemble a scope from one native creation receipt per leased Space")
    parser.add_argument("--fixture", nargs=2, action="append", metavar=("SPACE_ID", "FIELD_NOTES_STATE"))
    parser.add_argument("--observe-system", type=int, choices=range(1, 61), metavar="SECONDS",
                        help="sample a separately operated, leased S03 route without issuing input")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.observe_system:
        if args.created or args.fixture:
            parser.error("--observe-system expects an existing validated --scope")
        report = passive_system_observation(args.observer, args.scope, args.observe_system, args.output)
        print(json.dumps(report))
        raise SystemExit(0 if report["S03"] == "PARTIAL" else 3)
    if args.created:
        if args.scope:
            parser.error("--created and --scope are mutually exclusive")
        prepare_scope(args.observer, args.created, args.fixture or [], args.output)
        print(str((args.output / "scope.json").resolve()))
        raise SystemExit(0)
    if args.fixture:
        parser.error("--fixture requires --created")
    report = run(args.observer, args.driver, args.scope, args.output)
    print(json.dumps(report))
    raise SystemExit(0 if report["S02"] == report.get("R01RapidGroups") == "PASS" else 3)
