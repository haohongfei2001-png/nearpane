import copy
from hashlib import sha256
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from uuid import UUID

from evaluate import (
    RECOVERIES,
    assess,
    compare_order,
    distribution,
    paired_direction,
    prerequisites,
    read_run,
    resource_stats,
    workload_classes,
)
from witness import EvidenceError, artifact, hit_regions, transition


def ident(n):
    return str(UUID(int=n))


def fingerprint(n):
    return sha256(str(n).encode()).hexdigest()


def writer(pid):
    return dict(pid=pid, birth=pid * 111, codeSHA256=fingerprint(pid))


BOOT = ident(22)
CANDIDATE = fingerprint("candidate")
A, B = ident(1), ident(2)
G, H = ident(3), ident(4)


class Synthetic:
    """Temporary offline data only. None of these witnesses may be published as device observations."""

    def __init__(self, root):
        self.root = root
        self.count = 0

    def write(self, data, *, lines=False):
        self.count += 1
        path = self.root / f"test-only-{self.count}"
        binary = ("\n".join(json.dumps(row) for row in data) if lines else json.dumps(data)).encode()
        path.write_bytes(binary)
        return dict(path=path.name, sha256=sha256(binary).hexdigest())

    def env(self, system, hz=60):
        displays = [
            dict(
                idSHA256=fingerprint(401),
                physical=True,
                scale=2,
                nominalHz=hz,
                pixelWidth=1800,
                pixelHeight=1200,
                colorSpace="sRGB",
                originPoints=[0, 0],
            )
        ]
        if hz > 61:
            displays.append(dict(displays[0], idSHA256=fingerprint(402), originPoints=[900, 0]))
        install = (
            dict(
                bundlePath="/Applications/Nearpane.app",
                sha256=CANDIDATE,
                signatureVerified=True,
                teamID="ZB9D4T66QB",
            )
            if system == "nearpane"
            else dict(owner="AppleStageManager", appleSigned=True, signatureVerified=True)
        )
        install["controlOwner"] = dict(
            **writer(901 if system == "nearpane" else 902),
            bundleID="com.holdsnow.nearpane.alpha" if system == "nearpane" else "com.apple.dock",
            path="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost"
            if system == "nearpane"
            else "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
        )
        return dict(
            physicalMac=True,
            hosted=False,
            hardwareSHA256=fingerprint(4),
            bootUUID=BOOT,
            osVersion="27.0",
            build="26A428",
            sipEnabled=True,
            displays=displays,
            activeDisplay=displays[0]["idSHA256"],
            powerMode="AC",
            inputDeviceSHA256=fingerprint("mouse"),
            warmCold="warm",
            applicationRevisions=[fingerprint(700)],
            documentSHA256=[fingerprint(9)],
            initialGeometry={"layout": fingerprint("declared")},
            fixtureRevision=fingerprint("fixture"),
            observerRevision=fingerprint("observer"),
            permissions=dict(screenRecording=True, accessibility=True),
            highRefreshSupported=True,
            systemUnderTest=install,
        )

    def sample(self, session, index, start, *, reverse=False, hz=60, block=1, pair=1):
        session = ident(session) if type(session) is int else session
        intent = ident(int(UUID(session)) * (1 << 24) + index)
        old, new = (B, A) if reverse else (A, B)
        groups = (H, G) if reverse else (G, H)
        windows = {
            w: {
                **writer(500 + i),
                "window": 600 + i,
                "hitFingerprint": hit_regions([[0, 0, 200, 200]]),
                "hitRegionsPixels": [[0, 0, 200, 200]],
                "visualMarkerSHA256": fingerprint("paint-" + w),
            }
            for i, w in enumerate([A, B])
        }
        inc = int(1e9 / hz)
        rect = [200, 160, 320, 240]
        marker = fingerprint(intent)
        act = dict(
            session=session,
            clockDomain=BOOT,
            intent=intent,
            sequence=index,
            inputNS=start,
            entry="physicalMouseDown",
            dispatchStartNS=start + 1,
            dispatchEndNS=start + 10,
            returnCode=0,
            cancelled=False,
            timedOut=False,
            rollback="none",
            fromWindows={old: windows[old]},
            toWindows={new: windows[new]},
            preferred=new,
            markerSHA256=marker,
            goalPixels={new: rect},
            fromGroup=groups[0],
            toGroup=groups[1],
            inputSource="hardwareHID",
            deviceSHA256=fingerprint("mouse"),
            block=block,
            pair=pair,
            nativeInputTick=start,
        )
        snapshots = [
            dict(
                presentedNS=start + shift * inc,
                nativeDisplayTick=start + shift * inc,
                managedVisibleLeases=[old if shift <= 0 else new],
                visibleMarkerSHA256={w: windows[w]["visualMarkerSHA256"] for w in [old if shift <= 0 else new]},
                complete=True,
            )
            for shift in (-1, 0, 1, 2, 3)
        ]

        def z_order(window):
            return [dict(lease=window, cgNumber=windows[window]["window"], level=0)]

        observed = {
            w: {**windows[w], "cgNumber": windows[w]["window"], "axNumber": windows[w]["window"]}
            for w in windows
        }
        view = dict(
            session=session,
            clockDomain=BOOT,
            intent=intent,
            frameSource="physicalDisplaySCStream",
            geometrySource="AXAndCGWindow",
            windows=observed,
            focusedWindow=new,
            keyWindow=new,
            focusNS=start + inc,
            inactiveHits=[
                dict(
                    actualMouseDown=True,
                    inputSource="hardwareHID",
                    window=old,
                    hitFingerprint=windows[old]["hitFingerprint"],
                    receiverCountBefore=0,
                    receiverCountAfter=0,
                    points=[[1, 1]],
                )
            ],
            bystandersBefore=fingerprint("b"),
            bystandersAfter=fingerprint("b"),
            dockBefore=fingerprint("dock"),
            dockAfter=fingerprint("dock"),
            nativeBefore=fingerprint("native"),
            nativeAfter=fingerprint("native"),
            unregisteredSurfaces=[],
            orderBefore=z_order(old),
            orderDuring=z_order(new),
            orderAfter=z_order(new),
            axPixels={new: rect},
            cgPixels={new: rect},
            frames=snapshots,
            settledNS=start + inc * 2,
            displayDropped=0,
            displayExpected=len(snapshots),
            displayAccountingComplete=True,
        )
        owner = dict(
            session=session,
            clockDomain=BOOT,
            intent=intent,
            entry="fixtureAppKitReceiver",
            markerSHA256=marker,
            writer=windows[new],
            receivedCGNumber=windows[new]["window"],
            window=new,
            receivedNS=start + inc + 100,
            nativeReceivedTick=start + inc + 100,
            documentSHA256Before={old: fingerprint("old"), new: fingerprint("before")},
            documentSHA256After={old: fingerprint("old"), new: fingerprint("after")},
        )
        return act, view, owner

    def rows(self, name, session, body):
        roles = {
            "physical-input": 201,
            "display-ax-cg": 202,
            "owner-receipts": 203,
            "process-accounting": 204,
            "system-lifecycle": 205,
            "fixture-scenario": 206,
        }
        header = dict(
            schema=1,
            role=name,
            session=session,
            boot=BOOT,
            clock="mach-continuous-ns",
            calibration=dict(
                firstTick=1,
                lastTick=10**15,
                firstContinuousNS=1,
                lastContinuousNS=10**15,
                numer=1,
                denom=1,
                uncertaintyNS=0,
            ),
            **writer(roles[name]),
        )
        return self.write([header] + body, lines=True)

    def run(self, system, tag, n, *, hz=60, paired=False):
        session = ident(tag)
        env = self.env(system, hz)
        parts = [[], [], []]
        for i in range(n):
            block = i // (n // 2) + 1 if paired else 1
            shift = (int(system == "apple") if block % 2 == 0 else int(system == "nearpane")) * 500
            start = (2000 * block + shift + i + 20) * 1_000_000_000
            packet = self.sample(session, i + 1, start, reverse=bool(i % 2), hz=hz, block=block, pair=i + 1)
            packet[0].update(hitCGNumber=999, targetControlSHA256=fingerprint("target:" + packet[0]["toGroup"]))
            packet[1]["inputHit"] = dict(
                **env["systemUnderTest"]["controlOwner"],
                cgNumber=999,
                controlSHA256=packet[0]["targetControlSHA256"],
                hitAtInput=True,
                displaySHA256=env["activeDisplay"],
            )
            for out, item in zip(parts, packet):
                out.append(item)
        run = dict(session=session, environment=self.write(env))
        for key, role, body in zip(
            ("input", "observations", "owners"), ("physical-input", "display-ax-cg", "owner-receipts"), parts
        ):
            run[key] = self.rows(role, session, body)
        if paired:
            run["workload"] = self.rows(
                "fixture-scenario",
                session,
                [
                    dict(
                        fixtureRevision=env["fixtureRevision"],
                        groupLayout=env["initialGeometry"],
                        classes=["crossApp", "twoGroupsOneWindow"],
                    )
                ],
            )
            counters = []
            for mode, seconds in (("idle", 1), ("switch", 1), ("cycle", 600)):
                for k in range(3):
                    resource = dict(
                        mode=mode,
                        startNS=1 + int(k * seconds * 1e9),
                        endNS=1 + int((k + 1) * seconds * 1e9),
                        engineBaseline=dict(durationNS=1_000_000_000, cpuNS=0, residentBytes=20_000_000),
                    )
                    for pid, component in enumerate(("engine", "WindowServer", "replayd"), 700):
                        resource[component] = dict(
                            **writer(pid), cpuStartNS=0, cpuEndNS=int(seconds * 1e6), residentBytes=22_000_000
                        )
                    counters.append(resource)
            run["resources"] = self.rows("process-accounting", session, counters)
            recovery = [
                dict(
                    kind=k,
                    stableNotificationNS=5,
                    reconciledNS=6,
                    unownedHidden=[],
                    originalIdentitySHA256=fingerprint(9),
                    restoredIdentitySHA256=fingerprint(9),
                )
                for k in RECOVERIES
            ]
            native = [
                dict(
                    kind=k,
                    systemAcquiredNS=3,
                    systemReleasedNS=4,
                    writeTraceComplete=True,
                    writesWhileSystemOwned=[],
                )
                for k in ("spaceChange", "fullscreen", "splitView", "missionControl", "stageManager")
            ]
            run["lifecycle"] = self.rows("system-lifecycle", session, recovery + native)
        return run


