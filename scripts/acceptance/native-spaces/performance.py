"""WindowServer arrival and physical footprint measurements on the contract's three leased desktops."""
import hashlib
import importlib
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import time

from acceptance import catalog_match, checked, native_capabilities
from installed_profile import PROFILE, owns_profile, validate_home
from p0_drift_classification import action_record, normalized_uuid
from space_scope import ScopeError, require, validate_live
from space_trials import Driver


def matched_terminal(raw, filename, scope, trial):
    """Bind the official Host's three-phase submission to this exact leased route and press."""
    proof = action_record(raw)
    spaces = {entry["id"]: normalized_uuid(entry["uuid"]) for entry in scope["spaces"]}
    require(proof and normalized_uuid(filename.stem) == proof["operation"] and
            (proof["display"], proof["source"], proof["target"]) ==
            (normalized_uuid(scope["display"]), trial["source"], trial["target"]) and
            (proof["sourceUUID"], proof["targetUUID"]) == (spaces[trial["source"]], spaces[trial["target"]]) and
            proof["created"] >= trial["dispatch"][0]["tPress"], "Unrelated or unconfirmed installed Host submission")
    if proof["window"] is not None:
        require(any(w["space"] == trial["target"] and
                    all(w[key] == value for key, value in proof["window"].items()) for w in scope["witnesses"]),
                "Installed Host selection does not bind an enrolled target window")
    return proof


def arrival_distribution(trials, *, product):
    """Never publish partial/good-only or warm-up-biased percentiles as contract results."""
    batches = list(range(6)) if product else [None]
    expected = len(batches) * 20
    output = {"expected": 100 if product else 20,
              "observed": sum(not product or row.get("batch") != 0 for row in trials),
              "p50ms": None, "p95ms": None, "p99ms": None}
    if len(trials) != expected:
        return output
    values = []
    previous_end = previous_target = None
    seen_operations = set()
    schedule = [row.get("target") for row in trials[:20]]
    for index, trial in enumerate(trials):
        batch, ordinal = divmod(index, 20)
        start, end = trial.get("t0"), trial.get("tArrival")
        if (trial.get("status") != "PASS" or trial.get("batch") != batches[batch] or trial.get("ordinal") != ordinal + 1
                or not all(type(value) in (int, float) and math.isfinite(value) for value in (start, end))
                or end <= start or (previous_end is not None and start < previous_end)
                or any(type(trial.get(key)) is not int or trial[key] <= 0 for key in ("source", "target", "actual"))
                or (previous_target is not None and trial["source"] != previous_target)
                or trial["source"] == trial["target"] or trial["actual"] != schedule[ordinal]
                or trial["actual"] != trial["target"]):
            return output
        if product:
            events = trial.get("dispatch")
            if not isinstance(events, list) or len(events) != 1:
                return output
            operation = trial.get("hostOperation")
            if not isinstance(operation, str) or not operation or operation in seen_operations:
                return output
            seen_operations.add(operation)
            press = events[0]
            if (press.get("source") != trial["source"] or press.get("target") != trial["target"]
                    or press.get("axError") != 0 or type(press.get("tPress")) not in (int, float)
                    or not math.isfinite(press["tPress"]) or press["tPress"] <= 0
                    or not all(type(trial.get(k)) in (int, float) and math.isfinite(trial[k]) for k in ("tIssued", "hostConfirmed", "tHighlight"))
                    or not (start == press["tPress"] <= trial["tIssued"] <= end <= trial["tHighlight"])
                    or not trial["tIssued"] <= trial["hostConfirmed"] <= trial["tHighlight"]):
                return output
        previous_end, previous_target = end, trial["target"]
        if not product or batch:
            values.append((end - start) * 1000)
    values.sort()
    for percentile in (50, 95, 99):
        output[f"p{percentile}ms"] = values[math.ceil(len(values) * percentile / 100) - 1]
    return output


def warmed_cpu_percent(previous, current):
    """PID reuse, reparenting, or any individual counter rollback invalidates the tree delta."""
    def counters(snapshot):
        return {(row["pid"], row["parent"], row["birthSec"], row["birthUsec"]):
                (row["cpuUserNs"], row["cpuSystemNs"]) for row in snapshot["processes"]}
    before, after = counters(previous), counters(current)
    elapsed = current["monotonic"] - previous["monotonic"]
    require(before and before.keys() == after.keys() and len(before) == len(previous["processes"])
            and len(after) == len(current["processes"]) and math.isfinite(elapsed) and elapsed > 0,
            "Process tree or interval differs from warmed readback")
    delta = 0
    for key, prior in before.items():
        for end, start in zip(after[key], prior):
            require(0 <= start <= end, "Per-process CPU counter rolled back")
            delta += end - start
    return delta / 1e9 / elapsed * 100


