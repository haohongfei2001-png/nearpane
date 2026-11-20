"""Score six generated Chinese WAVs in a disposable macOS runner. No audio device is opened."""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import wave

import voice_matrix

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
spec = importlib.util.spec_from_file_location("cold_voice", HERE / "r4-voice-cold.py")
cold = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cold)
REPO = "haohongfei2001-png/nearpane"
SIGN_ID = "org.nearpane.acceptance.speech-file"
ASSET_SECONDS = 240
FILE_SECONDS = 25


def score(expected, heard):
    # The comparison uses the normalized original text before its privacy mask is applied.
    result = cold.compare(expected, heard)
    return {"expectedCharacters": len(cold.normalized(expected)), "heardCharacters": len(cold.normalized(heard)),
            "firstCharacterCorrect": result["leadingCharactersMatched"] > 0, "exact": result["exact"],
            "edits": result["characterEdits"], "cer": result["cer"]}


def aggregate(rows):
    scores = [row["score"] for row in rows if row.get("score") is not None]
    characters = sum(s["expectedCharacters"] for s in scores)
    edits = sum(s["edits"] for s in scores)
    return {"cases": len(rows), "scoredFinals": len(scores), "unscored": len(rows) - len(scores),
            "exact": sum(s["exact"] for s in scores), "firstCharacterCorrect": sum(s["firstCharacterCorrect"] for s in scores),
            "firstCharacterRate": sum(s["firstCharacterCorrect"] for s in scores) / len(scores) if scores else None,
            "characterEdits": edits if scores else None, "referenceCharacters": characters if scores else None,
            "microCER": edits / characters if characters else None}


def scheduled():
    # Identical independent phrase/condition inputs and noise seeds to the first 6 of the physical matrix.
    return [{"case": f"{cold.PHRASES.index(row['phrase']) + 1:02d}-{row['condition']}",
             "expected": row["phrase"], "condition": row["condition"], "seed": number if row["condition"] == "noise10dB" else None,
             "status": "NOT_RUN", "score": None}
            for number, row in enumerate(voice_matrix.schedule(cold.PHRASES)[:6], 1)]


def audio_samples(path):
    with wave.open(str(path), "rb") as stream:
        if (stream.getframerate(), stream.getnchannels(), stream.getsampwidth()) != (16_000, 1, 2):
            raise ValueError("unexpected PCM format")
        return [sample for sample, in struct.iter_unpack("<h", stream.readframes(stream.getnframes()))]


def prepare_inputs(directory, rows):
    listing = subprocess.run(["/usr/bin/say", "-v", "?"], capture_output=True, check=True, timeout=15).stdout.decode()
    if not re.search(r"(?m)^Tingting\b[^\n]*\bzh_CN\b", listing):
        raise ValueError("Tingting zh_CN voice unavailable")
    for number, phrase in enumerate(cold.PHRASES, 1):
        clean_path = directory / f"{number:02d}-clean.wav"
        clean = cold.make_stimulus(clean_path, phrase)
        reference = audio_samples(clean_path)
        for row in (r for r in rows if r["expected"] == phrase):
            info = {"cleanSHA256": clean["sha256"], "sha256": clean["sha256"],
                    "frames": len(reference), "sampleRate": 16_000, "firstCleanSignalSeconds": clean["firstSignalSeconds"]}
            if row["seed"] is not None:
                path = directory / (row["case"] + ".wav")
                shutil.copyfile(clean_path, path)
                noise = voice_matrix.add_noise(path, row["seed"])
                heard = audio_samples(path)
                gain = noise["linearPeakGain"]
                if len(heard) != len(reference):
                    raise ValueError("noise mixture changed the frame count")
                residual = sum((observed - gain * original) ** 2 for observed, original in zip(heard, reference))
                power = sum((gain * original) ** 2 for original in reference)
                info.update(sha256=noise["sha256"], linearPeakGain=gain,
                            measuredSourceSNRdB=10 * math.log10(power / residual))
            row["input"] = info


def actual_archive():
    directory = ROOT / "engineering/verification/native-spaces/5.22-90-installed-contract"
    reports = []
    for name in ("voice/02-ordinary-cold", "voice/03-counterbalanced", "runs/voice-final"):
        path = directory / name / "results.json"
        report = json.loads(path.read_text())
        rows = []
        for r in report["rounds"]:
            assert r["phrase"] in cold.PHRASES
            finals = [v for v in r.get("readback", {}).get("revisions", []) if v["preferred"] and v["origin"] == "final"]
            s = None
            if len(finals) == 1:
                # Every masked glyph was outside the full fixed reference alphabet. Each is a mismatch
                # against every reference glyph, so masking preserves Levenshtein cost and first-char equality.
                s = score(r["phrase"], finals[0]["comparison"]["heardNormalized"])
            rows.append({"expected": r["phrase"], "originalStatus": r["status"], "score": s})
        reports.append({"receipt": str(path.relative_to(ROOT)), "sha256": cold.digest(path.read_bytes()),
                        "originalSource": report["source"], "version": report["version"], "build": report["build"],
                        "rounds": rows, "aggregate": aggregate(rows)})
    return {"scope": "In-memory rescoring of retained, masked, synthetic-fixture finals from historical installed runs",
            "unknownPolicy": "Missing finals are unscored. Each physical receipt retains its original verdict and source.",
            "newPhysicalHostTrials": 0, "reports": reports}


