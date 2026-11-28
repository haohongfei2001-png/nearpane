#!/usr/bin/env python3
"""Reconstruct mutually exclusive wall-time intervals from existing trace stamps.

This is elapsed-time attribution, not sampled CPU attribution. Nested reader
metrics are deliberately kept separate from the additive timeline.
"""
import collections
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
OPS = {2: "worker-readback", 3: "worker-hide", 4: "worker-show",
       6: "worker-health", 8: "worker-launch-canary", 9: "worker-close-canary", 13: "worker-release"}


def load_log(path):
    out = []
    for line in path.read_text().splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def build(name):
    p = ROOT / name / "independent-runtime/runtime"
    receipt = json.loads((p / "summary.json").read_text())["productReceipt"]
    log = load_log(p / "product.stderr.log")
    phase = lambda v: [x for x in log if x.get("phase") == v]
    ws = sorted(phase("witness-read-completed"), key=lambda x: x["sequence"])
    wr = phase("worker-request-exit")
    reads = {x["requestRevision"]: x for x in phase("desktop-read-task-exit")}
    intervals = []

    def add(lo, hi, category, detail, priority=10):
        if hi > lo:
            intervals.append({"from": lo, "to": hi, "category": category,
                              "detail": detail, "priority": priority})

    for w in ws:
        lo = w["uptime"] - w["durationMS"] / 1000
        for f, category in [("openingDirectoryMS", "witness-opening-directory"),
                            ("bindingMS", "witness-binding-and-roster"),
                            ("physicalWindowsMS", "witness-original-AX-and-physical"),
                            ("closingDirectoryMS", "witness-closing-directory-and-finalization")]:
            hi = lo + w[f] / 1000
            add(lo, min(hi, w["uptime"]), category, {"sequence": w["sequence"], "traceField": f})
            lo = hi
    for x in wr:
        add(x["requestStartUptime"], x["uptime"], OPS.get(x["operation"], "worker-operation-"+str(x["operation"])),
            {"operation": x["operation"], "intent": x["intent"], "status": x.get("status"), "detail": x.get("detail")})
    for x in phase("worker-initializer-enter"):
        end = next((y for y in phase("worker-lifecycle-durable") if y["uptime"] >= x["uptime"]), None)
        if end:
            add(x["uptime"], end["uptime"], "worker-process-start-and-durable-owner", {"pid": end["pid"]})
    # A changed focus in consecutive complete witnesses with no intervening
    # worker call brackets ordinary(). The envelope also includes WAL and guards.
    for a, b in zip(ws, ws[1:]):
        lo, hi = a["uptime"], b["uptime"] - b["durationMS"] / 1000
        if (a.get("focusPID"), a.get("focusWindow")) == (b.get("focusPID"), b.get("focusWindow")):
            continue
        if any(max(lo, x["requestStartUptime"]) < min(hi, x["uptime"]) for x in wr):
            continue
        add(lo, hi, "ordinary-focus-and-WAL-envelope-inferred", {
            "beforeSequence": a["sequence"], "afterSequence": b["sequence"],
            "oldFocus": [a.get("focusPID"), a.get("focusWindow")],
            "newFocus": [b.get("focusPID"), b.get("focusWindow")],
            "limitation": "Upper bound including journal/guards; no isolated focus start/end trace."}, 5)
    caller = []
    for x in phase("after-action-directory-read"):
        r = reads.get(x.get("receivedRevision"))
        if not r:
            continue
        lo = max(r["uptime"], x["boundaryUptime"])
        hi = x["uptime"]
        directory_parts = [v for v in intervals if v["category"].startswith(("witness-opening", "witness-closing"))]
        for part in directory_parts:
            left, right = max(lo, part["from"]), min(hi, part["to"])
            add(left, right, "directory-task-exit-to-caller-resumption", {
                "requestRevision": x.get("receivedRevision"), "sequence": part["detail"]["sequence"],
                "afterActionBoundary": x["boundaryUptime"], "taskExit": r["uptime"],
                "afterActionReturn": hi}, 20)
        caller.append({"requestRevision": x.get("receivedRevision"), "boundary": x["boundaryUptime"],
                       "taskExit": r["uptime"], "return": hi, "gapMS": max(0, (hi-lo)*1000),
                       "afterActionMS": x["durationMS"], "taskDurationMS": r["durationMS"],
                       "nativeMS": r.get("nativeDurationMS"), "projectionMS": r.get("groupProjectionMS")})
    result = []
    for c in [x for x in receipt["events"] if x.get("phase") == "R4SwitchConfirmed"]:
        hi = c["uptime"]
        lo = hi - c["pressToDoubleReadMS"] / 1000
        # Each real input is paired with its observed navigation dequeue.
        dequeue = next((x for x in phase("navigation-dequeue") if lo <= x["uptime"] <= hi), None)
        local = list(intervals)
        if dequeue:
            local.append({"from": lo, "to": dequeue["uptime"], "category": "external-input-delivery-and-navigation-queue",
                          "detail": {"job": dequeue.get("job")}, "priority": 1})
        relevant = [x for x in local if x["from"] < hi and x["to"] > lo]
        edges = sorted({lo, hi} | {max(lo, x["from"]) for x in relevant} | {min(hi, x["to"]) for x in relevant})
        segments, totals = [], collections.defaultdict(float)
        for left, right in zip(edges, edges[1:]):
            if right-left < 1e-9:
                continue
            middle = (left+right)/2
            active = [x for x in relevant if x["from"] <= middle < x["to"]]
            chosen = max(active, key=lambda x: x["priority"]) if active else None
            category = chosen["category"] if chosen else "unattributed-host-bookkeeping-scheduling-or-fixture-polling"
            ms = (right-left)*1000
            totals[category] += ms
            segments.append({"from": left, "to": right, "milliseconds": ms, "category": category,
                             "detail": chosen["detail"] if chosen else None})
        task_rows = [x for x in reads.values() if lo <= x["uptime"] <= hi]
        nested = {k: sum(x.get(k,0) for x in task_rows) for k in
                  ["readerAwaitMS", "nativeDurationMS", "nativeBeginAfterRequestMS", "nativeEndToReturnMS",
                   "groupProjectionMS", "observeDirectoryMS", "taskQueueMS", "remainingProcessingMS"]}
        result.append({"step": c["step"], "inputUptime": lo, "doubleReadUptime": hi,
                       "pressToDoubleReadMS": c["pressToDoubleReadMS"],
                       "nonOverlappingWallTimeMS": dict(totals), "sumMS": sum(totals.values()),
                       "sumMatchesMeasurement": abs(sum(totals.values())-c["pressToDoubleReadMS"]) < 0.01,
                       "segments": segments,
                       "nestedDesktopDiagnosticsDoNotAddToWallTime": nested,
                       "callerResumptions": [x for x in caller if lo <= x["return"] <= hi]})
    return {"name": name, "sourceSummary": str(p / "summary.json"), "sourceTrace": str(p / "product.stderr.log"),
            "notes": ["All additive timeline intervals are clipped to external AX press start and the fixture's second physical confirmation.",
                      "Witness trace durations include nested directory and physical reads; no nested totals are added twice.",
                      "Task-exit stamp precedes final trace serialization/write; the caller gap does not identify its blocking cause.",
                      "Ordinary focus is an inferred envelope including WAL and guards, not a measured pure AX focus duration.",
                      "Elapsed intervals do not prove CPU occupancy or exclude sampling perturbation.",
                      "Candidate host and overview reader started before the measured click; their earlier startup is not charged to the click."],
            "steps": result}


if __name__ == "__main__":
    data = [build(n) for n in ["fast", "full", "5e3a/fast", "5e3a/full"]
            if (ROOT / n / "independent-runtime/runtime/summary.json").exists()]
    (ROOT / "5e3a/click-timelines.json").write_text(json.dumps(data, ensure_ascii=False, indent=2)+"\n")
    for d in data:
        for s in d["steps"]:
            print(d["name"], s["step"], {k: round(v, 2) for k, v in s["nonOverlappingWallTimeMS"].items()},
                  "sum", round(s["sumMS"], 2), "checked", s["sumMatchesMeasurement"])
