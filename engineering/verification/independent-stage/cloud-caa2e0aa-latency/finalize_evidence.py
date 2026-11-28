#!/usr/bin/env python3
"""Build caa2 failure analysis and a selected, byte-verifiable raw evidence bundle."""
import collections
import datetime
import hashlib
import json
import pathlib
import tarfile

DEST = pathlib.Path(__file__).resolve().parent
ROOT = DEST.parent
RUNTIME = DEST / "full/independent-runtime/runtime"
REVISION = "caa2e0aa4998baa9515dec85ae3c2bdc119639fd"
RUN = 46112069026

def read(path):
    return json.loads(path.read_text())

def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def trace(path):
    result = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        data["sourceLine"] = number
        result.append(data)
    return result

log = trace(RUNTIME / "product.stderr.log")
phase = lambda name: [x for x in log if x.get("phase") == name]
summary = read(RUNTIME / "summary.json")
receipt = summary["productReceipt"]
worker_path = next((RUNTIME / "product/profile/Nearpane").glob("spaces-worker-*.jsonl"))
worker = trace(worker_path)
failed = phase("witness-read-rejected")[0]
navigation_failure = phase("navigation-job-failed")[0]
press = receipt["lastExternalR4Press"]["inputUptime"]
end = navigation_failure["uptime"]
completed = [x for x in phase("witness-read-completed") if press < x["uptime"] < end]
requests = phase("worker-request-exit")
second_requests = [x for x in requests if press < x["uptime"] < end]
desktop_reads = [x for x in phase("desktop-read-task-exit") if press < x["uptime"] < end]
after_action = [x for x in phase("after-action-directory-read") if press < x["uptime"] < end]

# Split only top-level elapsed intervals. Reader and native metrics are nested
# diagnostics; they must never be added to these witness intervals a second time.
intervals = []
def add(lo, hi, category, detail=None, priority=10):
    if hi > lo:
        intervals.append(dict(start=lo, end=hi, category=category, detail=detail, priority=priority))

for w in completed:
    add(w["uptime"] - w["durationMS"] / 1000, w["uptime"], "completed-full-witness",
        dict(sequence=w["sequence"], sourceLine=w["sourceLine"]))
failure_start = failed["uptime"] - failed["durationMS"] / 1000
add(failure_start, failed["uptime"], "rejected-full-witness", dict(sourceLine=failed["sourceLine"]))
ops = {2: "worker-readback", 3: "worker-hide", 4: "worker-show", 6: "worker-health", 13: "worker-release"}
for x in second_requests:
    add(x["requestStartUptime"], x["uptime"], ops.get(x["operation"], str(x["operation"])),
        dict(operation=x["operation"], status=x["status"], sourceLine=x["sourceLine"]))
last_pre = completed[-1]
assert last_pre["sequence"] == 21
add(last_pre["uptime"], failure_start, "ordinary-focus-WAL-and-guards-inferred-envelope", {
    "classification": "Source control flow plus successful preflight and next post-read; not an isolated AX duration.",
    "preSequence": 21, "targetWindow": 55}, priority=5)
dequeue = next(x for x in phase("navigation-dequeue") if press < x["uptime"] < end)
add(press, dequeue["uptime"], "external-input-delivery-and-navigation-queue", priority=1)
edges = sorted({press, end} | {max(press, x["start"]) for x in intervals if x["end"] > press and x["start"] < end}
               | {min(end, x["end"]) for x in intervals if x["end"] > press and x["start"] < end})
segments = []
totals = collections.defaultdict(float)
for lo, hi in zip(edges, edges[1:]):
    if hi - lo < 1e-9:
        continue
    mid = (lo + hi) / 2
    active = [x for x in intervals if x["start"] <= mid < x["end"]]
    selected = max(active, key=lambda x: x["priority"]) if active else None
    category = selected["category"] if selected else "unattributed-host-bookkeeping-and-scheduling"
    ms = (hi - lo) * 1000
    totals[category] += ms
    segments.append(dict(start=lo, end=hi, milliseconds=ms, category=category,
                         detail=selected["detail"] if selected else None))
