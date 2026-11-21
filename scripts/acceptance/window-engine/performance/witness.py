"""Validate externally captured Gate 4 channels. This module performs no system observation or input."""

from hashlib import sha256
import json
import math
from pathlib import Path
import re
from struct import pack
from uuid import UUID


class EvidenceError(ValueError):
    def __init__(self, status, reason):
        super().__init__(reason)
        self.status = status


def require(value, reason, status="UNKNOWN"):
    if not value:
        raise EvidenceError(status, reason)


def integer(value, name, minimum=0):
    require(type(value) is int and value >= minimum, name)
    return value


def real(value, name, minimum=0):
    require(type(value) in (float, int) and math.isfinite(value) and value >= minimum, name)
    return value


def digest(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value), "invalidSHA256")
    return value


def uuid(value):
    try:
        return str(UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise EvidenceError("UNKNOWN", "invalidUUID") from None


def artifact(root, ref, *, lines=False):
    require(isinstance(ref, dict), "missingHashedArtifact")
    relative = ref["path"]
    digest(ref["sha256"])
    require(isinstance(relative, str) and relative and not Path(relative).is_absolute(), "unsafeArtifactPath")
    original = root / relative
    actual = original.resolve(strict=True)
    require(original == actual and actual.is_relative_to(root) and actual.is_file(), "unsafeArtifactPath")
    require(actual.stat().st_size <= 256 * 1024 * 1024, "artifactTooLarge")
    data = actual.read_bytes()
    require(sha256(data).hexdigest() == ref["sha256"], "artifactDigestChanged")
    if lines:
        return [json.loads(line) for line in data.splitlines()]
    return json.loads(data)


def identity(row):
    return (
        integer(row["pid"], "invalidPID", 2),
        integer(row["birth"], "invalidBirth", 1),
        digest(row["codeSHA256"]),
    )


def leases(rows):
    require(isinstance(rows, dict) and 0 < len(rows) <= 64, "missingWindowLifetimes")
    seen = set()
    for key, value in rows.items():
        uuid(key)
        pid, birth, _ = identity(value)
        window = integer(value["window"], "invalidCGWindowID", 1)
        require((pid, birth, window) not in seen, "duplicateWindowLease")
        seen.add((pid, birth, window))
    return set(rows)


def channel(root, ref, role, session, boot):
    rows = artifact(root, ref, lines=True)
    require(rows and isinstance(rows[0], dict), "missingChannelHeader")
    header = rows[0]
    require(
        header["schema"] == 1
        and header["role"] == role
        and header["session"] == session
        and header["boot"] == boot
        and header["clock"] == "mach-continuous-ns",
        "channelIdentityOrClockMismatch",
    )
    if role in {"physical-input", "display-ax-cg", "owner-receipts"}:
        calibration = header["calibration"]
        start = integer(calibration["firstTick"], "invalidClockAnchor", 1)
        end = integer(calibration["lastTick"], "invalidClockAnchor", start + 1)
        base = integer(calibration["firstContinuousNS"], "invalidClockAnchor", 1)
        numer = integer(calibration["numer"], "invalidTimebase", 1)
        denom = integer(calibration["denom"], "invalidTimebase", 1)
        error = integer(calibration["uncertaintyNS"], "missingClockUncertainty")

        def check(tick, stamp):
            integer(tick, "missingRawClockSample", start)
            integer(stamp, "missingCalibratedTime", 1)
            require(
                tick <= end and abs(base + (tick - start) * numer // denom - stamp) <= error,
                "rawTimestampOutsideBoundClock",
                "NOT_COMPARABLE",
            )

        check(end, calibration["lastContinuousNS"])
        for row in rows[1:]:
            row["_clockErrorNS"] = error
            if "excluded" in row:
                continue
            if role == "physical-input":
                check(row["nativeInputTick"], row["inputNS"])
            elif role == "owner-receipts":
                check(row["nativeReceivedTick"], row["receivedNS"])
            else:
                for frame in row["frames"]:
                    check(frame["nativeDisplayTick"], frame["presentedNS"])
    return identity(header), rows[1:]


def edge_errors(frames, expected, scale):
    require(set(frames) == set(expected) and bool(expected), "incompleteTargetGeometry")
    errors = []
    for key, target in expected.items():
        row = frames[key]
        require(
            isinstance(row, list)
            and isinstance(target, list)
            and len(row) == len(target) == 4
            and all(type(x) in (int, float) and math.isfinite(x) for x in row + target)
            and min(row[2:] + target[2:]) > 0,
            "invalidPhysicalPixelGeometry",
        )
        # Rects use global physical pixels; compare the four edges in points.
        for index in (0, 1):
            errors.extend(
                (
                    abs(target[index] - row[index]) / scale,
                    abs(target[index] + target[index + 2] - row[index] - row[index + 2]) / scale,
                )
            )
    return max(errors)


def hit_regions(values):
    require(isinstance(values, list) and 0 < len(values) <= 128, "missingFormerHitRegions")
    data = b""
    for rect in values:
        require(
            isinstance(rect, list)
            and len(rect) == 4
            and all(type(n) in (int, float) and math.isfinite(n) for n in rect)
            and min(rect[2:]) > 0,
            "invalidFormerHitRegion",
        )
        data += pack(">dddd", *rect)
    return sha256(data).hexdigest()


def transition(action, observer, owner, scale):
    intent = uuid(action["intent"])
    require(observer["intent"] == owner["intent"] == intent, "unrelatedIntent")
    require(
        action["entry"] == "physicalMouseDown"
        and observer["frameSource"] == "physicalDisplaySCStream"
        and observer["geometrySource"] == "AXAndCGWindow"
        and owner["entry"] == "fixtureAppKitReceiver",
        "nonEquivalentObserverOrActuation",
        "NOT_COMPARABLE",
    )
    t0 = integer(action["inputNS"], "physicalInputClockMissing", 1)
    start = integer(action["dispatchStartNS"], "missingDispatchStart", t0)
    integer(action["dispatchEndNS"], "invalidDispatchEnd", start)
    integer(action["returnCode"], "missingReturnCode")
    require(
        action["cancelled"] is False and action["timedOut"] is False and action["rollback"] == "none",
        "cancelledTimeoutOrRollback",
    )
    source, target = leases(action["fromWindows"]), leases(action["toWindows"])
    require(set.isdisjoint(source, target), "overlappingSourceAndTarget")
    wanted = action["preferred"]
    require(wanted in target and set(action["goalPixels"]) == target, "unboundPreferredTarget")
    declared = {**action["fromWindows"], **action["toWindows"]}
    require(
        len({digest(member["visualMarkerSHA256"]) for member in declared.values()}) == len(declared),
        "ambiguousFixturePixelMarkers",
    )
    observed = observer["windows"]
    require(set(observed) == source | target, "incompleteIndependentWindowRoster")
    for key, member in declared.items():
        row = observed[key]
        require(
            identity(row) == identity(member) and row["cgNumber"] == row["axNumber"] == member["window"],
            "AXCGWindowOrProcessGenerationChanged",
        )
    require(
        observer["session"] == owner["session"] == action["session"]
        and owner["markerSHA256"] == digest(action["markerSHA256"]),
        "unrelatedOwnerOrMarker",
    )
    require(owner["window"] in source | target, "receiverNotEnrolled")
    require(owner["window"] == wanted, "wrongWindowReceivedMarker", "FAIL")
    require(
        identity(owner["writer"]) == identity(action["toWindows"][wanted]), "receiverProcessGenerationChanged"
    )
    require(owner["receivedCGNumber"] == declared[wanted]["window"], "ownerSideWindowNumberChanged")
    require(
        observer["focusedWindow"] == wanted and observer["keyWindow"] == wanted, "wrongAXOrKeyWindow", "FAIL"
    )
    before, after = owner["documentSHA256Before"], owner["documentSHA256After"]
    require(set(before) == set(after) == source | target, "incompleteOwnerFileInventory")
    changed = {key for key in before if digest(before[key]) != digest(after[key])}
    require(changed == {wanted}, "wrongDocumentChangedOrMarkerAbsent", "FAIL")
    focus_ns = integer(observer["focusNS"], "unboundedFocusClock", t0)
    owner_ns = integer(owner["receivedNS"], "unboundedOwnerInputClock", t0)
    require(observer["clockDomain"] == owner["clockDomain"] == action["clockDomain"], "clockDomainChanged")
    require(isinstance(observer["inactiveHits"], list), "missingPointerIsolation")
    exercised = {lease: set() for lease in source}
    for hit in observer["inactiveHits"]:
        require(hit["actualMouseDown"] is True and hit["window"] in source, "unboundFormerHitRegion")
        require(
            integer(hit["receiverCountAfter"], "missingMouseCounter")
            == integer(hit["receiverCountBefore"], "missingMouseCounter"),
            "inactiveWindowReceivedPointer",
            "FAIL",
        )
        require(
            hit["hitFingerprint"] == action["fromWindows"][hit["window"]]["hitFingerprint"]
            and len(hit["points"]) >= 1
            and all(
                len(p) == 2 and all(type(n) in (int, float) and math.isfinite(n) for n in p)
                for p in hit["points"]
            ),
            "unverifiedFormerHitRegion",
        )
        lease = hit["window"]
        regions = declared[lease]["hitRegionsPixels"]
        require(
            hit["hitFingerprint"] == hit_regions(regions) and hit["inputSource"] == "hardwareHID",
            "inputOutsideEnrolledHitRegions",
        )
        if hit.get("shield") is not None:
            shield = hit["shield"]
            require(
                shield["ignoresMouseEvents"] is False
                and shield["topAtDown"] is True
                and shield["keyUnchanged"] is True,
                "shieldDidNotProtectFormerHitRegion",
                "FAIL",
            )
        for index, (x, y, width, height) in enumerate(regions):
            if any(x <= px < x + width and y <= py < y + height for px, py in hit["points"]):
                exercised[lease].add(index)
    require(
        all(exercised[lease] == set(range(len(declared[lease]["hitRegionsPixels"]))) for lease in source),
        "incompleteFormerHitRegionCoverage",
    )
    for before_key, after_key, name in [
        ("bystandersBefore", "bystandersAfter", "bystanderGeometryVisibilityFocusOrMembershipChanged"),
        ("dockBefore", "dockAfter", "dockTilesOrIconsChanged"),
        ("nativeBefore", "nativeAfter", "unrequestedNativeStateChanged"),
    ]:
        require(digest(observer[before_key]) == digest(observer[after_key]), name, "FAIL")
    require(observer["unregisteredSurfaces"] == [], "unobservedSurfaceMayAffectTrial")
    for stage, visible_group in (
        ("orderBefore", source),
        ("orderDuring", source | target),
        ("orderAfter", target),
    ):
        order = observer[stage]
        require(
            isinstance(order, list)
            and order
            and all(
                entry["lease"] in declared
                and type(entry["level"]) is int
                and entry["cgNumber"] == declared[entry["lease"]]["window"]
                for entry in order
            )
            and len(set(entry["lease"] for entry in order)) == len(order),
            "missingWindowOrdering",
        )
        require(order[0]["lease"] in visible_group, "wrongManagedFrontWindow", "FAIL")
    errors = [edge_errors(observer[k], action["goalPixels"], scale) for k in ("axPixels", "cgPixels")]
    require(max(errors) <= 1, "layoutEdgeBeyondOnePoint", "FAIL")
    frames = observer["frames"]
    require(isinstance(frames, list) and len(frames) >= 3, "missingPhysicalFrames")
    last = None
    intervals, first_target, last_outgoing, blank, worst_blank = [], None, None, 0, 0
    gone = False
    for i, frame in enumerate(frames):
        stamp = integer(frame["presentedNS"], "invalidDisplayTime", 1)
        require(last is None or stamp > last, "nonmonotonicFrames")
        require(frame["complete"] is True, "unknownFramePixels")
        visible = set(frame["managedVisibleLeases"])
        require(visible <= source | target, "wrongGroupFrame", "FAIL")
        colors = frame["visibleMarkerSHA256"]
        require(set(colors) == visible, "incompleteWindowPixelMarkers")
        for lease in visible:
            require(
                digest(colors[lease]) == digest(declared[lease]["visualMarkerSHA256"]),
                "staleOrIncorrectCompositedPixels",
                "FAIL",
            )
        if i == 0:
            require(stamp <= t0 and visible == source, "missingKnownSourceFrame")
        if stamp < t0:
            require(visible == source, "presentationChangedBeforeInput")
        if stamp >= t0 and visible & target and first_target is None:
            first_target = stamp
        if first_target is not None:
            if not visible & source:
                gone = True
            elif gone:
                raise EvidenceError("FAIL", "inactiveWindowFlash")
        if visible & source:
            last_outgoing = stamp
        blank = blank + 1 if not visible else 0
        worst_blank = max(blank, worst_blank)
        if last is not None:
            intervals.append((stamp - last) / 1e6)
        last = stamp
    require(
        first_target is not None and last_outgoing is not None and visible == target,
        "targetGroupPresentationUnconfirmed",
    )
    require(worst_blank <= 1, "blankLongerThanOneFrame", "FAIL")
    settled = integer(observer["settledNS"], "settleBeforePresentation", first_target)
    require(last_outgoing <= settled and last >= settled, "missingFrameAroundFinalGeometry")
    drops = integer(observer["displayDropped"], "missingDropCount")
    expected = integer(observer["displayExpected"], "missingExpectedFrameSlots", len(frames))
    require(
        expected == len(frames) + drops and observer["displayAccountingComplete"] is True,
        "incompleteDisplayAccounting",
    )
    return dict(
        intent=intent,
        sequence=integer(action["sequence"], "missingInputSequence", 1),
        inputNS=t0,
        direction=(uuid(action["fromGroup"]), uuid(action["toGroup"])),
        firstMS=(first_target - t0) / 1e6,
        interactiveMS=(max(focus_ns, owner_ns) - t0) / 1e6,
        settledMS=(settled - t0) / 1e6,
        intervals=intervals,
        dropped=drops,
        expected=expected,
        maxEdgePoint=max(errors),
        presentationErrorMS=(action.get("_clockErrorNS", 0) + observer.get("_clockErrorNS", 0)) / 1e6,
        interactiveErrorMS=(
            action.get("_clockErrorNS", 0)
            + max(observer.get("_clockErrorNS", 0), owner.get("_clockErrorNS", 0))
        )
        / 1e6,
        intervalErrorMS=2 * observer.get("_clockErrorNS", 0) / 1e6,
        memberWindows={k: (identity(v), v["window"]) for k, v in declared.items()},
        sourceMembers=source,
        targetMembers=target,
    )
