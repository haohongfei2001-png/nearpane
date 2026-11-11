#!/usr/bin/python3
"""Exercise migration on copies prepared by the P5.2 fixture and the new signed Host."""
import argparse
import errno
import fcntl
import importlib.util
import json
import os
import resource
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("migration", HERE / "profile-migration.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def synthetic(name):
    root = Path(name).resolve(strict=True)
    session = root.parent
    if (root.name != "support" or session.parent != HERE.parent / "build/native-acceptance"
            or json.loads((session / "session.json").read_text())["session"].lower() != session.name):
        raise ValueError("A prepared, labeled synthetic native session is required")
    return root


class Transactions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = Path(tempfile.mkdtemp(prefix="p53-transactions-", dir=ARGS.output)).resolve()
        m.validate_configuration = lambda root: m.validate_with_host(ARGS.host, root)
        cls.fingerprints = {str(path): m.digest(m.inventory(path)) for path in (ARGS.empty, ARGS.populated)}

    @classmethod
    def tearDownClass(cls):
        assert cls.fingerprints == {str(path): m.digest(m.inventory(path)) for path in (ARGS.empty, ARGS.populated)}
        print("Verified original signed fixture trees:", json.dumps(cls.fingerprints, sort_keys=True))

    def setUp(self):
        self.case = self.base / self._testMethodName
        self.case.mkdir()
        self.container = self.case / "Nearpane Alpha Profiles"
        self.first = str(uuid.uuid4())
        self.current = self.container / "generations" / self.first
        self.source = self.case / "Nearpane Alpha P5.2"
        shutil.copytree(ARGS.empty, self.current)
        shutil.copytree(ARGS.populated, self.source)
        (self.current / "profile.version").write_bytes(m.MARKER)
        self.initial = dict(format=1, active=self.first, imports={}, previous=None)
        m.put(self.container / "profile-index.json", self.initial)

    def apply(self, sections=m.SECTIONS, hook=lambda step: None):
        preview = m.preview(self.container, self.source, sections)
        with m.writer(self.container):
            return m.import_locked(self.container, self.source, sections, preview["token"], hook)

    def test_round_trip_and_duplicate(self):
        old = m.digest(m.inventory(self.source))
        result = self.apply()
        idx = m.index(self.container)
        self.assertEqual(result["active"], idx["active"])
        self.assertEqual(old, m.digest(m.inventory(self.source)))
        self.assertEqual(old, m.digest(m.inventory(self.container / "transactions" / idx["active"] / "source-backup")))
        self.assertEqual(m.domains.inspect_profile(m.generation(self.container, idx["active"]))["trayAssets"], 5)
        self.assertTrue(self.apply()["duplicate"])
        token = m.state(self.container)["rollbackToken"]
        with m.writer(self.container):
            restored = m.rollback_locked(self.container, token)
            with self.assertRaises(ValueError):
                m.rollback_locked(self.container, token)
        self.assertEqual(m.domains.inspect_profile(m.generation(self.container, restored["active"]))["trayAssets"], 0)
        self.assertTrue(m.generation(self.container, idx["active"]).exists())

    def test_empty_source_and_unselected_target(self):
        shutil.rmtree(self.source)
        shutil.copytree(ARGS.empty, self.source)
        self.assertEqual(m.domains.inspect_profile(m.generation(self.container, self.apply()["active"]))["voiceRecords"], 0)
        shutil.rmtree(self.source)
        shutil.copytree(ARGS.populated, self.source)
        g = m.generation(self.container, self.apply(["voice"])["active"])
        self.assertEqual((m.domains.inspect_profile(g)["voiceRecords"], m.domains.inspect_profile(g)["trayAssets"]), (1, 0))
        g = m.generation(self.container, self.apply(["tray"])["active"])
        self.assertEqual((m.domains.inspect_profile(g)["voiceRecords"], m.domains.inspect_profile(g)["trayAssets"]), (1, 5))

    def test_old_confirmation_rejected(self):
        token = m.preview(self.container, self.source, m.SECTIONS)["token"]
        cfg = self.source / m.domains.CONFIG
        cfg.write_bytes(cfg.read_bytes() + b" ")
        with m.writer(self.container), self.assertRaisesRegex(ValueError, "重新预览"):
            m.import_locked(self.container, self.source, m.SECTIONS, token)
        self.assertEqual(m.index(self.container), self.initial)
        self.assertFalse(m.state(self.container)["needsRecovery"])

    def test_lock_held_by_another_process(self):
        with m.writer(self.container):
            child = subprocess.run([sys.executable, "-I", "-B", str(HERE / "profile-migration.py"), "recover",
                                    "--container", str(self.container)], capture_output=True, check=False)
            self.assertNotEqual(child.returncode, 0)
            self.assertFalse(json.loads(child.stdout)["ok"])
        for rel in (m.domains.VOICE.parent / ".writer-lock", Path("Riftlet/instance.lock")):
            with (self.source / rel).open("rb") as f:
                fcntl.flock(f, fcntl.LOCK_EX)
                with self.assertRaisesRegex(ValueError, "写锁"):
                    self.apply()
        self.assertEqual(m.index(self.container), self.initial)

    def test_source_version_name_and_link_rejected(self):
        other = self.case / "Nearpane Alpha P5.1"
        self.source.rename(other)
        with self.assertRaisesRegex(ValueError, "身份不符"):
            m.preview(self.container, other, m.SECTIONS)
        other.rename(self.source)
        (self.source / "borrowed-media").symlink_to(self.current / "Riftlet/media", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "链接"):
            self.apply()
        self.assertEqual(m.index(self.container), self.initial)

    def test_disk_full(self):
        def full(step):
            if step == "backups":
                raise OSError(errno.ENOSPC, "synthetic filesystem full")
        original = m.digest(m.inventory(self.source))
        with self.assertRaises(OSError):
            self.apply(hook=full)
        self.assertEqual(m.index(self.container), self.initial)
        self.assertEqual(original, m.digest(m.inventory(self.source)))
        self.assertFalse(m.state(self.container)["needsRecovery"])

    def test_kernel_file_write_refusal(self):
        token = m.preview(self.container, self.source, m.SECTIONS)["token"]
        original = m.digest(m.inventory(self.source))
        args = [sys.executable, "-I", "-B", str(Path(__file__).resolve()), "--limited-file",
                "--container", str(self.container), "--source", str(self.source), "--token", token,
                "--host", str(ARGS.host)]
        child = subprocess.run(args, capture_output=True)
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertEqual(child.stdout.strip(), str(errno.EFBIG).encode())
        self.assertEqual(original, m.digest(m.inventory(self.source)))
        self.assertEqual(m.index(self.container), self.initial)
        self.assertFalse(m.state(self.container)["needsRecovery"])

    def test_schema_incompatible(self):
        db = sqlite3.connect(self.source / m.domains.VOICE)
        db.execute("PRAGMA user_version=726")
        db.close()
        with self.assertRaisesRegex(ValueError, "数据库版本"):
            self.apply()
        self.assertEqual(m.index(self.container), self.initial)

    def test_missing_media(self):
        next((self.source / "Riftlet/media").iterdir()).unlink()
        with self.assertRaises((ValueError, OSError)):
            self.apply()
        self.assertEqual(m.index(self.container), self.initial)

    def test_real_kill_before_and_after_publication(self):
        for step in ("backups", "published-directory", "published-index"):
            previous = m.index(self.container)
            token = m.preview(self.container, self.source, m.SECTIONS)["token"]
            args = [sys.executable, "-I", "-B", str(Path(__file__).resolve()), "--crash", step,
                    "--container", str(self.container), "--source", str(self.source), "--token", token,
                    "--host", str(ARGS.host)]
            child = subprocess.run(args, capture_output=True)
            self.assertEqual(child.returncode, -signal.SIGKILL, child.stderr)
            self.assertTrue(m.state(self.container)["needsRecovery"])
            with m.writer(self.container):
                m.recover_locked(self.container)
                m.recover_locked(self.container)
            current = m.index(self.container)
            self.assertEqual(current == previous, step != "published-index")
            self.assertFalse(m.state(self.container)["needsRecovery"])
        self.assertEqual(m.domains.inspect_profile(m.generation(self.container, current["active"]))["trayAssets"], 5)

    def test_forged_journal_preserves_unrelated_generation(self):
        result = self.apply()
        orphan = str(uuid.uuid4())
        data = self.container / "generations" / orphan
        shutil.copytree(self.current, data)
        original = m.digest(m.inventory(data))
        m.put(self.container / "transaction.json", dict(next=orphan, prior=result["active"],
                                                       priorIndex=m.digest(m.index(self.container)), nonce=str(uuid.uuid4())))
        with m.writer(self.container), self.assertRaises(ValueError):
            m.recover_locked(self.container)
        self.assertEqual(m.digest(m.inventory(data)), original)
        self.assertTrue(m.state(self.container)["needsRecovery"])

    def test_rollback_corrupt_backup(self):
        generation = self.apply()["active"]
        backup = self.container / "transactions" / generation / "previous-backup"
        (backup / "profile.version").write_text("damaged")
        with m.writer(self.container), self.assertRaisesRegex(ValueError, "备份指纹"):
            m.rollback_locked(self.container, m.state(self.container)["rollbackToken"])
        self.assertEqual(m.index(self.container)["active"], generation)

    def test_pending_window_recovery(self):
        path = self.source / "WorkRect"
        path.mkdir(exist_ok=True)
        (path / "manager.lock").touch()
        m.put(path / "management.json", dict(mode="off", pendingStop=True))
        original = m.digest(m.inventory(self.source))
        with self.assertRaisesRegex(ValueError, "恢复"):
            self.apply()
        self.assertEqual(original, m.digest(m.inventory(self.source)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--empty", type=synthetic)
    parser.add_argument("--populated", type=synthetic)
    parser.add_argument("--output", type=Path, default=HERE.parent / "build/verification/p53")
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--limited-file", action="store_true")
    parser.add_argument("--crash", choices=["backups", "published-directory", "published-index"])
    parser.add_argument("--container", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--token")
    ARGS = parser.parse_args()
    if ARGS.limited_file:
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (16384, 16384))
        try:
            with m.writer(ARGS.container):
                m.import_locked(ARGS.container, ARGS.source, m.SECTIONS, ARGS.token)
        except OSError as error:
            print(error.errno)
        else:
            raise AssertionError("Expected kernel file size refusal")
    elif ARGS.crash:
        m.validate_configuration = lambda root: m.validate_with_host(ARGS.host, root)
        def interrupt(step):
            if step == ARGS.crash:
                os.kill(os.getpid(), signal.SIGKILL)
        with m.writer(ARGS.container):
            m.import_locked(ARGS.container, ARGS.source, m.SECTIONS, ARGS.token, interrupt)
    else:
        if not ARGS.empty or not ARGS.populated:
            parser.error("--empty and --populated must refer to prepared native fixtures")
        unittest.main(argv=[sys.argv[0]], verbosity=2)
