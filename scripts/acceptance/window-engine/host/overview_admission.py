"""Read the private, same-session P0 observation before the regular Host receives a quit request."""
import hashlib
import json
import os
from pathlib import Path
import stat
import time

from visible_strip import replay


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
        if len(before) != 2 or len(after) != 2 or not all(r["overviewClosed"] is True for r in after):
            return False
        for row in before + after:
            if (row["sameOriginalAX"] is not True or [row["pid"], row["birth"], row["cgWindowID"]] !=
                    [original["pid"], original["birth"], original["window"]]):
                return False
        phases = report["hostTelemetry"]
        expected = [("before", 0, "signedDockAXListWithoutMC"), ("presented", 1, "signedDockMCIdentifier"),
                    ("dismissed", 0, "signedDockAXListWithoutMC"), ("terminal", 0, "signedDockAXListWithoutMC")]
        if [(p["phase"], p["missionControlPresented"], p["missionControlObservation"]) for p in phases] != expected:
            return False
        last = phases[-1]["endUptime"]
        # The witness and supervisor use Darwin monotonic uptime, across one signed Host process generation.
        uptime = time.monotonic() if now is None else now
        return all(p["pid"] == pid for p in phases) and 0 <= uptime - last <= 300
    except (KeyError, TypeError, ValueError, IndexError, OverflowError):
        return False
