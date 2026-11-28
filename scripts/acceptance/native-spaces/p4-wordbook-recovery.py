#!/usr/bin/env python3
"""Recover one disclosed existing word with two separately launched signed Hosts on the same disposable generation."""
import argparse
import datetime
import fcntl
import hashlib
import importlib
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import time
import uuid

from installed_profile import APP, PROFILE, installed_pid, launch_isolated, owns_profile, quit_host

route = importlib.import_module("installed-route")
require = route.require
NOTE = "sidebar-notebook.json"
SOURCE, ANSWER = "bicycle", "自行车"
PROVIDER = "seeded existing entry / Dictionary Services"


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def plain(path, maximum=32768):
    require(path.is_absolute() and path == path.resolve(strict=True), "Unexpected symlink in fixture data")
    with os.fdopen(os.open(path, os.O_NOFOLLOW | os.O_RDONLY), "rb") as f:
        st = os.fstat(f.fileno())
        require(stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid() and st.st_nlink == 1 and 0 < st.st_size <= maximum,
                "Invalid fixture file identity or size")
        return f.read(maximum + 1)


def frozen_seed(kit):
    require(kit.parent == Path("/private/tmp") and kit.name.startswith("nearpane-p4-wordbook.") and
            kit == kit.resolve(strict=True) and kit.stat().st_uid == os.getuid() and not kit.stat().st_mode & 0o077,
            "Expected the privately built wordbook kit")
    seed = json.loads(plain(kit / "seed.json"))
    data = plain(kit / "seed-notebook.json")
    row = json.loads(data)
    legacy_empty = (row.keys() == {"words", "tasks", "calculation", "memo"} and
                    row["tasks"] == [] and row["calculation"] == row["memo"] == "")
    unified_empty = (row.keys() in ({"schemaVersion", "records", "calculation", "words"},
                                   {"schemaVersion", "records", "activeRecordID", "calculation", "words"}) and
                     row["schemaVersion"] == 2 and row["records"] == [] and
                     row.get("activeRecordID") is None and row["calculation"] == "")
    require((legacy_empty or unified_empty) and isinstance(row["words"], list) and len(row["words"]) == 1,
            "Notebook fixture must contain only the disclosed word")
    word = row["words"][0]
    require(set(word) == {"id","source","translation","language","sourceLanguage","providerVersion","committedAt","requestID","sourceSHA256"}
            and (seed["kind"],seed["serialization"],seed["serviceRequests"],seed["translationSessionRequests"]) ==
            ("seeded existing entry","SidebarNotebook.commit",0,0) and
            seed["source"] == word["source"] == SOURCE and seed["answer"] == word["translation"] == ANSWER and
            seed["providerVersion"] == word["providerVersion"] == PROVIDER and
            seed["sourceSHA256"] == word["sourceSHA256"] == digest(SOURCE.encode()) and
            seed["answerSHA256"] == digest(ANSWER.encode()) and seed["fileSHA256"] == digest(data)
            and word["language"] == "zh-Hans" and word["sourceLanguage"] == "en" and
            type(word["committedAt"]) in (float,int) and math.isfinite(word["committedAt"]) and word["committedAt"] > 0 and
            str(uuid.UUID(seed["requestID"])).upper() == word["requestID"] == seed["requestID"] and
            str(uuid.UUID(seed["wordID"])).upper() == word["id"] == seed["wordID"] and seed["requestID"] != seed["wordID"],
            "Fixture word, original ID or digest changed")
    return seed, data


def generation(root, active):
    require(active.parent == root / "generations" and str(uuid.UUID(active.name)) == active.name and
            active == active.resolve(strict=True), "Wrong disposable generation")
    index = json.loads(plain(root / "profile-index.json"))
    require(index.get("format") == 1 and index.get("active") == active.name and index.get("previous") is None and
            not os.path.lexists(root / "transaction.json"), "Only a new, stable disposable generation can be seeded")
    support = active / "Nearpane"
    require(plain(active / "profile.version") == b"Nearpane P5.3\n", "Unknown disposable generation marker")
    for path in (root, root / "generations", active, support):
        node = path.stat()
        require(path == path.resolve(strict=True) and stat.S_ISDIR(node.st_mode) and node.st_uid == os.getuid()
                and not node.st_mode & 0o022, "Unsafe disposable profile directory")
    return support


