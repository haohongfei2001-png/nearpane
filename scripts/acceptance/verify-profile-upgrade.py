#!/usr/bin/env python3
"""Verify both signed candidates on disposable, binary-bound profiles. No live library input."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import time
import uuid
from contextlib import closing, nullcontext

ROOT = Path(__file__).resolve().parents[2]
NO_EXTERNAL_RUNTIME = ('(deny file-read* (subpath "/Library/Developer") (subpath "/Applications/Xcode.app")'
                       ' (subpath "/opt/homebrew") (subpath "/usr/local") (literal "/usr/bin/python3"))'
                       '(deny process-exec (literal "/usr/bin/xcrun") (literal "/usr/bin/xcode-select"))')
SANDBOX = ["/usr/bin/sandbox-exec", "-p",
           '(version 1)(allow default)(deny network-outbound)'
           '(deny file-read* file-write* (regex #"/Library/Application Support/(Nearpane|Saytile|Riftlet)"))']


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def tree(root):
    manifest = {str(f.relative_to(root)): sha(f.read_bytes()) for f in root.rglob("*") if f.is_file()}
    return sha(json.dumps(manifest, sort_keys=True).encode())


def run(args, *, reply=False, standalone=False, stdin=None):
    policy = SANDBOX.copy()
    env = None
    if standalone:
        policy[-1] += NO_EXTERNAL_RUNTIME
        env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin",
                   PYTHONHOME="/nonexistent/nearpane-python", PYTHONPATH="/nonexistent/nearpane-modules")
    proc = subprocess.run(policy + [str(x) for x in args], cwd=ROOT, capture_output=True, text=True,
                          input=stdin, timeout=45, env=env)
    if proc.returncode:
        raise ValueError(proc.stderr[-500:] or proc.stdout[-500:])
    if not reply:
        return proc.stdout
    objects = [line for line in proc.stdout.splitlines() if line.startswith("{")]
    require(len(objects) == 1, "Expected one structured reply")
    return json.loads(objects[0])


def binary(app, expected):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == expected, "Unexpected app identity")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)
    return app / "Contents/MacOS" / info["CFBundleExecutable"]


def prepare(exe, blank):
    sid = str(uuid.uuid4())
    command = "--native-acceptance-prepare-draft" if blank else "--native-acceptance-prepare"
    run([exe, "--verify-bundled-resources", command, sid])
    session = ROOT / "build/native-acceptance" / sid
    marker = json.loads((session / "session.json").read_bytes())
    require(marker["executableSHA256"] == sha(exe.read_bytes()), "Session is bound to another binary")
    return session


def evidence(profile):
    # Read db+WAL on a fresh physical copy. Never create an SHM file in the observed profile.
    with tempfile.TemporaryDirectory() as name:
        reports = {}
        for key, name_in_profile, tables in [
            ("voice", "Nearpane/Voice/Saytile.sqlite", {
                "recordings": "SELECT id, preferred_revision FROM recordings ORDER BY id",
                "revisions": "SELECT id,recording_id,origin,text FROM revisions ORDER BY id",
                "drafts": "SELECT * FROM editing_drafts ORDER BY recording_id",
                "dispatches": "SELECT count(*) FROM dispatches"}),
            ("tray", "Riftlet/queue.sqlite", {
                "queue": "SELECT id,file_name,image_json,status,visibility FROM assets ORDER BY sort_at,sequence",
                "operations": "SELECT id,asset_id,attempt,phase FROM operations ORDER BY sequence",
                "starts": "SELECT count(*) FROM upload_starts"})]:
            src = profile / name_in_profile
            db = Path(name) / (key + ".sqlite")
            for suffix in ("", "-wal"):
                f = Path(str(src) + suffix)
                if f.is_file():
                    shutil.copyfile(f, str(db) + suffix)
            with closing(sqlite3.connect(db)) as conn:
                require(conn.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
                        and not conn.execute("PRAGMA foreign_key_check").fetchall(), "Invalid database")
                reports[key] = {"schema": conn.execute("PRAGMA user_version").fetchone()[0],
                                "databaseSHA256": sha(src.read_bytes())}
                for field, sql in tables.items():
                    rows = conn.execute(sql).fetchall()
                    if field == "queue":
                        media = {}
                        for asset, file, payload, _, _ in rows:
                            h = sha((profile / "Riftlet/media" / file).read_bytes())
                            require(json.loads(payload)["sha256"] == h, "Media hash mismatch")
                            media[asset] = h
                        reports[key]["mediaSHA256"] = media
                        reports[key]["order"] = [row[0] for row in rows]
                    # ID, selected revision, text, ordering and operation state participate. No text in receipt.
                    reports[key][field] = {"count": len(rows), "sha256": sha(json.dumps(rows).encode())}
                    if field in ("dispatches", "starts"):
                        require(rows == [(0,)], "Unexpected dispatch or upload")
                    if field == "operations":
                        reports[key]["phases"] = [row[-1] for row in rows]
        return reports


def projection(report):
    return {domain: {k: v for k, v in fields.items() if k != "databaseSHA256"}
            for domain, fields in report.items()}


def verify_read_errors(app):
    """Run the installed Host's read-only profile gate on disposable SQLite failures."""
    host = binary(app, "com.holdsnow.nearpane.alpha")
    cases = (("missing-wal-sidecars", "Nearpane.Profile.SQLite", 14, "只读"),
             ("locked", "Nearpane.Profile.SQLite", 5, "正在使用"),
             ("not-a-database", "Nearpane.Profile.SQLite", 26, "无法识别"),
             ("damaged-page", "Nearpane.Profile.SQLite", 11, "结构损坏"),
             ("future-schema", "Nearpane.Profile", 4, "不兼容"))
    results = []
    for case, domain, code, text in cases:
        session = prepare(host, True)
        entry = [host, "--verify-bundled-resources", "--profile-acceptance-open", session.name]
        initial = run(entry, reply=True)
        generation = Path(initial["path"])
        require(generation == session/"Nearpane Alpha Profiles"/"generations"/str(uuid.UUID(initial["generation"])),
                "Unexpected fixture generation")
        db = generation/"Riftlet/queue.sqlite"
        if case == "missing-wal-sidecars":
            # Reproduce the system SQLite read of a clean WAL-mode main file without sidecars.
            require(db.read_bytes()[18:20] == bytes((2,2)), "Expected WAL format")
            wal = Path(str(db)+"-wal")
            require(not wal.exists() or wal.stat().st_size == 0, "Refusing to remove committed fixture frames")
            for suffix in ("-wal", "-shm"):
                Path(str(db)+suffix).unlink(missing_ok=True)
        else:
            run(["/usr/bin/sqlite3", db, "PRAGMA journal_mode=DELETE;"])
            if case == "future-schema":
                run(["/usr/bin/sqlite3", db, "PRAGMA user_version=91;"])
            elif case == "not-a-database":
                db.write_bytes(b"synthetic non-database " * 100)
            elif case == "damaged-page":
                with db.open("r+b") as file:
                    file.seek(100)  # First schema B-tree page type is no longer valid.
                    file.write(bytes((0xff,)))
        before = sha(db.read_bytes())
        lock_context = closing(sqlite3.connect(db)) if case == "locked" else nullcontext()
        with lock_context as lock:
            if lock is not None:
                lock.execute("BEGIN EXCLUSIVE")
            refused = subprocess.run(SANDBOX + list(map(str, entry)), cwd=ROOT, capture_output=True, text=True, timeout=25)
        require(refused.returncode == 3 and refused.stderr.startswith("Isolated profile open failed:")
                and f"Domain={domain} Code={code} " in refused.stderr
                and text in refused.stderr, f"{case}: unexpected refusal: {refused.stderr[:300]}")
        require(sha(db.read_bytes()) == before, case + ": read-only refusal modified database")
        if case == "missing-wal-sidecars":
            require(all(not Path(str(db)+s).exists() for s in ("-wal", "-shm")), "Refusal created SQLite sidecars")
        results.append(dict(case=case, session=session.name, domain=domain, code=code, output=refused.stderr.strip(),
                            databaseSHA256BeforeAndAfter=before))
    print(json.dumps({"hostSHA256":sha(host.read_bytes()), "refusals":results}, ensure_ascii=False, indent=2))