elapsed = (end - press) * 1000
assert abs(sum(totals.values()) - elapsed) < 1e-6

comparison = read(DEST / "comparison.json")
current = next(x for x in comparison if x["name"] == "caa2/full")
successful = [x for x in receipt["events"] if x["phase"] == "R4SwitchConfirmed"]
show = next(x for x in requests if x["operation"] == 4)
release = next(x for x in requests if x["operation"] == 13)
ordinary = read(RUNTIME / "config.json")
fixture_a = read(RUNTIME / "FixtureA/state.json")
fixture_b = read(RUNTIME / "FixtureB/state.json")
analysis = {
    "schema": 1, "revision": REVISION, "runID": RUN, "jobID": 140877585315,
    "sourceSummary": str(RUNTIME / "summary.json"), "sourceTrace": str(RUNTIME / "product.stderr.log"),
    "workerTrace": str(worker_path),
    "sampling": summary["hostSampling"], "directEngine": summary["engine"],
    "r4": {
        "status": receipt["status"], "reason": receipt["reason"],
        "actualInputs": receipt["actualR4Inputs"], "confirmed": len(successful),
        "successfulSteps": successful,
        "oneShotRetryEvents": [x for x in log if "witness-initial-directory-retry" in x.get("phase", "")],
        "oneShotRetryTriggered": any("witness-initial-directory-retry" in x.get("phase", "") for x in log),
        "scope": "One singleton-cycle confirmation, not a completed full R4 round trip or general reliability/latency qualification."
    },
    "firstFailure": {
        "witness": failed, "navigationFailure": navigation_failure,
        "operationStage": "First coordinator complete post-confirmation after ordinary focus of window 55, following a successful SHOW and its two completed post-witnesses.",
        "stageInference": {
            "basis": "StageGroupCoordinator.perform(.focus) consumes sequence21 as fresh preflight, calls StageEngineSession.dispatch(.focus) -> witness.ordinary -> StageHostWindow.perform, then begins confirmation 0. ordinary returns no coordinatedPost; this next full read rejects before completing.",
            "sourcePaths": ["Sources/NearpaneCore/StageGroupCoordinator.swift", "Sources/NearpaneCore/StageWindowEngine.swift", "Sources/NearpaneUI/StageWindowEngineWitness.swift", "Sources/NearpaneOrdinaryWindowController/StageHostWindow.swift"],
            "limitation": "No isolated focus begin/end trace; the 290ms envelope also contains WAL, guards, and scheduling."
        },
        "sequenceMap": {
            "18": "SHOW preflight", "19": "SHOW engine independent post-witness reused as coordinator confirmation 0",
            "20": "SHOW coordinator confirmation 1", "21": "focus preflight",
            "rejectedWithSequence21": "focus coordinator confirmation 0; sequence does not increment on rejected read"
        },
        "noNextHideSubmitted": not any(x["operation"] == 3 and x["uptime"] > show["uptime"] for x in requests),
        "retryIneligible": "Existing bindings3/claims1 and sequence21; initial-only retry must not apply.",
        "window82": {
            "pid": 35942, "fixture": "FixtureA", "authorizedWindows": [53, 55, 56], "authorized": False,
            "fixtureAOriginalWindows": [w["number"] for w in ordinary["fixtures"][0]["windows"]],
            "fixtureAStateWindows": [w["number"] for w in fixture_a["windows"]],
            "fixtureALastCreatedSequence": fixture_a["lastCreatedSequence"],
            "fixtureALastCreatedIndex": fixture_a["lastCreatedIndex"],
            "observed": "catalog issue records only pid/window and changing membership; catalog dropped this row",
            "notRecorded": ["beforeMembership", "afterMembership", "role", "subrole", "CG layer", "frame", "whether harmless"],
            "limitation": "Do not call window82 a script-created document, transient panel, tooltip, or harmless surface."
        }
    },
    "secondInputFailureTimeline": {
        "inputUptime": press, "navigationFailureUptime": end, "elapsedMS": elapsed,
        "isSuccessfulLatency": False, "nonOverlappingWallTimeMS": dict(totals), "segments": segments,
        "sumMS": sum(totals.values()), "sumMatchesMeasurement": abs(sum(totals.values()) - elapsed) < 1e-6,
        "completedWitnessCount": len(completed), "completedWitnessMS": sum(x["durationMS"] for x in completed),
        "rejectedWitnessMS": failed["durationMS"], "completedWitnesses": completed,
        "nestedDiagnosticsNotAdditive": {
            "desktopReadsEndingInInterval": desktop_reads,
            "afterActionReads": after_action,
            "note": "These reads nest in witness intervals and may include a pre-existing background read. Their full durations do not form a second additive latency decomposition."
        }
    },
    "productionWorker": {
        "terminalRequests": requests,
        "counts": {str(k): v for k,v in collections.Counter(x["operation"] for x in requests).items()},
        "failedTerminalRequests": [x for x in requests if x.get("status") != 0],
        "healthRequestDurationsMS": [x["durationMS"] for x in requests if x["operation"] == 6],
        "show": show,
        "showNativeReadSequence": [x for x in worker if 469 <= x["sourceLine"] <= 488],
        "showNativeInterpretation": {
            "expectedHomeMissMS": 3.743, "hiddenPreflightViewMS": 34.920,
            "latestSeeBeforeMoveMS": 9.752, "twoPostMoveCompleteViewsMS": [69.288,35.298],
            "scope": "One production SHOW passed. Total request210.766ms includes pre-move reads and cannot be compared directly with moved()120ms.",
            "limitation": "No absolute move-return trace. A successful second positive view exits before moved's internal deadline check; do not infer both views ended before120ms."
        },
        "canaryCloseCGReadback": [x for x in worker if x.get("event") == "spacesLaunchEngine" and x.get("phase") == "close-cg-readback"],
        "deadlineClaim": "No production terminal request detail214/217 failure in this one sequence. Expected canary close CG readback includes detail217 before finish-canary succeeds. This is not proof those failure modes are fixed generally."
    },
    "recovery": {
        "workerRelease": release, "workerClosed": [x for x in worker if x.get("event") == "spacesWorker" and x.get("phase") == "closed"],
        "hostFinalShutdown": receipt["stageWindowShutdown"],
        "externalTwoHomeReadback": receipt["shutdownReturnReadback"],
        "fixtureCleanup": summary["fixtureCleanup"], "productCleanup": receipt["cleanup"],
        "distinction": "Actual worker release263.686ms preceded the final shutdown2.656ms. Fixture-owned quits and CI workspace cleanup are separate; no successful second product switch is claimed."
    },
    "allRunReadCosts": {k:current[k] for k in ["witnessMS", "desktopReads", "afterAction", "readerProcesses", "dock"]},
    "limitations": [
        "Cloud runner is not the exact target machine; source/engine success does not qualify real R4 success.",
        "Compare only the first full singleton step with 5e3a1906.936667ms versus caa21890.558125ms, one success each; no aggregate p50/p95 improvement claim.",
        "Initial-only retry was not exercised by either caa2 lane; passing source cases do not constitute live retry validation.",
        "Elapsed intervals are not CPU measurements; full had host sampling disabled."
    ]
}
write(DEST / "full-analysis.json", analysis)

