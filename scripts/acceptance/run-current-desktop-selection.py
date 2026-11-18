#!/usr/bin/env python3
"""Build and run a disposable current-desktop fixture; retain evidence outside its app directory."""
import argparse
import json
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
INSTALL = Path("/Applications/Nearpane.app")
REGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
APPS = ("Controller.app", "Design Notes.app", "Sketch Board.app")
MODES = {
    "roster": ["--roster"],
    "public-roster": ["--roster", "--public-visible"],
    "cold-roster": ["--roster", "--cold-background"],
    "gallery": ["--gallery"],
    "single": ["--single-app"],
    "click": ["--click-cards"],
    "selection": [],
}


def cleanup(root, evidence):
    fixtures = root / "fixtures"
    if not fixtures.exists():
        root.rmdir()
        return
    for flag in ("finish-roster", "done"):
        (fixtures / flag).touch()
    apps = [fixtures / name for name in APPS if (fixtures / name).is_dir()]
    executables = [f for app in apps for subdir in ("MacOS", "Helpers")
                   for f in (app / "Contents" / subdir).glob("*") if f.is_file()]
    deadline = time.monotonic() + 8
    while executables:
        probe = subprocess.run(["/usr/sbin/lsof", "-nP", "-t", "-d", "txt", "-a", "--", *executables],
                               capture_output=True)
        if probe.returncode == 1 and not probe.stdout and not probe.stderr:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Cannot confirm fixture processes exited. Retained {fixtures} and {evidence}")
        time.sleep(.2)
    for f in fixtures.iterdir():
        if f.suffix in (".png", ".json") and not f.is_symlink() and f.is_file():
            shutil.copy2(f, evidence / f.name)
    errors = []
    with (evidence / "unregister.log").open("w") as log:
        for app in apps:
            result = subprocess.run([REGISTER, "-u", app], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(f"{app.name}: {result.returncode} {result.stdout.strip()}", file=log)
            # An incomplete build or a never-launched app may have no registration.
            if (result.returncode or "failed to unregister" in result.stdout.lower()) and "-10814" not in result.stdout:
                errors.append(app.name)
    shutil.rmtree(root)
    if errors:
        raise RuntimeError("Removed fixtures but could not verify unregistration: " + ", ".join(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=MODES, default="public-roster")
    args = parser.parse_args()
    dest = ROOT / "build/verification"
    dest.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="current-desktop-", dir=dest))
    print(evidence, flush=True)
    root = Path(tempfile.mkdtemp(prefix="nearpane-test-", dir="/private/tmp"))
    fixtures = root / "fixtures"
    code = 1
    helper = INSTALL / "Contents/Helpers/NearpaneOrdinaryWindowController"
    try:
        with (evidence / "build.log").open("wb") as log:
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", INSTALL], check=True,
                           stdout=log, stderr=subprocess.STDOUT)
            subprocess.run([ROOT / "scripts/acceptance/build-current-desktop-selection.sh", helper, fixtures],
                           check=True, stdout=log, stderr=subprocess.STDOUT)
        with (evidence / "result.json").open("wb") as output, (evidence / "controller.log").open("wb") as log:
            trial = subprocess.run([fixtures / "Controller.app/Contents/MacOS/NearpaneHost", *MODES[args.mode]],
                                   stdout=output, stderr=log, timeout=65)
            code = trial.returncode
        return code
    finally:
        try:
            (evidence / "run.json").write_text(json.dumps({"mode": args.mode, "trialExit": code}) + "\n")
        finally:
            cleanup(root, evidence)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sys.exit(main())
