"""Selective projection of closed, pinned Nearpane domain stores into a new generation."""
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import tempfile
import uuid

VOICE = Path("Nearpane/Voice/Saytile.sqlite")
TRAY = Path("Riftlet/queue.sqlite")
CONFIG = Path("Nearpane/host-configuration.json")
# sqlite_master, including indexes and constraints, from the two pinned domain writers.
SCHEMA = {VOICE: (5, "034c18279d1b3aaffc7580f07c568baf34809cceba5fc4f95469d96ccd4b76e9"),
          TRAY: (4, "04b043caf5f2b592719c1a5a7ef57e876ea2bb874462b01c6254a493d739f096")}
SECTIONS = {"voice", "tray", "settings"}
VOICE_TEXT = {"recordings", "revisions", "editing_drafts", "frozen_revisions"}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def regular(path):
    require(path.absolute() == path.resolve() and stat.S_ISREG(path.lstat().st_mode)
            and path.stat().st_nlink == 1, "资料包含链接或非常规文件，请保留原件。")
    return path


def directory(path):
    require(path.absolute() == path.resolve() and path.is_dir(), "资料目录不存在或指向了其他位置。")
    return path


def obj(path, limit=1024 * 1024):
    require(regular(path).stat().st_size <= limit, "资料说明文件超过大小限制。")
    with path.open('rb') as f:
        value = json.load(f)
    require(isinstance(value, dict), "资料说明格式无效。")
    return value


def save(path, data):
    with path.open("x", encoding="utf-8") as out:
        json.dump(data, out, ensure_ascii=False, allow_nan=False)


def digest(path):
    sha = hashlib.sha256()
    with regular(path).open("rb") as f:
        for part in iter(lambda: f.read(1024 * 1024), b""):
            sha.update(part)
    return sha.hexdigest()


@contextlib.contextmanager
def source_locks(source):
    """Legacy readers use the same flock files as the three actual owners. Never create one."""
    directory(source)
    names = [VOICE.parent / ".writer-lock", TRAY.parent / "instance.lock"]
    if (source / "WorkRect").exists():
        names.append(Path("WorkRect/manager.lock"))
    with contextlib.ExitStack() as stack:
        for name in names:
            path = regular(source / name)
            fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            stack.callback(os.close, fd)
            require(os.path.samestat(os.fstat(fd), path.stat()), "资料锁身份变化。")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ValueError("有应用仍持有资料写锁，请正常退出该版本。") from error
        yield


def check(db):
    require(list(db.execute("PRAGMA integrity_check")) == [("ok",)] and
            db.execute("PRAGMA foreign_key_check").fetchone() is None, "SQLite 完整性或关联检查失败。")


def checkpoint_private_copy(db, wal):
    # SQLite validates WAL checksums/salts while recovering. Compare its accepted frame
    # count to the complete supplied file so a truncated or ignored tail cannot silently
    # turn the older main database into a successful import.
    size = wal.stat().st_size
    if not size:
        return
    with wal.open("rb") as f:
        header = f.read(32)
    require(len(header) == 32 and int.from_bytes(header[:4], "big") in (0x377F0682, 0x377F0683),
            "SQLite WAL 日志头不完整，请先在原版核对资料。")
    page_size = int.from_bytes(header[8:12], "big")
    require(512 <= page_size <= 65536 and not page_size & (page_size - 1),
            "SQLite WAL 分页无效。")
    frames, remainder = divmod(size - 32, 24 + page_size)
    require(not remainder, "SQLite WAL 尾部不完整，请先在原版处理。")
    require(db.execute("PRAGMA wal_checkpoint(FULL)").fetchone() == (0, frames, frames),
            "SQLite 没有确认全部 WAL 帧，请先在原版核对并安全退出。")


