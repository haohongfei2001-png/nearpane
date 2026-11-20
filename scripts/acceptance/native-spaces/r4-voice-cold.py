"""Measure the first unprimed phrase of three separate installed Nearpane processes.

From scripts/acceptance/native-spaces run:
  python3 installed_profile.py OUTPUT/profile -- python3 r4-voice-cold.py OUTPUT/voice

The wrapper restores the previous daily profile. Each trial plays one local phrase through
the selected physical output after the first ready indication. The report retains each
final and partial revision as a masked character comparison, with hashes of audio and text.
"""
import argparse
from contextlib import closing
import difflib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import struct
import subprocess
import tempfile
import time
import unicodedata
import wave

PHRASES = ("今天测试语音", "窗外正在下雨", "蓝色雨伞放在门口")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normalized(text):
    return "".join(ch for ch in unicodedata.normalize("NFKC", text)
                   if not ch.isspace() and not unicodedata.category(ch).startswith("P"))


def compare(expected, actual):
    wanted, heard = normalized(expected), normalized(actual)
    # Leave fixture characters inspectable; never publish unrelated microphone speech.
    allowed = set("".join(PHRASES))
    visible = "".join(ch if ch in allowed else "□" for ch in heard)
    edits = [{"kind": op, "expectedRange": [i, j], "heardRange": [k, l],
              "expected": wanted[i:j], "heard": visible[k:l]}
             for op, i, j, k, l in difflib.SequenceMatcher(a=wanted, b=heard, autojunk=False).get_opcodes()]
    leading = 0
    for first, second in zip(wanted, heard):
        if first != second:
            break
        leading += 1
    return {"exact": wanted == heard, "heardNormalized": visible, "rawTextSHA256": digest(actual.encode()),
            "leadingCharactersMatched": leading, "edits": edits}


def save(path, data):
    staged = path.with_suffix(".tmp")
    staged.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    staged.replace(path)


def make_stimulus(path, phrase):
    subprocess.run(["/usr/bin/say", "-v", "Tingting", "-r", "165", "-o", str(path),
                    "--file-format=WAVE", "--data-format=LEI16@16000", phrase], check=True, timeout=15)
    with wave.open(str(path), "rb") as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, 16000):
            raise RuntimeError("Unexpected generated PCM format")
        onset = next((i for i, (sample,) in enumerate(struct.iter_unpack("<h", wav.readframes(1600)))
                      if abs(sample) > 32), None)
        if onset is None:
            raise RuntimeError("Generated phrase has over 100 ms of leading silence")
    return {"sha256": digest(path.read_bytes()), "firstSignalSeconds": onset / 16000,
            "thresholdPCM16": 32}


def database(voice):
    db = voice / "Saytile.sqlite"
    if (not db.is_file() or db.resolve() != db or any(Path(str(db) + ext).is_symlink() for ext in ("-shm", "-wal"))
            or os.path.lexists(voice / "nearpane-voice-api.json")):
        raise RuntimeError("Isolated, local-only Voice database unavailable")
    conn = sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only=ON")
    conn.execute("BEGIN")
    return conn


def all_ids(voice):
    with closing(database(voice)) as db:
        return {row[0] for row in db.execute("SELECT id FROM recordings")}


