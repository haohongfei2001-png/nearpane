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
    return scale_possible(sizes, previews)


def scale_possible(sizes, previews):
    intervals = []
    for source, preview in zip(sizes, previews):
        if len(source) != 2 or len(preview) != 2 or min(source) <= 0 or min(preview) <= 0:
            return False
        intervals.extend(((p - .51) / s, (p + .51) / s) for s, p in zip(source, preview))
    return bool(intervals) and max(lo for lo, _ in intervals) <= min(hi for _, hi in intervals)


def evaluate(sizes, cards):
    if len(sizes) != 2 or len(cards) != 2 or not all(card.get("observed") for card in cards):
        return {"status": "BLOCKED", "reason": "Could not bind both installed controls to the exact owned windows"}
    top, bottom = sorted(cards, key=lambda card: card["cardY"])
    vertical = all(c["cardHeight"] > 0 for c in cards) and top["cardY"] + top["cardHeight"] <= bottom["cardY"] + 1
    no_desktops = all(card["spaceRows"] == 0 for card in cards)
    witnesses = []
    for size, card in zip(sizes, cards):
        match = re.search(r"预览 (\d+) × (\d+) pt", card["value"])
        thumbnail = [int(v) for v in match.groups()] if match else None
        cg = card.get("cgSize")
        ax = card.get("axSize")
        different = len(cg or []) == 2 and any(abs(a-b) > 1 for a, b in zip(cg, size))
        ax_confirms = len(ax or []) == 2 and all(abs(a-b) <= 1 for a, b in zip(ax, size))
        withheld = card["value"] == "窗口尺寸待核对"
        witnesses.append({"window": card["window"], "ownerSize": size, "preview": thumbnail,
                          "cgDiffersFromOwner": different, "observerAXConfirmsOwner": ax_confirms,
                          "geometryExplicitlyWithheld": withheld,
                          "presentationMismatchSafelyWithheld": different and ax_confirms and withheld})
    usable = [w for w in witnesses if w["preview"] is not None]
    faithful = scale_possible([w["ownerSize"] for w in usable], [w["preview"] for w in usable]) if usable else None
    if not no_desktops or not vertical or faithful is False:
        status, reason = "FAIL", "Exposed window proportions, vertical order or navigation rows contradicted their witnesses"
    elif len(usable) == 2 and same_scale(sizes, [w["preview"] for w in witnesses]):
        status, reason = "PASS", "Both confirmed window dimensions used one scale in separate, vertically ordered cards"
    else:
        status, reason = "BLOCKED", "Both windows were listed but both true preview dimensions were not established"
    return {"status": status, "reason": reason, "nonoverlappingTopToBottom": vertical, "noSpaceRows": no_desktops,
            "windowGeometry": witnesses, "realPixelsIndependentlyVerified": False}


def measure(observer, output):
    kind = os.environ.get("NEARPANE_ROSTER_FIXTURE", "roster")
    if kind not in ("roster", "public-visible"):
        raise ValueError("Unsupported owned fixture presentation")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    read = lambda *args: json.loads(checked([str(observer), *map(str, args)]))
    initial = read()
    host = initial.get("host", {})
    frozen = manifest(initial, observer.parent / "metrics")
    result = {"source": frozen["source"], "build": frozen["build"],
              "permissions": frozen["installedHostCurrentPermissions"],
              "fixturePresentation": kind, "stageManager": initial.get("stageManager"),
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
                                stderr=subprocess.DEVNULL, env=dict(os.environ, NP_FIXTURE_PRESENTATION=kind))
        state = wait_state(folder / "windows.json", lambda d: d.get("session") == folder.name and d.get("pid") == proc.pid and
                           d.get("birth", 0) > 0 and d.get("presentation") == kind and len(set(d.get("numbers", []))) == 2, start + 7)
        if not state:
            return result.update(reason="No two distinct fixture windows")
        numbers = state["numbers"]
        sizes = state["sizes"]
        samples = []
        first_observed = None
        while time.monotonic() - start < 8:
            command = "roster-shared-card" if kind == "public-visible" else "roster-card"
            samples = [read(command, host["pid"], host["codeHash"], proc.pid, n, app, signed, scope["scope"],
                            scope["current"], state["birth"]) for n in numbers]
            if all(s.get("observed") for s in samples):
                # Geometry from the capture filter can arrive just after the member list.
                first_observed = first_observed or time.monotonic()
                if evaluate(sizes, samples)["status"] == "PASS" or time.monotonic() - first_observed >= 1.0:
                    break
            time.sleep(.15)
        result.update(ownerFrames=sizes, installedCards=samples, secondsToReadback=round(time.monotonic() - start, 3))
        result.update(evaluate(sizes, samples))
    finally:
        if proc:
            (folder / "close").touch()
            proc.wait(timeout=8)
        final = read()
        cleanup = {"ownedProcessExited": proc is None or proc.poll() is not None,
                   "ownedWindowsGone": not numbers or read("absence", *numbers).get("allGone", False),
                   "frontmostPreserved": initial.get("frontmostPID") == final.get("frontmostPID"),
                   "scopesPreserved": initial.get("scopes") == final.get("scopes")}
        if initial.get("focusedNumber"):
            cleanup["focusedWindowPreserved"] = initial["focusedNumber"] == final.get("focusedNumber")
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
