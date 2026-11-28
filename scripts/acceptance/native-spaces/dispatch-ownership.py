"""Check mutual exclusion on the signed installed Host with Stage Manager enabled."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import time

from installed_profile import APP, installed_pid


def read(probe, pid):
    raw = subprocess.check_output([probe, str(pid)], text=True, timeout=12)
    return json.loads(raw)


def sample(probe, metrics, pid):
    return {"observed": read(probe, pid), "host": read(metrics, pid)}


def checks(sample):
    observed = sample["observed"]
    host = sample["host"]
    counts = observed["toolAndRegionCounts"]
    panels = observed["boundVisibleToolPanels"]
    return {
        "stageActive": observed["stageManager"],
        "hostAcknowledged": host.get("stageManagerOwnsDispatch") == 1,
        "toolsPresent": all(counts[name] > 0 for name in ("voice-capture-toggle", "tray-camera-entry", "tray-file-drop")),
        "windowRegionWithdrawn": counts["desktop-reserved-region"] == observed["nativeCards"] == observed["splitMembers"] == 0,
        "compactPhysicalPanel": len(panels) == 1 and panels[0]["height"] < min(observed["visibleScreenHeights"]),
        "noGallery": host["gallerySessions"] == host["visibleDisplays"] == host["activeStreams"] == 0,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe", type=Path)
    parser.add_argument("metrics", type=Path)
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()
    result = {"status": "BLOCKED", "app": str(APP)}
    with args.receipt.open("x") as receipt:
        try:
            pid = installed_pid()
            if not pid:
                raise ValueError("running installed Host unavailable")
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", APP], check=True, timeout=20)
            plist = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
            result.update(source=plist["NearpaneSourceRevision"], version=plist["CFBundleShortVersionString"], build=plist["CFBundleVersion"])
            result["before"] = sample(args.probe, args.metrics, pid)
            time.sleep(2.2)
            result["after"] = sample(args.probe, args.metrics, pid)
            if installed_pid() != pid:
                raise ValueError("installed Host restarted")
            result["checks"] = {name: checks(result[name]) for name in ("before", "after")}
            counters = ("captureRequests", "deliveredFrames")
            result["steadyCapture"] = all(result["before"]["host"][n] == result["after"]["host"][n] for n in counters)
            result["status"] = "PASS" if result["steadyCapture"] and all(all(facts.values()) for facts in result["checks"].values()) else "FAIL"
        except (KeyError, OSError, ValueError, subprocess.SubprocessError) as error:
            result["reason"] = str(error)
        json.dump(result, receipt, indent=2)
        receipt.write("\n")
    print(result["status"])
    return 0 if result["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