def seed_unused(root, active, data):
    """Use the production writer lock and an exclusive link, so an existing notebook can never be replaced."""
    lock = root / "writer.lock"
    with os.fdopen(os.open(lock, os.O_RDWR | os.O_NOFOLLOW), "r+b") as lease:
        st = os.fstat(lease.fileno())
        require(stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid() and st.st_nlink == 1, "Invalid generation writer lock")
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        support = generation(root, active)
        directory = os.open(support, os.O_DIRECTORY | os.O_NOFOLLOW)
        temp = ".wordbook-fixture-" + uuid.uuid4().hex
        created = False
        try:
            fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_WRONLY, 0o600, dir_fd=directory)
            created = True
            with os.fdopen(fd, "wb") as out:
                out.write(data)
                out.flush()
                os.fsync(out.fileno())
            os.link(temp, NOTE, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
            os.fsync(directory)
        finally:
            try:
                if created:
                    os.unlink(temp, dir_fd=directory)
            finally:
                os.close(directory)
        require(plain(support / NOTE) == data, "Seeded fixture did not read back")


def current(root, signed, expected=None):
    s = route.system_snapshot(APP)
    require(s["pidSourcesAgree"] and len(s["processes"]) == 1, "Sole signed Host PID unavailable")
    p = s["processes"][0]
    require(p.get("verified") is True and p.get("identifierMatches") is True and p.get("kernelExecutableMatches") is True
            and p.get("location") == "selected" and p.get("cdhash") == signed["cdhash"] and p.get("team") == signed["team"]
            and type(p.get("birth")) is int and p["birth"] > 0 and p["pid"] == installed_pid() and owns_profile(p["pid"], root)
            and not owns_profile(p["pid"], Path.home()/PROFILE), "Exact signed Host does not hold only the enrolled profile")
    if expected:
        require(p == expected, "Enrolled Host generation changed")
    return p


def reopen_stages(p, seed, launched):
    ident = seed["requestID"]
    prefix = "toolStage id=" + ident + " "
    predicate = (f'processID == {p["pid"]} AND subsystem == "com.holdsnow.nearpane.alpha" AND category == "LocalToolStage" '
                 f'AND eventMessage BEGINSWITH "{prefix}"')
    start = datetime.datetime.fromtimestamp(p["birth"]/1e6 - 1).strftime("%Y-%m-%d %H:%M:%S")
    command = ["/usr/bin/log","show","--info","--style","ndjson","--start",start,"--predicate",predicate]
    raw = subprocess.check_output(command, text=True, timeout=16)
    return qualified_reopen(raw, p["pid"], seed, launched, time.monotonic())


def qualified_reopen(raw, pid, seed, launched, ended):
    ident = seed["requestID"]
    prefix = "toolStage id=" + ident + " "
    rows = []
    for line in raw.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        match = re.fullmatch(re.escape(prefix) + r"stage=(\w+) hash=(-|[a-f0-9]{64}) uptime=([0-9.]+)", record.get("eventMessage",""))
        if match and int(record.get("processID",-1)) == pid and launched <= float(match[3]) <= ended:
            rows.append({"kind":match[1], "digest":match[2], "uptime":float(match[3])})
    return {"status": "PASS" if rows and all(r["kind"] == "wordReopened" and r["digest"] == seed["answerSHA256"] for r in rows)
            else "UNKNOWN", "requestID":ident, "stages":rows}


def write_result(out, result):
    temp = out / "result.next"
    temp.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    os.replace(temp, out / "result.json")


def run(kit, out, revision):
    os.umask(0o077)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    result = {"status":"BLOCKED", "purpose":"seeded existing entry persistence", "serviceRequests":0,
              "newTranslation":"NOT_RUN", "hostReads":[], "seedStatus":"NOT_RUN", "outerProfileRestored":"NOT_RUN"}
    write_result(out,result)
    stopped = False
    try:
        home, active = (Path(os.environ[k]) for k in ("NEARPANE_TEST_HOME","NEARPANE_TEST_GENERATION"))
        root = route.private_home(home)
        note = generation(root, active) / NOTE
        require(not os.path.lexists(note), "Existing notebook was left untouched")
        signed = route.bundle_identity(APP, revision)
        require(signed["sourceMatches"] and signed["p4RequestBoundPanelPackaged"], "Installed candidate lacks the enrolled revision or P4 binding")
        seed, data = frozen_seed(kit)
        view = kit / "p4-wordbook-view"
        require(view == view.resolve(strict=True), "Unsafe Settings reader path")
        subprocess.run(["/usr/bin/codesign","--verify","--strict",view], check=True, timeout=8, capture_output=True)
        def counters():
            values = json.loads(subprocess.check_output([view,"--read-input"],text=True,timeout=4))
            require(isinstance(values, list) and len(values) == 10 and
                    all(type(value) is int and 0 <= value <= 0xffffffff for value in values), "Hardware input counters unavailable")
            return values
        initial_input = counters()
        def quiet():
            require(counters() == initial_input, "Physical input changed; preserve the user's latest intent")
        original = current(root,signed)
        result.update(installed=signed,originalHost=original,scope=active.name,seed=seed,scopeKind="outer-created disposable generation")
        quiet()
        require(not os.path.lexists(note), "A notebook was created concurrently")
        current(root,signed,original)
        stopped = True
        quit_host(original["pid"])
        seed_unused(root,active,data)
        result["seedStatus"] = "SEEDED_EXISTING_ENTRY"
        write_result(out,result)
        prior = original
        for ordinal in (1,2):
            quiet()
            launched = time.monotonic()
            pid, actual = launch_isolated(home)
            require(actual == active, "Launch Services selected a different generation")
            proc = current(root,signed)
            require(proc["pid"] == pid and proc["birth"] > prior["birth"], "Normal relaunch did not produce a new signed process")
            quiet()
            item = {"ordinal":ordinal,"host":proc,"launchIntentUptime":launched,"diskBefore":digest(plain(note)),
                    "scope":active.name,"wordID":seed["wordID"],"requestID":seed["requestID"]}
            result["hostReads"].append(item)
            write_result(out,result)
            require(item["diskBefore"] == seed["fileSHA256"], "Saved word changed before Settings was opened")
            # Capture the actual signed Host's launch read even when the visible Settings route is unavailable.
            item["hostDiskReopen"] = reopen_stages(proc,seed,launched)
            item["settings"] = json.loads(subprocess.check_output([view,str(pid),str(out)], text=True, timeout=70))
            if item["hostDiskReopen"]["status"] != "PASS":
                item["hostDiskReopen"] = reopen_stages(proc,seed,launched)
            current(root,signed,proc)
            require(generation(root,active) / NOTE == note, "Disposable generation changed")
            item["diskAfter"] = digest(plain(note))
            require(item["diskAfter"] == seed["fileSHA256"], "Seeded row was modified")
            item["status"] = "PASS" if item["hostDiskReopen"]["status"] == item["settings"].get("status") == "PASS" else "UNKNOWN"
            write_result(out,result)
            if ordinal == 1:
                quiet()
                quit_host(pid)
                prior = proc
        result["status"] = "PASS" if all(read["status"] == "PASS" for read in result["hostReads"]) else "UNKNOWN"
    except (ValueError, OSError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        result.update(status="UNKNOWN" if result["seedStatus"] != "NOT_RUN" else "BLOCKED",reason=str(error)[:220])
    finally:
        if stopped:
            try:
                if installed_pid() is None:
                    _, actual = launch_isolated(home)
                    require(actual == active, "Restoration reopened another generation")
                current(root,signed)
                require(generation(root,active)/NOTE == note, "Outer disposable generation changed")
                result["outerProfileRestored"] = "PASS"
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                result.update(status="UNKNOWN", outerProfileRestored="UNKNOWN", restoreReason=str(error)[:160])
        write_result(out,result)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kit",type=Path)
    parser.add_argument("output",type=Path)
    parser.add_argument("--expected-source",required=True)
    args = parser.parse_args()
    raise SystemExit(0 if run(args.kit,args.output,args.expected_source)["status"] == "PASS" else 2)
