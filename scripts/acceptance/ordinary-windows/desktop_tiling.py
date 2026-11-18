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
    with tempfile.TemporaryDirectory(dir="/private/tmp", prefix="nearpane-desktop-check-") as temp:
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


def exercise(app):
    subprocess.run([ROOT / "scripts/acceptance/ordinary-windows/build.sh"], check=True, cwd=ROOT)
    first = Trial(app, single=True)
    second = None
    try:
        first.desktop_tiling = True
        a = first.baseline(count=1)
        second = Trial(app, single=True, palette=True)
        b = second.baseline(count=1)
        first.peer = second
        check(len(a) == len(b) == 1 and a.keys().isdisjoint(b) and first.bundle != second.bundle
              and first.fixture.pid != second.fixture.pid and first.focus(second.run_focus)
              and first.run_focus["side"] == second.run_focus["side"], "two distinct stable owners required")
        originals = {**a, **b}
        first.start_host()
        first.checkpoint("before-grant", originals, 0)
        first.press("desktop-tiling-enable")
        wait(lambda: first.ui().get("desktop-tiling-confirm", {}).get("enabled"))
        first.checkpoint("scope-preview", originals, 0)
        first.press("desktop-tiling-confirm")
        wait(lambda: len(list(first.records.glob("action-*.json"))) >= 2)
        actual = {**first.sample("ordered-left-to-right"), **second.sample("ordered-left-to-right")}
        left, right = sorted(originals, key=lambda number: actual[number][0])
        x, y, width, height = first.run_focus["usableQuartz"]
        half = math.floor((width - 160) / 2 + .5)
        expected = {left: [x + 160, y, half, height], right: [x + 160 + half, y, width - 160 - half, height]}
        actions = first.checkpoint("two-applications-tiled", expected, 2)
        check({a["id"]["number"] for a in actions} == set(originals), "each window must have its own receipt")
        first.press("desktop-tiling-stop")
        actions = first.checkpoint("originals-restored", originals, 4)
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
    args = parser.parse_args()
    os.environ["NEARPANE_SINGLE_ORDINARY_WITNESS"] = "1"
    app = args.app.resolve(strict=True)
    report = readiness(app)
    destination = OUT / "desktop-tiling-result.json"
    if not all(report["conditions"].values()):
        report.update(status="BLOCKED", fixtureWindows=0, confirmedActions=0)
    else:
        try:
            report.update(exercise(app), status="PASS")
        except Exception as exc:
            report.update(status="NOT_PASSED", reason=str(exc))
            raise
        finally:
            put(destination, report)
    put(destination, report)
    print(json.dumps(report), destination, flush=True)
    raise SystemExit(0 if report["status"] == "PASS" else 77)
