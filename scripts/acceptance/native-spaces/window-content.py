"""Verify an installed window-only roster before, during and after two owned documents."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

from acceptance import encode, identity, wait_state
from installed_profile import APP, PROFILE, installed_pid, owns_profile


def read(command):
    output = subprocess.check_output([str(part) for part in command], text=True, timeout=8)
    return json.loads(output)


def run(kit, output, owned_stage):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    observer = kit / "observe"
    capture = kit / "capture"
    host = installed_pid()
    home = Path(os.environ["NEARPANE_TEST_HOME"])
    if not owns_profile(host, home / PROFILE):
        raise RuntimeError("Requires the signed installed Host holding the isolated profile")
    digest = identity(APP)["CDHash"]
    version = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    result = dict(source=version["NearpaneSourceRevision"], hostCDHash=digest, build=version["CFBundleVersion"],
                  checkpoints={}, fixtureExited=False, status="BLOCKED")
    result_path = output / "results.json"

    def checkpoint(label, pid=0, numbers=()):
        args = ["roster-content", digest, str(pid), *map(str, numbers)]
        deadline = time.monotonic() + 12
        previous = None
        while True:
            proof = read([observer, *args])
            if proof.get("ready") and proof == previous:
                break
            if time.monotonic() >= deadline:
                break
            previous = proof
            time.sleep(0.3)
        census = read([observer, "compare-roster"])
        record = {"proof": proof, "independentRoster": census}
        if proof.get("ready") and proof == previous:
            screenshot = output / (label + ".png")
            captured = read([capture, observer, *args, screenshot])
            record["captured"] = captured.get("ready") is True and screenshot.is_file()
            if record["captured"]:
                record["image"] = screenshot.name
                panel = output / (label + "-sidebar.png")
                panel_proof = read([capture, observer, "roster-panel", *args[1:], panel])
                if panel_proof.get("ready") and panel.is_file():
                    record["sidebarImage"] = panel.name
                    record["wallpaperIncluded"] = panel_proof.get("wallpaperIncluded", False)
                    record["isolatedProfile"] = panel_proof.get("isolatedProfile", False)
        proven = census.get("provenVisibleStandard")
        record["status"] = "PASS" if (record.get("captured") and proven == len(numbers) and
                                      census.get("missingProvenVisible") == 0 and census.get("knownWrongCards") == 0) else "BLOCKED"
        if proof.get("spaceRows", 0) or proof.get("placeholderLabels"):
            record["status"] = "FAIL"
        result["checkpoints"][label] = record
        result_path.write_text(encode(result))

    fixture = kit / "Field Notes.app" / "Contents/MacOS/FieldNotes"
    if not fixture.is_file():
        raise RuntimeError("Missing disposable regular document application")
    with tempfile.TemporaryDirectory(prefix="nearpane-roster-docs.", dir="/private/tmp") as container:
        folder = Path(container) / str(uuid.uuid4())
        folder.mkdir(mode=0o700)
        if not owned_stage:
            checkpoint("empty-before")
        proc = subprocess.Popen([str(fixture), str(folder), "2"],
                                env={**os.environ, "NP_FIXTURE_PRESENTATION": "roster-cycle" if owned_stage else "roster"},
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        numbers = []
        try:
            def documents(count):
                return wait_state(folder / "windows.json",
                                  lambda s: s.get("session") == folder.name and s.get("pid") == proc.pid and
                                  len(set(s.get("numbers", []))) == count and s.get("visible") == [True] * count,
                                  time.monotonic() + 8)

            state = documents(2)
            if state and owned_stage:
                warmup = state["numbers"]
                (folder / "close-documents").touch()
                if not documents(0):
                    raise RuntimeError("Warm-up document owner still reports windows")
                result["warmupNumbersGoneImmediately"] = read([observer, "absence", *warmup]).get("allGone")
                checkpoint("empty-before")
                (folder / "open-documents").touch()
                state = documents(2)
            if state:
                numbers = state["numbers"]
                result["fixture"] = {k: state[k] for k in ("bundle", "pid", "birth", "numbers", "visible")}
                checkpoint("two-documents", proc.pid, numbers)
                if owned_stage:
                    (folder / "close-documents").touch()
                    if not documents(0):
                        raise RuntimeError("Document owner still reports enrolled windows")
                    result["closedNumbersGoneImmediately"] = read([observer, "absence", *numbers]).get("allGone")
                    checkpoint("empty-after")
        except (RuntimeError, OSError, subprocess.SubprocessError) as error:
            result["issue"] = str(error)
        finally:
            (folder / "close").touch()
            proc.wait(timeout=12)
            result["fixtureExited"] = True
            until = time.monotonic() + 5
            result["windowNumbersGone"] = False
            while numbers and time.monotonic() < until:
                if read([observer, "absence", *numbers]).get("allGone"):
                    result["windowNumbersGone"] = True
                    break
                time.sleep(0.15)
            result_path.write_text(encode(result))
        if not owned_stage:
            checkpoint("empty-after")
    states = [case["status"] for case in result["checkpoints"].values()]
    if result["fixtureExited"] and result["windowNumbersGone"] and states == ["PASS"] * 3:
        result["status"] = "PASS"
    elif "FAIL" in states:
        result["status"] = "FAIL"
    result_path.write_text(encode(result))
    return 0 if result["status"] == "PASS" else 2


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kit", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--owned-stage", action="store_true", help="activate only the disposable document app and keep it running while its documents close")
    args = parser.parse_args()
    raise SystemExit(run(args.kit.resolve(), args.output.resolve(), args.owned_stage))
