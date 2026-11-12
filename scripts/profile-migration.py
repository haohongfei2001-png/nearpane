#!/usr/bin/python3
"""Inspect an explicitly chosen Alpha and switch verified local profile generations."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import uuid
from contextlib import contextmanager

# The signed launcher uses -I -B. Only load the module shipped beside this entry.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import profile_domains as domains

MARKER = b"Nearpane P5.3\n"
LEGACY = {"Nearpane P" + v for v in ("4.8", "4.8.1", "4.9", "5.0", "5.1", "5.2")}
SECTIONS = ("voice", "tray", "settings")
LABELS = {"voice": "文字与修订", "tray": "截图与队列历史", "settings": "设置"}


def require(test, message):
    if not test:
        raise ValueError(message)


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(encode(value)).hexdigest()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def put(path, value):
    fd, name = tempfile.mkstemp(prefix=".profile-write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(encode(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        sync_directory(path.parent)
    finally:
        Path(name).unlink(missing_ok=True)


def checked_root(path):
    path = path.absolute()
    require(path == path.resolve(strict=True) and path.is_dir() and path.stat().st_uid == os.getuid(),
            "资料目录不可用，或包含链接。")
    return path


def plain_file(path):
    st = path.lstat()
    require(stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid() and st.st_nlink == 1,
            "资料包含链接、特殊文件或其他账户的文件。")
    return st


def identifier(value):
    require(isinstance(value, str) and str(uuid.UUID(value)) == value, "资料代际标识无效。")
    return value


def read_json(path):
    plain_file(path)
    return json.loads(path.read_bytes())


def generation(root, key):
    path = checked_root(checked_root(root / "generations") / identifier(key))
    plain_file(path / "profile.version")
    require((path / "profile.version").read_bytes() == MARKER, "这份资料需要其他版本的 Nearpane。")
    return path


def index(root):
    value = read_json(root / "profile-index.json")
    require(isinstance(value, dict) and type(value.get("format")) is int and value["format"] == 1,
            "当前版本不支持这份资料契约。")
    generation(root, value["active"])
    if value.get("previous") is not None:
        identifier(value["previous"])
        require(value["previous"] != value["active"], "当前及回退资料身份冲突。")
    require(isinstance(value.get("imports"), dict), "资料版本索引损坏。")
    return value


@contextmanager
def writer(root):
    fd = os.open(root / "writer.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        plain_file(root / "writer.lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("当前资料正由其他 Nearpane 实例使用，请先退出。") from None
        yield
    finally:
        os.close(fd)


def inventory(source, destination=None):
    """Hash directory entries relative to opened parent fds, including empty dirs."""
    files = {}
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW

    def visit(parent_fd, rel):
        for name in sorted(os.listdir(parent_fd)):
            key = rel / name
            entry = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            require(entry.st_uid == os.getuid(), "资料属于其他账户。")
            if stat.S_ISDIR(entry.st_mode):
                child_fd = os.open(name, directory_flags, dir_fd=parent_fd)
                try:
                    require(os.path.samestat(entry, os.fstat(child_fd)), "复制时资料目录身份已变化。")
                    files[str(key) + "/"] = None
                    if destination is not None:
                        (destination / key).mkdir(mode=0o700)
                    visit(child_fd, key)
                    if destination is not None:
                        sync_directory(destination / key)
                finally:
                    os.close(child_fd)
                continue
            require(stat.S_ISREG(entry.st_mode) and entry.st_nlink == 1, "资料包含链接或特殊文件。")
            h = hashlib.sha256()
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
            with os.fdopen(fd, "rb") as reader:
                observed = os.fstat(fd)
                require(stat.S_ISREG(observed.st_mode) and os.path.samestat(entry, observed) and observed.st_nlink == 1,
                        "复制时资料文件身份已变化。")
                out = None if destination is None else (destination / key).open("xb")
                try:
                    for chunk in iter(lambda: reader.read(1024 * 1024), b""):
                        h.update(chunk)
                        if out is not None:
                            out.write(chunk)
                    if out is not None:
                        out.flush()
                        os.fsync(out.fileno())
                finally:
                    if out is not None:
                        out.close()
            files[str(key)] = h.hexdigest()

    if destination is not None:
        destination.mkdir(mode=0o700)
    fd = os.open(source, directory_flags)
    try:
        visit(fd, Path())
    finally:
        os.close(fd)
    if destination is not None:
        sync_directory(destination)
    return files


def snapshot(source, dest):
    original = inventory(source, dest)
    require(original == inventory(source) == inventory(dest), "资料在复制期间发生变化，请退出来源版本后重新预览。")
    return digest(original)


def select_source(root, source):
    require(source is not None, "请选择来源版本。")
    source = checked_root(source)
    require(source != root and source not in root.parents and root not in source.parents,
            "来源和目标资料必须相互独立。")
    plain_file(source / "profile.version")
    marker = (source / "profile.version").read_bytes()
    allowed = {v + "\n" for v in LEGACY}
    require(marker.decode() in allowed, "暂不支持此来源资料版本。")
    require(source.parent == root.parent and source.name == "Nearpane Alpha " + marker.decode().strip().split(" ")[1],
            "来源目录与选定版本的资料身份不符。")
    return source


def selection(sections):
    values = sections.split(",")
    require(values and len(set(values)) == len(values) and set(values) <= set(SECTIONS),
            "请选择要导入的资料类别。")
    return [s for s in SECTIONS if s in values]


def identifiers(source, source_digest, sections, idx):
    identity = source.stat()
    operation = digest([source_digest, str(source), identity.st_dev, identity.st_ino, sections])
    return operation, digest([operation, idx])


def safe_summary(folder):
    report = domains.inspect_profile(folder)
    require(not report["windowRecoveryBlocked"], "该版本有未解决的窗口管理或恢复事务，请先在原版本处理。")
    require(not report["activeAttachments"], "该版本有尚在进行的附件操作，请先在原版本核对。")
    return report


def preview(root, source, sections):
    idx = index(root)
    require(not (root / "transaction.json").exists(), "请先恢复中断的资料切换。")
    source = select_source(root, source)
    with domains.source_locks(source), tempfile.TemporaryDirectory() as name:
        copy = Path(name).resolve() / "source"
        fingerprint = snapshot(source, copy)
        info = safe_summary(copy)
        _, token = identifiers(source, fingerprint, sections, idx)
    selected = "、".join(LABELS[s] for s in sections)
    message = f"将以所选版本的{selected}替换对应资料。其他类别沿用当前资料，切换前的整份资料可回退。"
    lines = [f"文字 {info['voiceRecords']} 条，修订 {info['voiceRevisions']} 项，编辑草稿 {info['voiceDrafts']} 份。",
             f"截图 {info['trayAssets']} 张，附件历史 {info['trayOperations']} 条，其中结果未知 {info['trayUnknown']} 条、失败 {info['trayFailed']} 条。",
             f"已保存 {info['displaySettings']} 组显示器设置。"]
    return dict(token=token, summary=info, lines=lines, sourceSHA256=fingerprint, message=message)


def state(root):
    idx = index(root)
    previous = idx.get("previous")
    pending = (root / "transaction.json").exists()
    return dict(active=idx["active"], canRollback=bool(previous and not pending), needsRecovery=pending,
                rollbackToken=digest(["rollback", idx]) if previous and not pending else None,
                message="需清理上次中断的资料切换。" if pending else "资料可用。")


def transaction_paths(root, key):
    parent = root / "transactions"
    parent.mkdir(mode=0o700, exist_ok=True)
    checked_root(parent)
    key = identifier(key)
    return parent / key, root / "generations" / key


def begin(root, work, idx, key):
    journal = dict(next=key, prior=idx["active"], priorIndex=digest(idx), nonce=str(uuid.uuid4()))
    work.mkdir(mode=0o700)
    put(work / "ownership.json", journal)
    sync_directory(work.parent)
    # Before this pointer exists an interrupted setup owns only an empty receipt,
    # and no user content has been copied. Afterwards recovery has both records.
    put(root / "transaction.json", journal)


def recover_locked(root):
    marker = root / "transaction.json"
    if not marker.exists():
        return
    tx = read_json(marker)
    idx = index(root)
    key, old = identifier(tx["next"]), identifier(tx["prior"])
    identifier(tx["nonce"])
    require(key != old and idx["active"] in (key, old), "事务和当前资料代际不符，请保留现场。")
    work, output = transaction_paths(root, key)
    unpublished = idx["active"] == old
    if unpublished:
        require(digest(idx) == tx["priorIndex"] and key != idx.get("previous") and key not in idx["imports"].values(),
                "未发布资料与历史记录冲突。")
    else:
        require(idx.get("previous") == old and idx.get("previousBackup") == key, "已发布的代际索引不符。")

    if work.exists():
        checked_root(work)
    owns_work = work.exists() and (work / "ownership.json").exists() and read_json(work / "ownership.json") == tx
    if output.exists() or not unpublished:
        # A corrupted journal must never point removal at a former user's generation.
        require(owns_work, "缺少可验证的原事务凭据，已保留现场。")
        receipt = read_json(work / "receipt.json")
        require(receipt["generation"] == key and receipt["prior"] == old and receipt["nonce"] == tx["nonce"]
                and receipt["outputSHA256"] == digest(inventory(generation(root, key)))
                and receipt["previousSHA256"] == digest(inventory(checked_root(work / "previous-backup"))),
                "切换后代际或备份指纹不符，已保留现场。")
        if "sourceSHA256" in receipt:
            require(receipt["sourceSHA256"] == digest(inventory(checked_root(work / "source-backup"))),
                    "来源备份损坏，已保留现场。")
    if unpublished:
        discard = work.parent / (".discard-" + tx["nonce"])
        if output.exists():
            # Move the complete, verified, unpublished generation out of the
            # namespace atomically before attempting an interruptible tree removal.
            os.rename(output, work / "aborted-generation")
            sync_directory(output.parent)
            sync_directory(work)
        if work.exists():
            require(owns_work and not discard.exists(), "暂存目录归属不明，已保留现场。")
            os.rename(work, discard)
            sync_directory(discard.parent)
        if discard.exists():
            checked_root(discard)
            shutil.rmtree(discard)
            sync_directory(discard.parent)
    marker.unlink()
    sync_directory(root)


def import_locked(root, source, sections, token, checkpoint=lambda step: None):
    require(not (root / "transaction.json").exists(), "请先恢复中断的资料切换。")
    idx = index(root)
    source = select_source(root, source)
    current = generation(root, idx["active"])
    key = str(uuid.uuid4())
    work, output = transaction_paths(root, key)
    require(not work.exists() and not output.exists(), "新资料代际已存在。")
    with domains.source_locks(source), domains.source_locks(current):
        begin(root, work, idx, key)
        try:
            source_copy = work / "source-backup"
            source_digest = snapshot(source, source_copy)
            operation, expected = identifiers(source, source_digest, sections, idx)
            if idx["imports"].get(operation) == idx["active"]:
                recover_locked(root)
                return dict(active=idx["active"], duplicate=True, message="本次所选资料已导入。")
            require(token == expected, "来源、当前资料或选择已改变，请重新预览。")
            current_copy = work / "previous-backup"
            previous_digest = snapshot(current, current_copy)
            # Validators open only private working copies, so SQLite sidecars on
            # either file-for-file backup stay untouched.
            with tempfile.TemporaryDirectory(dir=work) as scratch:
                src = Path(scratch) / "source"
                prior = Path(scratch) / "prior"
                require(snapshot(source_copy, src) == source_digest and snapshot(current_copy, prior) == previous_digest,
                        "备份指纹不一致。")
                safe_summary(src)
                safe_summary(prior)
                checkpoint("backups")
                new = work / "generation"
                new.mkdir(mode=0o700)
                info = domains.import_profile(src, new, sections, prior)
                (new / "profile.version").write_bytes(MARKER)
                validate_configuration(new)
                safe_summary(new)
                # Re-read after the complete import and before publishing authority.
                require(digest(inventory(source)) == source_digest and digest(inventory(current)) == previous_digest,
                        "切换前来源或当前资料已改变。")
                put(work / "receipt.json", dict(generation=key, nonce=read_json(work / "ownership.json")["nonce"],
                                               outputSHA256=digest(inventory(new)), prior=idx["active"], operation=operation,
                                               sections=sections, sourceSHA256=source_digest,
                                               previousSHA256=previous_digest, summary=info))
            publish(root, key, work, output, new, idx, previous_digest, checkpoint, operation)
            return dict(active=key, message="已导入所选资料。重新打开 Nearpane 后使用新资料。")
        except Exception:
            recover_locked(root)
            raise


def publish(root, key, work, output, new, idx, previous_digest, checkpoint, operation=None):
    for path in new.rglob("*"):
        if path.is_file():
            with path.open("rb") as stream:
                os.fsync(stream.fileno())
    for path in reversed(list(new.rglob("*"))):
        if path.is_dir():
            sync_directory(path)
    sync_directory(new)
    os.rename(new, output)
    sync_directory(output.parent)
    sync_directory(work)
    sync_directory(work.parent)
    checkpoint("published-directory")
    imports = dict(idx["imports"])
    if operation is not None:
        imports[operation] = key
    next_idx = dict(idx, active=key, previous=idx["active"], previousSHA256=previous_digest,
                    previousBackup=key, imports=imports, revision=str(uuid.uuid4()))
    put(root / "profile-index.json", next_idx)
    checkpoint("published-index")
    recover_locked(root)


def rollback_locked(root, token):
    idx = index(root)
    require(not (root / "transaction.json").exists() and idx.get("previous") and token == digest(["rollback", idx]),
            "回退对象已改变，请重新查看。")
    current = generation(root, idx["active"])
    backup_folder, _ = transaction_paths(root, identifier(idx["previousBackup"]))
    original = checked_root(checked_root(backup_folder) / "previous-backup")
    key = str(uuid.uuid4())
    work, output = transaction_paths(root, key)
    require(not work.exists() and not output.exists(), "新资料代际已存在。")
    with domains.source_locks(current):
        begin(root, work, idx, key)
        try:
            before = work / "previous-backup"
            fingerprint = snapshot(current, before)
            with tempfile.TemporaryDirectory(dir=work) as name:
                store = Path(name).resolve()
                target, previous = store / "current", store / "previous"
                require(snapshot(before, target) == fingerprint, "当前资料备份校验失败。")
                require(snapshot(original, previous) == idx["previousSHA256"], "回退备份指纹不符。")
                safe_summary(target)
                safe_summary(previous)
                # Rehydrate through domain rules instead of re-enabling historical grants.
                new = work / "generation"
                new.mkdir(mode=0o700)
                info = domains.restore_profile(previous, new, target)
                (new / "profile.version").write_bytes(MARKER)
                validate_configuration(new)
                safe_summary(new)
                require(digest(inventory(current)) == fingerprint, "回退期间当前资料已改变。")
                put(work / "receipt.json", dict(generation=key, nonce=read_json(work / "ownership.json")["nonce"],
                                               outputSHA256=digest(inventory(new)), restoredFrom=idx["previous"],
                                               prior=idx["active"], previousSHA256=fingerprint, summary=info))
            publish(root, key, work, output, new, idx, fingerprint, lambda step: None)
            return dict(active=key, message="已恢复上一份资料。刚才使用的资料也已备份。")
        except Exception:
            recover_locked(root)
            raise


def validate_configuration(root):
    # The Host's normal Codable validation remains authoritative. The source-tree
    # test driver injects a frozen executable; installed copies always use their own.
    host = Path(__file__).resolve().parents[2] / "MacOS" / "NearpaneHost"
    validate_with_host(host, root)


def validate_with_host(host, root):
    staged_clock = domains.obj(root / domains.CONFIG).get("clockTimeZoneID")
    result = subprocess.run([str(host), "--validate-import-configuration", str(root / domains.CONFIG)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=15, check=False)
    require(result.returncode == 0 and 0 < len(result.stdout) <= 1024 * 1024,
            "Host 无法安全读取导入的显示器或模块设置。")
    confirmed = json.loads(result.stdout)
    require(isinstance(confirmed, dict) and confirmed.get("version") == 1, "Host 返回的设置版本不符。")
    require(confirmed.get("clockTimeZoneID") == staged_clock, "当前版本无法识别所选资料的额外时区，请在来源版本核对。")
    put(root / domains.CONFIG, confirmed)
    # Both files are still in the unpublished generation. The normalized projection, not any
    # earlier occupant or adjacent file, supplies the preference that survives a legacy save.
    put(root / domains.CLOCK, confirmed.get("clockTimeZoneID"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["preview", "status", "import", "rollback", "recover"])
    parser.add_argument("--container", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--sections", default="voice,tray,settings")
    parser.add_argument("--token")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        root = checked_root(args.container)
        if args.action == "status":
            result = state(root)
        elif args.action == "preview":
            result = preview(root, args.source, selection(args.sections))
        else:
            with writer(root):
                if args.action == "import":
                    result = import_locked(root, args.source, selection(args.sections), args.token)
                elif args.action == "rollback":
                    result = rollback_locked(root, args.token)
                else:
                    recover_locked(root)
                    result = state(root)
        print(json.dumps(dict(ok=True, **result), ensure_ascii=False))
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, RuntimeError, subprocess.SubprocessError) as e:
        # Only deliberate, user-facing refusals from our validators may escape.
        message = str(e) if type(e) is ValueError and not isinstance(e, UnicodeError) else "资料读写或校验失败，请检查存储空间、资料版本及文件完整性。"
        print(json.dumps(dict(ok=False, message=message), ensure_ascii=False))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
