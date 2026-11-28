"""Measure unprimed phrases in separate launches of the installed Nearpane Host.

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
import stat
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


def character_distance(wanted, heard):
    previous = list(range(len(heard) + 1))
    for i, left in enumerate(wanted, 1):
        current = [i]
        for j, right in enumerate(heard, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (left != right)))
        previous = current
    return previous[-1]


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
    distance = character_distance(wanted, heard)
    return {"exact": wanted == heard, "characterEdits": distance, "cer": distance / len(wanted) if wanted else None,
            "heardNormalized": visible, "rawTextSHA256": digest(actual.encode()),
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
        journal = hashlib.sha256()
        for chunk in db.execute("SELECT path,frames FROM chunks WHERE recording_id=? ORDER BY ordinal", (rid,)):
            relative = Path(chunk["path"])
            if relative.is_absolute() or len(relative.parts) != 2 or relative.parts[0] != rid or relative.suffix != ".wav":
                raise RuntimeError("Unexpected isolated audio path")
            path = voice / "Audio" / relative
            if path.resolve() != path or not path.is_file():
                raise RuntimeError("Isolated journal file unavailable")
            with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as audio:
                before_file = os.fstat(audio.fileno())
                if not stat.S_ISREG(before_file.st_mode):
                    raise RuntimeError("The journal chunk length or type changed")
                with wave.open(audio, "rb") as wav:
                    frames = wav.getnframes()
                    correct = before_file.st_size == 44 + 2 * chunk["frames"] and (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), frames) == (1, 2, 16000, chunk["frames"])
                audio.seek(0)
                file_hash = hashlib.sha256()
                while block := audio.read(65536):
                    journal.update(block)
                    file_hash.update(block)
                live = path.stat(follow_symlinks=False)
                if (live.st_dev, live.st_ino, live.st_size, live.st_mtime_ns) != (before_file.st_dev, before_file.st_ino, before_file.st_size, before_file.st_mtime_ns):
                    raise RuntimeError("The durable original audio changed during readback")
            evidence["chunks"].append({"frames": frames, "pcm16Mono16kMatchesIndex": correct, "sha256": file_hash.hexdigest()})
        if evidence["chunks"]:
            evidence["journalSHA256"] = journal.hexdigest()
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


def run(output, calibration=False, file_readback=False, matrix=False):
    import voice_matrix
    import installed_profile as profile  # A normal Launch Services session owned by the outer wrapper.
    require_readback = calibration or file_readback
    phrases = (PHRASES[1], PHRASES[0]) if calibration else PHRASES
    attempts = voice_matrix.schedule(PHRASES) if matrix else [{"phrase": phrase, "status": "NOT_RUN"} for phrase in phrases]
    mode = "3 phrases × 10 cold starts × clean or +10 dB SNR stimulus" if matrix else (
        "counterbalanced diagnostic" if calibration else "three independent cold starts")
    summary = {"mode": mode, "app": "/Applications/Nearpane.app", "rounds": attempts, "speech": "local Tingting, rate 165, physical speaker to microphone",
               "textComparison": "NFKC, omit spaces and punctuation only; unrelated characters masked in published readback"}
    def snapshot():
        summary["status"] = summarize(attempts)
        if matrix:
            summary["counts"] = {key: sum(a["status"] == key for a in attempts)
                                 for key in ("PASS", "FAIL", "UNKNOWN", "BLOCKED", "NOT_RUN")}
            if summary["status"] == "PASS" and any(a.get("reopened", {}).get("status") != "PASS"
                    or a.get("productionStages", {}).get("status") != "PASS" for a in attempts):
                summary["status"] = "UNKNOWN"
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
        def verify_reopened(attempt):
            original = voice_matrix.fingerprint(attempt.get("readback", {}))
            restored = None
            if original and original["recordingID"] in all_ids(voice):
                baseline = all_ids(voice) - {original["recordingID"]}
                restored = voice_matrix.fingerprint(read_new(voice, baseline, attempt["phrase"]))
            attempt["reopened"] = {"status": "PASS" if restored and restored == original else "UNKNOWN",
                                   "record": restored, "witnessPID": profile.installed_pid()}
            if attempt["status"] == "PASS" and attempt["reopened"]["status"] != "PASS":
                attempt.update(status="UNKNOWN", reason="Relaunched installed Host could not confirm the same final and original WAV")
            snapshot()

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
                    if matrix and attempt["condition"] == "noise10dB":
                        original = attempt["stimulus"]["sha256"]
                        clean_onset = attempt["stimulus"]["firstSignalSeconds"]
                        attempt["stimulus"].update(voice_matrix.add_noise(stimulus, seed=number),
                                                   cleanSHA256=original, cleanFirstSignalSeconds=clean_onset)
                    previous = profile.installed_pid()
                    if previous:
                        if not profile.owns_profile(previous, root):
                            raise RuntimeError("Refusing to stop a Host outside the controlled profile")
                        profile.quit_host(previous)
                    pid, fresh = profile.launch_isolated(home)
                    if fresh != generation or pid in seen or not profile.owns_profile(pid, root):
                        raise RuntimeError("A distinct cold Host in the same isolated generation could not be confirmed")
                    seen.add(pid)
                    if matrix and number > 1:
                        verify_reopened(attempts[number - 2])
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
                    if matrix and pid:
                        try:
                            stages = voice_matrix.stages(pid, attempt.get("readback", {}))
                        except (OSError, ValueError, subprocess.SubprocessError):
                            stages = {"status": "UNKNOWN", "reason": "Installed Host stage log unavailable"}
                        attempt["productionStages"] = stages
                        if attempt["status"] == "PASS" and stages["status"] != "PASS":
                            attempt.update(status="UNKNOWN", reason="First PCM or durable final did not match this installed Host")
                        snapshot()
                if matrix and (not pid or (attempt["status"] == "BLOCKED" and
                        not any(e["kind"] == "startPressed" for e in attempt.get("ui", {}).get("events", [])))):
                    summary["stoppedAtRound"] = number
                    break
            attempted = [a for a in attempts if "pid" in a]
            if matrix and attempted:
                if profile.installed_pid() is not None:
                    raise RuntimeError("An unexpected Host appeared before the last independent reopen")
                last, fresh = profile.launch_isolated(home)
                if fresh != generation or last in seen or not profile.owns_profile(last, root):
                    raise RuntimeError("A fresh installed Host could not reopen the matrix generation")
                verify_reopened(attempted[-1])
                for attempt in attempted:
                    if attempt["status"] == "PASS" and attempt.get("reopened", {}).get("status") != "PASS":
                        attempt.update(status="UNKNOWN", reason="Missing independent reopen")
                snapshot()
            # Finish all physical trials before initializing the independent recognizer; its Apple asset cache
            # must not warm the second live trial. Use the same, hashed PCM before the outer cleanup removes it.
            if require_readback or any(a["status"] == "FAIL" for a in attempts):
                replay = temp / "file-only-calibration"
                subprocess.run(["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library",
                                str(Path(__file__).with_name("r4-voice-replay.swift")), "-o", str(replay)],
                               check=True, timeout=90)
                for number, attempt in enumerate(attempts, start=1):
                    if matrix and not require_readback and attempt["status"] != "FAIL":
                        continue
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
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--matrix", action="store_true",
                      help="60 cold installed starts, counterbalanced clean and deterministic +10 dB acoustic stimuli, with relaunch readback")
    mode.add_argument("--calibrate", action="store_true",
                        help="two counterbalanced cold starts and file-only controls; retain the original acceptance outcomes")
    parser.add_argument("output", type=Path, help="new directory for receipts, outside the disposable home")
    args = parser.parse_args()
    os.umask(0o077)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    return run(args.output.resolve(), calibration=args.calibrate, file_readback=args.file_readback, matrix=args.matrix)


if __name__ == "__main__":
    raise SystemExit(main())
