#!/usr/bin/env python3
"""Read-only evaluation of paired physical Apple Stage Manager and installed Nearpane observations."""

import argparse
from collections import defaultdict
from hashlib import sha256
import json
import math
from pathlib import Path

from witness import EvidenceError, artifact, channel, digest, identity, integer, real, require, transition, uuid

SYSTEMS = ("apple", "nearpane")
STAGES = {"single": 1, "ten": 10, "fifty": 50, "soak": 1000}
WORKLOADS = {
    "twoGroupsOneWindow",
    "threeGroupsThreeWindowsTwoApps",
    "sameAppSiblings",
    "twoWindowComposite",
    "fiveWindowLoad",
    "unmanagedAndPreMinimized",
    "crossApp",
    "modalSheet",
    "menu",
    "popover",
    "notification",
}
ENV_KEYS = (
    "hardwareSHA256",
    "bootUUID",
    "osVersion",
    "build",
    "sipEnabled",
    "displays",
    "activeDisplay",
    "powerMode",
    "inputDeviceSHA256",
    "warmCold",
    "applicationRevisions",
    "documentSHA256",
    "initialGeometry",
    "fixtureRevision",
    "observerRevision",
    "permissions",
    "highRefreshSupported",
)
RECOVERIES = {"sleepWake", "hotPlug", "appCrashRelaunch"}
VALID_PRE_EXCLUSIONS = {
    "externalInputBeforeDispatch",
    "changedTopologyBeforeDispatch",
    "cancelledBeforeDispatch",
}


def distribution(values):
    data = sorted(values)
    require(bool(data), "noValidSamples", "NOT_RUN")
    return {f"p{n}": data[math.ceil(n * len(data) / 100) - 1] for n in (50, 95, 99)}


def status(issues):
    return next(
        (
            value
            for value in ("FAIL", "UNKNOWN", "NOT_COMPARABLE", "NOT_RUN")
            if any(item["status"] == value for item in issues)
        ),
        "PASS",
    )


def environment(root, ref):
    env = artifact(root, ref)
    require(env["physicalMac"] is True and env["hosted"] is False, "requiresPhysicalMac", "NOT_COMPARABLE")
    for key in ENV_KEYS:
        require(key in env and env[key] is not None and env[key] != "", "missingEnvironment:" + key)
    uuid(env["bootUUID"])
    for key in ("hardwareSHA256", "inputDeviceSHA256", "fixtureRevision", "observerRevision"):
        digest(env[key])
    require(
        env["applicationRevisions"] and env["documentSHA256"] and env["initialGeometry"],
        "missingIdenticalWorkload",
    )
    for value in env["documentSHA256"]:
        digest(value)
    require(
        env["warmCold"] in ("warm", "cold")
        and env["permissions"].get("screenRecording") is True
        and env["permissions"].get("accessibility") is True,
        "missingObserverPermissions",
    )
    displays = env["displays"]
    require(isinstance(displays, list) and bool(displays), "missingPhysicalDisplays")
    ids = set()
    for display in displays:
        ident = digest(display["idSHA256"])
        require(ident not in ids and display["physical"] is True, "duplicateOrVirtualDisplay")
        ids.add(ident)
        for key in ("scale", "nominalHz", "pixelWidth", "pixelHeight"):
            real(display[key], "invalidDisplayConfiguration", 0.001)
        require(display["colorSpace"] and len(display["originPoints"]) == 2, "incompleteDisplayConfiguration")
    require(env["activeDisplay"] in ids, "selectedDisplayNotFound")
    return env