def children(root):
    edges = [tuple(map(int, line.split())) for line in checked(["/bin/ps", "-axo", "pid=,ppid="]).splitlines()]
    found = {root}
    for _ in range(len(edges)):
        descendants = {pid for pid, parent in edges if parent in found}
        if descendants <= found:
            break
        found.update(descendants)
    return sorted(found)


def snapshot(pid, reader, metrics):
    changes = []
    for _ in range(6):
        processes = children(pid)
        measured = subprocess.run([str(reader), *map(str, processes)], capture_output=True, text=True, timeout=5)
        after = children(pid)
        if after != processes or measured.returncode == 3:
            changes.append({'before':processes, 'after':after, 'kernelExit':measured.returncode})
            time.sleep(.12)
            continue
        require(measured.returncode == 0, "Kernel physical footprint read failed")
        keys = ("pid", "parent", "birthSec", "birthUsec", "physFootprint", "cpuUserNs", "cpuSystemNs")
        readings = [line.split() for line in measured.stdout.splitlines()]
        require(all(len(values) == len(keys) for values in readings), "Incomplete kernel counters")
        rows = [dict(zip(keys, map(int, values))) for values in readings]
        require([row['pid'] for row in rows] == processes, "Incomplete physical footprint read")
        return {"processes":rows, "physicalBytes":sum(row['physFootprint'] for row in rows),
                "cpuTimeNs":sum(row["cpuUserNs"] + row["cpuSystemNs"] for row in rows),
                "transientReads":changes, "metrics":json.loads(checked([str(metrics), str(pid)]))}
    raise ScopeError("No complete, stable kernel process tree in six observations")