class Bench(unittest.TestCase):
    def setUp(self):
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.s = Synthetic(self.root)

    def test_real_channels_are_separate_and_bound_to_exact_receiving_window(self):
        action, view, owner = self.s.sample(101, 1, 100_000_000)
        self.assertGreater(transition(action, view, owner, 2)["firstMS"], 0)
        for key, changed, cause in (
            ("window", A, "wrongWindowReceivedMarker"),
            ("receivedCGNumber", 999, "ownerSideWindowNumberChanged"),
            ("markerSHA256", fingerprint(333), "unrelatedOwnerOrMarker"),
        ):
            with self.assertRaisesRegex(EvidenceError, cause):
                transition(action, view, dict(owner, **{key: changed}), 2)
        stale = copy.deepcopy(view)
        stale["windows"][A]["axNumber"] += 1
        with self.assertRaisesRegex(EvidenceError, "AXCGWindowOrProcessGenerationChanged"):
            transition(action, stale, owner, 2)

    def test_wrong_pixel_and_inactive_pointer_are_not_exclusions(self):
        action, view, owner = self.s.sample(101, 1, 100_000_000)
        wrong = copy.deepcopy(view)
        wrong["frames"][2]["managedVisibleLeases"] = [ident(33)]
        with self.assertRaisesRegex(EvidenceError, "wrongGroupFrame"):
            transition(action, wrong, owner, 2)
        click = copy.deepcopy(view)
        click["inactiveHits"][0]["receiverCountAfter"] = 1
        with self.assertRaisesRegex(EvidenceError, "inactiveWindowReceivedPointer"):
            transition(action, click, owner, 2)
        missing = copy.deepcopy(view)
        missing["frames"][1]["complete"] = False
        with self.assertRaisesRegex(EvidenceError, "unknownFramePixels"):
            transition(action, missing, owner, 2)

    def test_100_per_direction_percentiles_and_native_relative_guard(self):
        self.assertEqual(distribution(range(1, 101)), {"p50": 50, "p95": 95, "p99": 99})
        sample = transition(*self.s.sample(101, 1, 100_000_000), 2)
        with self.assertRaisesRegex(EvidenceError, "fewerThan100"):
            paired_direction([sample] * 99, [sample] * 99, 60)
        slow = dict(sample, firstMS=99, interactiveMS=140)
        result = paired_direction([sample] * 100, [slow] * 100, 60)
        self.assertEqual(result["checks"]["firstMS_p50"], "PASS")
        self.assertEqual(result["checks"]["firstMS_relativeP95"], "FAIL")
        borderline = dict(sample, firstMS=149, presentationErrorMS=4)
        self.assertEqual(
            paired_direction([sample] * 100, [borderline] * 100, 60)["checks"]["firstMS_p95"], "UNKNOWN"
        )

    def test_gate_refusal_does_not_open_nonexistent_performance_data(self):
        q = self.s.write(dict(status="FAIL", reason="parkedWindowReceivedRealMouseDown"))
        result = assess(
            self.root,
            dict(
                schema=1,
                candidateSHA256=CANDIDATE,
                qualification=q,
                cases=[{"apple": "path-that-must-never-open"}],
            ),
        )
        self.assertEqual(
            (result["status"], result["cases"], result["prerequisiteStatus"]), ("NOT_RUN", [], "FAIL")
        )

    def test_hash_check_and_cross_channel_actor_identity(self):
        run = self.s.run("apple", 101, 1)
        with self.assertRaisesRegex(EvidenceError, "artifactDigestChanged"):
            artifact(self.root, dict(run["input"], sha256=fingerprint("bad")), lines=True)
        rows = artifact(self.root, run["observations"], lines=True)
        rows[0].update(writer(201))
        run["observations"] = self.s.write(rows, lines=True)
        with self.assertRaisesRegex(EvidenceError, "observerIsActuator"):
            read_run(self.root, run, "apple", CANDIDATE, set())

    def test_raw_clocks_replayed_markers_and_hosted_are_refused(self):
        for defect, expected in (
            ("clock", "rawTimestampOutsideBoundClock"),
            ("marker", "reusedInputMarker"),
            ("hosted", "requiresPhysicalMac"),
            ("simulated", "inputDeviceOrPhysicalEventUnconfirmed"),
        ):
            run = self.s.run("apple", 111, 2)
            if defect == "hosted":
                run["environment"] = self.s.write(dict(artifact(self.root, run["environment"]), hosted=True))
            else:
                rows = artifact(self.root, run["input"], lines=True)
                if defect == "clock":
                    rows[1]["nativeInputTick"] += 200
                if defect == "marker":
                    rows[2]["markerSHA256"] = rows[1]["markerSHA256"]
                if defect == "simulated":
                    rows[1]["inputSource"] = "postedCGEvent"
                run["input"] = self.s.write(rows, lines=True)
            with self.assertRaisesRegex(EvidenceError, expected):
                read_run(self.root, run, "apple", CANDIDATE, set())

    def test_declaring_five_windows_or_stale_pixels_never_supplies_the_evidence(self):
        action, view, owner = self.s.sample(116, 1, 100_000_000)
        measured = transition(action, view, owner, 2)
        with self.assertRaisesRegex(EvidenceError, "declaredWorkloadNotObserved"):
            workload_classes(dict(classes=["fiveWindowLoad"]), [measured])
        view["frames"][-1]["visibleMarkerSHA256"][B] = fingerprint("previous epoch")
        with self.assertRaisesRegex(EvidenceError, "staleOrIncorrectCompositedPixels"):
            transition(action, view, owner, 2)

    def test_1000_gate_requires_1000_distinct_completed_witnesses(self):
        phases = {
            k: self.s.run("nearpane", 200 + i, n)
            for i, (k, n) in enumerate((("single", 1), ("ten", 10), ("fifty", 50), ("soak", 999)))
        }
        qualification = dict(
            kind="installed-stagegroup-safety",
            provider="spaces",
            status="PASS",
            candidateSHA256=CANDIDATE,
            phases=phases,
        )
        with self.assertRaisesRegex(EvidenceError, "incompleteSafetyPhase:soak"):
            prerequisites(self.root, qualification, CANDIDATE, set())

    def test_synthetic_end_to_end_and_unmatched_power_mode(self):
        phases = {
            k: self.s.run("nearpane", 400 + i, n)
            for i, (k, n) in enumerate((("single", 1), ("ten", 10), ("fifty", 50), ("soak", 1000)))
        }
        q = self.s.write(
            dict(
                kind="installed-stagegroup-safety",
                provider="spaces",
                status="PASS",
                candidateSHA256=CANDIDATE,
                phases=phases,
            )
        )
        cases = []
        for i, hz in enumerate((60, 120)):
            cases.append(
                dict(
                    id=str(hz),
                    directions=[[G, H], [H, G]],
                    apple=self.s.run("apple", 500 + i * 2, 200, hz=hz, paired=True),
                    nearpane=self.s.run("nearpane", 501 + i * 2, 200, hz=hz, paired=True),
                )
            )
        manifest = dict(schema=1, candidateSHA256=CANDIDATE, qualification=q, cases=cases)
        result = assess(self.root, manifest)
        self.assertEqual(result["status"], "NOT_RUN", result)
        self.assertEqual([c["status"] for c in result["cases"]], ["PASS", "PASS"], result)
        self.assertIn("fiveWindowLoad", result["missingCoverage"]["workloads"])
        self.assertEqual(result["qualificationCounts"]["soak"], 1000)
        env = artifact(self.root, cases[0]["apple"]["environment"])
        cases[0]["apple"]["environment"] = self.s.write(dict(env, powerMode="different"))
        result = assess(self.root, manifest)
        self.assertEqual(result["cases"][0]["status"], "NOT_COMPARABLE")

    def test_order_and_resource_missing_timing(self):
        p = transition(*self.s.sample(101, 1, 100_000_000), 2)
        a = [dict(p, block=i, pair=i, inputNS=i * 1e9) for i in (1, 2)]
        b = [dict(x, inputNS=x["inputNS"] + 1e8) for x in a]
        with self.assertRaisesRegex(EvidenceError, "blockOrderNotCounterbalanced"):
            compare_order(a, b)
        run = self.s.run("apple", 99, 4, paired=True)
        rows = artifact(self.root, run["resources"], lines=True)
        rows[-1]["endNS"] = rows[-1]["startNS"] + 10
        run["resources"] = self.s.write(rows, lines=True)
        with self.assertRaisesRegex(EvidenceError, "ThirtyMinute"):
            resource_stats(self.root, run, self.s.env("apple"))


if __name__ == "__main__":
    unittest.main()
