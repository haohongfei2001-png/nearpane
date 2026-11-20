"""Offline regressions for the verdicts and recording boundaries; no UI, mic, or playback."""
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest
import wave

MODULE = Path(__file__).with_name("r4-voice-cold.py")
spec = importlib.util.spec_from_file_location("cold_voice", MODULE)
cold = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cold)
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
