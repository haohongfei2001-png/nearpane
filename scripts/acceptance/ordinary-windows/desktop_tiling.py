#!/usr/bin/env python3
"""Test one desktop grant through the installed Settings and two new, isolated apps."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

from run import OFF, OUT, ROOT, Trial, check, put, wait


def readiness(app):
    exe = app / "Contents/MacOS/NearpaneHost"
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                    '-R=identifier "com.holdsnow.nearpane.alpha"', app], check=True)
    digest = hashlib.sha256(exe.read_bytes()).hexdigest()
    session = str(uuid.uuid4())
    # Foundation canonicalizes /private/tmp to /tmp after POSIX getcwd(). The
    # existing fixture verifier requires the exact same path at both checks.
    # The per-user cache is unprotected by Documents TCC and holds only our new lock copy.
    with tempfile.TemporaryDirectory(dir=Path.home() / "Library/Caches", prefix="nearpane-desktop-check-") as temp:
        root = Path(temp)
        (root / "Dependencies").mkdir()
        shutil.copyfile(ROOT / "Dependencies/domains.lock.json", root / "Dependencies/domains.lock.json")
        args = OFF + [exe, "--verify-bundled-resources"]
        subprocess.run(args + ["--native-acceptance-prepare-draft", session], cwd=root, check=True, timeout=20)
        directory = root / "build/native-acceptance" / session
        check(json.loads((directory / "session.json").read_bytes())["executableSHA256"] == digest, "unexpected Host")
        subprocess.run(args + ["--desktop-tiling-readiness", session], cwd=root, check=True, timeout=15)
        flags = json.loads((directory / "desktop-tiling-readiness.json").read_bytes())
    check(set(flags) == {"currentOrdinarySpace", "oneDisplay", "hostAccessibility", "readerAccessibility"}
          and all(type(v) is bool for v in flags.values()), "incomplete readiness")
    return {"session": session, "sha256": digest, "conditions": flags}


def exercise(app, late_window):
    subprocess.run([ROOT / "scripts/acceptance/ordinary-windows/build.sh"], check=True, cwd=ROOT)
    first = Trial(app, single=True)
    second = None
    try:
        first.desktop_tiling = True
        a = first.baseline(count=1)
        second = Trial(app, single=True, palette=True)
        b = second.baseline(count=0 if late_window else 1)
        first.peer = second
        check(len(a) == 1 and len(b) == (0 if late_window else 1) and a.keys().isdisjoint(b) and first.bundle != second.bundle
              and first.fixture.pid != second.fixture.pid and first.focus(second.run_focus)
              and first.run_focus["side"] == second.run_focus["side"], "two distinct stable owners required")
        originals = {**a, **b}
        first.start_host()
        first.checkpoint("before-grant", originals, 0)
        first.press("desktop-tiling-enable")
        wait(lambda: first.ui().get("desktop-tiling-confirm", {}).get("enabled"))
        first.checkpoint("scope-preview", originals, 0)
        first.press("desktop-tiling-confirm")
        x, y, width, height = first.run_focus["usableQuartz"]
        pair_writes = 2
        if late_window:
            first.checkpoint("single-fills-workrect", {next(iter(a)): [x + 160, y, width - 160, height]}, 1)
            created = second.command("add 1")["windows"]
            check(len(created) == 1 and created[0]["number"] not in originals, "missing distinct new window")
            originals = {**originals, created[0]["number"]: created[0]["frame"]}
            pair_writes += 1
        wait(lambda: len(list(first.records.glob("action-*.json"))) >= pair_writes)
        actual = {**first.sample("ordered-left-to-right"), **second.sample("ordered-left-to-right")}
        left, right = sorted(originals, key=lambda number: actual[number][0])
        half = math.floor((width - 160) / 2 + .5)
        expected = {left: [x + 160, y, half, height], right: [x + 160 + half, y, width - 160 - half, height]}
        actions = first.checkpoint("two-applications-tiled", expected, pair_writes)
        check({a["id"]["number"] for a in actions} == set(originals), "each window must have its own receipt")
        first.press("desktop-tiling-stop")
        actions = first.checkpoint("originals-restored", originals, pair_writes + 2)
        check(not (first.records / "journal.json").exists(), "unresolved recovery journal")
        return {"settingsSession": first.sid, "fixtureWindows": len(originals), "confirmedActions": len(actions),
                "maximumGeometryErrorPt": max(r["maxErrorPt"] for r in first.receipts)}
    finally:
        try:
            first.close()
        finally:
            if second is not None:
                second.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--late-window", action="store_true", help="Open the other application's window after the desktop grant")
    args = parser.parse_args()
    os.environ["NEARPANE_SINGLE_ORDINARY_WITNESS"] = "1"
    app = args.app.resolve(strict=True)
    report = readiness(app)
    report["lateWindow"] = args.late_window
    destination = OUT / "desktop-tiling-result.json"
    if not all(report["conditions"].values()):
        report.update(status="BLOCKED", fixtureWindows=0, confirmedActions=0)
    else:
        try:
            report.update(exercise(app, args.late_window), status="PASS")
        except Exception as exc:
            report.update(status="NOT_PASSED", reason=str(exc))
            raise
        finally:
            put(destination, report)
    put(destination, report)
    print(json.dumps(report), destination, flush=True)
    raise SystemExit(0 if report["status"] == "PASS" else 77)