artifacts = read(DEST / "artifact-api-metadata.json")["artifacts"]
paths = {
    15250481947: (DEST / "full.zip", DEST / "full"),
    15250495509: (DEST / "fast.zip", DEST / "fast"),
    15250635224: (DEST / "source/context.zip", DEST / "source/context"),
}
artifact_receipts = []
for a in artifacts:
    if a["id"] not in paths:
        continue
    zip_path, directory = paths[a["id"]]
    sha = digest(zip_path)
    assert a["digest"] == "sha256:" + sha
    assert a["size_in_bytes"] == zip_path.stat().st_size
    artifact_receipts.append({
        "artifactID": a["id"], "artifactName": a["name"], "runID": RUN, "commit": REVISION,
        "providerURL": a["url"], "zipPath": str(zip_path), "extractedPath": str(directory),
        "downloadBytes": zip_path.stat().st_size, "downloadSHA256": sha,
        "providerDigest": a["digest"], "digestMatches": True
    })
write(DEST / "full-download-receipt.json", next(x for x in artifact_receipts if x["artifactID"] == 15250481947))

files = set()
for lane in ["fast", "full"]:
    parent = DEST / lane
    runtime = parent / "independent-runtime/runtime"
    for relative in ["independent-runtime/summary.json", "independent-runtime/runtime/summary.json",
                     "independent-runtime/runtime/product.stderr.log", "independent-runtime/runtime/engine-result.json",
                     "independent-runtime/runtime/engine.stderr.log", "independent-runtime/runtime/fixture-cleanup.json",
                     "independent-runtime/runtime/config.json", "independent-runtime/runtime/product/config.json",
                     "independent-runtime/runtime/product/product-result.json", "independent-runtime/runtime/FixtureA/state.json",
                     "independent-runtime/runtime/FixtureB/state.json"]:
        path = parent / relative
        if path.is_file(): files.add(path)
    for pattern in ["product/profile/Nearpane/spaces-worker-*.jsonl", "product/profile/Nearpane/*.json",
                    "product/r4-press-*.result.json", "product/host-*-sample.json", "product/host-*.sample.txt"]:
        files.update(path for path in runtime.glob(pattern) if path.is_file())
    files.update(path for path in parent.rglob("Nearpane-independent-candidate.json") if path.is_file())
    files.update(path for path in parent.rglob("Nearpane-independent-candidate.sha256") if path.is_file())