def shell_identity(env, system, candidate):
    install = env["systemUnderTest"]
    owner = install["controlOwner"]
    identity(owner)
    if system == "nearpane":
        require(
            install["bundlePath"] == "/Applications/Nearpane.app"
            and digest(install["sha256"]) == candidate
            and install["signatureVerified"] is True
            and install["teamID"] == "ZB9D4T66QB",
            "signedInstalledCandidateUnavailable",
        )
        require(
            owner["bundleID"] == "com.holdsnow.nearpane.host"
            and owner["path"] == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost",
            "installedHostControlOwnerUnconfirmed",
        )
    else:
        require(
            install["owner"] == "AppleStageManager"
            and install["signatureVerified"] is True
            and install["appleSigned"] is True,
            "nativeAppleReferenceUnavailable",
            "NOT_COMPARABLE",
        )
        require(
            (owner["bundleID"], owner["path"])
            in {
                ("com.apple.dock", "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
                (
                    "com.apple.WindowManager",
                    "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager",
                ),
            },
            "systemStripControlOwnerUnconfirmed",
            "NOT_COMPARABLE",
        )


def read_run(root, run, system, candidate, seen):
    env = environment(root, run["environment"])
    shell_identity(env, system, candidate)
    tag = uuid(run["session"])
    boot = env["bootUUID"]
    active = next(d for d in env["displays"] if d["idSHA256"] == env["activeDisplay"])
    actor, events = channel(root, run["input"], "physical-input", tag, boot)
    watcher, pictures = channel(root, run["observations"], "display-ax-cg", tag, boot)
    reporter, owners = channel(root, run["owners"], "owner-receipts", tag, boot)
    require(len({actor[:2], watcher[:2], reporter[:2]}) == 3, "observerIsActuatorOrReceiver")

    def index(rows):
        mapping = {uuid(row["intent"]): row for row in rows}
        require(len(mapping) == len(rows), "duplicateChannelIntent")
        return mapping

    pictures, owners = index(pictures), index(owners)
    valid, excluded = [], []
    last_seq = last_end = 0
    for event in events:
        intent = uuid(event["intent"])
        require(intent not in seen and event["session"] == tag, "replayedIntentOrSession")
        seen.add(intent)
        sequence = integer(event["sequence"], "missingInputSequence", last_seq + 1)
        last_seq = sequence
        if "excluded" in event:
            require(
                event["excluded"] in VALID_PRE_EXCLUSIONS
                and event["dispatchIssued"] is False
                and intent not in pictures
                and intent not in owners,
                "attemptedTransitionCannotBeExcluded",
            )
            excluded.append({"intent": intent, "reason": event["excluded"]})
            continue
        require(intent in pictures and intent in owners, "missingIndependentChannel")
        proof = pictures.pop(intent)
        owner = owners.pop(intent)
        hit = proof["inputHit"]
        registered = env["systemUnderTest"]["controlOwner"]
        require(
            identity(hit) == identity(registered)
            and hit["bundleID"] == registered["bundleID"]
            and integer(hit["cgNumber"], "inputHitNumberUnavailable", 1) == event["hitCGNumber"]
            and digest(hit["controlSHA256"]) == digest(event["targetControlSHA256"])
            and hit["displaySHA256"] == env["activeDisplay"]
            and hit["hitAtInput"] is True,
            "physicalInputDidNotHitBoundSystemControl",
            "NOT_COMPARABLE",
        )
        require(
            event["clockDomain"] == boot
            and identity(owner["writer"])[:2] != watcher[:2]
            and identity(owner["writer"])[:2] != actor[:2],
            "observerOrClockNotIndependent",
        )
        require(
            event["inputSource"] == "hardwareHID" and event["deviceSHA256"] == env["inputDeviceSHA256"],
            "inputDeviceOrPhysicalEventUnconfirmed",
            "NOT_COMPARABLE",
        )
        marker = ("marker", digest(event["markerSHA256"]))
        require(marker not in seen, "reusedInputMarker")
        seen.add(marker)
        measured = transition(event, proof, owner, active["scale"])
        require(
            measured["inputNS"] > last_end and measured["direction"][0] != measured["direction"][1],
            "invalidDirectionOrInputClock",
        )
        last_end = measured["inputNS"] + max(measured["settledMS"], measured["interactiveMS"]) * 1e6
        measured["block"] = integer(event["block"], "missingCounterbalancedBlock", 1)
        measured["pair"] = integer(event["pair"], "missingPairIndex", 1)
        valid.append(measured)
    require(not pictures and not owners, "orphanDisplayOrOwnerReceipt")
    return env, active, valid, excluded


ANCHOR = ("hardwareSHA256", "osVersion", "build", "sipEnabled", "fixtureRevision", "observerRevision")


def prerequisites(root, qualification, candidate, seen, anchor=None):
    q = qualification
    require(
        q.get("status") == "PASS",
        "visibilityOrInputGate:" + str(q.get("reason", q.get("status", "missing"))),
        "NOT_RUN",
    )
    require(
        q["kind"] == "installed-stagegroup-safety" and q["candidateSHA256"] == candidate,
        "qualificationCandidateMismatch",
    )
    result = {}
    require(q.get("provider") in ("corner", "spaces"), "qualifiedProviderUnavailable")
    baseline = None
    for key, count in STAGES.items():
        require(key in q.get("phases", {}), "missingQualificationPhase:" + key, "NOT_RUN")
        env, _, rows, excluded = read_run(root, q["phases"][key], "nearpane", candidate, seen)
        if q["provider"] == "spaces":
            require(
                env["build"] == "26A428"
                and env["osVersion"] in ("27.0", "27.0.0")
                and env["sipEnabled"] is True,
                "spacesTargetBuildOrSIPUnqualified",
                "NOT_COMPARABLE",
            )
        conditions = {key: env[key] for key in ANCHOR}
        if baseline is None:
            baseline = conditions
        require(baseline == conditions, "qualificationHardwareBuildOrCollectorsDiffer", "NOT_COMPARABLE")
        require(len(rows) == count and not excluded, "incompleteSafetyPhase:" + key, "NOT_RUN")
        result[key] = len(rows)
    if anchor is not None:
        anchor.update(baseline)
    return result


def workload_classes(scenario, rows):
    """Derive group shapes from the actual transitioned window lifetimes, then check ancillary witnesses."""
    groups, applications = {}, {}
    for row in rows:
        for group, members in zip(row["direction"], (row["sourceMembers"], row["targetMembers"])):
            require(groups.setdefault(group, members) == members, "groupMembersChangedWithinWorkload")
        for lease, (process, window) in row["memberWindows"].items():
            require(
                applications.setdefault(lease, (process, window)) == (process, window),
                "workloadWindowWasReplaced",
            )
    sizes = [len(members) for members in groups.values()]
    processes = {process for process, _ in applications.values()}
    facts = set()
    if len(sizes) == 2 and sizes == [1, 1]:
        facts.add("twoGroupsOneWindow")
    if len(sizes) == 3 and all(size == 3 for size in sizes) and len(processes) >= 2:
        facts.add("threeGroupsThreeWindowsTwoApps")
    if 2 in sizes:
        facts.add("twoWindowComposite")
    if len(applications) == 5:
        facts.add("fiveWindowLoad")
    if len(processes) >= 2:
        facts.add("crossApp")
    for group, members in groups.items():
        same = {applications[key][0] for key in members}
        if any(
            same & {applications[key][0] for key in other} for name, other in groups.items() if name != group
        ):
            facts.add("sameAppSiblings")
    for item in scenario.get("bystanders", []):
        identity(item)
        integer(item["window"], "invalidBystanderCGID", 1)
        require(
            item["unmanaged"] is True and digest(item["beforeSHA256"]) == digest(item["afterSHA256"]),
            "bystanderChangedOrUnverified",
            "FAIL",
        )
    bystanders = scenario.get("bystanders", [])
    if any(item["preMinimized"] is True for item in bystanders) and any(
        item["preMinimized"] is False for item in bystanders
    ):
        facts.add("unmanagedAndPreMinimized")
    roles = {
        "AXSheet": "modalSheet",
        "AXMenu": "menu",
        "AXPopover": "popover",
        "AXNotification": "notification",
    }
    trials = {row["intent"] for row in rows}
    for surface in scenario.get("systemSurfaces", []):
        require(
            surface["intent"] in trials and surface["role"] in roles and surface["observedNS"] > 0,
            "unboundSystemSurface",
        )
        require(
            identity(surface) in processes
            or (
                surface["role"] == "AXNotification"
                and surface["appleSigned"] is True
                and surface["bundleID"] == "com.apple.notificationcenterui"
            ),
            "unrelatedSystemSurface",
        )
        facts.add(roles[surface["role"]])
    declared = set(scenario["classes"])
    require(bool(declared) and declared <= facts, "declaredWorkloadNotObserved")
    return declared


def compare_order(apple, nearpane):
    def collect(rows):
        data = {(row["block"], row["pair"]): row for row in rows}
        require(len(data) == len(rows), "duplicatePairIndex")
        return data

    a, b = collect(apple), collect(nearpane)
    require(set(a) == set(b), "unmatchedPairedSamples", "NOT_COMPARABLE")
    order = defaultdict(lambda: [[], []])
    for key in a:
        require(a[key]["direction"] == b[key]["direction"], "differentPairedDirections", "NOT_COMPARABLE")
        for i, data in enumerate((a, b)):
            row = data[key]
            order[key[0]][i].append(
                (row["inputNS"], row["inputNS"] + max(row["settledMS"], row["interactiveMS"]) * 1e6)
            )
    previous = end = None
    require(len(order) >= 2, "noCounterbalancedBlock", "NOT_COMPARABLE")
    for block in sorted(order):
        ar, br = order[block]
        first = min(ar)[0] < min(br)[0]
        left, right = (ar, br) if first else (br, ar)
        require(
            max(x[1] for x in left) < min(right)[0]
            and (end is None or end < min(left)[0])
            and first != previous,
            "blockOrderNotCounterbalanced",
            "NOT_COMPARABLE",
        )
        previous, end = first, max(x[1] for x in right)


def bound_check(lower, upper, limit_lower, limit_upper=None):
    limit_upper = limit_lower if limit_upper is None else limit_upper
    if upper <= limit_lower:
        return "PASS"
    return "FAIL" if lower > limit_upper else "UNKNOWN"


def paired_direction(apple, product, hz):
    require(len(apple) == len(product), "unmatchedPairedSamples", "NOT_COMPARABLE")
    require(len(apple) >= 100, "fewerThan100ValidPerSystemPerDirection", "NOT_RUN")
    systems = {}
    for name, series in zip(SYSTEMS, (apple, product)):
        stats = {}
        bounds = {}
        for key, error in (
            ("firstMS", "presentationErrorMS"),
            ("interactiveMS", "interactiveErrorMS"),
            ("settledMS", "presentationErrorMS"),
        ):
            stats[key] = distribution([row[key] for row in series])
            bounds[key] = dict(
                lower=distribution([max(0, row[key] - row[error]) for row in series]),
                upper=distribution([row[key] + row[error] for row in series]),
            )
        intervals = [interval for row in series for interval in row["intervals"]]
        lo = [max(0, x - r["intervalErrorMS"]) for r in series for x in r["intervals"]]
        hi = [x + r["intervalErrorMS"] for r in series for x in r["intervals"]]
        bounds["frameIntervalMS"] = dict(lower=distribution(lo), upper=distribution(hi))
        bounds["worstFrameGapMS"] = dict(lower=max(lo), upper=max(hi))
        bounds["worstSettledMS"] = dict(
            lower=max(r["settledMS"] - r["presentationErrorMS"] for r in series),
            upper=max(r["settledMS"] + r["presentationErrorMS"] for r in series),
        )
        stats.update(
            samples=len(series),
            bounds=bounds,
            frameIntervalMS=distribution(intervals),
            worstFrameGapMS=max(intervals),
            worstSettledMS=max(r["settledMS"] for r in series),
            droppedPercent=100 * sum(r["dropped"] for r in series) / sum(r["expected"] for r in series),
        )
        systems[name] = stats
    native = systems["apple"]["bounds"]
    product = systems["nearpane"]["bounds"]
    checks = {}
    for key, limits in (("firstMS", (100, 150, 250)), ("interactiveMS", (150, 220, 350))):
        for percentile, maximum in zip(("p50", "p95", "p99"), limits):
            checks[key + "_" + percentile] = bound_check(
                product[key]["lower"][percentile], product[key]["upper"][percentile], maximum
            )
        offset = 20 if key == "firstMS" else 30
        checks[key + "_relativeP95"] = bound_check(
            product[key]["lower"]["p95"],
            product[key]["upper"]["p95"],
            1.2 * native[key]["lower"]["p95"] + offset,
            1.2 * native[key]["upper"]["p95"] + offset,
        )
    for key, maximum in (("settledMS", 250), ("frameIntervalMS", 1.25 * 1000 / hz)):
        checks[key + "_p95"] = bound_check(product[key]["lower"]["p95"], product[key]["upper"]["p95"], maximum)
    for key, maximum in (("worstSettledMS", 500), ("worstFrameGapMS", 50)):
        checks[key] = bound_check(product[key]["lower"], product[key]["upper"], maximum)
    checks["droppedPercent"] = "PASS" if systems["nearpane"]["droppedPercent"] <= 1 else "FAIL"
    return dict(status=status([{"status": v} for v in checks.values()]), checks=checks, **systems)


def resource_stats(root, run, env):
    _, samples = channel(root, run["resources"], "process-accounting", run["session"], env["bootUUID"])
    idle = []
    burst = []
    cycle = []
    all_cpu = defaultdict(list)
    generations = {}
    last_interval = {}
    for s in samples:
        mode = s["mode"]
        require(mode in ("idle", "switch", "cycle"), "unknownAccountingPhase")
        a = integer(s["startNS"], "missingResourceStart", 1)
        b = integer(s["endNS"], "missingResourceEnd", a + 1)
        require(a >= last_interval.get(mode, 0), "overlappingResourceIntervals")
        last_interval[mode] = b
        for component in ("engine", "WindowServer", "replayd"):
            process = s[component]
            ident = identity(process)
            require(ident == generations.setdefault(component, ident), "resourceProcessChanged")
            initial = integer(process["cpuStartNS"], "missingKernelUserSystemCPU")
            delta = integer(process["cpuEndNS"], "kernelCPUReversed", initial) - initial
            cpu = 100 * delta / (b - a)
            all_cpu[(mode, component)].append(cpu)
        baseline = s["engineBaseline"]
        base_duration = integer(baseline["durationNS"], "missingBaselineDuration", 1)
        base_cpu = 100 * integer(baseline["cpuNS"], "invalidBaselineCPU") / base_duration
        increment = max(0, all_cpu[(mode, "engine")][-1] - base_cpu)
        if mode == "idle":
            idle.append((a, b, increment))
        elif mode == "switch":
            require(0.95e9 <= b - a <= 1.05e9, "switchCPUBurstIsNotOneSecond", "NOT_COMPARABLE")
            burst.append(increment)
        else:
            resident = integer(s["engine"]["residentBytes"], "missingResidentBytes", 1)
            base_resident = integer(baseline["residentBytes"], "missingBaselineMemory", 1)
            cycle.append((a, b, resident - base_resident))
    require(idle and burst and len(cycle) >= 3, "incompleteCPUOrMemoryCapture")
    duration = sum(b - a for a, b, _ in idle)
    idle_mean = sum((b - a) * v for a, b, v in idle) / duration
    longest = current = 0
    previous = None
    for a, b, value in idle:
        current = ((current if a == previous else 0) + b - a) if value > 5 else 0
        longest = max(longest, current)
        previous = b
    policy = env.get("sustainedIdleSeconds")
    require(
        not longest or (type(policy) in (int, float) and math.isfinite(policy) and policy > 0),
        "sustainedCPUIntervalNotPredeclared",
        "NOT_COMPARABLE",
    )
    require(
        sum(b - a for a, b, _ in cycle) >= 1800e9
        and all(cycle[i][0] == cycle[i - 1][1] for i in range(1, len(cycle))),
        "incompleteContiguousThirtyMinuteMemoryCycle",
    )
    memory = [x[2] for x in cycle]
    growing = memory[-1] > memory[0] and all(b >= a for a, b in zip(memory, memory[1:]))
    checks = dict(
        idleMean=idle_mean <= 1,
        oneSecondBurst=distribution(burst)["p95"] <= 20,
        sustainedIdle=not longest or longest / 1e9 < policy,
        steadyMemory=max(memory) <= 100_000_000,
        noMonotonicGrowth=not growing,
    )
    return dict(
        status="PASS" if all(checks.values()) else "FAIL",
        thresholds=checks,
        idleMeanPercent=idle_mean,
        burstPercent=distribution(burst),
        longestIdleOver5Seconds=longest / 1e9,
        steadyMemoryMaximumBytes=max(memory),
        cycleSeconds=sum(b - a for a, b, _ in cycle) / 1e9,
        processCPUPercent={
            mode: {name: distribution(all_cpu[(mode, name)]) for name in ("engine", "WindowServer", "replayd")}
            for mode in ("idle", "switch", "cycle")
        },
    )


def lifecycle(root, run, env):
    _, rows = channel(root, run["lifecycle"], "system-lifecycle", run["session"], env["bootUUID"])
    recovered, takeovers = set(), set()
    for row in rows:
        kind = row["kind"]
        if kind in RECOVERIES:
            stable = integer(row["stableNotificationNS"], "missingStableNotification", 1)
            actual = integer(row["reconciledNS"], "invalidRecoveryClock", stable)
            require(
                row["unownedHidden"] == [] and (actual - stable) <= 2e9, "unownedWindowOrLateRecovery", "FAIL"
            )
            require(
                digest(row["originalIdentitySHA256"]) == digest(row["restoredIdentitySHA256"]),
                "wrongRecoveredIdentity",
                "FAIL",
            )
            recovered.add(kind)
        else:
            require(
                kind in {"spaceChange", "fullscreen", "splitView", "missionControl", "stageManager"},
                "unknownTakeoverClass",
            )
            acquired = integer(row["systemAcquiredNS"], "missingSystemTakeover", 1)
            integer(row["systemReleasedNS"], "missingSystemRelease", acquired + 1)
            require(
                row["writeTraceComplete"] is True and row["writesWhileSystemOwned"] == [],
                "unreconciledNativeOwnership",
                "FAIL" if row.get("writesWhileSystemOwned") else "UNKNOWN",
            )
            takeovers.add(kind)
    return recovered, takeovers


def assess(root, manifest):
    result = dict(
        gate=4,
        status="NOT_RUN",
        physicalBenchmark="NOT_RUN",
        recorderActions=0,
        cases=[],
        issues=[],
        percentiles="nearest rank, sorted index ceil(p*n/100)-1",
        qualificationCounts={},
        references=[],
        physicalComparability="UNCONFIRMED",
    )
    seen = set()
    try:
        require(manifest.get("schema") == 1, "invalidManifest")
        candidate = digest(manifest["candidateSHA256"])
        q = artifact(root, manifest["qualification"])
        result["prerequisiteStatus"] = q.get("status", "UNKNOWN")
        result["references"].append(manifest["qualification"])
        result["qualificationEnvironment"] = {}
        result["qualificationCounts"] = prerequisites(
            root, q, candidate, seen, result["qualificationEnvironment"]
        )
        require(manifest["cases"], "noPairedPhysicalCaptures", "NOT_RUN")
    except (EvidenceError, ValueError, KeyError, OSError, TypeError) as error:
        result["reason"] = str(error)
        result["prerequisiteValidation"] = getattr(error, "status", "UNKNOWN")
        return result
    workloads, display_counts, rates, recovered, takeovers = set(), set(), set(), set(), set()
    for case in manifest["cases"]:
        report = dict(id=case.get("id"), status="UNKNOWN", directions=[], issues=[], exclusions={})
        result["cases"].append(report)
        try:
            runs = {system: case[system] for system in SYSTEMS}
            report["references"] = {
                system: {
                    key: ref
                    for key, ref in run.items()
                    if isinstance(ref, dict) and set(ref) == {"path", "sha256"}
                }
                for system, run in runs.items()
            }
            data = {system: read_run(root, run, system, candidate, seen) for system, run in runs.items()}
            e0, e1 = (data[system][0] for system in SYSTEMS)
            require(
                all(e0[k] == e1[k] for k in ENV_KEYS)
                and e0.get("sustainedIdleSeconds") == e1.get("sustainedIdleSeconds"),
                "pairedPhysicalEnvironmentsDiffer",
                "NOT_COMPARABLE",
            )
            require(
                all(e1[key] == result["qualificationEnvironment"][key] for key in ANCHOR),
                "benchmarkHardwareBuildOrCollectorsDifferFromQualification",
                "NOT_COMPARABLE",
            )
            seqs = {system: data[system][2] for system in SYSTEMS}
            report["exclusions"] = {system: data[system][3] for system in SYSTEMS}
            compare_order(seqs["apple"], seqs["nearpane"])
            expected = {(uuid(d[0]), uuid(d[1])) for d in case["directions"]}
            require(
                expected and all(a != b and (b, a) in expected for a, b in expected), "missingReturnDirection"
            )
            for seq in seqs.values():
                require({r["direction"] for r in seq} == expected, "missingRequestedDirection", "NOT_RUN")
            for direction in sorted(expected):
                groups = ([r for r in seqs[system] if r["direction"] == direction] for system in SYSTEMS)
                item = paired_direction(*groups, data["nearpane"][1]["nominalHz"])
                item["fromGroup"], item["toGroup"] = direction
                report["directions"].append(item)
                if item["status"] != "PASS":
                    report["issues"].append(
                        dict(status=item["status"], reason="pairedTimingOrContinuityUnmetOrUnresolved")
                    )
            # Coverage is attached to a hashed independent configuration witness from both systems.
            matched = []
            for system in SYSTEMS:
                run, env = runs[system], data[system][0]
                _, observed = channel(
                    root, run["workload"], "fixture-scenario", run["session"], env["bootUUID"]
                )
                require(
                    len(observed) == 1
                    and observed[0]["fixtureRevision"] == env["fixtureRevision"]
                    and observed[0]["groupLayout"] == env["initialGeometry"],
                    "unboundWorkloadConfiguration",
                )
                matched.append(workload_classes(observed[0], seqs[system]))
            require(
                matched[0] == matched[1] and matched[0] and matched[0] <= WORKLOADS,
                "differentWorkloads",
                "NOT_COMPARABLE",
            )
            workloads.update(matched[0])
            display_counts.add(len(e1["displays"]))
            hz = data["nearpane"][1]["nominalHz"]
            rates.add(
                "60Hz"
                if 59 <= hz <= 61
                else "highRefresh"
                if hz > 61 and e1["highRefreshSupported"] is True
                else "other"
            )
            result["physicalBenchmark"] = "OBSERVED"
            result["physicalComparability"] = "MATCHED_FOR_REPORTED_CASES"
            report["resources"] = {}
            for system in SYSTEMS:
                resource = resource_stats(root, runs[system], data[system][0])
                report["resources"][system] = resource
                if system == "nearpane" and resource["status"] != "PASS":
                    report["issues"].append(dict(status="FAIL", reason="engineResourcesExceeded"))
            done, take = lifecycle(root, runs["nearpane"], e1)
            recovered.update(done)
            takeovers.update(take)
        except (EvidenceError, ValueError, KeyError, OSError, TypeError) as error:
            report["issues"].append(dict(status=getattr(error, "status", "UNKNOWN"), reason=str(error)))
        report["status"] = status(report["issues"])
        result["issues"].extend(report["issues"])
    missing = dict(
        workloads=sorted(WORKLOADS - workloads),
        topology=sorted({1, 2} - display_counts),
        refreshModes=sorted({"60Hz", "highRefresh"} - rates),
        recoveries=sorted(RECOVERIES - recovered),
        systemTakeovers=sorted(
            {"spaceChange", "fullscreen", "splitView", "missionControl", "stageManager"} - takeovers
        ),
    )
    result["missingCoverage"] = missing
    if any(missing.values()):
        result["issues"].append(dict(status="NOT_RUN", reason="incompleteRequiredMatrix"))
    result["status"] = status(result["issues"])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--manifest", type=Path, help="Hashed physical qualification and both systems' raw captures"
    )
    group.add_argument(
        "--qualification", type=Path, help="Read one current gate disposition; no benchmark data is opened"
    )
    parser.add_argument(
        "--output", required=True, type=Path, help="Fresh machine receipt; existing evidence is never replaced"
    )
    args = parser.parse_args()
    source = (args.manifest or args.qualification).resolve()
    try:
        raw = source.read_bytes()
        data = json.loads(raw)
        require(isinstance(data, dict), "invalidRootEvidenceObject")
    except (OSError, ValueError) as error:
        data = None
        report = dict(
            gate=4,
            status="UNKNOWN",
            physicalBenchmark="NOT_RUN",
            recorderActions=0,
            reason="sourceEvidenceUnavailable",
            error=type(error).__name__,
        )
    if data is not None and args.manifest:
        report = assess(source.parent, data)
    elif data is not None:
        report = dict(
            gate=4,
            status="NOT_RUN",
            physicalBenchmark="NOT_RUN",
            recorderActions=0,
            reason="pairedPhysicalManifestRequired"
            if data.get("status") == "PASS"
            else "visibilityOrInputGateNotQualified",
            prerequisiteStatus=data.get("status", "UNKNOWN"),
            prerequisiteReason=data.get("reason"),
            qualificationSHA256=sha256(raw).hexdigest(),
            qualifiedTransitions=0,
        )
    root = Path(__file__).resolve().parents[4]
    report["source"] = str(source.relative_to(root)) if source.is_relative_to(root) else source.name
    with args.output.open("x", encoding="utf-8") as file:
        json.dump(report, file, indent=2)
        file.write("\n")
    return 0 if report["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
