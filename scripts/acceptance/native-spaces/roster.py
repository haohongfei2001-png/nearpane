"""Measure two synthetic windows in the installed sidebar without capturing personal pixels."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

from acceptance import checked, identity, manifest, wait_state


def same_scale(sizes, previews):
    """AX reports preview dimensions rounded to points. Intersect the possible shared scales."""
    if len(sizes) != 2 or len(previews) != 2 or sizes[0] == sizes[1]:
        return False
    intervals = []
    for source, preview in zip(sizes, previews):
        if len(source) != 2 or len(preview) != 2 or min(source) <= 0 or min(preview) <= 0:
            return False
        intervals.extend(((p - .51) / s, (p + .51) / s) for s, p in zip(source, preview))
    return max(lo for lo, _ in intervals) <= min(hi for _, hi in intervals)


def measure(observer, output):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    read = lambda *args: json.loads(checked([str(observer), *map(str, args)]))
    initial = read()
    host = initial.get("host", {})
    frozen = manifest(initial, observer.parent / "metrics")
    result = {"source": frozen["source"], "build": frozen["build"],
              "permissions": frozen["installedHostCurrentPermissions"],
              "status": "BLOCKED", "pixelsCapturedByObserver": 0}
    proc = None
    numbers = []
    try:
        if not (initial["observerAX"] and frozen["signatureValid"] and frozen["loadedMatchesInstalled"]
                and len(initial["displays"]) == len(initial.get("scopes") or []) == 1):
            return result.update(reason="Installed process, observer AX or single-display scope unavailable")
        scope = initial["scopes"][0]
        counters = json.loads(checked([str(observer.parent / "metrics"), str(host["pid"])]))
        if (counters.get("windowManagementBusy") != 0 or counters.get("visibleDisplays") != 1 or
                not any(r["type"] == 0 and r["id"] == scope["current"] for r in scope["records"])):
            return result.update(reason="Needs visible installed panel, idle window management and current ordinary desktop")
        app = observer.parent / "Field Notes.app"
        fx = app / "Contents/MacOS/FieldNotes"
        signed = identity(fx)["CDHash"]
        folder = observer.parent / str(uuid.uuid4())
        folder.mkdir(mode=0o700)
        start = time.monotonic()
        proc = subprocess.Popen([str(fx), str(folder), "2"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, env=dict(os.environ, NP_FIXTURE_PRESENTATION="roster"))
        state = wait_state(folder / "windows.json", lambda d: d.get("session") == folder.name and d.get("pid") == proc.pid and
                           d.get("birth", 0) > 0 and len(set(d.get("numbers", []))) == 2, start + 7)
        if not state:
            return result.update(reason="No two distinct fixture windows")
        numbers = state["numbers"]
        sizes = state["sizes"]
        samples = []
        while time.monotonic() - start < 8:
            samples = [read("roster-card", host["pid"], host["codeHash"], proc.pid, n, app, signed, scope["scope"],
                            scope["current"], state["birth"]) for n in numbers]
            if all(s.get("observed") for s in samples):
                break
            time.sleep(.15)
        result.update(ownerFrames=sizes, installedCards=samples, secondsToReadback=round(time.monotonic() - start, 3))
        if not all(s.get("observed") for s in samples):
            return result.update(reason="Could not bind both installed controls to the exact owned windows")
        dims = [re.search(r'预览 (\d+) × (\d+) pt', s["value"]) for s in samples]
        if not all(dims):
            return result.update(reason="System could not corroborate both actual window dimensions")
        previews = [[int(v) for v in match.groups()] for match in dims]
        top, bottom = sorted(samples, key=lambda s: s["cardY"])
        valid = (same_scale(sizes, previews) and all(s["spaceRows"] == 0 for s in samples) and
                 top["cardHeight"] > 0 and top["cardY"] + top["cardHeight"] <= bottom["cardY"] + 1)
        result.update(status="PASS" if valid else "FAIL", check="geometry, nonoverlapping vertical order and no Space rows",
                      previewSizes=previews, realPixelsIndependentlyVerified=False)
    finally:
        if proc:
            (folder / "close").touch()
            proc.wait(timeout=8)
        final = read()
        cleanup = {"ownedProcessExited": proc is None or proc.poll() is not None,
                   "ownedWindowsGone": not numbers or read("absence", *numbers).get("allGone", False),
                   "frontmostPreserved": initial.get("frontmostPID") == final.get("frontmostPID"),
                   "scopesPreserved": initial.get("scopes") == final.get("scopes")}
        result["cleanup"] = cleanup
        if not all(cleanup.values()):
            result["status"] = "FAIL"
        (output / "roster-result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    output = Path(sys.argv[2])
    measure(Path(sys.argv[1]).resolve(), output)
    status = json.loads((output / "roster-result.json").read_text())["status"]
    sys.exit({"PASS": 0, "BLOCKED": 2, "FAIL": 1}[status])
