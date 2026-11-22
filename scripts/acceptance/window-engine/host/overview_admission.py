"""Read the private, same-session P0 observation before the regular Host receives a quit request."""
import hashlib
import ctypes
import json
import math
import os
from pathlib import Path
import stat
import time

from visible_strip import replay


def current_hid():
    # CGEventType values in the exact order of StageCanaryOverview.hid().
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    counter = cg.CGEventSourceCounterForEventType
    counter.argtypes = [ctypes.c_int32, ctypes.c_uint32]
    counter.restype = ctypes.c_uint32
    button = cg.CGEventSourceButtonState
    button.argtypes = [ctypes.c_int32, ctypes.c_uint32]
    button.restype = ctypes.c_bool
    secure = ctypes.CDLL("/System/Library/Frameworks/Carbon.framework/Carbon").IsSecureEventInputEnabled
    secure.restype = ctypes.c_bool
    secure.argtypes = []
    start_secure = secure()
    counts = [counter(1, event) for event in (1, 2, 3, 4, 25, 26, 5, 6, 7, 27, 10, 11, 12, 22)]
    pressed = any(button(source, n) for n in range(32) for source in (1, 0))
    return dict(uptime=time.monotonic(), counts=counts, pressed=pressed, secure=start_secure or secure())


def observed_host_phases(phases, pid, birth):
    expected = [("before", 0), ("presented", 1), ("dismissed", 0), ("terminal", 0)]
    if len(phases) != len(expected):
        return False
    previous = 0
    for phase, (name, mode) in zip(phases, expected):
        source = "signedDockMCIdentifier" if mode else "signedDockAXListWithoutMC"
        attempts = phase["attempts"]
        if (phase["phase"] != name or phase["pid"] != pid or phase["missionControlPresented"] != mode or
                phase["missionControlObservation"] != source or not 1 <= len(attempts) <= 5):
            return False
        start, end = phase["startUptime"], phase["endUptime"]
        if not (math.isfinite(start) and math.isfinite(end) and previous <= start <= end):
            return False
        cursor = start
        for attempt in attempts:
            a, b = attempt["uptime"], attempt["endUptime"]
            if (not (math.isfinite(a) and math.isfinite(b) and cursor <= a <= b <= end) or
                    attempt["targetPID"] != pid or attempt["targetBirth"] != birth or
                    attempt["source"] != "installedHostPreviewMetrics"):
                return False
            cursor = b
        last = attempts[-1]
        if (last["status"] != "observed" or last["exit"] != 0 or last["pid"] != pid or
                last["missionControlPresented"] != mode or last["missionControlObservation"] != source):
            return False
        kind = last.get("missionControlSample")
        lo, hi = last.get("missionControlReadStartUptime"), last.get("missionControlReadEndUptime")
        if (kind not in {"requested", "cached"} or type(lo) not in (float, int) or type(hi) not in (float, int)
                or not (math.isfinite(lo) and math.isfinite(hi)
                        and (last["uptime"] if kind == "requested" else start) <= lo <= hi <= last["endUptime"])):
            return False
        previous = end
    return True


def load_receipt(path):
    if path is None:
        raise ValueError("missingPhysicalP0Receipt")
    path = Path(path)
    parent = path.parent
    directory = parent.stat()
    if (path != path.resolve(strict=True) or not path.is_relative_to("/private/tmp") or
            directory.st_uid != os.getuid() or stat.S_IMODE(directory.st_mode) != 0o700):
        raise ValueError("privateP0DirectoryRequired")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or
                info.st_mode & 0o077 or not 0 < info.st_size <= 1_000_000):
            raise ValueError("privateP0ReceiptRequired")
        raw = stream.read(info.st_size + 1)
        if len(raw) != info.st_size or os.fstat(fd).st_mtime_ns != info.st_mtime_ns:
            raise ValueError("p0ReceiptChangedDuringRead")
    return json.loads(raw), hashlib.sha256(raw).hexdigest()