def archived_fixture(receipt):
    # Reuse the original synthetic import SOURCE, whose whole-tree fingerprint was
    # recorded after the historical UNKNOWN was added. Never open its SQLite in place.
    data = json.loads(receipt.read_bytes())
    legacy = ROOT / "build/native-acceptance" / str(uuid.UUID(data["newSession"]))
    marker = json.loads((legacy / "session.json").read_bytes())
    require(str(uuid.UUID(marker["session"])) == legacy.name and marker["executableSHA256"] == data["newAppSHA256"],
            "Archived session identity mismatch")
    source = legacy / "Nearpane Alpha P5.2"
    require(tree(source) == data["beforeSourceSHA256"] == data["afterSourceSHA256"] and
            (source / "profile.version").read_bytes() == b"Nearpane P5.2\n", "Archived fixture differs")
    return source, data["oldAppSHA256"]


def reopen_previous(previous, container, reference, expected):
    """Read the very same isolated generation with the actual previous and new binaries."""
    before = binary(previous, "com.holdsnow.nearpane.alpha")
    previous_session = prepare(before, True)
    moved = previous_session / container.name
    require(not moved.exists(), "Previous binary session is not empty")
    key = reference.stat().st_dev, reference.stat().st_ino
    container.rename(moved)
    try:
        report = run([before, "--verify-bundled-resources", "--profile-acceptance-open", previous_session.name],
                     reply=True)
        opened = Path(report["path"])
        require(opened == moved / reference.relative_to(container) and
                (opened.stat().st_dev, opened.stat().st_ino) == key, "Previous Host opened a different generation")
        require(projection(evidence(opened)) == expected and report["counts"] == {"assets": 5, "recordings": 1},
                "Previous Host changed data or could not read the two domains")
    finally:
        moved.rename(container)
    require((reference.stat().st_dev, reference.stat().st_ino) == key, "Generation changed during round trip")
    return dict(executableSHA256=sha(before.read_bytes()), session=previous_session.name, generation=report["generation"])