def run(*, workspace, scope, observer, driver, output):
    output = Path(output)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    ledger = importlib.import_module("p0-cards")
    out = {"status": "NOT_RUN", "native": [], "product": [], "memorySamples": [], "method":
           "OS Mission Control selection and production sidebar; independent sampled arrival includes observer overhead",
           "feedbackP95ms": None, "comparableAnimationP95ms": None,
           "frameDrops": {"status":"NOT_RUN", "value":None, "reason":"No attributable compositor drop counters"},
           "wakeRecoveryMs":None, "wakeRecoveryStatus":"NOT_RUN"}
    ids = [s["id"] for s in scope["spaces"]]
    host = scope["host"]
    def now():
        return time.monotonic()
    def save():
        ledger.store(output/"results.json", out)
    stream = (output / "actions.jsonl").open("x")
    def log(event, **fields):
        stream.write(json.dumps(dict(event=event, monotonic=now(), **fields))+"\n")
        stream.flush(); os.fsync(stream.fileno())
    def current():
        obs = workspace.read()
        return validate_live(scope, obs, host, require_highlight=False), obs
    channel = None
    origin = None
    try:
        caps = native_capabilities(host)
        qualified = caps[-1] if caps else {}
        out["installedCapabilities"] = qualified
        require(qualified.get("ready") is True and qualified.get("canSwitch") is True,
                "Installed Host has no qualified switch adapter; native and product batches were not started")
        home = Path(os.environ.get("NEARPANE_TEST_HOME", ""))
        validate_home(home)
        require(owns_profile(host["pid"], home/PROFILE), "Signed Host does not own the isolated recording profile")
        os_build = checked(["/usr/sbin/sysctl", "-n", "kern.osversion"]).strip()
        journal = home/"Library/Application Support/Nearpane/NativeSwitch"/("dock-v1-" + os_build)
        require(not (journal/"pending.json").exists(), "Earlier installed action still unresolved")
        origin, baseline = current()
        require(origin in ids and len(ids) == 3, "Performance fixture requires three proven ordinary desktops")
        position = ids.index(origin)
        order = [ids[(position+i%2+1)%3] for i in range(20)]
        native_source = origin
        for ordinal, target in enumerate(order, 1):
            require(current()[0] == native_source and native_source != target, "Native starting desktop changed")
            trial = {"source": native_source, "target": target, "ordinal": ordinal, "t0": now(), "tArrival": None, "status": "UNKNOWN"}
            out["native"].append(trial); log("native-intent", **trial)
            workspace.select(target)
            actual, sample = current()
            trial.update(tArrival=now(), actual=actual, status="PASS" if actual == target else "FAIL")
            log("native-readback", **trial); save()
            require(actual == target, "Native selection reached a different desktop")
            native_source = actual
        workspace.select(origin)
        channel = Driver(driver, scope, log)
        source = origin
        operations = set()
        with tempfile.TemporaryDirectory(prefix="np-footprint-") as tmp:
            reader = Path(tmp) / "footprint"
            subprocess.run(["xcrun","clang",str(Path(__file__).with_name("footprint.c")),"-o",reader], check=True)
            for batch in range(6):
                for ordinal, target in enumerate(order, 1):
                    trial = {"batch":batch, "ordinal":ordinal, "source":source, "target":target, "requested":now(), "t0":None,
                             "tIssued":None, "tFeedback":None, "tArrival":None, "tHighlight":None, "status":"UNKNOWN"}
                    out["product"].append(trial); log("product-intent", **trial)
                    require(not (journal/"pending.json").exists(), "Earlier installed action still unresolved")
                    before = set(ledger.journal_files(journal))
                    trial["dispatch"] = channel.command([target], [source])
                    require(len(trial["dispatch"]) == 1, "Missing production sidebar action receipt")
                    press = trial["dispatch"][0]
                    trial["t0"] = press.get("tPress")
                    require((press["source"], press["target"], press["axError"]) == (source, target, 0),
                            "Production sidebar input does not match this sample")
                    terminal = None
                    deadline = now() + 4
                    while now() < deadline:
                        actual, sample = current()
                        created = set(ledger.journal_files(journal)) - before
                        require(len(created) <= 1, "More than one new installed operation")
                        if terminal is None and created:
                            filename = journal/created.pop()
                            data = ledger.journal_read(filename)
                            with (output/filename.name).open("xb") as evidence:
                                evidence.write(data)
                            trial["hostReceiptSHA256"] = hashlib.sha256(data).hexdigest()
                            raw = json.loads(data)
                            state = (raw.get("result") or {}).get("state")
                            trial["hostTerminalState"] = state if state in ("confirmed","failed","outcomeUnknown") else "unknown"
                            terminal = matched_terminal(raw, filename, scope, trial)
                            require(terminal["operation"] not in operations, "A prior installed operation was replayed")
                            operations.add(terminal["operation"])
                            trial.update(hostOperation=terminal["operation"], tIssued=terminal["issued"],
                                         hostConfirmed=terminal["confirmed"])
                        if actual == target:
                            trial["tArrival"] = trial["tArrival"] or now()
                            if terminal and not (journal/"pending.json").exists() and catalog_match(sample)["highlightMatchesSystem"]:
                                trial.update(tHighlight=now(), actual=actual, status="PASS")
                                break
                        elif actual != source or trial["tArrival"] is not None:
                            trial.update(actual=actual, status="FAIL")
                            break
                        time.sleep(.035)
                    log("product-readback", **trial); save()
                    require(trial["status"] == "PASS", "Production selection did not settle on its target")
                    source = target
                time.sleep(30)
                reading = snapshot(host["pid"], reader, Path(observer).parent/"metrics")
                reading.update(batch=batch, monotonic=now())
                out["memorySamples"].append(reading); save()
                if batch == 0:
                    tree = [(r["pid"],r["birthSec"],r["birthUsec"]) for r in reading["processes"]]
                    first = reading["physicalBytes"]
                else:
                    require(tree == [(r["pid"],r["birthSec"],r["birthUsec"]) for r in reading["processes"]],
                            "Process tree identity differs from the warmed baseline")
                    previous = out["memorySamples"][-2]
                    reading["averageProcessTreeCPUPercent"] = warmed_cpu_percent(previous, reading)
                    require(reading["physicalBytes"] <= first + max(64*1024**2, first*.1), "Physical footprint exceeds contract")
                m = reading["metrics"]
                require(m["cacheEntries"] <= 128 and m["chargedPixelBytes"] <= 256*1024**2, "Pixel cache exceeds contract")
        require(arrival_distribution(out["product"], product=True)["p95ms"] is not None and
                arrival_distribution(out["native"], product=False)["p95ms"] is not None,
                "Warmed series lacks unique installed operations or independent native samples")
        out["status"] = "PARTIAL"
        out["reason"] = "Memory series completed. Comparable default animation and product feedback timing were not established."
        out["memoryProtocol"] = "PASS"
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        out.update(status="BLOCKED" if not out["product"] else "INCOMPLETE", reason=str(error))
    finally:
        if channel: channel.close()
        try:
            if (out["native"] or out["product"]) and origin is not None and current()[0] != origin:
                workspace.select(origin)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            out["returnIssue"] = str(error)
        for key in ("native", "product"):
            distribution = arrival_distribution(out[key], product=key == "product")
            out[key + "ObservedArrival"] = distribution
            out[key + "ObservedArrivalP95ms"] = distribution["p95ms"]
        save(); stream.close()
    return out