def read_new(voice, before, expected):
    """Read metadata and revisions only for a single, newly created isolated recording."""
    with closing(database(voice)) as db:
        live = {row[0] for row in db.execute("SELECT id FROM recordings")}
        new = sorted(live - before)
        evidence = {"newIDs": new, "baselineIntact": before <= live}
        if len(new) != 1 or not evidence["baselineIntact"]:
            return evidence
        rid, = new
        row = db.execute("""SELECT recognition_state,is_recording,total_frames,preferred_revision,deleted
                          FROM recordings WHERE id=?""", (rid,)).fetchone()
        evidence.update(recognitionState=row["recognition_state"], isRecording=bool(row["is_recording"]),
                        totalFrames=row["total_frames"], deleted=bool(row["deleted"]))
        evidence["cloudGrants"] = db.execute("SELECT count(*) FROM recording_cloud_authorizations WHERE recording_id=?",
                                              (rid,)).fetchone()[0]
        revisions = db.execute("SELECT id,origin,text FROM revisions WHERE recording_id=? ORDER BY rowid", (rid,))
        evidence["revisions"] = [{"id": rev["id"], "origin": rev["origin"],
                                  "preferred": rev["id"] == row["preferred_revision"],
                                  "comparison": compare(expected, rev["text"])} for rev in revisions]
        evidence["chunks"] = []
        if evidence["isRecording"]:
            return evidence
        for chunk in db.execute("SELECT path,frames FROM chunks WHERE recording_id=? ORDER BY ordinal", (rid,)):
            relative = Path(chunk["path"])
            if relative.is_absolute() or len(relative.parts) != 2 or relative.parts[0] != rid or relative.suffix != ".wav":
                raise RuntimeError("Unexpected isolated audio path")
            path = voice / "Audio" / relative
            if path.resolve() != path or not path.is_file():
                raise RuntimeError("Isolated journal file unavailable")
            with wave.open(str(path), "rb") as wav:
                frames = wav.getnframes()
                correct = (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), frames) == (1, 2, 16000, chunk["frames"])
                correct = correct and len(wav.readframes(frames)) == frames * 2
            evidence["chunks"].append({"frames": frames, "pcm16Mono16kMatchesIndex": correct, "sha256": digest(path.read_bytes())})
        return evidence


def verdict(ui, db):
    kinds = [e["kind"] for e in ui.get("events", [])]
    if not db.get("baselineIntact", False) or len(db.get("newIDs", [])) > 1:
        return "UNKNOWN", "Recording inventory changed ambiguously"
    if any(len(ui.get(key, "")) != 4 for key in ("physicalInputTransport", "physicalOutputTransport")):
        return "BLOCKED", ui.get("issue", "Missing verified physical microphone or playback route")
    if "stimulusStarted" not in kinds:
        return "BLOCKED", ui.get("issue", "No confirmed physical playback from the installed sidebar")
    if ui.get("issue") or kinds != ["startPressed", "captureReady", "stimulusStarted", "stimulusFinished", "pausePressed", "pauseObserved"]:
        return "UNKNOWN", "UI start, playback, or pause did not finish"
    if not db.get("newIDs"):
        return "FAIL", "No recording created after a complete controlled utterance"
    if db["deleted"] or db["cloudGrants"] or db["isRecording"]:
        return "UNKNOWN", "Local recording boundary unavailable"
    if db["recognitionState"] in ("failed", "cancelled"):
        return "FAIL", "Recognition ended in " + db["recognitionState"]
    if db["recognitionState"] != "completed":
        return "UNKNOWN", "Final recognition did not settle within the observation window"
    final = [r for r in db["revisions"] if r["preferred"] and r["origin"] == "final"]
    chunks = db["chunks"]
    if (not chunks or not all(c["pcm16Mono16kMatchesIndex"] for c in chunks)
            or sum(c["frames"] for c in chunks) != db["totalFrames"] or db["totalFrames"] <= 0):
        return "FAIL", "Persisted audio does not match the independent WAV readback"
    if len(final) != 1 or not final[0]["comparison"]["exact"]:
        return "FAIL", "Preferred final did not reproduce the entire phrase"
    return "PASS", "Physical playback, exact final and independent WAV readback confirmed"


def summarize(attempts):
    return next((state for state in ("FAIL", "UNKNOWN", "BLOCKED", "NOT_RUN")
                 if any(a["status"] == state for a in attempts)), "PASS")


