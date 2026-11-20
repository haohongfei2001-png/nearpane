"""Ordinary same-display card drags and click-to-confirmed-editor latency on a verified lease.

The native observer posts only session pointer events. Both ordinary windows are enrolled by
Launch Services, AX identifier, CGID, file URL, PID generation and code signature in p2_documents.
"""
import hashlib
import json
import math
import os
import statistics
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from installed_profile import PROFILE, owns_profile
from p2_documents import RegisteredRun, Superseded, TrialStop, capture_dimensions, check_hid, coherent, digest, require
from space_scope import private_file


def rect(value):
    require(isinstance(value, list) and len(value) == 4 and
            all(type(x) in (int, float) and math.isfinite(x) for x in value) and min(value[2:]) > 0,
            "ordinaryWindowOrDisplayGeometryInvalid")
    return tuple(value)


def close(a, b):
    return len(a) == len(b) == 4 and all(abs(x-y) <= 1 for x, y in zip(a, b))


def reservation(config, display_id):
    """Select the current display's committed edge and any explicit independent reservation."""
    tables = config.get("displays", {})
    require(isinstance(tables, dict), "displaySettingsUnreadable")
    matches = [x for id_, x in tables.items() if id_.lower() == display_id.lower()]
    require(len(matches) <= 1, "ambiguousDisplaySettings")
    display = matches[0] if matches else {}
    edge = display.get("edge") or config.get("edge")
    require(edge in ("left", "right"), "missingCommittedPanelEdge")
    raw = display.get("measures", [])
    if isinstance(raw, list):
        require(len(raw) % 2 == 0 and all(isinstance(k, str) for k in raw[::2]) and
                len(set(raw[::2])) == len(raw)//2, "invalidDisplayMeasurePairs")
        raw = dict(zip(raw[::2], raw[1::2]))
    require(isinstance(raw, dict), "invalidDisplayMeasures")
    return {"edge": edge, "explicit": raw.get("reservedWidth")}


def work_rect(proof, policy):
    """Use the actual sidebar window bounds on the usable NSScreen, never the pair's result."""
    vx, vy, vw, vh = rect(proof["visible"])
    px, py, pw, ph = rect(proof["panel"])
    require(px >= vx-1 and py >= vy-1 and px+pw <= vx+vw+1 and py+ph <= vy+vh+1, "panelOffUsableDisplay")
    left = policy["edge"] == "left"
    occupied = px+pw-vx if left else vx+vw-px
    opposite = vx+vw-px if left else px+pw-vx
    require(0 < occupied < opposite, "committedEdgeDoesNotMatchVisibleSidebar")
    explicit = policy["explicit"]
    width = occupied
    if explicit is not None:
        require(isinstance(explicit, dict) and explicit.get("unit") in ("pt", "%") and
                type(explicit.get("value")) in (int, float) and math.isfinite(explicit["value"]),
                "explicitReservationUnproven")
        width = explicit["value"] * (vw/100 if explicit["unit"] == "%" else 1)
        require(occupied-1 <= width < vw, "explicitReservationConflictsWithVisibleHost")
    start = math.ceil(vx + (width if left else 0))
    end = math.floor(vx+vw - (0 if left else width))
    area = [start, math.ceil(vy), end-start, math.floor(vy+vh)-math.ceil(vy)]
    rect(area)
    return area


def halves(area):
    x, y, w, h = area
    left = math.floor(w/2 + .5)
    return [[x, y, left, h], [x+left, y, w-left, h]]


def geometry_agrees(proof, expected, anchor, numbers):
    if (proof.get("members") != numbers or proof.get("panelID") != anchor.get("panelID") or
            proof.get("displayUUID") != anchor.get("displayUUID") or
            any(not close(rect(proof[k]), rect(anchor[k])) for k in ("visible", "panel"))):
        return False
    return all(len(proof.get(stream, [])) == 2 and
               all(close(rect(actual), rect(wanted)) for actual, wanted in zip(proof[stream], expected))
               for stream in ("ax", "cg"))


def host_route(reply):
    """Only our tagged events are visible at the process-scoped passive receiver."""
    route = reply.get("hostRouting") or {}
    checked = {"receiver":route.get("status", "NOT_IN_THIS_TOOL"), "status":"UNCONFIRMED",
               "AppKitCallback":"NOT_OBSERVED"}
    if route.get("status") != "OBSERVED":
        return checked
    rows = route.get("events", [])
    posted = reply.get("events", [])
    if len(posted) < 2 or posted[0]["type"] != 1 or posted[-1]["type"] != 2:
        return checked
    ends = [r for r in rows if r["type"] in (1,2)]
    if ([r["type"] for r in ends] != [1,2] or
            any(v.get("source") == "different" or v.get("destination") == "different" for v in ends) or
            any(math.dist(r["point"], p["point"]) > 1 for r,p in zip(ends, (posted[0],posted[-1])))):
        return checked
    observed = [v["acceptingPointer"] if v["acceptingPointer"] != "unreported" else v["underPointer"] for v in ends]
    checked.update(status="HOST_PANEL" if observed == ["boundPanel"]*2 else
                   "HOST_OTHER_WINDOW" if "different" in observed else "HOST_PID",
                   reportedWindow=observed, timestampPreserved=[r["timestampNS"] == e["eventTimestampNS"] for r,e in zip(ends,(posted[0],posted[-1]))],
                   taggedDragSamples=sum(r["type"] == 6 for r in rows))
    return checked


def click_timing(reply):
    events, f = reply.get("events", []), reply.get("focus", {})
    require([e.get("type") for e in events] == [1, 2] and reply.get("status") == "FOCUSED", "missingClickOrFocusClock", "UNKNOWN")
    down, up = events
    t = [down["beforePost"], down["afterPost"], up["beforePost"], up["afterPost"],
         f["firstPositiveStart"], f["firstPositiveEnd"], f["secondPositiveEnd"]]
    require(all(type(x) in (int,float) and math.isfinite(x) for x in t) and t == sorted(t) and f["reads"] >= 2 and
            up["beforePost"] <= f["lastNegativeSampleStarted"] <= f["firstPositiveStart"], "invalidFocusClockOrder", "UNKNOWN")
    # The target might already be focused at mouse-up. Only the last independently
    # negative observation (or mouse-down itself) supplies a safe lower bound.
    lower = f["lastNegativeSampleStarted"] if f["lastNegativeSampleStarted"] > up["beforePost"] else down["beforePost"]
    return {"downToFocusLowerMs":max(0, (lower-down["afterPost"])*1000),
            "downToFocusUpperMs":(f["firstPositiveEnd"]-down["beforePost"])*1000,
            "upToFocusLowerMs":max(0, (lower-up["afterPost"])*1000),
            "upToFocusUpperMs":max(0, (f["firstPositiveEnd"]-up["beforePost"])*1000),
            "secondPositiveAfterUpMs":(f["secondPositiveEnd"]-up["beforePost"])*1000}


def summary(values):
    if not values:
        return {"n":0}
    values = sorted(values)
    return {"n":len(values), "p50":statistics.median(values), "p95":values[math.ceil(.95*len(values))-1], "max":values[-1]}


class PairPointerRun(RegisteredRun):
    def __init__(self, *args):
        super().__init__(*args)
        self.focus_only = False
        self.drag_only = False
        self.out["layoutCapture"] = {"status":"NOT_RUN","reason":"twoVerifiedOrdinaryWindowFramesUnavailable"}
        self.out["drags"] = {k:{"status":"NOT_RUN"} for k in ("self", "right", "left")}
        self.out["selection"] = {"status":"NOT_RUN","planned":10}
        self.out["measurement"] = {
            "clock":"ProcessInfo.systemUptime","unit":"ms","origin":"WindowServer session mouse posting",
            "endpoint":"foreground application + focused and main AX window + both focused editor reads",
            "displayPresentation":"NOT_MEASURED","nativeComparison":"NOT_MEASURED",
        }

    def packet(self, kind, target, hashes):
        proof = self.call("pair-pointer", {"pointerKind":kind,"target":target,"digests":hashes}, timeout=7)
        self.rec.log("pair-pointer-system-proof", trial=self.trial, kind=kind, proof=proof)
        if kind in self.out["drags"]:
            self.out["drags"][kind].update(issued=proof.get("issued"), events=proof.get("events", []), hostRouting=host_route(proof))
        elif kind == "click" and self.attempt is not None:
            self.attempt["pointerIssued"] = proof.get("issued")
        check_hid(proof, self.baseline)
        return proof

    def terminal_focus_reads(self):
        samples = []
        for _ in range(2):
            try:
                read = self.call("read",timeout=1.3)
                check_hid(read,self.baseline)
                sample = {k:read[k] for k in ("clock","status","reason","focused","main","editorFocused","frontIsFixture",
                                              "knownIssueMessages","cards") if k in read}
                if read.get("status") == "READ":
                    local = json.loads(private_file(self.folder/"windows.json"))
                    files = [digest(private_file(self.folder/(slot+".txt"),limit=4096)) for slot in "AB"]
                    require(local.get("session")==self.folder.name, "fixtureFileGenerationChanged")
                    sample.update(digestsAgree=coherent(read,local,files), key=local.get("key"), localMain=local.get("main"))
                samples.append(sample)
            except Superseded:
                raise
            except (ValueError,OSError,subprocess.SubprocessError,KeyError) as error:
                samples.append({"status":"UNKNOWN","reason":type(error).__name__})
        return samples

    def select_document(self, target, intent, attempt):
        proof = self.packet("click", target["target"], target["digests"])
        attempt["pointerIssued"] = proof.get("issued")
        attempt["pointerStatus"] = proof.get("status")
        attempt["pointerReason"] = proof.get("reason")
        route = host_route(proof)
        attempt["hostRouting"] = route
        if proof.get("issued") is True and proof.get("status") != "FOCUSED":
            attempt["terminalFocusReads"] = self.terminal_focus_reads()
        if route["status"] == "HOST_OTHER_WINDOW":
            raise TrialStop("taggedEventsRoutedToOtherHostWindow", "UNKNOWN")
        require(proof.get("issued") is True, proof.get("reason") or "sessionClickUnconfirmed", "BLOCKED")
        require(proof.get("status") == "FOCUSED", proof.get("reason") or "twoExactFocusReadsUnavailable",
                "FAIL" if proof.get("reason") == "systemFocusReadbackTimedOut" and
                route["status"] in ("HOST_PANEL", "HOST_PID") else "UNKNOWN")
        attempt["timing"] = click_timing(proof)

    def geometry(self, target, hashes):
        proof = self.packet("read", target, hashes)
        require(proof.get("status") == "READ" and isinstance(proof.get("geometry"), dict),
                proof.get("reason") or "ordinaryGeometryReadFailed")
        return proof["geometry"]

    def profile_policy(self, anchor):
        root = Path(os.environ["NEARPANE_TEST_HOME"])/PROFILE
        generation = Path(os.environ["NEARPANE_TEST_GENERATION"])
        require(owns_profile(self.binding["hostPID"], root) and generation.resolve(strict=True) == generation and
                generation.parent == root/"generations" and str(uuid.UUID(generation.name)) == generation.name and
                json.loads((root/"profile-index.json").read_bytes())["active"] == generation.name, "pairIsolatedGenerationChanged")
        path = generation/"Nearpane/host-configuration.json"
        require(path.resolve(strict=True) == path and path.is_file() and path.stat().st_size < 1_000_000, "isolatedConfigurationUnavailable")
        raw = path.read_bytes()
        return {**reservation(json.loads(raw), anchor["displayUUID"]), "sha256":hashlib.sha256(raw).hexdigest()}

    def drag(self, kind, hashes, anchor, expected, baseline):
        a, b = self.binding["numbers"]
        entry = self.out["drags"][kind]
        entry.update(status="BLOCKED", id=str(uuid.uuid4()), source=a, destination=a if kind == "self" else b,
                     expected=expected, issued=False, method="WindowServer session down/dragged/up on production cards")
        self.rec.attempts.append(entry)
        before = self.geometry(a, hashes)
        require(geometry_agrees(before, baseline, anchor, [a,b]), "pairChangedBeforeGesture")
        entry["before"] = before
        proof = self.packet(kind, a, hashes)
        entry.update(issued=proof.get("issued"), events=proof.get("events", []))
        require(proof.get("status") == "DISPATCHED" and proof.get("issued") is True,
                proof.get("reason") or "dragDispatchUnconfirmed", "UNKNOWN" if proof.get("issued") else "BLOCKED")
        events = entry["events"]
        require(len(events) >= 5 and events[0]["type"] == 1 and events[-1]["type"] == 2 and
                all(e["type"] == 6 for e in events[1:-1]) and
                max(math.dist(events[0]["point"], e["point"]) for e in events[1:]) > 8,
                "actualPointerDragNotEstablished", "UNKNOWN")
        require(geometry_agrees(proof["geometry"], baseline, anchor, [a,b]), "geometryChangedAtDispatch", "UNKNOWN")
        if kind == "self":
            snapshots = proof.get("duringSelfDrag", [])
            require(len(snapshots) == len(events)-2 and all(len(s.get("cg", [])) == 2 for s in snapshots),
                    "selfDragWindowServerReadIncomplete", "UNKNOWN")
            require(all(s["cg"] == before["cg"] for s in snapshots), "windowMovedDuringSelfDrop", "FAIL")
            entry["duringSelfDrag"] = snapshots
        entry["status"] = "UNKNOWN"
        start = time.monotonic()
        recent = []
        mismatch = []
        while time.monotonic()-start < 3.5:
            sample = self.geometry(a, hashes)
            if kind == "self":
                same = sample["cg"] == before["cg"] and sample["ax"] == before["ax"]
                require(same, "windowMovedAfterSelfDrop", "FAIL")
            if geometry_agrees(sample, expected, anchor, [a,b]):
                recent = (recent+[sample])[-2:]
                mismatch.clear()
                if (len(recent) == 2 and recent[1]["clock"] > recent[0]["clock"] and
                        (kind != "self" or time.monotonic()-start >= .8)):
                    entry.update(status="PASS", after=recent, reason="twoIndependentCGAndAXBounds")
                    return
            else:
                recent.clear()
                mismatch = (mismatch+[sample])[-2:]
            time.sleep(.08)
        entry["after"] = mismatch or recent
        stable_other = (len(mismatch) == 2 and mismatch[0]["clock"] < mismatch[1]["clock"] and
                        geometry_agrees(mismatch[0], mismatch[1]["cg"], anchor, [a,b]) and
                        geometry_agrees(mismatch[1], mismatch[1]["cg"], anchor, [a,b]))
        raise TrialStop("independentlyObservedDifferentWindowLayout" if stable_other else "layoutStabilityUnconfirmed",
                        "FAIL" if stable_other else "UNKNOWN")

    def capture_pair(self, hashes, anchor, expected):
        """Each PNG comes solely from one enrolled CGID after the timing samples."""
        proof = {"status":"NOT_RUN","scope":"two separate enrolled document windows","files":[]}
        self.out["layoutCapture"] = proof
        if not self.initial.get("observerScreenRead"):
            proof["reason"] = "screenRecordingPreflightUnavailable"
            return
        numbers = self.binding["numbers"]
        try:
            with tempfile.TemporaryDirectory(prefix=".pair-images.", dir=self.folder) as tmp:
                candidates = []
                for slot, n in zip("AB", numbers):
                    before = self.geometry(n,hashes)
                    require(geometry_agrees(before,expected,anchor,numbers), "changedBeforeWindowCapture")
                    path = Path(tmp)/(slot+".png")
                    got = subprocess.run(["/usr/sbin/screencapture","-x","-o","-t","png","-l"+str(n),str(path)],
                                         capture_output=True,timeout=1.2)
                    after = self.geometry(n,hashes)
                    require(got.returncode == 0 and path.is_file() and geometry_agrees(after,expected,anchor,numbers)
                            and after["clock"] > before["clock"], "windowCaptureOrIndependentReadbackUnavailable")
                    raw = path.read_bytes()
                    width, height = capture_dimensions(raw)
                    candidates.append((raw,dict(slot=slot,window=n,width=width,height=height,sha256=digest(raw),
                                                file="paired-ordinary-window-"+slot+".png",before=before,after=after)))
                self.read_until(None,hashes,"AfterScopedImages",seconds=2.5)
                for raw, item in candidates:
                    with (self.rec.output/item["file"]).open("xb") as f:
                        f.write(raw)
                    proof["files"].append(item)
                proof["status"]="CAPTURED"
        except Superseded:
            proof["reason"]="userSuperseded"
            raise
        except (ValueError,KeyError,OSError,subprocess.SubprocessError) as error:
            proof["reason"] = error.reason if isinstance(error, TrialStop) else type(error).__name__

    def trials(self, reader):
        texts = [f"Field Notes {name} {self.folder.name}\n" for name in ("A","B")]
        hashes = [digest(t.encode()) for t in texts]
        initial_focus = self.prepare_front(hashes)
        selection_error = None
        if self.drag_only:
            self.out["selection"].update(status="NOT_RUN",planned=0,reason="independentDragOnlyFreshFixture")
        else:
            self.out["selection"]["status"] = "UNKNOWN"
            try:
                self.selection_trials(reader, texts, hashes, initial_focus)
                self.out["selection"]["status"] = "PASS"
            except Superseded:
                raise
            except TrialStop as error:
                if self.attempt is not None and self.attempt["status"] != "PASS":
                    self.attempt.update(status=error.status, reason=error.reason)
                self.out["selection"].update(status=error.status, reason=error.reason)
                self.seal()
                if self.focus_only or error.reason in ("mouseUpTargetOrScopeChanged", "mouseDownAdmissionChanged"):
                    raise
                selection_error = error
        if self.focus_only:
            self.out.update(status="PASS",reason="tenExactAlternatingPointerSelectionsAndInputs")
            return
        self.attempt = None
        hashes = [digest(t.encode()) for t in texts]
        self.read_until(None, hashes, "BeforeIndependentDrags", ready=True, focus=True)
        a, b = self.binding["numbers"]
        phase = "self"
        try:
            anchor = self.geometry(a, hashes)
            policy = self.profile_policy(anchor)
            area = work_rect(anchor, policy)
            sides = halves(area)
            self.out["workRect"] = {"usable":anchor["visible"], "panel":anchor["panel"], "policy":policy, "ordinary":area,
                                    "source":"independent NSScreen usable bounds, actual installed panel, isolated configuration"}
            initial = [list(rect(x)) for x in anchor["cg"]]
            for phase, expected, baseline in (("self", initial, initial), ("right", sides[::-1], initial), ("left", sides, sides[::-1])):
                require(phase == "self" or not all(close(x,y) for x,y in zip(baseline, expected)), "noDistinguishableGeometryChange")
                self.drag(phase, hashes, anchor, expected, baseline)
            self.capture_pair(hashes, anchor, sides)
        except Superseded:
            self.out["drags"][phase].update(status="BLOCKED",reason="userSuperseded")
            raise
        except TrialStop as error:
            self.out["drags"][phase].update(status=error.status, reason=error.reason)
            if error.reason in ("dragPathLeftQualifiedHostPanel", "mouseUpTargetOrScopeChanged"):
                raise
        if selection_error:
            raise selection_error
        statuses = [e["status"] for e in self.out["drags"].values()]
        self.out.update(status="PASS" if statuses == ["PASS"]*3 else next(s for s in statuses if s != "PASS"),
                        reason=("threeIndependentlyObservedOrdinaryDragChecks" if self.drag_only else "tenExactPointerInputsAndThreeOrdinaryDragChecks")
                        if statuses == ["PASS"]*3 else "dragPhaseIncomplete")

    def publish(self):
        rows = self.out["attempts"]
        self.out["scenario"] = "pair-drag" if self.drag_only else "pair-focus" if self.focus_only else "pair-pointer"
        if any(v.get("issued") for v in self.out["drags"].values()) and self.out["operationStatus"] == "NOT_RUN":
            self.out["operationStatus"] = self.out["status"]
        if self.out["selection"]["status"] == "UNKNOWN":
            self.out["selection"].update(status=self.out["operationStatus"],reason=self.out["reason"])
        samples = [v["timing"] for v in rows if v.get("timing")]
        self.out["selection"].update(attempted=len(rows), inputsConfirmed=self.out["passes"], focusTimed=len(samples),
                                      notAttempted=self.out["selection"]["planned"]-len(rows))
        self.out["measurement"]["statistics"] = {k:summary([row[k] for row in samples]) for k in
            ("downToFocusLowerMs","downToFocusUpperMs","upToFocusLowerMs","upToFocusUpperMs","secondPositiveAfterUpMs")}
        self.out["measurement"]["percentiles"] = "sample only, median p50, nearest-rank p95"
        self.rec.write("pair-pointer.json", self.out)
        self.rec.summary["pairPointer"] = {k:self.out[k] for k in ("status","operationStatus","reason","selection","measurement","cleanup")}
        self.rec.scenarios["ordinary-pair-pointer"] = {"status":self.out["status"],"reason":self.out["reason"]}
