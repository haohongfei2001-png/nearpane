"""Run each mechanism in fresh, registered fixture apps in an empty hosted login."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time


def run_comparison(binary, destination):
    destination.mkdir(exist_ok=False)
    suite = {"source": os.environ["GITHUB_SHA"], "installedHost": "NOT_RUN", "trials": {},
             "osBuild": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
             "tenRoundTrips": "NOT_RUN", "fiftyRoundTrips": "NOT_RUN"}
    # Never enter the second mechanism with a window left over from the first.
    for method in ("minimize", "corner", "wallpaper"):
        with tempfile.TemporaryDirectory(prefix="nearpane-isolation-") as directory:
            root = Path(directory).resolve()
            (root / "comparison").touch()
            apps = []
            trial = {"status": "UNKNOWN", "reason": "missingTrialReceipt"}
            movie = destination / (method + ".mp4")
            capture = None
            trial_seconds = None
            try:
                for label in ("a", "b"):
                    app = root / ("Group Owner " + label + ".app")
                    exe = app / "Contents/MacOS/StageFixture"
                    exe.parent.mkdir(parents=True)
                    shutil.copy2(binary, exe)
                    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
                        CFBundleName=app.stem, CFBundlePackageType="APPL", CFBundleExecutable=exe.name,
                        CFBundleIdentifier="net.example.nearpane.stage-group-" + label, CFBundleVersion="1",
                        NSPrincipalClass="NSApplication", LSUIElement=False)))
                    subprocess.run(["codesign", "-s", "-", "--force", app], check=True)
                    subprocess.run(["codesign", "--verify", "--strict", app], check=True)
                    apps.append(subprocess.Popen(["/usr/bin/open", "-gnW", "--env", "RUNNER_ENVIRONMENT=github-hosted",
                                                  "-a", app, "--args", label, root]))
                end = time.monotonic() + 12
                while not all((root / (label + ".json")).exists() for label in ("a", "b")) and time.monotonic() < end:
                    if any(p.poll() is not None for p in apps):
                        break
                    time.sleep(.1)
                if all((root / (label + ".json")).exists() for label in ("a", "b")):
                    # The host check in the entry point restricts capture and input to GitHub's disposable desktop.
                    capture = subprocess.Popen([binary, "film", root], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    ready = time.monotonic() + 8
                    while capture.poll() is None and not (root / "film-ready").exists() and time.monotonic() < ready:
                        time.sleep(.05)
                    trial_started = time.monotonic()
                    proc = subprocess.run([binary, method, root], timeout=110, capture_output=True, text=True)
                    trial_seconds = time.monotonic() - trial_started
                    if (root / "trial.json").exists():
                        trial = json.loads((root / "trial.json").read_bytes())
                    if proc.returncode:
                        trial.update(status="UNKNOWN", inspectorExit=proc.returncode, stderr=proc.stderr[-400:])
                else:
                    trial = {"status": "BLOCKED", "reason": "signedOwnerLaunchOrEnrollment",
                             "ownerErrors": [json.loads(p.read_bytes()) for p in root.glob("*-failure.json")]}
            finally:
                (root / "film-stop").touch()
                if capture:
                    try:
                        _, film_error = capture.communicate(timeout=9)
                    except subprocess.TimeoutExpired:
                        capture.terminate()
                        _, film_error = capture.communicate(timeout=3)
                    trial["captureExit"] = capture.returncode
                    if film_error:
                        trial["captureDetail"] = film_error.decode(errors="replace")[-350:]
                if (root / "trial.mp4").exists():
                    shutil.copy2(root / "trial.mp4", movie)
                (root / "stop").touch()
                trial["fixtureOwnersExited"] = all([p.wait(timeout=15) == 0 for p in apps])
                if not trial["fixtureOwnersExited"]:
                    trial["status"] = "UNKNOWN"
                # AVFoundation reports the recorded duration. File existence alone proves nothing.
                if movie.exists():
                    probe = subprocess.run([binary, "movie", movie], capture_output=True, text=True, timeout=7)
                    seconds = float(probe.stdout.strip()) if probe.returncode == 0 else 0
                    covers = trial_seconds is not None and seconds + 0.25 >= trial_seconds
                    trial["recording"] = {"status": "PASS" if probe.returncode == 0 and capture.returncode == 0 and covers else "UNKNOWN",
                                          "seconds": seconds, "inspectorSeconds": trial_seconds, "bytes": movie.stat().st_size}
                else:
                    trial["recording"] = {"status": "BLOCKED", "reason": "captureUnavailable"}
                (destination / (method + ".json")).write_text(json.dumps(trial, indent=2) + "\n")
                suite["trials"][method] = {k: trial[k] for k in ("status", "reason", "recording", "fixtureOwnersExited") if k in trial}
        if not trial["fixtureOwnersExited"]:
            break
    (destination / "summary.json").write_text(json.dumps(suite, indent=2) + "\n")
    print(json.dumps(suite, indent=2))
