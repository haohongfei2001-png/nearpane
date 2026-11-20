"""Verify an installed window-only roster before, during and after two owned documents."""
import argparse
from contextlib import nullcontext
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
from roster_recording import RosterRecording


def read(command, *, timeout=8):
    output = subprocess.check_output([str(part) for part in command], text=True, timeout=timeout)
    return json.loads(output)


def sample_census(observe, binding, count, *, budget=10, limit=8, interval=.25):
    """Retain every fresh observer result. An unknown sample breaks the matching pair."""
    deadline = time.monotonic() + budget
    samples, previous_witness = [], None
    for _ in range(limit):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            census = observe(min(8, remaining))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            census = {"status": "INCONCLUSIVE", "reason": type(error).__name__}
        samples.append(census)
        if census.get("generationChanged") or any(key in census and census[key] != value for key, value in binding.items()):
            return samples, False, "generation changed"
        if census.get("status") == "FAIL":
            return samples, False, "independently observed roster discrepancy"
        # The generic no-fixture comparison is INCONCLUSIVE for zero windows.
        # An enrolled empty stage separately proves complete coverage and both exact empty sets.
        agrees = (all(census.get(key) == value for key, value in binding.items()) and
                  census.get("status") == ("PASS" if count else "INCONCLUSIVE") and
                  all(census.get(key) is True for key in ("coverageComplete", "expectedVisibleSetMatches", "expectedCardSetMatches")) and
                  census.get("cards") == count and census.get("provenVisibleStandard") == count and
                  all(census.get(key) == 0 for key in ("missingProvenVisible", "knownWrongCards", "duplicateControls", "unconfirmedCards")))
        witness = (census.get("observerPID"), census.get("observerBirth"), census.get("observedUptime"))
        if agrees and all(isinstance(number, (int, float)) and number > 0 for number in witness):
            if previous_witness and witness[:2] != previous_witness[:2] and witness[2] > previous_witness[2]:
                return samples, True, "two consecutive independent reads"
            previous_witness = witness
        else:
            previous_witness = None
        if len(samples) < limit:
            time.sleep(min(interval, max(0, deadline - time.monotonic())))
    return samples, False, "no consecutive independent confirmation within budget"


def run(kit, output, owned_stage, film=False):
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

    recording = None
    def checkpoint(label, owner_pid=0, owner_birth=0, numbers=()):
        args = ["roster-content", digest, str(owner_pid if numbers else 0), *map(str, numbers)]
        deadline = time.monotonic() + 12
        previous = None
        proof_errors = []
        while True:
            try:
                proof = read([observer, *args], timeout=min(8, max(.01, deadline - time.monotonic())))
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                proof = {"ready": False, "reason": type(error).__name__}
                proof_errors.append(proof["reason"])
            if proof.get("ready") and proof == previous:
                break
            if time.monotonic() >= deadline:
                break
            previous = proof
            time.sleep(0.3)
        record = {"proof": proof, "proofReadErrors": proof_errors, "status": "BLOCKED", "censusSamples": []}
        result["checkpoints"][label] = record
        confirmed = False
        stable = (proof.get("ready") and proof == previous and proof.get("pid") == host and
                  proof.get("signature") == digest and (proof.get("hostBirth") or 0) > 0 and
                  (not numbers or proof.get("documentBirth") == owner_birth) and
                  proof.get("display") and (proof.get("space") or 0) > 0)
        if stable:
            generation = {key: proof[key] for key in ("pid", "hostBirth", "signature", "display", "space")}
            stable = generation == result.setdefault("observationGeneration", generation) and owns_profile(host, home / PROFILE)
        if stable:
            binding = dict(generation, panelNumber=proof["number"], fixturePID=owner_pid, fixtureBirth=owner_birth)
            command = [observer, "compare-roster", proof["number"], owner_pid, owner_birth, *numbers]
            samples, confirmed, reason = sample_census(lambda timeout: read(command, timeout=timeout), binding, len(numbers))
            record.update(censusSamples=samples, independentRoster=samples[-1] if samples else None, censusDecision=reason)
            result_path.write_text(encode(result))
            stable = reason != "generation changed"
        if stable:
            screenshot = output / (label + ".png")
            with recording.camera if recording else nullcontext():
                captured = read([capture, observer, *args, screenshot], timeout=12)
                record["captured"] = captured == proof and screenshot.is_file()
                if record["captured"]:
                    record["image"] = screenshot.name
                    panel = output / (label + "-sidebar.png")
                    panel_proof = read([capture, observer, "roster-panel", *args[1:], panel], timeout=12)
                    if panel_proof.get("ready") and panel.is_file():
                        record["sidebarImage"] = panel.name
                        record["wallpaperIncluded"] = panel_proof.get("wallpaperIncluded", False)
                        record["isolatedProfile"] = panel_proof.get("isolatedProfile", False)
        if record.get("captured") and confirmed:
            record["status"] = "PASS"
        if proof.get("spaceRows", 0) or proof.get("placeholderLabels"):
            record["status"] = "FAIL"
        result_path.write_text(encode(result))
        if recording:
            recording.witness(numbers)

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
            owner_birth = 0
            def documents(count):
                return wait_state(folder / "windows.json",
                                  lambda s: s.get("session") == folder.name and s.get("pid") == proc.pid and
                                  (s.get("birth") or 0) > 0 and (not owner_birth or s["birth"] == owner_birth) and
                                  len(set(s.get("numbers", []))) == count and s.get("visible") == [True] * count,
                                  time.monotonic() + 8)

            state = documents(2)
            owner_birth = state.get("birth", 0)
            if state and owned_stage:
                warmup = state["numbers"]
                (folder / "close-documents").touch()
                if not documents(0):
                    raise RuntimeError("Warm-up document owner still reports windows")
                result["warmupNumbersGoneImmediately"] = read([observer, "absence", *warmup]).get("allGone")
                if film:
                    recording = RosterRecording(kit, folder, proc.pid, digest, output)
                checkpoint("empty-before", proc.pid, owner_birth)
                (folder / "open-documents").touch()
                state = documents(2)
            if state:
                numbers = state["numbers"]
                result["fixture"] = {k: state[k] for k in ("bundle", "pid", "birth", "numbers", "visible")}
                checkpoint("two-documents", proc.pid, owner_birth, numbers)
                if owned_stage:
                    (folder / "close-documents").touch()
                    if not documents(0):
                        raise RuntimeError("Document owner still reports enrolled windows")
                    result["closedNumbersGoneImmediately"] = read([observer, "absence", *numbers]).get("allGone")
                    checkpoint("empty-after", proc.pid, owner_birth)
        except (RuntimeError, OSError, subprocess.SubprocessError) as error:
            result["issue"] = str(error)
        finally:
            (folder / "close").touch()
            proc.wait(timeout=12)
            if recording:
                recording.finish()
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
    parser.add_argument("--record", action="store_true", help="record independently admitted sidebar frames throughout the owned window cycle")
    args = parser.parse_args()
    if args.record and not args.owned_stage:
        parser.error("--record requires --owned-stage")
    raise SystemExit(run(args.kit.resolve(), args.output.resolve(), args.owned_stage, args.record))
