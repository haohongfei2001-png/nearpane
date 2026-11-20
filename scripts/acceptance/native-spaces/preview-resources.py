#!/usr/bin/env python3
"""Sample only an enrolled installed Host during the existing paired preview trial."""
import argparse
import ctypes as C
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from residence import Usage, seconds_per_tick
from session_evidence import process_path

HOST = Path("/Applications/Nearpane.app/Contents/MacOS/NearpaneHost")


def read(path):
    try:
        return json.loads(path.read_bytes())
    except (FileNotFoundError, ValueError):
        return {}


def sample(trial, output):
    if output.exists():
        raise ValueError("Choose a new receipt path")
    lib = C.CDLL("/usr/lib/libproc.dylib")
    seconds = seconds_per_tick()
    rows = []
    identity = None
    reason = "session ended"
    until = time.monotonic() + 300
    while time.monotonic() < until:
        session = read(trial / "profile/profile-session.json")
        if "commandExit" in session or session.get("dailyHostRestored"):
            break
        preview = read(trial / "native/preview/result.json")
        host = preview.get("installed", {})
        pid = session.get("isolatedPID")
        if not (session.get("isolatedLockConfirmed") and isinstance(pid, int) and pid > 1 and
                host.get("pid") == pid and host.get("source") == session.get("source") and
                session.get("installed") == "/Applications/Nearpane.app"):
            time.sleep(.5)
            continue
        usage = Usage()
        try:
            if process_path(pid).resolve() != HOST or lib.proc_pid_rusage(pid, 0, C.byref(usage)):
                reason = "process disappeared before read"
                break
        except (OSError, ValueError):
            reason = "process reference unavailable"
            break
        witnessed = (pid, usage.start, host.get("cdHash"))
        if not all(witnessed) or (identity is not None and witnessed != identity):
            reason = "enrolled process changed"
            break
        identity = witnessed
        rows.append(dict(uptime=time.monotonic(), cpuSeconds=(usage.user + usage.system) * seconds,
                         residentBytes=usage.resident, footprintBytes=usage.footprint))
        time.sleep(.75)
    result = dict(status="SAMPLED" if len(rows) >= 2 else "NOT_MEASURED", reason=reason,
                  hostIdentity=identity, samples=rows, intervalSeconds=.75, warmedBenchmark="NOT_RUN",
                  scope="Darwin cumulative resource counters. Intervals include test preparation and polling.")
    with output.open("x") as f:
        json.dump(result, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trial", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    sample(args.trial, args.output)