def verify(old, new, fixture_receipt=None, previous=None):
    after = binary(new, "com.holdsnow.nearpane.alpha")
    if fixture_receipt:
        old_root, old_hash = archived_fixture(fixture_receipt)
    else:
        before = binary(old, "com.holdsnow.nearpane.candidate.p52")
        old_root, old_hash = prepare(before, False) / "support", sha(before.read_bytes())
    legacy = old_root.parent
    fresh = prepare(after, True)
    source = fresh / "Nearpane Alpha P5.2"
    original = tree(old_root)
    shutil.copytree(old_root, source)
    require(tree(source) == original, "Synthetic copy is incomplete")
    # Add one historical, unresolved operation only to the verified copy. No transport is involved.
    q = source / "Riftlet/queue.sqlite"
    with closing(sqlite3.connect(q)) as db:
        historical = db.execute("SELECT asset_id FROM operations WHERE phase='unknown'").fetchall()
        asset = (historical[0][0] if historical else
                 db.execute("SELECT id FROM assets ORDER BY sequence LIMIT 1").fetchone()[0])
        lease = json.dumps(dict(adapterID="chatgpt-web", surface="webChat", applicationID="com.google.Chrome",
                                sessionID="synthetic", windowID="1", tabID="2", documentID="test-doc",
                                composerID="test-editor", draftGeneration="test-generation"),sort_keys=True)
        op = str(uuid.uuid4()).upper()
        with db:
            # An archived import source already contains the verified historical operation.
            if historical:
                require(len(historical) == 1 and db.execute("SELECT count(*) FROM operations").fetchone() == (1,),
                        "Unexpected archived operation history")
            else:
                db.execute("""INSERT INTO operations(id,asset_id,attempt,target_key,target_json,phase,created_at,updated_at,reason)
                              VALUES(?,?,1,?,?,'unknown',1,1,'isolated fixture')""", (op, asset, lease, lease))
                db.execute("UPDATE assets SET status='unknown',active_operation_id=? WHERE id=?", (op, asset))
    # Preserve the user's settings for an offline display without assigning them to a different UUID.
    config_path = source / "Nearpane/host-configuration.json"
    config = json.loads(config_path.read_bytes())
    offline_display = str(uuid.uuid4()).upper()
    config["preferredDisplayID"] = offline_display
    config["displays"] = {offline_display: {"placement":"floating", "measures":[
        "panelWidth", {"value":20, "unit":"pt"}, "panelHeight", {"value":20, "unit":"pt"}]}}
    config_path.write_text(json.dumps(config))
    fingerprint = tree(source)
    baseline = evidence(source)
    require(baseline["tray"]["phases"] == ["unknown"] and len(baseline["tray"]["order"]) == 5
            and baseline["voice"]["revisions"]["count"] > 0, "Incorrect synthetic input")

    container = fresh / "Nearpane Alpha Profiles"
    entry = [after, "--verify-bundled-resources", "--profile-acceptance-open", fresh.name]
    helper = new / "Contents/Helpers/NearpaneAutomation"
    require(helper.is_file(), "Candidate lacks its packaged runtime")
    runtime_check = run([after, "--check-helper-runtime"], standalone=True).strip()
    def migrate(action, *options):
        value = run([helper, "profile", action, "--container", container, *options], reply=True, standalone=True)
        require(value["ok"], "Profile operation failed")
        return value
    def active():
        identifier = json.loads((container / "profile-index.json").read_bytes())["active"]
        return container / "generations" / str(uuid.UUID(identifier))
    first = run(entry, reply=True, standalone=True)
    empty = evidence(active())
    require(empty["voice"]["recordings"]["count"] == 0 and not empty["tray"]["order"], "New profile already contains data")
    options = ("--source", source, "--sections", "voice,tray,settings")
    plan = migrate("preview", *options)
    result = migrate("import", *options, "--token", plan["token"])
    imported_path = active()
    imported = evidence(imported_path)
    stored = json.loads((imported_path/"Nearpane/host-configuration.json").read_bytes())
    require(stored["preferredDisplayID"] == offline_display and set(stored["displays"]) == {offline_display},
            "Settings were reassigned to another display")
    measures = stored["displays"][offline_display]["measures"]
    pairs = dict(zip(measures[::2], measures[1::2]))
    require(all(pairs[metric] == {"value":20,"unit":"pt"} for metric in ("panelWidth", "panelHeight")),
            "Icon size settings changed")
    require(projection(imported) == projection(baseline), "Imported data or history differs")
    require((imported_path/"Riftlet/imported-attachment-holds"/asset.lower()).is_file(), "Imported operation can be replayed")
    again = migrate("import", *options, "--token", plan["token"])
    require(again.get("duplicate") and active() == imported_path, "Duplicate import switched profiles")
    fallback = reopen_previous(previous, container, imported_path, projection(baseline)) if previous else None
    reopened = run(entry, reply=True, standalone=True)
    require(Path(reopened["path"]) == imported_path, "Re-upgrade selected another generation")
    require(projection(evidence(imported_path)) == projection(baseline), "Reopening the Alpha changed imported records")
    rollback = migrate("rollback", "--token", migrate("status")["rollbackToken"])
    restored = run(entry, reply=True, standalone=True)
    require(projection(evidence(active())) == projection(empty), "Rollback failed to restore the previous profile")
    require(projection(evidence(imported_path)) == projection(baseline), "Rollback lost the imported generation")
    require(tree(source) == fingerprint and tree(old_root) == original, "Source changed")
    management = run([helper, "workrect", active()], reply=True, standalone=True, stdin="quit\n")
    require(management["mode"] == "off" and not management["blocked"] and not management["members"]
            and not management["windows"] and not list((active() / "WorkRect").rglob("action-*.json")),
            "Empty profile unexpectedly managed a window")
    receipt = dict(oldAppSHA256=old_hash, newAppSHA256=sha(after.read_bytes()), previousUnifiedHost=fallback,
                   runtimeCheck=runtime_check, developerToolsDenied=True, workrect=management,
                   oldSession=legacy.name, newSession=fresh.name, beforeSourceSHA256=fingerprint,
                   afterSourceSHA256=tree(source), oldOriginalSHA256=original, preservedOfflineDisplay=offline_display,
                   originalFixtureIntact=tree(old_root)==original, old=baseline, imported=imported, empty=empty,
                   duplicate=again.get("duplicate"), initialHost=first, reopenedHost=reopened, rollbackHost=restored,
                   importedGeneration=result["active"], restoredGeneration=rollback["active"])
    out = ROOT/"build/verification/p53"/fresh.name
    out.mkdir(mode=0o700, parents=True)
    (out/"packaged-upgrade.json").write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print(out/"packaged-upgrade.json")