source = DEST / "full/independent-source/source"
for name in ["summary.json", "rust.log", "binding-attributes.log", "binding-attributes-build.log", "swift.log",
             "swift.stderr.log", "swift.xml", "windowserver-context.json", "read-only-context.json"]:
    path = source / name
    if path.is_file(): files.add(path)
manifest = {"schema":1,"revision":REVISION,"runID":RUN,"members":[]}
archive = DEST / "runtime-traces-caa2.tar.gz"
with tarfile.open(archive, "w:gz", compresslevel=9) as out:
    for path in sorted(files):
        name = str(path.relative_to(ROOT))
        out.add(path, arcname=name, recursive=False)
        manifest["members"].append({"path":name,"bytes":path.stat().st_size,"sha256":digest(path)})
manifest["archive"] = {"path":str(archive),"bytes":archive.stat().st_size,"sha256":digest(archive),"memberCount":len(files)}
write(DEST / "runtime-traces-manifest.json", manifest)
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
provenance = {
    "schema":1,"repository":"haohongfei2001-png/nearpane","pullRequest":16,"runID":RUN,"commit":REVISION,
    "baselineCommits":["5e3a7ea4b0adceae401ef222a79f7d1887268324","1e5d357a6649fc8afb64b97334769bc00eef9379"],
    "baselineProvenance":[str(ROOT/"5e3a/provenance.json"),str(ROOT/"1e5d/provenance.json")],
    "createdUTC":now,"artifacts":artifact_receipts,"workflowJobs":str(DEST/"workflow-jobs.json"),
    "apiMetadata":str(DEST/"artifact-api-metadata.json"),"sourceGateAudit":str(DEST/"source/audit.json"),
    "derivedFiles":{name:str(DEST/name) for name in ["comparison.json","click-timelines.json","full-analysis.json","fast-analysis.json","recompute.py","finalize_evidence.py"]},
    "selectedRawEvidence":{"archivePath":str(archive),"archiveBytes":archive.stat().st_size,"archiveSHA256":digest(archive),
                           "members":len(files),"manifestPath":str(DEST/"runtime-traces-manifest.json")},
    "dataFrozenUTC":now
}
write(DEST / "provenance.json", provenance)
print(json.dumps({"r4Inputs":receipt["actualR4Inputs"],"confirmed":len(successful),"failureElapsedMS":elapsed,
                  "failurePartitionMS":dict(totals),"archive":manifest["archive"]},indent=2))
