#!/usr/bin/env python3
"""Read sealed focus packets without opening a display. Report physical samples and same-scene parity separately."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import uuid


ROOT = Path(__file__).resolve().parents[3]
PACKET = ROOT / "engineering/verification/native-spaces/5.22-90-sidebar-pair/final-installed"
WARM = 20
BATCHES = 5
ENDPOINTS = ("presentedDocument", "deliveredEditorInput")
PERCENTILES = (50, 95, 99, 100)


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def number(x):
    return type(x) in (int, float) and math.isfinite(x)


def interval(x):
    return isinstance(x, list) and len(x) == 2 and all(number(v) for v in x) and 0 < x[0] <= x[1]


def sealed(folder, manifest, name):
    # Only fixed local filenames from the reader; no supplied paths or arbitrary archive contents are opened.
    path = folder / name
    require(path.is_file() and not path.is_symlink(), "missingSealedArtifact")
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == manifest["files"][name], "artifactHashMismatch")
    return raw


def first_frame(visual, numbers, space, target, down, up):
    require(visual["fixtureWindows"] == numbers and visual["spaceUUID"] == space and
            visual["method"] == "twoEnrolledWindowDisplayRasterWithPhysicalStackAtEightPointCrop" and
            visual["status"] == "OBSERVED" and visual["evidenceKind"] == "firstObservedNativeFrame" and
            visual["targetFrameObserved"] is True and visual["finalTargetStackMatched"] is True and
            visual["retainedPixelBytes"] == 0 and visual["clickDownUptime"] == down and visual["clickUpUptime"] == up,
            "physicalDocumentFrameUnavailable")
    target_slot = numbers.index(target)
    require(visual["sourceSlot"] == 1-target_slot and visual["targetSlot"] == target_slot, "wrongWindowSlot")
    uncertain = visual["clockUncertaintySeconds"]
    require(number(uncertain) and 0 <= uncertain <= .005, "presentationClockUnbounded")
    frames = visual["frames"]
    source, arrived = [], []
    last_time = last_ticks = 0
    for f in frames:
        t, ticks, slot = f["displayUptime"], f["presentationMachTicks"], f["slot"]
        require(number(t) and t > last_time and type(ticks) is int and ticks > last_ticks and type(slot) is int and slot in (0,1),
                "rasterClockOrSlotChanged")
        before, after = f["stackBefore"], f["stackAfter"]
        require(len(before) == len(after) == 3 and interval(before[:2]) and interval(after[:2]) and
                before[1] <= t-uncertain and t+uncertain <= after[0] and
                all(type(s) is int and s in (0,1) for s in (before[2],after[2])) and
                (before[2] != target_slot or after[2] == target_slot) and (slot != target_slot or after[2] == target_slot),
                "physicalStackDoesNotBracketFrame")
        if slot == target_slot:
            arrived.append(t)
        else:
            require(not arrived, "sourceReturnedAfterFirstTarget")
            source.append(t)
        last_time, last_ticks = t, ticks
    require(source and arrived and source[0]+uncertain < down[0] and arrived[0]-uncertain >= down[1] and
            arrived[0] == visual["firstTargetDisplayUptime"] and source[-1] == visual["lastSourceDisplayUptime"],
            "presentationTransitionUnconfirmed")
    first = next(f for f in frames if f["slot"] == target_slot)
    require(visual["firstTargetPresentationMachTicks"] == first["presentationMachTicks"], "targetClockNotBound")
    return [max(0, (source[-1]-uncertain-down[1])*1000), (max(arrived[0]+uncertain,first["stackAfter"][1])-down[0])*1000]


def input_delivery(marker, attempt, registration, session, numbers, down, up):
    target = attempt["target"]
    sender, delivered = marker["sender"], marker["keyDelivery"]
    require(marker["status"] == "SEALED" and marker["closureConfirmed"] is True and marker["truncated"] is False and
            marker["intent"] == attempt["id"] and marker["session"] == session and marker["target"] == target and
            marker["pid"] == registration["pid"] and marker["birth"] == registration["birth"] and marker["numbers"] == numbers and
            marker["receiverDisposition"] == "COMPLETE_REGISTERED_SEQUENCE" and sender["status"] == "TAGGED_POST" and
            sender["complete"] is True and sender["transport"] == delivered["mode"] == "pidNumericKeypad" and
            type(sender["postedDown"]) is int and sender["postedDown"] > 0 and sender["postedDown"] == sender["postedUp"] ==
            delivered["attributedDown"] == delivered["attributedUp"] and delivered["unattributedDown"] == delivered["unattributedUp"] == 0 and
            delivered["sequenceMatches"] is True and delivered["physicalSuperseded"] is False and delivered["posterBound"] is True and
            delivered["overflow"] is False and attempt["siblingUnchanged"] is True, "fixtureInputNotSealed")
    events = [e for e in marker["events"] if e["step"] == "editorKeyDown"]
    require(events, "editorInputTimeUnavailable")
    for e in events:
        require(e["active"] is True and e["attribution"] == "eventTag" and e["eventWindow"] == e["main"] == e["key"] == target and
                all(number(x) for x in (sender["beforePost"],e["eventClock"],e["clock"],sender["afterPost"])) and
                up[1] <= sender["beforePost"] <= e["eventClock"] <= e["clock"] <= sender["afterPost"], "unrelatedEditorInput")
    t = min(e["clock"] for e in events)
    return [(t-down[1])*1000,(t-down[0])*1000], sender["beforePost"]


def bound_environment(env, scope, registration, session, numbers):
    require(isinstance(env,dict) and env["boot"] and env["osBuild"] and number(env["refreshHz"]) and env["refreshHz"] > 0 and
            type(env["otherOrdinaryAppWindows"]) is int and env["otherOrdinaryAppWindows"] == 0 and
            type(env["reduceMotion"]) is bool and env["stageManager"] is False and len(env["bounds"]) == 4 and
            all(number(x) for x in env["bounds"]) and min(env["bounds"][2:]) > 0 and
            all(type(env[k]) is int and env[k] > 0 for k in ("hostPID","hostBirth","fixturePID","fixtureBirth","space")) and
            all(isinstance(env[k],str) and len(env[k]) == 40 and all(c in "0123456789abcdef" for c in env[k])
                for k in ("hostHash","fixtureHash")) and len(numbers) == len(set(numbers)) == 2 and
            all(type(n) is int and n > 0 for n in numbers) and
            len(env["modePixels"]) == 2 and all(type(x) is int and x > 0 for x in env["modePixels"]) and
            len(env["frames"]) == 2 and all(len(r) == 4 and all(number(x) for x in r) and min(r[2:])>0 for r in env["frames"]) and
            env["numbers"] == numbers and env["session"] == session and env["fixtureHash"] == registration["cdHash"] and
            env["fixturePID"] == registration["pid"] and env["fixtureBirth"] == registration["birth"] and
            all(env[key] == scope[key] for key in ("display","space","spaceUUID","hostPID","hostBirth","hostHash")),
            "sameSceneEvidenceIncomplete")
    for key in ("boot","display","spaceUUID","session"):
        uuid.UUID(env[key])
    return env


def admitted_click(route, proof, attempt, scope, numbers, target, down, up, before):
    require(proof["issued"] is True and proof["status"] == "FOCUSED" and proof["initialFocus"] ==
            {"editor":True,"focused":attempt["sibling"],"main":attempt["sibling"]} and proof["target"] == target and
            proof["dispatch"] == "WindowServer.cgSessionEventTap" and proof["hardwareUnchangedAtRelease"] is True,
            "pointerOrInitialFocusUnconfirmed")
    events = proof["events"]
    require([e["type"] for e in events] == [1,2] and all(type(e["eventTimestampNS"]) is int and
            t[0]-1e-6 <= e["eventTimestampNS"]/1e9 <= t[1]+1e-6 for e,t in zip(events,(down,up))) and
            events[0]["point"] == events[1]["point"], "unattributedPointerEvents")
    route_proof = proof["hostRouting"] if route == "nearpane" else proof["systemRouting"]
    expected = "boundPanel" if route == "nearpane" else "boundNativeButton"
    routed = route_proof["events"]
    require(route_proof["status"] == "OBSERVED" and len(routed) == len(events) and
            all(e["destination"] == "bound" and e["source"] == "bound" and e["underPointer"] == expected and
                e["acceptingPointer"] == expected and e["type"] == posted["type"] and
                e["timestampNS"] == posted["eventTimestampNS"] and e["point"] == posted["point"]
                for e,posted in zip(routed,events)), "clickNotRoutedToEnrolledPicker")
    if route == "nearpane":
        require(route_proof["hostPID"] == scope["hostPID"] and attempt["hostButton"]["status"] == "OBSERVED","installedCallbackUnavailable")
    else:
        require(before["status"] == "LINKS_OBSERVED" and before["issued"] is False and before["retainedPixelBytes"] == 0 and
                interval(before["interval"]) and before["interval"][1] <= down[0] and before["spaceUUID"] == scope["spaceUUID"] and
                before["owner"]["bundle"] in ("com.apple.dock","com.apple.WindowManager") and
                type(before["owner"]["birth"]) is int and before["owner"]["birth"] > 0 and
                type(before["owner"]["pid"]) is int and before["owner"]["pid"] > 1 and
                isinstance(before["owner"]["cdHash"],str) and len(before["owner"]["cdHash"]) == 40 and
                before["owner"] == route_proof["owner"] and [x["number"] for x in before["targets"]] == numbers and
                all(e.get("linkedFixture") == [before["fixturePID"],before["fixtureBirth"],target] for e in routed) and
                len(before["observations"]) == 2 and all(x["firstLinks"] == x["secondLinks"] == 1 for x in before["observations"]),
                "nativeFixtureButtonNotBound")
        x,y,width,height = before["targets"][numbers.index(target)]["rect"]
        px,py = events[0]["point"]
        require(x < px < x+width and y < py < y+height, "nativeClickOutsideBoundTarget")


def load_run(folder, route):
    manifest = json.loads((folder/"manifest.json").read_bytes())
    run = json.loads(sealed(folder,manifest,"pair-pointer.json"))
    ledger = [json.loads(r) for r in sealed(folder,manifest,"actions.jsonl").splitlines()]
    register = run["registration"]; scope = run["scope"]
    install = json.loads(sealed(folder,manifest,"protected-installation.json"))
    require(install["candidate"]["source"] == manifest["source"] and install["candidate"]["cdhash"] == scope["hostHash"],
            "installedCandidateGenerationNotBound")
    require(register["kernelExecutableConfirmed"] is True and register["regular"] is True and
            register["cdHash"] == run["fixtureSigning"]["CDHash"] and register["bundle"] == "net.example.spaces-document" and
            register["team"] == run["fixtureSigning"]["TeamIdentifier"] == "ZB9D4T66QB", "signedFixtureNotEnrolled")
    launch = [x for x in ledger if x["event"] == "P2-fixture-app-bound"]
    require(len(launch) == 1 and launch[0]["fixturePID"] == register["pid"] and launch[0]["birth"] == register["birth"],"fixtureGenerationChanged")
    session,numbers = launch[0]["session"],launch[0]["numbers"]
    require(len(numbers) == len(set(numbers)) == 2 and all(type(n) is int and n > 0 for n in numbers), "fixtureNumbersNotUnique")
    summary = {"route":route, "source":manifest.get("source"), "attempted":0, "trials":[], "environment":None,
               "inputPolicy":None, "sceneStatus":"NOT_RECORDED", "checksummedLedger":manifest["files"]["actions.jsonl"]}
    # New runs enclose the entire route in two independent reads by the same fixture/Host observer.
    # Older archives still contribute their individual positive endpoints.
    contexts = [r for r in ledger if r["event"] == "focus-reference-environment"]
    if len(contexts) == 2:
        try:
            first,last = [r["proof"] for r in contexts]
            require([r["stage"] for r in contexts] == ["before","after"] and all(r["status"] == "ENVIRONMENT_OBSERVED" and
                    r["issued"] is False and interval(r["interval"]) for r in (first,last)) and
                    first["interval"][1] < last["interval"][0] and first["environment"] == last["environment"],"sceneChanged")
            summary["environment"] = bound_environment(first["environment"],scope,register,session,numbers)
            summary["sceneStatus"] = "OBSERVED"
        except (KeyError, ValueError, TypeError):
            summary["sceneStatus"] = "UNCONFIRMED"
    proofs = [r for r in ledger if r["event"] == "pair-pointer-system-proof" and r["kind"] == "click"]
    attempts = [a for a in run["attempts"] if a["kind"] == "window"]
    summary["attempted"] = len(attempts)
    summary["unmatchedClicks"] = sum(r["trial"] not in {a["trial"] for a in attempts} for r in proofs)
    for ordinal,a in enumerate(attempts,1):
        row = {"id":a.get("id"),"ordinal":ordinal,"status":"UNKNOWN","reportedStatus":a.get("status"),"targetSlot":None}
        summary["trials"].append(row)
        try:
            uuid.UUID(a["id"]); n = a["trial"]; target = a["target"]; row["targetSlot"] = numbers.index(target)
            require(type(n) is int and n == ordinal and a["sibling"] == numbers[1-row["targetSlot"]] and
                    a["status"] == "PASS" and a["pointerIssued"] is True and a["markerIssued"] is True,"incompleteAttempt")
            matching = [r["proof"] for r in proofs if r["trial"] == n]
            require(len(matching) == 1,"missingOrRepeatedClick")
            p = matching[0]
            require(len(p["events"]) == 2,"unexpectedInputCount")
            down,up = [[e["beforePost"],e["afterPost"]] for e in p["events"]]
            require(interval(down) and interval(up) and down[1] <= up[0],"pointerClockMissing")
            v = json.loads(sealed(folder,manifest,f"window-presentation-{n:02d}.json"))
            marker = json.loads(sealed(folder,manifest,f"marker-witness-{n:02d}.json"))
            before = p.get("nativeButton")
            if route == "missionControl":
                require(isinstance(before,dict) and before.get("session") == session and before.get("fixturePID") == register["pid"] and
                        before.get("fixtureBirth") == register["birth"] and before.get("fixtureHash") == register["cdHash"] and
                        before.get("display") == scope["display"] and before.get("space") == scope["space"], "nativeTileFixtureScopeUnconfirmed")
            admitted_click(route,p,a,scope,numbers,target,down,up,before)
            visible = first_frame(v,numbers,scope["spaceUUID"],target,down,up)
            keys,post = input_delivery(marker,a,register,session,numbers,down,up)
            reads = [r for r in ledger if r["event"] == "P2-independent-document-read" and r["trial"] == n and r["stage"] == "Input"]
            require(len(reads) == 1 and reads[0]["confirmed"] is True and len(reads[0]["reads"]) >= 2 and
                    all(r["status"] == "READ" and r["editorFocused"] is True and r["frontIsFixture"] is True and
                        r["focused"] == r["main"] == target and r["enrolledMemberships"] == [[scope["space"]]]*2 and
                        r["fileSHA256"] == r["axSHA256"] == r["fixtureSHA256"] == reads[0]["expectedSHA256"]
                        for r in reads[0]["reads"][-2:]),"independentDocumentsUnconfirmed")
            if summary["environment"] is not None:
                env = summary["environment"]
                bracketing = [r["proof"] for r in ledger if r["event"] == "focus-reference-trial-environment" and r["trial"] == n]
                require(len(bracketing) == 2 and all(q["status"] == "ENVIRONMENT_OBSERVED" and q["issued"] is False and
                        q["environment"] == env and interval(q["interval"]) for q in bracketing) and
                        bracketing[0]["interval"][1] <= down[0] and marker["events"][-1]["clock"] <= bracketing[1]["interval"][0],
                        "environmentDoesNotBracketThisClick")
                require(first["interval"][1] <= down[0] and marker["events"][-1]["clock"] <= last["interval"][0] and
                        p["geometry"]["ax"] == p["geometry"]["cg"] == env["frames"] and p["geometry"]["members"] == numbers and
                        p["geometry"]["displayUUID"] == env["display"] and (route != "missionControl" or before["environment"] == env),
                        "clickOutsideVerifiedEnvironment")
            row.update(status="OBSERVED",down=down,end=marker["events"][-1]["clock"],presentedDocument=visible,
                       deliveredEditorInput=keys,markerOfferAfterUpMs=(post-up[1])*1000,
                       mouseHoldMs=(p["events"][1]["eventTimestampNS"]-p["events"][0]["eventTimestampNS"])/1e6,
                       markerKeyCount=marker["sender"]["postedDown"])
        except (KeyError, ValueError, TypeError, IndexError, StopIteration) as error:
            row["reason"] = str(error) if isinstance(error,ValueError) else "invalidOrIncompleteTrialReceipt"
            if a.get("status") == "FAIL":
                row["status"] = "FAIL"
    policy = run.get("referenceMarkerAfterUpMs")
    if number(policy) and policy >= 0:
        summary["inputPolicy"] = policy
    return summary


def percentiles(rows, key):
    if not rows:
        return {}
    lower,upper = (sorted(row[key][i] for row in rows) for i in (0,1))
    return {f"p{p}":[lower[math.ceil(len(rows)*p/100)-1],upper[math.ceil(len(rows)*p/100)-1]]
            for p in PERCENTILES}


def verdict(product, native, allowance=0):
    if product[0] > native[1] + allowance:
        return "FAIL"
    if product[1] <= native[0] + allowance:
        return "PASS"
    return "UNKNOWN"


def compare(product, native):
    out = {"scope":"select a different document of the same application from an already visible picker on its current ordinary Space",
           "origin":"routed WindowServer left mouse down; opening the picker is outside this interval",
           "endpoints":["first fixture-colored display frame independently bounded by physical stack reads",
                        "first tagged key observed by the enrolled target editor under the same input-probe schedule"],
           "policy":{"native":WARM,"productWarmup":WARM,"productMeasured":WARM*BATCHES,
                     "strictParity":"empirical P50/P95/P99/worst for each direction and both endpoints",
                     "contractInputP95AllowanceMs":150},
           "status":"UNKNOWN","reasons":[],"strictParity":None,"contractInputP95":None}
    reasons = out["reasons"]
    for expected,run,name in ((WARM*(BATCHES+1),product,"nearpane"),(WARM,native,"missionControl")):
        if run is None:
            reasons.append(name+"NotRun")
            out[name] = {"attempts":0,"observed":0,"sampleOnly":{},"trials":[]}
            continue
        obs = [r for r in run["trials"] if r["status"] == "OBSERVED"]
        out[name] = {"attempts":run["attempted"],"observed":len(obs),"source":run["source"],"scene":run["sceneStatus"],
                     "ledgerSHA256":run["checksummedLedger"],"sampleOnly":{k:percentiles(obs,k) for k in ENDPOINTS},
                     "trials":run["trials"]}
        if run["route"] != name: reasons.append(name+"RouteUnconfirmed")
        if run["attempted"] != expected or len(obs) != expected or run["unmatchedClicks"]: reasons.append(name+"IncompleteSeries")
        if run["sceneStatus"] != "OBSERVED" or not run["environment"]: reasons.append(name+"MissingScene")
        if run["inputPolicy"] is None: reasons.append(name+"MissingInputSchedule")
    if native is None:
        out["status"] = "NOT_RUN"
    if reasons:
        return out
    try:
        env = product["environment"]
        require(env == native["environment"], "differentDisplaySpaceWorkloadOrMotion")
        bound_environment(env,env,{"pid":env["fixturePID"],"birth":env["fixtureBirth"],"cdHash":env["fixtureHash"]},env["session"],env["numbers"])
        require(product["inputPolicy"] == native["inputPolicy"], "differentMarkerOfferPolicy")
        all_rows = sorted(product["trials"]+native["trials"], key=lambda r:r["down"][0])
        require(len({uuid.UUID(r["id"]) for r in all_rows}) == len(all_rows) and
                all(i["end"] <= j["down"][0] for i,j in zip(all_rows,all_rows[1:])), "reusedOrOverlappingTrial")
        period = 1000 / env["refreshHz"]
        for run in (product,native):
            for ordinal,r in enumerate(run["trials"],1):
                require(r["ordinal"] == ordinal and type(r["targetSlot"]) is int and r["targetSlot"] in (0,1) and
                        interval(r["down"]) and number(r["end"]) and r["end"] >= r["down"][1] and
                        all(len(r[k]) == 2 and all(number(v) for v in r[k]) and 0 <= r[k][0] <= r[k][1] for k in ENDPOINTS),
                        "invalidOrOutOfOrderTrial")
                if ordinal > 1:
                    prev = run["trials"][ordinal-2]
                    require(prev["end"] <= r["down"][0] and prev["targetSlot"] != r["targetSlot"], "unmatchedTrialOrder")
                # If one route waits longer to offer the keyboard probe, tInput measures
                # the harness. Both routes must offer it at the prespecified display refresh.
                require(math.floor(r["markerOfferAfterUpMs"]/period) == math.floor(run["inputPolicy"]/period),
                        "observedMarkerOfferScheduleChanged")
        schedule = [r["targetSlot"] for r in native["trials"]]
        require(all(r["targetSlot"] == schedule[i%WARM] for i,r in enumerate(product["trials"])), "differentTargetOrder")
        for i,r in enumerate(product["trials"]):
            ref = native["trials"][i%WARM]
            require(all(number(x) and x > 0 for x in (r["mouseHoldMs"],ref["mouseHoldMs"])) and
                    abs(r["mouseHoldMs"]-ref["mouseHoldMs"]) < period and
                    type(r["markerKeyCount"]) is int and r["markerKeyCount"] == ref["markerKeyCount"] > 0,
                    "clickDurationOrKeyboardWorkloadChanged")
    except (ValueError, TypeError, KeyError, IndexError, ZeroDivisionError) as e:
        reasons.append(str(e) if isinstance(e,ValueError) else "invalidComparisonEvidence")
        return out
    out["strictParity"] = {}
    for key in ENDPOINTS:
        for slot in ("both",0,1):
            p = percentiles([r for r in product["trials"][WARM:] if slot == "both" or r["targetSlot"] == slot],key)
            n = percentiles([r for r in native["trials"] if slot == "both" or r["targetSlot"] == slot],key)
            checks = {pct:verdict(p[pct],n[pct]) for pct in p}
            out["strictParity"][f"{key}/{slot}"] = {"nearpane":p,"missionControl":n,"outcomes":checks}
            if key == "deliveredEditorInput" and slot == "both":
                out["contractInputP95"] = verdict(p["p95"],n["p95"],150)
    outcomes = {v for test in out["strictParity"].values() for v in test["outcomes"].values()}
    out["status"] = "FAIL" if "FAIL" in outcomes else "UNKNOWN" if "UNKNOWN" in outcomes else "PASS"
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--product",type=Path,default=PACKET)
    parser.add_argument("--native",type=Path)
    args = parser.parse_args()
    problems = []
    def load(path, route):
        if path is None:
            return None
        try:
            return load_run(path,route)
        except (KeyError,OSError,TypeError,ValueError,IndexError) as e:
            reason = str(e) if type(e) is ValueError else "missingOrInvalidArchive"
            problems.append(route+"ArchiveUnqualified:"+reason)
            return None
    result = compare(load(args.product,"nearpane"),load(args.native,"missionControl"))
    if problems:
        result["status"] = "UNKNOWN"
        for problem in problems:
            route = problem.split("ArchiveUnqualified:",1)[0]
            result["reasons"].remove(route+"NotRun")
            result[route].update(attempts=None,observed=None)
        result["reasons"] += problems
    print(json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False))
    return 0 if result["status"] == "PASS" else 1 if result["status"] == "FAIL" else 2


if __name__ == "__main__":
    raise SystemExit(main())