def verify_settings(old, new, fixture_receipt=None):
    new_exe = binary(new, "com.holdsnow.nearpane.alpha")
    require(subprocess.run(["pgrep", "-x", "NearpaneHost"], stdout=subprocess.DEVNULL).returncode == 1,
            "Other Nearpane process is running or process inventory unavailable")
    if fixture_receipt:
        legacy_source, _ = archived_fixture(fixture_receipt)
    else:
        legacy_source = prepare(binary(old, "com.holdsnow.nearpane.candidate.p52"), False) / "support"
    fresh = prepare(new_exe, True)
    source = fresh / "Nearpane Alpha P5.2"
    shutil.copytree(legacy_source, source)
    before = tree(source)
    require(before == tree(legacy_source), "Synthetic Settings source is incomplete")
    run_id = str(uuid.uuid4())
    out = ROOT/"build/verification/p53"/fresh.name
    out.mkdir(parents=True, mode=0o700)
    controls = out/"settings-controls"
    subprocess.run(["/usr/bin/xcrun", "swiftc", ROOT/"scripts/acceptance/admission-controls.swift",
                    "-module-cache-path", out/"module-cache", "-o", controls], check=True)
    env = dict(os.environ, NEARPANE_PROFILE_ACCEPTANCE=fresh.name, NEARPANE_ACCEPTANCE_RUN=run_id)
    def wait(sample, timeout=12):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            require(child.poll() is None, "Settings process exited")
            result = sample()
            if result:
                return result
            time.sleep(.15)
        raise ValueError("Settings checkpoint timed out")
    records = []
    with (out/"settings.log").open("xb") as log:
        policy = SANDBOX[:-1] + [SANDBOX[-1] + NO_EXTERNAL_RUNTIME]
        child = subprocess.Popen(policy + [str(new_exe), "--native-acceptance-secondary", fresh.name],
                                 cwd=ROOT, env=env, stdout=log, stderr=log)
        try:
            file = wait(lambda: next(fresh.glob("profile-settings-*.json"), None))
            window = json.loads(file.read_bytes())
            require(window["pid"] == child.pid, "Unexpected panel owner")
            actions = [controls, child.pid, window["windowNumber"], new_exe]
            def button(name):
                def enabled():
                    row = json.loads(run(actions + ["read"]))
                    require(row["frontPID"] == window["frontPID"] and row["frontPID"] != child.pid,
                            "Unexpected foreground change")
                    matches = [n for n in row["nodes"] if n["id"] == name and n["enabled"]]
                    return row if len(matches) == 1 else None
                observed = wait(enabled, 18)
                records.append({"button":name,"visibleButtons":observed["nodes"],"front":observed["frontPID"],
                                "frame":observed["bounds"]})
                require(observed["bounds"] == records[0]["frame"], "Settings resized while showing the result")
                records[-1]["pressResult"] = run(actions + [name]).strip() or "AX success"
            button("np.profile.preview")
            button("np.profile.import")
            button("np.profile.quit")
            require(child.wait(timeout=12) == 0, "Settings did not exit cleanly")
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=8)
            (out/"settings-checkpoints.json").write_text(json.dumps(records, indent=2))
    host = run([new_exe, "--verify-bundled-resources", "--profile-acceptance-open", fresh.name], reply=True)
    active = fresh/"Nearpane Alpha Profiles"/"generations"/str(uuid.UUID(host["generation"]))
    require(len(evidence(active)["tray"]["order"]) == 5 and tree(source) == before,
            "Settings confirmation did not switch to the expected generation")
    receipt = dict(session=fresh.name, window=window, checkpoints=records, sourceBefore=before,
                   sourceAfter=tree(source), host=host, exitCode=child.returncode)
    (out/"settings.json").write_text(json.dumps(receipt, indent=2)+"\n")
    print(out/"settings.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old", type=Path, default=Path.home()/"Applications/Nearpane P5.2/Nearpane P5.2 Alpha.app")
    parser.add_argument("--new", type=Path, default=Path.home()/"Applications/Nearpane.app")
    parser.add_argument("--fixture-receipt", type=Path, help="Use a verified legacy synthetic fixture after retiring its app")
    parser.add_argument("--previous-unified", type=Path, help="Also verify downgrade and re-upgrade on the same generation")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--settings", action="store_true", help="Press the real Settings controls in the marked secondary panel")
    mode.add_argument("--read-errors", action="store_true", help="Check the installed Host's profile refusal reasons without GUI")
    args = parser.parse_args()
    os.umask(0o077)
    if args.read_errors:
        verify_read_errors(args.new.resolve(strict=True))
    elif args.settings:
        verify_settings(args.old, args.new.resolve(strict=True), args.fixture_receipt)
    else:
        verify(args.old, args.new.resolve(strict=True), args.fixture_receipt, args.previous_unified)
