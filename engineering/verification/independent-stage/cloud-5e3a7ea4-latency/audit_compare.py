#!/usr/bin/env python3
"""Summarize original R4 receipts without treating direct engine tests as R4."""
import collections
import json
import pathlib
import statistics
import sys

ROOT = pathlib.Path(__file__).resolve().parent


def rows(path):
    result = []
    for line in path.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return result


def stats(values):
    values = [float(v) for v in values if isinstance(v, (int, float))]
    if not values:
        return {"count": 0}
    return {"count": len(values), "total": round(sum(values), 3),
            "median": round(statistics.median(values), 3), "max": round(max(values), 3)}


def measure(xs, fields):
    return {f: stats(x.get(f) for x in xs) for f in fields}


def audit(name):
    runtime = ROOT / name / "independent-runtime/runtime"
    s = json.loads((runtime / "summary.json").read_text())
    p = s["productReceipt"]
    log = rows(runtime / "product.stderr.log")
    phase = lambda value: [x for x in log if x.get("phase") == value]
    witness = phase("witness-read-completed")
    reads = phase("desktop-read-task-exit")
    after = phase("after-action-directory-read")
    confirm = [x for x in p["events"] if x.get("phase") == "R4SwitchConfirmed"]
    failed = phase("navigation-job-failed")
    starts = phase("desktop-overview-reader-started")
    reaped = phase("desktop-overview-reader-reaped")
    for start in starts:
        end = next((x["uptime"] for x in reaped if x.get("pid") == start["pid"]
                    and x["uptime"] > start["uptime"]), float("inf"))
        start["nativeReplies"] = sum(start["uptime"] <= x.get("nativeBeganUptime", -1) < end
                                      for x in reads)
        start["reapedInTrace"] = end != float("inf")
    windows = []
    for c in confirm:
        lo = c["uptime"] - c["pressToDoubleReadMS"] / 1000
        ws = [w for w in witness if lo <= w["uptime"] <= c["uptime"]]
        windows.append({"step": c["step"], "latencyMS": c["pressToDoubleReadMS"],
                        "witnessCompletionsBeforeFixtureConfirmation": len(ws),
                        "witnessCostMS": measure(ws, ["durationMS", "openingDirectoryMS",
                         "bindingMS", "physicalWindowsMS", "closingDirectoryMS"])})
    worker_faults = []
    for path in (runtime / "product/profile/Nearpane").glob("spaces-worker-*.jsonl"):
        worker_faults += [x for x in rows(path) if x.get("event") in
                         ["spacesHealthReadFailed", "spacesLeaseFault", "spacesLateHealthFailure"]]
    return {
        "name": name, "overall": s.get("overall"), "directEngine": s.get("engine"),
        "r4": {"status": p["status"], "reason": p.get("reason"),
               "inputs": p.get("actualR4Inputs"), "confirmed": len(confirm),
               "switchLatencyMS": p.get("switchLatencyMS"), "steps": windows,
               "failedNavigation": failed, "cleanup": p.get("cleanup"),
               "hostShutdown": p.get("stageWindowShutdown"),
               "externalHomeConfirmed": p.get("shutdownReturnReadback", {}).get("confirmed"),
               "lifecycle": {k: s.get(k) for k in ["newWindowLifecycle", "windowCloseLifecycle",
                   "applicationExitLifecycle", "groupMergeSplit", "hostCrashRecovery"]}},
        "witnessMS": measure(witness, ["durationMS", "openingDirectoryMS", "bindingMS",
                                       "physicalWindowsMS", "closingDirectoryMS"]),
        "desktopReads": {"exits": len(reads),
                         "completed": sum(x.get("completed", False) for x in reads),
                         "receivedReply": sum(x.get("receivedReply", False) for x in reads),
                         "MS": measure(reads, ["taskQueueMS", "readerAwaitMS", "nativeDurationMS",
                         "nativeBeginAfterRequestMS", "nativeEndToReturnMS", "groupProjectionMS",
                         "observeDirectoryMS", "remainingProcessingMS"])},
        "afterAction": {"count": len(after), "hadPrior": sum(x.get("hadPrior", False) for x in after),
                        "reusedPrior": sum(x.get("reusedPrior", False) for x in after),
                        "MS": measure(after, ["durationMS", "priorWaitMS", "freshReadMS"])},
        "readerProcesses": {"started": starts, "reaped": reaped},
        "dock": {"polls": len(phase("dispatch-dock-poll-completed")),
                 "expired": phase("dispatch-dock-observation-expired")},
        "workerFaults": worker_faults,
        "failedWorkerRequests": [x for x in phase("worker-request-exit") if x.get("status") != 0],
    }


if __name__ == "__main__":
    names = sys.argv[1:] or ["fast", "full", "5e3a/fast", "5e3a/full"]
    data = [audit(n) for n in names if (ROOT / n / "independent-runtime/runtime/summary.json").exists()]
    out = ROOT / "5e3a/comparison.json"
    out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    for x in data:
        r = x["r4"]
        print(x["name"], "R4", r["confirmed"], "/", r["inputs"],
              "latencies", [round(s["latencyMS"], 1) for s in r["steps"]],
              "witnesses", x["witnessMS"]["durationMS"]["count"],
              "reader processes", len(x["readerProcesses"]["started"]),
              "released", r["hostShutdown"].get("released"))
