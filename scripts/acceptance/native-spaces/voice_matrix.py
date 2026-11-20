"""Source audio and durable evidence for the installed 3 × 10 × 2 voice contract."""
import hashlib
import math
import random
import re
import struct
import subprocess
import wave


def schedule(phrases):
    cases = [(phrases[i % 3], ("clean", "noise10dB")[i % 2]) for i in range(6)]
    return [{"phrase": phrase, "condition": condition, "repetition": trial + 1, "status": "NOT_RUN"}
            for trial in range(10) for phrase, condition in cases[trial % 6:] + cases[:trial % 6]]


def add_noise(path, seed):
    with wave.open(str(path), "rb") as reader:
        params = reader.getparams()
        source = [sample for sample, in struct.iter_unpack("<h", reader.readframes(params.nframes))]
    rng = random.Random(seed)
    raw = [rng.uniform(-1.0, 1.0) for _ in source]
    ratio = math.sqrt(sum(x * x for x in source) / (10 * sum(v * v for v in raw)))
    mixed = [x + ratio * n for x, n in zip(source, raw)]
    gain = min(1, 32760 / max(abs(x) for x in mixed))
    encoded = b"".join(struct.pack("<h", round(gain * x)) for x in mixed)
    with wave.open(str(path), "wb") as writer:
        writer.setparams(params)
        writer.writeframes(encoded)
    onset = next((i for i, (sample,) in enumerate(struct.iter_unpack("<h", encoded)) if abs(sample) > 32), None)
    return {"seed": seed, "snrDBAtSource": 10.0, "linearPeakGain": gain,
            "firstSignalSeconds": onset / 16_000 if onset is not None else None,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def fingerprint(db):
    finals = [r for r in db.get("revisions", []) if r["preferred"] and r["origin"] == "final"]
    if len(db.get("newIDs", [])) != 1 or len(finals) != 1:
        return None
    return {"recordingID": db["newIDs"][0], "finalRevision": finals[0]["id"],
            "finalSHA256": finals[0]["comparison"]["rawTextSHA256"],
            "chunks": db["chunks"], "totalFrames": db["totalFrames"], "recognitionState": db["recognitionState"]}


def stages(pid, db):
    predicate = f"processID == {int(pid)} AND subsystem == 'com.holdsnow.nearpane.alpha' AND category == 'LocalToolStage'"
    log = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--last", "3m", "--predicate", predicate],
                         capture_output=True, text=True, timeout=15)
    if log.returncode:
        return {"status": "UNKNOWN", "reason": "Installed Host stage log unavailable"}
    records = [{"id": i, "stage": stage, "hash": h, "uptime": float(t)}
               for i, stage, h, t in re.findall(r"toolStage id=([0-9A-F-]{36}) stage=([a-zA-Z]+) hash=(-|[a-f0-9]{64}) uptime=([0-9.]+)", log.stdout)
               if stage.startswith("voice") or stage == "firstPCM"]
    return match_stages(records, db)


def match_stages(records, db):
    durable = fingerprint(db)
    if durable is None or len(durable["chunks"]) != 1:
        return {"status": "UNKNOWN", "stages": records}
    rid = durable["recordingID"].upper()
    link = hashlib.sha256(rid.encode()).hexdigest()
    intents = {s["id"] for s in records if s["stage"] == "voiceRecordingLinked" and s["hash"] == link}
    if len(intents) != 1:
        return {"status": "UNKNOWN", "stages": records}
    intent, = intents
    scoped = [s for s in records if s["id"] in (rid, intent)]
    def moments(i, stage, digest=None):
        return [s["uptime"] for s in scoped if s["id"] == i and s["stage"] == stage and (digest is None or s["hash"] == digest)]
    starts, frames = moments(intent, "voiceStarted"), moments(intent, "firstPCM")
    audio = moments(rid, "voiceAudioPersisted", durable["chunks"][0]["sha256"])
    final = moments(rid, "voiceFinal", durable["finalSHA256"])
    matched = all(len(group) == 1 for group in (starts, frames, audio, final)) and starts[0] <= frames[0] <= audio[0] <= final[0]
    return {"status": "PASS" if matched else "UNKNOWN", "intent": intent, "stages": scoped}
