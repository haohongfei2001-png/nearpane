#!/usr/bin/env python3
"""Read back a fresh, exact synthetic window in the signed Host's production sidebar."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

from run import OFF, OUT, ROOT, Trial, check

parser = argparse.ArgumentParser()
parser.add_argument("candidate", type=Path)
parser.add_argument("--preflight-only", action="store_true", help="Inspect existing permissions without opening a window")
args = parser.parse_args()
app = args.candidate.resolve()
exe = app / "Contents/MacOS/NearpaneHost"
subprocess.run(["codesign", "--verify", "--strict", "--deep",
                '-R=identifier "com.holdsnow.nearpane.alpha"', app], check=True)
session_id = str(uuid.uuid4())
session = ROOT / "build/native-acceptance" / session_id
subprocess.run(OFF + [exe, "--verify-bundled-resources", "--native-acceptance-prepare-draft", session_id],
               cwd=ROOT, timeout=20, check=True)
marker = json.loads((session / "session.json").read_text())
check(marker["executableSHA256"] == hashlib.sha256(exe.read_bytes()).hexdigest(), "candidate changed")
subprocess.run(OFF + [exe, "--verify-bundled-resources", "--selected-window-readiness", session_id],
               cwd=ROOT, timeout=10, check=True)
availability = json.loads((session / "preview-readiness.json").read_text())
print(dict(session=session_id, readiness=availability), flush=True)
check(all(availability.values()), "no existing capture grant or not a single screen")
if args.preflight_only:
    raise SystemExit(0)
os.environ["NEARPANE_SINGLE_ORDINARY_WITNESS"] = "1"
trial = Trial(app, single=True)
try:
    initial = trial.baseline(count=1)
    check(len(initial) == 1, "expected a single enrolled window")
    number = next(iter(initial))
    trial.command("preview-swatches")
    check(trial.sample("with-swatches") == initial, "geometry changed")
    subprocess.run(OFF + [exe, "--verify-bundled-resources", "--selected-window-readback", session_id,
                          str(trial.fixture.pid), str(number)], cwd=ROOT, timeout=18, check=True)
    check(trial.sample("after-readback") == initial, "window moved or focus changed")
    receipt = json.loads((session / "selected-preview.json").read_text())
    print(json.dumps(dict(session=session_id, trial=str(OUT), **receipt), ensure_ascii=False), flush=True)
    check(receipt["pass"], "sidebar did not render and revoke both known colors")
finally:
    trial.close()
