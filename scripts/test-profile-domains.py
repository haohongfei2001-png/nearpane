#!/usr/bin/python3
"""Check selective import using a labeled, populated, synthetic older Host profile."""
import argparse
import contextlib
import json
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
import unittest
import uuid
import wave

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import profile_domains as domain


def fixture(value):
    root = Path(value).resolve(strict=True)
    sid = root.parent.name
    if (root.name != "support" or root.parent.parent != HERE.parent / "build/native-acceptance" or
            str(uuid.UUID(sid)) != sid or json.loads((root.parent / "session.json").read_text())["session"].lower() != sid):
        raise ValueError("A synthetic Nearpane native session is required.")
    return root


def query(path, sql):
    relative = domain.VOICE if path.name == domain.VOICE.name else domain.TRAY
    profile = path.parents[len(relative.parts) - 1]
    with domain.snapshot(profile, relative) as db:
        return list(db.execute(sql))


def fingerprint(root):
    return {str(p.relative_to(root)): domain.digest(p) for p in root.rglob("*") if p.is_file()}


class Domains(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = fingerprint(ARGS.source)

    @classmethod
    def tearDownClass(cls):
        assert fingerprint(ARGS.source) == cls.original, "original synthetic source changed"

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(prefix=self._testMethodName + "-", dir=ARGS.output)).resolve()
        self.data = self.case / "source"
        self.dest = self.case / "out"
        self.dest.mkdir(mode=0o700)
        shutil.copytree(ARGS.source, self.data)

    def operation(self, asset, phase):
        ident = str(uuid.uuid4()).upper()
        target = dict(adapterID="chatgpt-web", applicationID="com.google.Chrome", surface="webChat",
                      sessionID="old-test",windowID="123",documentID="old",composerID="old",draftGeneration="one")
        t = json.dumps(target)
        with contextlib.closing(sqlite3.connect(str(self.data / domain.TRAY))) as db, db:
            db.execute("INSERT INTO operations(id,asset_id,attempt,target_key,target_json,phase,created_at,updated_at) "
                       "VALUES(?,?,1,?,?,?,1234,1234)", (ident, asset, t, t, phase))
            db.execute("UPDATE assets SET status=?,active_operation_id=? WHERE id=?", (phase,ident,asset))
        return ident

    def test_queue_history_spent_claim_and_permissions(self):
        assets = query(self.data / domain.TRAY, "SELECT id,file_name FROM assets ORDER BY sort_at,sequence")
        self.assertEqual(len(assets), 5)
        self.operation(assets[0][0], "unknown")
        self.operation(assets[1][0], "failed")
        claims = self.data / "Riftlet/draft-input-claims"
        claims.mkdir(mode=0o700)
        (claims / (assets[2][0].lower()+".json")).write_text('{"syntheticExpiredAuthority":true}')
        bookmark = self.data / "Riftlet/capture-bookmark.json"
        bookmark.write_text('{"syntheticBookmark":true}')
        path = self.data / domain.TRAY
        with contextlib.closing(sqlite3.connect(str(path))) as db, db:
            db.execute("INSERT INTO checkpoints VALUES('synthetic-consent', x'01')")
        before = fingerprint(self.data)
        summary = domain.import_profile(self.data, self.dest, domain.SECTIONS)
        self.assertEqual((summary["trayUnknown"],summary["trayFailed"],summary["heldAssets"]),(1,1,3))
        self.assertEqual(fingerprint(self.data), before)
        fields = "SELECT id,status,visibility,active_operation_id,visibility_revision,sort_at,sequence FROM assets ORDER BY sort_at,sequence"
        self.assertEqual(query(path, fields),query(self.dest / domain.TRAY, fields))
        self.assertEqual(query(self.dest / domain.TRAY,"SELECT count(*) FROM checkpoints"), [(0,)])
        for _, name in assets:
            sub = Path("Riftlet/media") / name
            self.assertEqual(domain.digest(self.data/sub), domain.digest(self.dest/sub))
        self.assertFalse((self.dest / "Riftlet/draft-input-claims").exists())
        self.assertFalse((self.dest / "Riftlet/capture-bookmark.json").exists())
        self.assertEqual({p.name for p in (self.dest / "Riftlet/imported-attachment-holds").iterdir()},
                         {a[0].lower() for a in assets[:3]})

        (ARGS.output / "queue-fingerprints.json").write_text(json.dumps({
            "sourceTreeUnchanged": before == fingerprint(self.data),
            "files": {name: domain.digest(self.dest/"Riftlet/media"/name) for _,name in assets},
            "orderedIDs": [key for key,_ in assets], "retainedOperations": query(
                self.dest/domain.TRAY, "SELECT id,asset_id,attempt,phase FROM operations ORDER BY sequence"),
            "sourceDatabaseSHA256": domain.digest(path), "outputDatabaseSHA256": domain.digest(self.dest/domain.TRAY),
            "summary": summary}, indent=2) + "\n")

    def test_rollback_carries_spent_ids_across_replaced_queue(self):
        assets = query(self.data/domain.TRAY, "SELECT id FROM assets ORDER BY sequence")
        self.operation(assets[1][0], "failed")
        domain.restore_profile(ARGS.source, self.dest, self.data)
        self.assertTrue((self.dest / "Riftlet/imported-attachment-holds" / assets[1][0].lower()).is_file())
        self.assertEqual(query(self.dest/domain.TRAY, "SELECT count(*) FROM operations"),[(0,)])
        second = self.case / "second"
        second.mkdir()
        self.assertEqual(domain.import_profile(self.dest, second, domain.SECTIONS)["heldAssets"],1)

    def test_text_revisions_selected_edit_draft_and_frozen_final(self):
        f = self.data / domain.VOICE
        rid = query(f, "SELECT id FROM recordings")[0][0]
        rev = query(f, "SELECT id FROM revisions")[0][0]
        with contextlib.closing(sqlite3.connect(str(f))) as db, db:
            db.execute("INSERT INTO frozen_revisions VALUES(?)",(rev,))
            db.execute("INSERT INTO editing_drafts VALUES(?,?,1)",(rid, "本轮未保存的编辑"))
            db.execute("INSERT INTO recording_cloud_authorizations VALUES(?,?,1)",(rid,"synthetic-consent"))
            db.execute("INSERT INTO bindings VALUES(?,?,1,1)",(str(uuid.uuid4()),"synthetic-target"))
        result = domain.import_profile(self.data, self.dest, domain.SECTIONS)
        self.assertEqual(result["voiceDrafts"],1)
        other = self.dest / domain.VOICE
        for table in ("revisions", "editing_drafts", "frozen_revisions"):
            sql = "SELECT * FROM "+table
            self.assertEqual(query(f,sql), query(other,sql))
        self.assertEqual(query(other, "SELECT preferred_revision FROM recordings"),[(rev,)])
        for table in ("recording_cloud_authorizations","bindings","chunks"):
            self.assertEqual(query(other,"SELECT count(*) FROM "+table),[(0,)])

    def test_unselected_voice_and_rollback_retain_real_audio_blocks(self):
        rid = query(self.data / domain.VOICE, "SELECT id FROM recordings")[0][0]
        wav = self.data / domain.VOICE.parent / "Audio" / rid / "0001.wav"
        wav.parent.mkdir()
        with wave.open(str(wav), "wb") as out:
            out.setparams((1,2,16000,0,"NONE","not compressed"))
            out.writeframes(bytes(1600))
        with contextlib.closing(sqlite3.connect(str(self.data/domain.VOICE))) as db, db:
            db.execute("INSERT INTO chunks VALUES(?,?,?,800,1)", (str(uuid.uuid4()), rid, rid+"/0001.wav"))
            db.execute("UPDATE recordings SET recognition_state='queued', audio_state='available'")
            db.execute("INSERT INTO recording_cloud_authorizations VALUES(?,?,1)",(rid,"previous-synthetic-authorization"))
        for dest, run in ((self.dest,lambda d: domain.import_profile(ARGS.source,d,["tray"],self.data)),
                          (self.case/"restored",lambda d: domain.restore_profile(self.data,d,ARGS.source))):
            dest.mkdir(exist_ok=True)
            self.assertEqual(run(dest)["voiceAudioChunks"],1)
            self.assertEqual(domain.digest(wav), domain.digest(dest/wav.relative_to(self.data)))
            self.assertEqual(query(dest/domain.VOICE,"SELECT count(*) FROM recording_cloud_authorizations"),[(0,)])
            self.assertEqual(query(dest/domain.VOICE,"SELECT recording_id FROM recognition_retry_blocks"),[(rid,)])
            self.assertEqual(query(dest/domain.VOICE,"SELECT audio_state,total_frames FROM recordings"),[("available",800)])
        copy = self.case/"text-only"
        copy.mkdir()
        domain.import_profile(self.data,copy,domain.SECTIONS)
        self.assertFalse((copy/wav.relative_to(self.data)).exists())

    def test_display_and_explicit_layout_survive_but_window_permission_retires(self):
        cfg = domain.obj(self.data / domain.CONFIG)
        display = str(uuid.uuid4())
        cfg.update(preferredDisplayID=display, surfaceHidden=True)
        cfg["displays"] = {display: {"placement":"floating","measures":["panelWidth",{"value":20,"unit":"pt"}]}}
        cfg["workspaces"].update(excludedApps=["com.example.private"],windows=[{"pid":122,"launch":2,"number":9,"element":str(uuid.uuid4())},"include"])
        (self.data / domain.CONFIG).write_text(json.dumps(cfg))
        work = self.data / "WorkRect"
        work.mkdir(mode=0o700)
        (work/"manager.lock").touch()
        domain.save(work/"management.json",dict(mode="off", ratio=.63, swap=True, session=str(uuid.uuid4())))
        domain.import_profile(self.data,self.dest,domain.SECTIONS)
        out = domain.obj(self.dest/domain.CONFIG)
        self.assertEqual(out["displays"],cfg["displays"])
        self.assertEqual(out["preferredDisplayID"],display)
        self.assertTrue(out["surfaceHidden"])
        self.assertEqual(out["workspaces"]["excludedApps"],["com.example.private"])
        self.assertEqual(out["workspaces"]["windows"],[])
        self.assertEqual(domain.obj(self.dest/"WorkRect/management.json"),dict(mode="off",ratio=.63,swap=True))

    def test_committed_wal_recovered_in_private_copy_and_truncated_wal_refused(self):
        base = self.data / domain.VOICE
        rid = query(base, "SELECT id FROM recordings")[0][0]
        copy = self.case / "wal-copy"
        with contextlib.closing(sqlite3.connect(str(base))) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA wal_autocheckpoint=0")
            db.execute("INSERT INTO editing_drafts VALUES(?,?,1)", (rid, "只在 WAL 中提交"))
            db.commit()
            shutil.copytree(self.data, copy)
        before = fingerprint(copy)
        self.assertEqual(domain.inspect_profile(copy)["voiceDrafts"], 1)
        domain.import_profile(copy, self.dest, domain.SECTIONS)
        self.assertEqual(query(self.dest / domain.VOICE,"SELECT text FROM editing_drafts"),[("只在 WAL 中提交",)])
        self.assertEqual(before,fingerprint(copy))
        wal = Path(str(copy / domain.VOICE)+"-wal")
        with wal.open("r+b") as f:
            f.truncate(wal.stat().st_size-2)
        with self.assertRaisesRegex(ValueError, "WAL"):
            domain.inspect_profile(copy)

    def test_same_version_unknown_schema_cannot_replace_generation(self):
        with contextlib.closing(sqlite3.connect(str(self.data/domain.VOICE))) as db, db:
            db.execute("CREATE TRIGGER injected AFTER INSERT ON revisions BEGIN DELETE FROM editing_drafts; END")
        with self.assertRaisesRegex(ValueError,"结构"):
            domain.import_profile(self.data,self.dest,domain.SECTIONS)
        self.assertEqual(list(self.dest.iterdir()),[])

    def test_media_corruption_and_pending_journal_block(self):
        image=next((self.data/"Riftlet/media").glob("*.png"))
        image.write_bytes(b"damaged")
        with self.assertRaisesRegex(ValueError,"SHA-256"):
            domain.inspect_profile(self.data)
        shutil.copyfile(ARGS.source/image.relative_to(self.data),image)
        stage = self.data / "Riftlet/staging/unfinished.part"
        stage.touch()
        with self.assertRaisesRegex(ValueError,"未完成"):
            domain.inspect_profile(self.data)
        stage.unlink()
        work=self.data/"WorkRect"/str(uuid.uuid4())
        work.mkdir(parents=True)
        domain.save(work/"journal.json",dict(status="recovering"))
        self.assertTrue(domain.inspect_profile(self.data)["windowRecoveryBlocked"])
        with self.assertRaisesRegex(ValueError,"恢复"):
            domain.import_profile(self.data,self.dest,domain.SECTIONS)


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=fixture)
    parser.add_argument("--output", required=True, type=Path)
    ARGS=parser.parse_args()
    ARGS.output.mkdir(mode=0o700, exist_ok=True, parents=True)
    unittest.main(argv=[sys.argv[0]], verbosity=2)
