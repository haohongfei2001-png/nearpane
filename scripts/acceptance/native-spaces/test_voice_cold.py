"""Offline regressions for the verdicts and recording boundaries; no UI, mic, or playback."""
import importlib.util
import collections
import hashlib
import struct
from pathlib import Path
import sqlite3
import tempfile
import unittest
import wave

MODULE = Path(__file__).with_name("r4-voice-cold.py")
spec = importlib.util.spec_from_file_location("cold_voice", MODULE)
cold = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cold)
matrix_spec = importlib.util.spec_from_file_location("voice_matrix", MODULE.with_name("voice_matrix.py"))
matrix = importlib.util.module_from_spec(matrix_spec)
matrix_spec.loader.exec_module(matrix)

UI = {"physicalInputTransport": "bltn", "physicalOutputTransport": "bltn", "events": [{"kind": kind} for kind in ("startPressed", "captureReady", "stimulusStarted", "stimulusFinished",
                                               "pausePressed", "pauseObserved")]}


class VerdictTests(unittest.TestCase):
    def test_requires_every_character_including_first_and_masks_unrelated_speech(self):
        phrase = cold.PHRASES[0]
        self.assertTrue(cold.compare(phrase, phrase + "。")["exact"])
        for faulty in (phrase[1:], "张" + phrase, phrase + "张", phrase[:1] + phrase[2:]):
            result = cold.compare(phrase, faulty)
            self.assertFalse(result["exact"])
            self.assertNotIn("张", str(result))
        self.assertEqual(cold.compare(phrase, phrase[1:])["leadingCharactersMatched"], 0)

    def test_matrix_balances_ten_starts_per_condition_and_phrase(self):
        plan = matrix.schedule(cold.PHRASES)
        counts = collections.Counter((r["phrase"], r["condition"]) for r in plan)
        self.assertEqual(len(plan), 60)
        self.assertEqual(len(counts), 6)
        self.assertEqual(set(counts.values()), {10})
        self.assertEqual({r["status"] for r in plan}, {"NOT_RUN"})
        before = cold.PHRASES[0]
        self.assertEqual(cold.compare(before, before[1:])["cer"], 1 / len(before))

    def test_seeded_noise_writes_pcm_and_preserves_source_duration(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "synthetic.wav"
            with wave.open(str(path), "wb") as out:
                out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                out.writeframes(b"".join(struct.pack("<h", i % 128 * 70) for i in range(3200)))
            clean = path.read_bytes()
            noisy = matrix.add_noise(path, seed=3)
            self.assertNotEqual(noisy["sha256"], hashlib.sha256(clean).hexdigest())
            with wave.open(str(path), "rb") as reader:
                self.assertEqual(reader.getnframes(), 3200)
            path.write_bytes(clean)
            self.assertEqual(matrix.add_noise(path, seed=3), noisy)

    def test_matrix_stage_hashes_and_session_must_match_the_durable_recording(self):
        rid = "AA"
        db = {"newIDs": [rid], "revisions": [{"id": "r", "preferred": True, "origin": "final",
              "comparison": {"rawTextSHA256": "final"}}], "chunks": [{"sha256": "audio"}], "totalFrames": 1,
              "recognitionState": "completed"}
        records = [{"id": i, "stage": stage, "hash": digest, "uptime": t}
                   for t, (i, stage, digest) in enumerate((
                       ("I", "voiceStarted", "-"), ("I", "firstPCM", "-"),
                       ("I", "voiceRecordingLinked", hashlib.sha256(rid.encode()).hexdigest()),
                       (rid, "voiceAudioPersisted", "audio"), (rid, "voiceFinal", "final")))]
        self.assertEqual(matrix.match_stages(records, db)["status"], "PASS")
        self.assertEqual(matrix.match_stages(records[1:], db)["status"], "UNKNOWN")
        records[-1]["hash"] = "partial"
        self.assertEqual(matrix.match_stages(records, db)["status"], "UNKNOWN")

    def test_multichunk_hash_and_link_after_first_pcm(self):
        rid="DB-UUID"; intent="intent"; link=hashlib.sha256(rid.encode()).hexdigest()
        db={"newIDs":[rid],"revisions":[{"id":"r","preferred":True,"origin":"final","comparison":{"rawTextSHA256":"text"}}],
            "chunks":[{"sha256":"one"},{"sha256":"two"}],"journalSHA256":"both","totalFrames":2,"recognitionState":"completed"}
        records=[dict(id=i,stage=s,hash=h,uptime=t) for t,(i,s,h) in enumerate([
            (intent,"voiceStarted","-"),(intent,"firstPCM","-"),(intent,"voiceRecordingLinked",link),
            (rid,"voiceAudioPersisted","both"),(rid,"voiceFinal","text")])]
        self.assertEqual(matrix.match_stages(records,db)["status"],"PASS")
        records[2]["uptime"]=0
        self.assertEqual(matrix.match_stages(records,db)["status"],"UNKNOWN")
        records[2]["uptime"]=2
        db.pop("journalSHA256")
        self.assertEqual(matrix.match_stages(records,db)["status"],"UNKNOWN")

    def test_only_new_final_and_durable_pcm_can_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            voice = Path(temp).resolve()
            (voice / "Audio" / "fixture-id").mkdir(parents=True)
            path = voice / "Audio/fixture-id/audio.wav"
            with wave.open(str(path), "wb") as wav:
                wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                wav.writeframes(b"\x00\x00" * 16)
            phrase = cold.PHRASES[1]
            db = sqlite3.connect(voice / "Saytile.sqlite")
            db.executescript("""
                CREATE TABLE recordings(id,recognition_state,is_recording,total_frames,preferred_revision,deleted);
                CREATE TABLE revisions(id,recording_id,origin,text);
                CREATE TABLE recording_cloud_authorizations(recording_id);
                CREATE TABLE chunks(recording_id,path,frames,ordinal);
                INSERT INTO recordings VALUES ('old-id','completed',0,10,'old-final',0);
                INSERT INTO revisions VALUES ('old-final','old-id','final','unrelated old transcript');
                INSERT INTO recordings VALUES ('fixture-id','completed',0,16,'new-final',0);
                INSERT INTO chunks VALUES ('fixture-id','fixture-id/audio.wav',16,0);
            """)
            db.executemany("INSERT INTO revisions VALUES (?,?,?,?)",
                           [("new-partial", "fixture-id", "partial", phrase),
                            ("new-final", "fixture-id", "final", phrase[1:])])
            db.commit()
            def read():
                return cold.read_new(voice, {"old-id"}, phrase)
            evidence = read()
            self.assertEqual([r["id"] for r in evidence["revisions"]], ["new-partial", "new-final"])
            self.assertEqual(cold.verdict(UI, evidence)[0], "FAIL")  # Complete partial cannot redeem a clipped final.
            db.execute("UPDATE revisions SET text=? WHERE id='new-final'", (phrase,))
            db.commit()
            self.assertEqual(cold.verdict(UI, read())[0], "PASS")
            self.assertEqual(cold.verdict({"events": []}, read())[0], "BLOCKED")
            db.execute("UPDATE chunks SET frames=15")
            db.commit()
            self.assertEqual(cold.verdict(UI, read())[0], "FAIL")
            db.execute("INSERT INTO recordings(id) VALUES ('unexpected')")
            db.commit()
            self.assertEqual(cold.verdict(UI, read())[0], "UNKNOWN")
            db.close()

    def test_refuses_symlinked_voice_db_before_reading(self):
        with tempfile.TemporaryDirectory() as temp:
            voice = Path(temp).resolve()
            (voice / "source").touch()
            (voice / "Saytile.sqlite").symlink_to(voice / "source")
            with self.assertRaises(RuntimeError):
                cold.all_ids(voice)


if __name__ == "__main__":
    unittest.main()