def hosted():
    return (os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("RUNNER_OS") == "macOS" and os.environ.get("GITHUB_REPOSITORY") == REPO
            and platform.machine() == "arm64")


def build(directory):
    bundle = directory / "NearpaneSpeechFileProbe.app"
    executables = bundle / "Contents/MacOS"
    executables.mkdir(parents=True)
    exe = executables / "FileProbe"
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": SIGN_ID, "CFBundleExecutable": exe.name, "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1", "LSMinimumSystemVersion": "26.0", "LSBackgroundOnly": True,
    }))
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos26.0",
                    str(HERE / "p4-apple-file.swift"), "-o", str(exe)], check=True, timeout=100)
    subprocess.run(["/usr/bin/codesign", "--sign", "-", "--identifier", SIGN_ID, str(bundle)], check=True, timeout=15)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(bundle)], check=True, timeout=10)
    return exe


def invoke(exe, args, directory, seconds):
    start = time.monotonic()
    try:
        child = subprocess.run([str(exe), *args], env={**os.environ, "NEARPANE_SPEECH_FIXTURES": str(directory)},
                               capture_output=True, timeout=seconds)
        raw, return_code, timed_out = child.stdout, child.returncode, False
    except subprocess.TimeoutExpired as e:
        raw, return_code, timed_out = e.stdout or b"", None, True
    events = []
    for line in raw.decode(errors="replace").splitlines():
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and isinstance(value.get("stage"), str):
            events.append(value)
    return {"deadlineSeconds": seconds, "elapsedSeconds": round(time.monotonic() - start, 3),
            "exitCode": return_code, "timedOut": timed_out, "events": events}


def assessed(row, result):
    finals = [e for e in result["events"] if e["stage"] == "analysis-finished"]
    if result["timedOut"] or result["exitCode"] != 0 or len(finals) != 1:
        row.update(status="UNKNOWN", reason="analysis did not produce a confirmed end", process=result)
        return
    final = finals[0]
    if not isinstance(final.get("finalCount"), int) or final["finalCount"] < 1 or not isinstance(final.get("finalText"), str):
        row.update(status="UNKNOWN", reason="no framework final event", process=result)
        return
    s = score(row["expected"], final["finalText"])
    row.update(status="PASS" if s["exact"] else "FAIL", finalText=final["finalText"], score=s, process=result)


def run(output, mode):
    output.parent.mkdir(parents=True, exist_ok=True)
    if mode == "archive":
        cold.save(output, actual_archive())
        return 0
    rows = scheduled()
    report = {"scope": "Apple SpeechAnalyzer / SpeechTranscriber on generated 16 kHz mono PCM files",
              "mode": mode, "physicalInstalledHost": {"trials": 0, "contractTrials": 60, "status": "NOT_RUN"},
              "source": {"voice": "Tingting", "locale": "zh_CN", "rate": 165,
                         "output": "WAVE file only", "noise": "uniform seeded at +10 dB source SNR"},
              "macOS": platform.mac_ver()[0], "osBuild": subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"], text=True).strip(),
              "architecture": platform.machine(), "status": "NOT_RUN", "rounds": rows}
    def snapshot():
        report["aggregate"] = aggregate(rows)
        cold.save(output, report)
    snapshot()
    if mode == "hosted":
        if not hosted():
            report.update(status="BLOCKED", reason="model preparation requires the designated disposable hosted runner")
            snapshot()
            return 7
        report["runner"] = {k: os.getenv(k) for k in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "ImageOS", "ImageVersion")}
    with tempfile.TemporaryDirectory(prefix="nearpane-speech-file-", dir=os.getenv("RUNNER_TEMP") if mode == "hosted" else None) as tmp:
        directory = Path(tmp).resolve()
        try:
            prepare_inputs(directory, rows)
            report["fixtures"] = "READY"
        except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as e:
            report["fixtures"] = "BLOCKED"
            report["fixtureError"] = type(e).__name__
        snapshot()
        if mode == "fixtures":
            report["status"] = "FIXTURES_READY" if report["fixtures"] == "READY" else "BLOCKED"
            snapshot()
            return 0 if report["fixtures"] == "READY" else 1
        try:
            exe = build(directory)
        except (OSError, subprocess.SubprocessError) as e:
            report.update(status="BLOCKED", reason="compile or signing failed", errorType=type(e).__name__)
            snapshot()
            return 1
        report["preparation"] = invoke(exe, ["--prepare"], directory, ASSET_SECONDS)
        inventory = report["preparation"]
        if (inventory["timedOut"] or inventory["exitCode"] != 0 or
                not any(e["stage"] == "inventory-after" and e.get("asset") == "installed" and e.get("localeInstalled") is True
                        for e in inventory["events"])):
            report.update(status="BLOCKED", reason="runner did not confirm an installed local zh-CN model")
            snapshot()
            return 1
        if report["fixtures"] != "READY":
            report.update(status="BLOCKED", reason="fixed synthetic corpus unavailable")
            snapshot()
            return 1
        snapshot()
        for row in rows:
            assessed(row, invoke(exe, ["--recognize", row["case"]], directory, FILE_SECONDS))
            snapshot()
        states = {r["status"] for r in rows}
        report["status"] = "FAIL" if "FAIL" in states else ("PASS" if states == {"PASS"} else "UNKNOWN")
        snapshot()
        return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=["fixtures", "archive", "hosted"])
    p.add_argument("output", type=Path)
    args = p.parse_args()
    sys.exit(run(args.output, args.mode))
