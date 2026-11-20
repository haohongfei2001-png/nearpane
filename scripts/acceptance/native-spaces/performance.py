"""WindowServer arrival and physical footprint measurements on the contract's three leased desktops."""
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import time

from acceptance import catalog_match, checked, encode
from space_scope import ScopeError, require, validate_live
from space_trials import Driver


def arrival_distribution(trials, *, product):
    """Never publish partial/good-only or warm-up-biased percentiles as contract results."""
    expected_batches = list(range(1, 6)) if product else [None]
    selected = [trial for trial in trials if not product or trial.get("batch") != 0]
    output = {"expected": 20 * len(expected_batches), "observed": len(selected),
              "p50ms": None, "p95ms": None, "p99ms": None}
    if product and sum(row.get("batch") == 0 and row.get("status") == "PASS" for row in trials) != 20:
        return output
    if len(selected) != output["expected"] or any(
            sum(row.get("batch") == batch for row in selected) != 20 for batch in expected_batches):
        return output
    values = []
    for trial in selected:
        start, end = trial.get("t0"), trial.get("tArrival")
        if (trial.get("status") != "PASS" or not all(type(value) in (int, float) and math.isfinite(value)
                                                    for value in (start, end)) or end < start):
            return output
        values.append((end - start) * 1000)
    values.sort()
    for percentile in (50, 95, 99):
        output[f"p{percentile}ms"] = values[math.ceil(len(values) * percentile / 100) - 1]
    return output


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
    output.mkdir(parents=True, exist_ok=False)
    out = {"status": "NOT_RUN", "native": [], "product": [], "memorySamples": [], "method":
           "OS Mission Control selection and production sidebar; independent sampled arrival includes observer overhead",
           "feedbackP95ms": None, "comparableAnimationP95ms": None,
           "frameDrops": {"status":"NOT_RUN", "value":None}, "wakeRecoveryMs":None}
    ids = [s["id"] for s in scope["spaces"]]
    host = scope["host"]
    def now():
        return time.monotonic()
    def save():
        (output / "results.json").write_text(encode(out))
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
        origin, baseline = current()
        require(origin in ids and len(ids) == 3, "Performance fixture requires three proven ordinary desktops")
        position = ids.index(origin)
        order = [ids[(position+i%2+1)%3] for i in range(20)]
        for target in order:
            trial = {"target": target, "t0": now(), "tArrival": None, "status": "UNKNOWN"}
            out["native"].append(trial); log("native-intent", **trial)
            workspace.select(target)
            actual, sample = current()
            trial.update(tArrival=now(), actual=actual, status="PASS" if actual == target else "FAIL")
            log("native-readback", **trial); save()
            require(actual == target, "Native selection reached a different desktop")
        workspace.select(origin)
        channel = Driver(driver, scope, log)
        source = origin
        with tempfile.TemporaryDirectory(prefix="np-footprint-") as tmp:
            reader = Path(tmp) / "footprint"
            subprocess.run(["xcrun","clang",str(Path(__file__).with_name("footprint.c")),"-o",reader], check=True)
            for batch in range(6):
                for target in order:
                    trial = {"batch":batch, "source":source, "target":target, "t0":now(),
                             "tIssued":None, "tFeedback":None, "tArrival":None, "tHighlight":None, "status":"UNKNOWN"}
                    out["product"].append(trial); log("product-intent", **trial)
                    trial["dispatch"] = channel.command([target], [source])
                    require(len(trial["dispatch"]) == 1, "Missing production sidebar action receipt")
                    deadline = now() + 4
                    while now() < deadline:
                        actual, sample = current()
                        if actual == target:
                            trial["tArrival"] = trial["tArrival"] or now()
                            if catalog_match(sample)["highlightMatchesSystem"]:
                                trial.update(tHighlight=now(), status="PASS")
                                break
                        elif actual != source:
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
                    elapsed = reading["monotonic"] - previous["monotonic"]
                    # rusage uses native Mach ticks, converted by the kernel reader.
                    duration = (reading["cpuTimeNs"] - previous["cpuTimeNs"]) / 1e9
                    require(elapsed > 0 and duration >= 0, "Invalid CPU interval")
                    reading["averageProcessTreeCPUPercent"] = 100 * duration / elapsed
                    require(reading["physicalBytes"] <= first + max(64*1024**2, first*.1), "Physical footprint exceeds contract")
                m = reading["metrics"]
                require(m["cacheEntries"] <= 128 and m["chargedPixelBytes"] <= 256*1024**2, "Pixel cache exceeds contract")
        out["status"] = "PARTIAL"
        out["reason"] = "Memory series completed. Comparable default animation and product feedback timing were not established."
        out["memoryProtocol"] = "PASS"
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        out.update(status="BLOCKED" if not out["product"] else "INCOMPLETE", reason=str(error))
    finally:
        if channel: channel.close()
        try:
            if origin is not None and current()[0] != origin: workspace.select(origin)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            out["returnIssue"] = str(error)
        for key in ("native", "product"):
            distribution = arrival_distribution(out[key], product=key == "product")
            out[key + "ObservedArrival"] = distribution
            out[key + "ObservedArrivalP95ms"] = distribution["p95ms"]
        save(); stream.close()
    return out
