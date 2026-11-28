"""Correlate a read-only witness with the registered window's own migration journal."""
from contextlib import contextmanager
import hashlib
import json
import math
from pathlib import Path
import subprocess
import time


def registration_bound(header, owner, digest, challenge, home):
    return (isinstance(header, dict) and header.get("event") == "bound" and header.get("cdhash") == digest
            and header.get("challenge") == challenge and type(home) is int and home > 0
            and type(header.get("home")) is int and header["home"] == home
            and all(type(owner.get(k)) is int and type(header.get(k)) is int and owner[k] > 0 and header[k] == owner[k]
                    for k in ("pid", "birth", "window")))


def witnessed(row, space, home):
    return (row.get("event") == "sample" and all(type(row.get(key)) is int for key in ("space","spaceHits","homeHits"))
            and row["space"] == space and row["spaceHits"] == 1
            and row.get("homeHits") == int(space == home))


@contextmanager
def observe(reader, work, challenge, owner, digest, home, report):
    path = work / "independent-membership.jsonl"
    args = [reader, "--trace-membership", challenge, str(owner["pid"]), str(owner["birth"]), str(owner["window"]), digest]
    with path.open("xb") as output, subprocess.Popen(args, stdin=subprocess.PIPE, stdout=output) as child:
        try:
            ready = False
            deadline = time.monotonic() + 4
            with path.open("rb") as stream:
                while child.poll() is None and time.monotonic() < deadline:
                    stream.seek(0)
                    lines = [stream.readline(4096) for _ in range(3)]
                    if all(line.endswith(b"\n") for line in lines):
                        try:
                            header, first, second = (json.loads(line) for line in lines)
                            ready = (registration_bound(header, owner, digest, challenge, home)
                                     and witnessed(first, home, home) and witnessed(second, home, home))
                        except (ValueError, TypeError, AttributeError):
                            ready = False
                        break
                    time.sleep(.03)
            report["independentTraceReady"] = ready
            yield ready
        finally:
            child.stdin.close()
            try:
                report["independentTraceExit"] = child.wait(timeout=6)
            except subprocess.TimeoutExpired:
                # Only the private read-only sampler is our child. The owning app and Host finish independently.
                child.kill()
                report["independentTraceExit"] = child.wait()
            report["independentTraceFile"] = path.name
            report["independentTraceSHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()


def evaluate(work, report):
    try:
        path = Path(work) / "independent-membership.jsonl"
        if path.stat().st_size > 2_000_000 or report["independentTraceExit"] != 0:
            return {"status": "UNKNOWN", "reason": "witnessDidNotClose"}
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != report["independentTraceSHA256"]:
            return {"status": "UNKNOWN", "reason": "witnessReceiptChanged"}
        header, *samples, last = [json.loads(line) for line in raw.splitlines()]
        proof = report["fixtureJournal"]
        archived = proof["archive"]
        actions = {a["event"]: a for a in archived["knownActions"] if a["owner"] == "signedOrdinaryFixture"}
        home, park = archived["originalSpace"], actions["hideResponse"]["space"]
        if (proof["status"] != "PASS" or proof["sameBoot"] is not True or type(park) is not int or home == park or park <= 0
                or not registration_bound(header, report["ownerStart"], report["fixture"]["CDHash"], report["challenge"], home)
                or last != {"event": "closed", "samples": len(samples)} or not 6 <= len(samples) <= 4500):
            return {"status": "UNKNOWN", "reason": "unboundWitnessOrArchive"}
        cuts = [actions[k]["uptime"] for k in ("willHideWindow", "hideResponse", "willReturnWindow", "returnResponse")]
        counts = [0, 0, 0]
        previous = 0
        if not all(math.isfinite(t) for t in cuts) or cuts != sorted(cuts):
            return {"status": "UNKNOWN", "reason": "unboundJournalIntervals"}
        for row in samples:
            start, end = row["start"], row["end"]
            if not (row["event"] == "sample" and math.isfinite(start) and math.isfinite(end) and previous <= start <= end):
                return {"status": "UNKNOWN", "reason": "witnessTimeDiscontinuity"}
            previous = end
            phase = 0 if end < cuts[0] else 1 if cuts[1] <= start and end < cuts[2] else 2 if start >= cuts[3] else None
            if phase is None:  # A sample straddling either dispatch is retained in the raw trace.
                continue
            if not witnessed(row, park if phase == 1 else home, home):
                if phase and not counts[phase]:  # OS membership can settle after the dispatch returns.
                    continue
                status = "FAIL" if witnessed(row, home if phase == 1 else park, home) else "UNKNOWN"
                return {"status": status, "reason": "membershipChangedAfterConfirmation", "phase": phase}
            counts[phase] += 1
        return {"status": "PASS" if min(counts) >= 2 else "UNKNOWN", "counts": dict(zip(("before", "parked", "returned"), counts))}
    except (KeyError, TypeError, IndexError, AttributeError, OSError, ValueError, OverflowError):
        return {"status": "UNKNOWN", "reason": "independentMembershipTraceIncomplete"}