def calibrate(driver, stimulus, voice, attempt):
    evidence = attempt.get("readback", {})
    ids, chunks = evidence.get("newIDs", []), evidence.get("chunks", [])
    if len(ids) != 1 or len(chunks) != 1 or not chunks[0]["pcm16Mono16kMatchesIndex"]:
        return {"status": "UNKNOWN", "reason": "Requires a unique, verified single-chunk controlled utterance"}
    rid, = ids
    with closing(database(voice)) as db:
        row = db.execute("SELECT path FROM chunks WHERE recording_id=?", (rid,)).fetchone()
    relative = Path(row["path"])
    if relative.is_absolute() or len(relative.parts) != 2 or relative.parts[0] != rid or relative.suffix != ".wav":
        raise RuntimeError("Unexpected isolated calibration path")
    recorded = voice / "Audio" / relative
    if recorded.resolve() != recorded or digest(recorded.read_bytes()) != chunks[0]["sha256"]:
        raise RuntimeError("Isolated audio changed since the production readback")
    proc = subprocess.run([str(driver), str(stimulus), str(recorded)], capture_output=True, timeout=38)
    if proc.returncode:
        return {"status": "UNKNOWN", "reason": "File-only calibration failed", "exit": proc.returncode}
    observed = json.loads(proc.stdout)
    report = {"status": "COMPLETE", "wavSHA256": chunks[0]["sha256"], "alignment": observed["alignment"]}
    # Never copy raw microphone audio, unrelated transcript text, or the whole DB to a public receipt.
    for key in ("clean", "captured"):
        if key in observed:
            report[key] = compare(attempt["phrase"], observed[key])
        else:
            report[key] = {"status": "UNKNOWN"}
            report["status"] = "PARTIAL"
    return report


