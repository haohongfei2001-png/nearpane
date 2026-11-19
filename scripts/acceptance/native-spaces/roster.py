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
    fits = all(
        (f := card.get("fit", {})).get("cardCount", 0) >= len(cards)
        and f.get("cardCount") == f.get("measured") and f.get("allOnscreen")
        and f.get("insideOnePanel") and f.get("ordered") and f.get("scrollAreas") == 0
        for card in cards
    )
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
    if not no_desktops or not vertical or not fits or faithful is False:
        status, reason = "FAIL", "Window shape, row order, visible non-scrolling bounds or navigation rows contradicted their witnesses"
    elif len(usable) == 2 and same_scale(sizes, [w["preview"] for w in witnesses]):
        status, reason = "PASS", "Both confirmed window dimensions used one scale in separate, vertically ordered cards"
    else:
        status, reason = "BLOCKED", "Both windows were listed but both true preview dimensions were not established"
    return {"status": status, "reason": reason, "nonoverlappingTopToBottom": vertical, "noSpaceRows": no_desktops,
            "allMeasuredCardsFit": bool(fits), "windowGeometry": witnesses, "realPixelsIndependentlyVerified": False}


def pixel_verdict(numbers, measurements):
    if len(numbers) != 2 or len(set(numbers)) != 2 or len(measurements) != 2:
        return "BLOCKED"
    for number, sample in zip(numbers, measurements):
        if not sample.get("ready") or sample.get("fixture") != number or sample.get("sampleCount") != 64:
            return "BLOCKED"
    first, second = measurements
    return "PASS" if first["green"] >= 52 and second["purple"] >= 52 else "FAIL"


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
              "status": "BLOCKED", "pixelStatus": "BLOCKED", "cardCropAttempts": 0, "realPixelsIndependentlyVerified": False}
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
        inspect_pixels = bool(initial.get("observerScreenRead") and (result.get("permissions") or {}).get("screen"))
        while time.monotonic() - start < 8:
            command = "roster-shared-card" if kind == "public-visible" else "roster-card"
            samples = [read(command, host["pid"], host["codeHash"], proc.pid, n, app, signed, scope["scope"],
                            scope["current"], state["birth"]) for n in numbers]
            if all(s.get("observed") for s in samples):
                # Geometry from the capture filter can arrive just after the member list.
                first_observed = first_observed or time.monotonic()
                geometry_observed = evaluate(sizes, samples)["status"] == "PASS" or time.monotonic() - first_observed >= 1.0
                if geometry_observed and (not inspect_pixels or all(s.get("pixelCrop") for s in samples)):
                    break
            time.sleep(.15)
        result.update(ownerFrames=sizes, installedCards=samples, secondsToReadback=round(time.monotonic() - start, 3))
        result.update(evaluate(sizes, samples))
        result["geometryStatus"] = result["status"]
        if inspect_pixels and len(samples) == 2 and all(s.get("pixelCrop") for s in samples):
            measurements = []
            for number in numbers:
                result["cardCropAttempts"] += 1
                args = [observer.parent / "capture", observer, command, host["pid"], host["codeHash"],
                        proc.pid, number, app, signed, scope["scope"], scope["current"], state["birth"]]
                measurements.append(json.loads(checked(list(map(str, args)))))
            result["colorWitnesses"] = measurements
            result["pixelStatus"] = pixel_verdict(numbers, measurements)
            result["realPixelsIndependentlyVerified"] = result["pixelStatus"] == "PASS"
            if result["pixelStatus"] == "FAIL":
                result.update(status="FAIL", reason="Installed card pixels contradicted the fixture content")
        else:
            result["pixelReason"] = ("Both signed source cards did not expose measurable pictures" if inspect_pixels
                                     else "Screen recording access not confirmed in installed Host and observer")
        if kind == "roster" and all(card.get("observed") for card in samples):
            result["currentRosterAudit"] = read("compare-roster")
            if result["currentRosterAudit"]["status"] == "FAIL":
                result.update(status="FAIL", reason="Installed card set disagrees with independently identified visible windows")

            def card_counts():
                rows = [read("fixture-card-presence", host["pid"], host["codeHash"], proc.pid, n, app, signed,
                             scope["scope"], scope["current"], state["birth"]) for n in numbers]
                return [r.get("matches") if r.get("issued") else None for r in rows]

            def wait_counts(expected):
                until = time.monotonic() + 4
                while time.monotonic() < until:
                    counts = card_counts()
                    if counts == expected:
                        return True
                    time.sleep(.12)
                return False

            (folder / "withdraw-first").touch()
            matches_owner = lambda d: d.get("birth") == state["birth"] and d.get("pid") == proc.pid and d.get("numbers") == numbers
            withdrawn = wait_state(folder / "windows.json", lambda d: matches_owner(d) and d.get("visible") == [False, True],
                                   time.monotonic() + 3)
            result["withdrawnWindow"] = ("PASS" if wait_counts([0, 1]) else "FAIL") if withdrawn else "INCONCLUSIVE"
            (folder / "minimize-second").touch()
            mini = wait_state(folder / "windows.json", lambda d: matches_owner(d) and d.get("minimized") == [False, True],
                              time.monotonic() + 3)
            result["minimizedWindow"] = ("PASS" if wait_counts([0, 0]) else "FAIL") if mini else "INCONCLUSIVE"
            if "FAIL" in (result["withdrawnWindow"], result["minimizedWindow"]):
                result.update(status="FAIL", reason="An ineligible fixture stayed in the installed sidebar or its eligible sibling disappeared")
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