def qualifies_read_only(report, image, pid, birth, now=None):
    """Handoff for signed-fixture membership reads only. This never admits an engine write."""
    try:
        host, scope = report["host"], report["scope"]
        before, after = report["admission"], report["terminalAdmission"]
        phase, = report["hostTelemetry"]
        attempt = phase["attempts"][-1]
        hid = report["hidBeforePassiveRead"]
        stamp = report["terminalReadbackUptime"]
        age = (time.monotonic() if now is None else now) - stamp
        return (report["stage"] == "passiveReadOnly" and report["status"] == "NOT_RUN"
                and report["systemVersion"] == "27.0" and report["build"] == "26A428"
                and report["sip"] == "System Integrity Protection status: enabled."
                and report["sameHostAtEnd"] is True and report["observerAXTrusted"] is True
                and host["pid"] == pid and host["birth"] == birth and host["source"] == image["source"]
                and host["cdhash"] == image["cdhash"] and host["path"] == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost"
                and scope["status"] == "PASS" and scope == report["terminalScope"] and scope["nativeID"] > 0
                and all(scope.get(k) for k in ("displayUUID", "spaceUUID"))
                and not before.get("reason") and not after.get("reason") and after["sameOriginalAX"] is True
                and all(type(before[k]) is int and before[k] > 0 and before[k] == after[k] for k in ("workspacePID","birth","cgWindowID"))
                and phase["phase"] == "passive" and phase["pid"] == pid and attempt["status"] == "observed"
                and attempt["exit"] == 0 and attempt["pid"] == pid and attempt["targetBirth"] == birth and attempt["targetPID"] == pid
                and attempt["missionControlPresented"] == 0 and attempt["missionControlObservation"] == "signedDockAXListWithoutMC"
                and attempt["missionControlSample"] in ("requested","cached")
                and before["uptime"] <= phase["startUptime"] <= attempt["uptime"] <= attempt["endUptime"] <= after["uptime"] <= stamp
                and (attempt["missionControlSample"] == "cached" or attempt["uptime"] <= attempt["missionControlReadStartUptime"]
                     <= attempt["missionControlReadEndUptime"] <= attempt["endUptime"])
                and report["inputAvailableBefore"] is True and report["inputAvailableAfter"] is True
                and 0 <= age <= 30 and len(hid) == 14 and hid == report["hidAfterPassiveRead"]
                and all(type(n) is int and n >= 0 for n in hid)
                and all(report[k] == 0 for k in ("buttonsBefore","buttonsAfter","windowWrites","spaceWrites","launchedHosts")))
    except (KeyError, IndexError, TypeError, ValueError, OverflowError):
        return False


def qualifies(report, image, pid, birth, now=None):
    """Check the underlying points, original retained AX witness and real Host transitions as well as the verdict."""
    try:
        host, m = report["host"], report["measurement"]
        count = m["expectedCount"]
        if (report["status"] != "PASS" or report["stage"] != "physicalP0BeforeWrites" or
                report["build"] != "26A428" or report["systemVersion"] != "27.0" or
                report["sip"] != "System Integrity Protection status: enabled." or
                report["observerAXTrusted"] is not True or report["sameHostAtEnd"] is not True or
                report["hostSequenceConfirmed"] is not True or host["pid"] != pid or host["birth"] != birth or
                host["source"] != image["source"] or host["cdhash"] != image["cdhash"] or
                host["path"] != "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost" or
                any(report[k] != 0 for k in ("windowWrites", "spaceWrites", "launchedHosts")) or
                m["stage"] != "beforeWindowWrites" or m["status"] != "PASS" or m["scopeType"] != 0 or
                report["scope"] != report["scopeImmediatelyBeforeOverview"] or report["scope"]["status"] != "PASS" or
                report["scope"]["nativeID"] != m["currentSpaceID"] or m["currentSpaceID"] not in m["managedIDsBefore"] or
                any(m[k] != 0 for k in ("windowWrites", "spaceWrites", "inputEventsPosted")) or
                any(m[k] is not True for k in ("restored", "inputUninterrupted", "nativeInventoryRestored", "stableHitLayout")) or
                m["presentations"] != 1 or m["dismissals"] != 1 or len(m["hidBefore"]) != 14 or m["hidBefore"] != m["hidAfter"] or
                type(count) is not int or not 1 <= count <= 256 or len(m["managedIDsBefore"]) != count or
                m["managedIDsBefore"] != m["managedIDsAfter"] or m["tileCounts"] != [count, count] or
                len(m["hitTestSamples"]) != 2):
            return False
        if replay(m)["status"] != "PASS" or m["originalFocusConfirmedReads"] != 2:
            return False
        original = m["originalFocus"]
        before, after = m["focusBefore"], m["focusAfter"][-2:]
        terminal = m["terminalFocus"]
        if len(before) != 2 or len(after) != 2 or not all(r["overviewClosed"] is True for r in [*after, terminal]):
            return False
        for row in [*before, *after, terminal]:
            if (row["sameOriginalAX"] is not True or [row["pid"], row["birth"], row["cgWindowID"]] !=
                    [original["pid"], original["birth"], original["window"]]):
                return False
        phases = report["hostTelemetry"]
        if not observed_host_phases(phases, pid, birth):
            return False
        last = m["terminalReadbackUptime"]
        focus_time = terminal["uptime"]
        if not (math.isfinite(focus_time) and math.isfinite(last) and phases[-1]["endUptime"] <= focus_time <= last):
            return False
        # The witness and supervisor use Darwin monotonic uptime, across one signed Host process generation.
        uptime = time.monotonic() if now is None else now
        return last <= uptime and uptime - phases[-1]["endUptime"] <= 300
    except (KeyError, TypeError, ValueError, IndexError, OverflowError):
        return False