@contextlib.contextmanager
def snapshot(root, rel):
    # Even a mode=ro WAL reader can update shared-memory bytes. Run SQLite only on a private copy.
    dbfile = regular(root / rel)
    with tempfile.TemporaryDirectory(prefix="nearpane-import-") as tmp:
        local = Path(tmp) / "domain.sqlite"
        require(not Path(str(dbfile) + "-journal").exists(), "发现未清理的回滚日志，请先安全关闭旧版。")
        shutil.copyfile(dbfile, local)
        wal = Path(str(dbfile) + "-wal")
        if wal.exists():
            shutil.copyfile(regular(wal), str(local) + "-wal")
        with contextlib.closing(sqlite3.connect(str(local))) as db:
            if wal.exists():
                checkpoint_private_copy(db, Path(str(local) + "-wal"))
            db.execute("PRAGMA trusted_schema=OFF")
            version, known = SCHEMA[rel]
            require(db.execute("PRAGMA user_version").fetchone() == (version,), "此版本不支持该数据库版本，请使用原版本。")
            objects = list(db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name"))
            signature = hashlib.sha256(json.dumps(objects, separators=(',', ':')).encode()).hexdigest()
            require(signature == known, "数据库结构与固定领域版本不符。")
            check(db)
            yield db


def scalar(db, sql):
    return db.execute(sql).fetchone()[0]


def voice_stats(db):
    require(not scalar(db, """SELECT count(*) FROM recordings r WHERE preferred_revision IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM revisions v WHERE v.id=r.preferred_revision AND v.recording_id=r.id)"""),
            "手工选择的语音修订归属无法核对。")
    for (key,) in db.execute("SELECT id FROM recordings UNION ALL SELECT id FROM revisions"):
        uuid.UUID(key)
    return dict(voiceRecords=scalar(db, "SELECT count(*) FROM recordings"),
                voiceRevisions=scalar(db, "SELECT count(*) FROM revisions"),
                voiceDrafts=scalar(db, "SELECT count(*) FROM editing_drafts"),
                voiceAudioChunks=scalar(db, "SELECT count(*) FROM chunks"),
                voiceSchema=5)


def text_projection(db, dest):
    voice_dir = dest / VOICE.parent
    (voice_dir / "Audio").mkdir(parents=True, mode=0o700)
    (voice_dir / ".writer-lock").touch(mode=0o600)
    export_store(db, dest / VOICE, VOICE_TEXT,
                 """UPDATE recordings SET audio_state='deleted',total_frames=0,is_recording=0,active_attempt=NULL,
                     last_error=NULL,recognition_state=CASE WHEN recognition_state IN ('queued','running')
                     THEN 'cancelled' ELSE recognition_state END""")


def retain_voice(db, root, dest):
    """Restore a verified copy of this same profile's local data on rollback or deselection."""
    target = dest / VOICE
    audio = directory(root / VOICE.parent / "Audio")
    directory(dest)
    (target.parent / "Audio").mkdir(parents=True, mode=0o700)
    (target.parent / ".writer-lock").touch(mode=0o600)
    # Erasure and live recordings belong to the process that accepted them.
    require(not scalar(db, "SELECT count(*) FROM recordings WHERE is_recording!=0 OR active_attempt IS NOT NULL "
                           "OR recognition_state='running' OR audio_state='deletePending'") and
            not scalar(db, "SELECT count(*) FROM erasures WHERE completed=0"),
            "当前语音资料还有进行中的录音、识别或擦除，请先在原版本处理。")
    for path in audio.rglob("*"):
        to = target.parent / "Audio" / path.relative_to(audio)
        if path.is_dir():
            directory(path)
            to.mkdir(parents=True, exist_ok=True, mode=0o700)
        else:
            shutil.copyfile(regular(path), to)
            require(digest(path) == digest(to), "原音文件复制后校验失败。")
    for name, in db.execute("SELECT path FROM chunks JOIN recordings ON recordings.id=chunks.recording_id "
                            "WHERE recordings.audio_state='available'"):
        require(not Path(name).is_absolute() and all(p not in (".", "..", "") for p in name.split("/")),
                "原音索引路径越界。")
        regular(target.parent / "Audio" / name)
    with contextlib.closing(sqlite3.connect(str(target))) as out:
        db.backup(out)
        out.execute("PRAGMA secure_delete=ON")
        with out:
            out.execute("DELETE FROM recording_cloud_authorizations")
            out.execute("UPDATE bindings SET active=0")
            out.execute("UPDATE owned_input_ranges SET valid=0")
            out.execute("UPDATE owned_corrections SET state='cancelled' WHERE state='pending'")
            out.execute("UPDATE owned_corrections SET state='unverified' WHERE state='dispatching'")
            out.execute("UPDATE dispatches SET state='unverified' WHERE state='dispatching'")
            out.execute("INSERT OR IGNORE INTO recognition_retry_blocks(recording_id,reason) "
                        "SELECT id,'资料切换后需手动重试' FROM recordings WHERE audio_state='available' "
                        "AND recognition_state IN ('failed','queued') AND deleted=0")
        out.execute("PRAGMA journal_mode=DELETE")
        out.execute("VACUUM")
        check(out)
    os.chmod(target, 0o600)


def export_store(db, path, allowed, sanitize):
    # Copy the verified schema and whitelisted logical rows only. Unselected tables, free
    # pages, old WAL bytes and erased text cannot leak into the new database.
    with contextlib.closing(sqlite3.connect(str(path))) as out:
        out.execute("PRAGMA trusted_schema=OFF")
        objects = list(db.execute("SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL "
                                  "AND name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END,name"))
        with out:
            for kind, name, sql in objects:
                out.execute(sql)
                if kind == "table" and name in allowed:
                    rows = db.execute('SELECT * FROM "' + name + '"')
                    insert = 'INSERT INTO "' + name + '" VALUES(' + ','.join('?' for _ in rows.description) + ')'
                    out.executemany(insert, rows)
            out.execute(sanitize)
            out.execute("PRAGMA user_version=" + str(scalar(db, "PRAGMA user_version")))
        check(out)
    os.chmod(path, 0o600)


def tray_contents(db, root, dest=None):
    library = directory(root / "Riftlet")
    require(db.execute("SELECT value FROM metadata WHERE key='mode'").fetchone() == ("production",),
            "截图资料库不是此候选支持的正式领域格式。")
    media_names, ids = set(), set()
    if dest is not None:
        for name in ("media", "journal", "staging", "imported-attachment-holds"):
            (dest / "Riftlet" / name).mkdir(parents=True, mode=0o700, exist_ok=True)
    for key, row_id, name, payload, active in db.execute(
            "SELECT source_key,id,file_name,image_json,active_operation_id FROM assets ORDER BY sort_at,sequence"):
        item = json.loads(payload)
        uid = str(uuid.UUID(row_id))
        require(item["id"] == row_id and item["fileName"] == name and item["sourceKey"] == key and
                re.fullmatch(r'[a-fA-F0-9-]{36}\.[A-Za-z0-9]+', name) and name.split('.')[0].lower() == uid,
                "截图 UUID、文件名或来源不一致。")
        path = regular(library / "media" / name)
        require(item["byteCount"] > 0 and path.stat().st_size == item["byteCount"] and
                digest(path) == item["sha256"], "截图媒体大小或 SHA-256 校验失败。")
        if active:
            require(db.execute("SELECT asset_id FROM operations WHERE id=?", (active,)).fetchone() == (row_id,),
                    "截图与附件操作归属不一致。")
        media_names.add(name)
        ids.add(uid)
        if dest is not None:
            target = dest / "Riftlet/media" / name
            shutil.copyfile(path, target)
            require(digest(target) == item["sha256"], "写入后截图 SHA-256 校验失败。")
            save(dest / "Riftlet/journal" / (uid + ".json"), dict(version=1, image=item))
        manifest = library / "journal" / (uid + ".json")
        if manifest.exists():
            old = obj(manifest)
            require(old.get("version") == 1 and old.get("image") == item, "截图收录日志与资料库不一致。")
    for kind, expected in (("media", media_names), ("journal", {u+'.json' for u in ids}), ("staging", set())):
        folder = library / kind
        if folder.exists():
            require(all(p.name in expected for p in directory(folder).iterdir()), "截图库有未完成或未登记的媒体，请先在原版恢复。")
    holds = attachment_holds(db, library, ids)
    if dest is not None:
        write_holds(dest, holds)
        (dest / "Riftlet/instance.lock").touch(mode=0o600)
        export_store(db, dest / TRAY, {"assets","operations","compensations","upload_starts","metadata"},
                     """DELETE FROM metadata WHERE key NOT IN ('mode','transfer-dispatch-slots-v1',
                        'capture_paused','user_hidden')""")
    return dict(traySchema=4, trayAssets=len(ids), trayOperations=scalar(db, "SELECT count(*) FROM operations"),
                trayUnknown=scalar(db, "SELECT count(*) FROM operations WHERE phase IN ('unknown','compensated')"),
                trayFailed=scalar(db, "SELECT count(*) FROM operations WHERE phase='failed'"),
                activeAttachments=scalar(db, "SELECT count(*) FROM operations WHERE phase IN "
                                         "('prepared','dispatchIntent','inputTriggered','attachmentPresent')"),
                heldAssets=len(holds))


def write_holds(dest, holds):
    for uid in holds:
        marker = dest / "Riftlet/imported-attachment-holds" / uid
        if not marker.exists():
            marker.touch(mode=0o600, exist_ok=False)


def attachment_holds(db, library, ids):
    holds = {str(uuid.UUID(x[0])) for x in db.execute("SELECT DISTINCT asset_id FROM operations")}
    for folder, suffix in (("draft-input-claims", ".json"), ("imported-attachment-holds", "")):
        path = library / folder
        if path.exists():
            for file in directory(path).iterdir():
                regular(file)
                key = file.stem if suffix else file.name
                require(str(uuid.UUID(key)) == key and (not suffix or key in ids) and file.name == key + suffix,
                        "浏览器输入记录与截图不对应。")
                holds.add(key)
    return holds


def settings(root):
    cfg = obj(root / CONFIG, 128 * 1024)
    require(cfg.get("version") == 1 and cfg.get("edge") in ("left", "right") and
            isinstance(cfg.get("modules"), list) and isinstance(cfg.get("displays", {}), dict),
            "Host 设置版本或结构无法识别。")
    cfg = {k: v for k, v in cfg.items() if k in {"version","edge","preferredDisplayID","surfaceHidden",
           "candidateTrayConnected","workspaces","displays","modules","fixture","clockTimeZoneID"}}
    cfg["experimentalSpaceObservation"] = False
    ws = cfg.get("workspaces", {})
    cfg["workspaces"] = {k: v for k, v in ws.items() if k in ("excludedApps", "newWindow", "overflow")}
    cfg["workspaces"]["windows"] = []
    cfg["modules"] = [{k: m[k] for k in ("id","enabled","pinned")} for m in cfg["modules"]]
    work = root / "WorkRect"
    manager = {}
    blocked = False
    if work.exists():
        directory(work)
        if (work / "management.json").exists():
            manager = obj(work / "management.json")
            blocked = (manager.get("mode") != "off" or bool(manager.get("pendingStop") or manager.get("blockedReason")
                                                            or manager.get("fullscreenHold")))
        for journal in work.glob("*/journal.json"):
            blocked |= obj(journal).get("status") not in ("retained", "restored")
    ratio = manager.get("ratio", .5)
    require(type(ratio) in (float,int) and math.isfinite(ratio) and .2 <= ratio <= .8 and
            type(manager.get("swap", False)) is bool, "窗口布局比例或槽位无效。")
    return cfg, dict(mode="off", ratio=ratio, swap=manager.get("swap", False)), blocked


def copy_capture_preferences(source, destination):
    path = source / "capture-entry-settings.json"
    if path.exists():
        entry = obj(path)
        enabled = entry.get("builtInScreenshotEnabled", entry.get("isEnabled", True))
        require(entry.get("version") == 1 and entry.get("defaultMode") in ("region","window","fullScreen")
                and type(enabled) is bool, "截图模式设置不受支持。")
        save(destination / path.name, dict(version=1, defaultMode=entry["defaultMode"], builtInScreenshotEnabled=enabled))
    path = source / "arrival-motion-settings.json"
    if path.exists():
        entry = obj(path)
        require(entry.get("version") == 1 and entry.get("mode") in ("none","magnet"), "截图动效设置不受支持。")
        save(destination / path.name, dict(version=1, mode=entry["mode"]))


def inspect_profile(source):
    source = directory(Path(source))
    cfg, _, blocked = settings(source)
    with snapshot(source, VOICE) as voice, snapshot(source, TRAY) as queue:
        return dict(**voice_stats(voice), **tray_contents(queue, source),
                    displaySettings=len(cfg.get("displays", {})), windowRecoveryBlocked=blocked)


def restore_profile(previous, dest, current):
    return _project(previous, dest, SECTIONS, current, preserve_audio=True)


def import_profile(source, destination, sections, current=None):
    return _project(source, destination, sections, current, preserve_audio="voice" not in sections)


def _project(source, destination, sections, current, preserve_audio):
    require(set(sections) and set(sections) <= SECTIONS, "必须选择支持的资料类别。")
    dest = directory(Path(destination))
    require(not any(dest.iterdir()), "目标资料代际必须是新建的空目录。")
    if set(sections) != SECTIONS:
        require(current is not None, "保留未选类别需要当前资料代际。")
    roots = {section: Path(source if section in sections else current) for section in SECTIONS}
    for root in set(roots.values()) | ({Path(current)} if current is not None else set()):
        summary = inspect_profile(root)
        require(not summary["windowRecoveryBlocked"] and not summary["activeAttachments"],
                "请先在原版本处理尚未完成的窗口恢复或附件事务。")
    with snapshot(roots["voice"], VOICE) as voice:
        if preserve_audio:
            retain_voice(voice, roots["voice"], dest)
        else:
            text_projection(voice, dest)
    with snapshot(roots["tray"], TRAY) as queue:
        tray_contents(queue, roots["tray"], dest)
    if current is not None and Path(current) != roots["tray"]:
        with snapshot(Path(current), TRAY) as queue:
            ids = {str(uuid.UUID(row[0])) for row in queue.execute("SELECT id FROM assets")}
            write_holds(dest, attachment_holds(queue, Path(current) / "Riftlet", ids))
    config, manager, _ = settings(roots["settings"])
    copy_capture_preferences(roots["settings"] / "Riftlet", dest / "Riftlet")
    save(dest / CONFIG, config)
    (dest / "WorkRect").mkdir(mode=0o700)
    (dest / "WorkRect/manager.lock").touch(mode=0o600)
    save(dest / "WorkRect/management.json", manager)
    return inspect_profile(dest)