def run(output, calibration=False, file_readback=False):
    import installed_profile as profile  # A normal Launch Services session owned by the outer wrapper.
    require_readback = calibration or file_readback
    phrases = (PHRASES[1], PHRASES[0]) if calibration else PHRASES
    attempts = [{"phrase": phrase, "status": "NOT_RUN"} for phrase in phrases]
    summary = {"mode": "counterbalanced diagnostic" if calibration else "three independent cold starts", "app": "/Applications/Nearpane.app", "rounds": attempts, "speech": "local Tingting, rate 165, physical speaker to microphone",
               "textComparison": "NFKC, omit spaces and punctuation only; unrelated characters masked in published readback"}
    def snapshot():
        summary["status"] = summarize(attempts)
        if require_readback or any("calibration" in a for a in attempts):
            summary["physicalStatus"] = summary["status"]
            controls = [a.get("calibration", {}).get("status", "PENDING") for a in attempts]
            summary["calibrationState"] = ("PENDING" if "PENDING" in controls else
                                           "COMPLETE" if all(state == "COMPLETE" for state in controls) else "UNKNOWN")
            if summary["physicalStatus"] == "PASS" and summary["calibrationState"] != "COMPLETE":
                summary["status"] = "UNKNOWN"
        save(output / "results.json", summary)
    snapshot()
    try:
        home = Path(os.environ["NEARPANE_TEST_HOME"])
        generation = Path(os.environ["NEARPANE_TEST_GENERATION"])
        root = home / profile.PROFILE
        profile.validate_home(home)
        active = json.loads((root / "profile-index.json").read_text())["active"]
        if (generation != root / "generations" / active or generation.parent != root / "generations" or generation.resolve() != generation
                or not profile.owns_profile(profile.installed_pid(), root)):
            raise RuntimeError("Expected a running installed Host that owns this test generation")
        voice = generation / "Nearpane/Voice"
        if all_ids(voice):
            raise RuntimeError("Run the voice suite inside a new empty dedicated profile session")
        info = plistlib.loads((profile.APP / "Contents/Info.plist").read_bytes())
        summary.update(build=info["CFBundleVersion"], version=info["CFBundleShortVersionString"],
                       source=info.get("NearpaneSourceRevision"), generation=active)
        seen = {profile.installed_pid()}
        with tempfile.TemporaryDirectory(prefix="nearpane-voice-", dir="/private/tmp") as temp:
            temp = Path(temp)
            driver = temp / "cold-microphone"
            sources = Path(__file__).resolve().parents[3] / "Sources/CReadOnlySpaces"
            header = sources / "include/ReadOnlySpaces.h"
            observer = temp / "read-spaces.o"
            subprocess.run(["/usr/bin/xcrun", "clang", "-c", str(sources / "ReadOnlySpaces.c"), "-I", str(header.parent),
                            "-o", str(observer)], check=True, timeout=30)
            subprocess.run(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-import-objc-header", str(header),
                            str(Path(__file__).with_name("r4-cold-microphone.swift")), str(observer), "-o", str(driver)],
                           check=True, timeout=90)
            for number, attempt in enumerate(attempts, start=1):
                pid = None
                try:
                    phrase = attempt["phrase"]
                    stimulus = temp / f"{number}.wav"
                    attempt["stimulus"] = make_stimulus(stimulus, phrase)
                    previous = profile.installed_pid()
                    if previous:
                        if not profile.owns_profile(previous, root):
                            raise RuntimeError("Refusing to stop a Host outside the controlled profile")
                        profile.quit_host(previous)
                    pid, fresh = profile.launch_isolated(home)
                    if fresh != generation or pid in seen or not profile.owns_profile(pid, root):
                        raise RuntimeError("A distinct cold Host in the same isolated generation could not be confirmed")
                    seen.add(pid)
                    before = all_ids(voice)
                    attempt.update(pid=pid, previousPID=previous, baselineRecordings=len(before), status="UNKNOWN")
                    snapshot()
                    ui_file = output / f"{number:02}-ui.json"
                    ui_result = subprocess.run([str(driver), str(pid), str(stimulus), str(ui_file)], timeout=52,
                                               capture_output=True, text=True)
                    ui = json.loads(ui_file.read_text()) if ui_file.exists() else {"issue": ui_result.stderr.strip()[:300]}
                    if ui.get("events") and ui.get("pid") != pid:
                        ui["issue"] = "UI evidence belongs to an unexpected process"
                    if ui_result.returncode and not ui.get("issue"):
                        ui["issue"] = "UI driver exited with code " + str(ui_result.returncode)
                    attempt["ui"] = ui
                    if profile.installed_pid() != pid or not profile.owns_profile(pid, root):
                        raise RuntimeError("Isolated Host identity was lost during the trial")
                    if ui.get("issue") and not any(e["kind"] == "pauseObserved" for e in ui.get("events", [])):
                        profile.quit_host(pid)  # Ordinary quit closes the test microphone even after an incomplete AX action.
                    deadline = time.monotonic() + 29
                    while True:
                        db = read_new(voice, before, phrase)
                        if (ui.get("issue") or db.get("recognitionState") in ("completed", "failed", "cancelled")
                                or not db["baselineIntact"] or len(db["newIDs"]) > 1 or time.monotonic() >= deadline):
                            break
                        time.sleep(.25)
                    attempt["readback"] = db
                    attempt["status"], attempt["reason"] = verdict(ui, db)
                except (OSError, RuntimeError, ValueError, wave.Error, sqlite3.Error, subprocess.SubprocessError) as error:
                    attempt["status"] = "UNKNOWN" if pid else "BLOCKED"
                    attempt["reason"] = str(error)
                finally:
                    snapshot()
                    if pid and profile.owns_profile(pid, root):
                        profile.quit_host(pid)
            # Finish all physical trials before initializing the independent recognizer; its Apple asset cache
            # must not warm the second live trial. Use the same, hashed PCM before the outer cleanup removes it.
            if require_readback or any(a["status"] == "FAIL" for a in attempts):
                replay = temp / "file-only-calibration"
                subprocess.run(["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library",
                                str(Path(__file__).with_name("r4-voice-replay.swift")), "-o", str(replay)],
                               check=True, timeout=90)
                for number, attempt in enumerate(attempts, start=1):
                    try:
                        attempt["calibration"] = calibrate(replay, temp / f"{number}.wav", voice, attempt)
                    except (OSError, KeyError, ValueError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as error:
                        attempt["calibration"] = {"status": "UNKNOWN", "reason": type(error).__name__}
                    snapshot()
    except (KeyError, OSError, RuntimeError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
        summary["setupOrCleanupIssue"] = str(error)
        snapshot()
        if summary["status"] != "FAIL":
            summary["status"] = "BLOCKED" if all(a["status"] == "NOT_RUN" for a in attempts) else "UNKNOWN"
        save(output / "results.json", summary)
    return 0 if summary["status"] == "PASS" else 3


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file-readback", action="store_true",
                        help="analyze each existing WAV after all three physical starts; always automatic on a failed phrase")
    parser.add_argument("--calibrate", action="store_true",
                        help="two counterbalanced cold starts and file-only controls; retain the original acceptance outcomes")
    parser.add_argument("output", type=Path, help="new directory for receipts, outside the disposable home")
    args = parser.parse_args()
    os.umask(0o077)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    return run(args.output.resolve(), calibration=args.calibrate, file_readback=args.file_readback)


if __name__ == "__main__":
    raise SystemExit(main())
