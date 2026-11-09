"""Local, content-free receipts for the supervised disposable acceptance process."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import sqlite3
import subprocess
import sys
import time
import uuid
from contextlib import closing
import voice_evidence

SCENES = ("idle","button","edit","hide","restore")
SEALED_SCRIPTS = ("scripts/native-acceptance.py", "scripts/acceptance/draft-observation.js",
                  "scripts/acceptance/capture-panel.swift", "scripts/acceptance/observe-draft.swift",
                  "scripts/acceptance/session_evidence.py", "scripts/acceptance/voice_evidence.py",
                  "scripts/acceptance/residence.py", "Resources/AcceptanceTargetGuard.js",
                  "Sources/NearpaneTray/AcceptanceBrowserRoute.swift")


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fingerprint(obj):
    return digest(json.dumps(obj,sort_keys=True,separators=(",",":")).encode())


def put(file,obj):
    with file.open("x") as stream:
        json.dump(obj,stream,sort_keys=True)
        stream.write("\n")


def code_subject(exe):
    exe = Path(exe).resolve(strict=True)
    info = subprocess.run(["/usr/bin/codesign","-d","-r-","--verbose=4",str(exe)],capture_output=True,text=True,check=True)
    lines = (info.stdout+"\n"+info.stderr).splitlines()
    fields = dict(l.split("=",1) for l in lines if l.startswith(("Identifier=","TeamIdentifier=","CDHash=")))
    require(fields.get("CDHash") and fields.get("Identifier"), "Missing executable code identity")
    requirement = next((l.strip() for l in lines if "designated =>" in l),None)
    bundle = next((p for p in exe.parents if p.suffix == ".app"),None)
    plist = plistlib.loads((bundle/"Contents/Info.plist").read_bytes()) if bundle else {}
    sha = digest(exe.read_bytes())
    os_build = subprocess.check_output(["/usr/bin/sw_vers","-buildVersion"],text=True).strip()
    version = plist.get("CFBundleShortVersionString")
    source = "bundle"
    if not version:
        if exe.name in ("capture-panel","observe-draft"):
            version,source = "schema-2+"+sha[:12],"compiled acceptance helper"
        elif exe == Path(sys.executable).resolve():
            version,source = platform.python_version(),"Python interpreter"
        else:
            version,source = os_build,"host OS build; executable separately identified by CDHash"
    return dict(code=fields, requirement=requirement, sha256=sha, version=version, versionSource=source,
                osBuild=os_build, build=plist.get("CFBundleVersion"), bundleID=plist.get("CFBundleIdentifier"))



def process_path(pid):
    import ctypes
    buffer = ctypes.create_string_buffer(4096)
    size = ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(int(pid),buffer,len(buffer))
    require(size > 0, "Process identity unavailable")
    return Path(os.fsdecode(buffer.value))


def observe_launcher():
    # Only ancestors of this launcher. Never enumerate or inspect users' other apps/windows.
    import ctypes
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    pid = os.getppid()
    for _ in range(12):
        if pid <= 1: break
        # PROC_PIDTBSDINFO: verify pbi_pid before following pbi_ppid. The sandbox may hide an ancestor.
        info = (ctypes.c_uint32 * 128)()
        size = libproc.proc_pidinfo(pid,3,ctypes.c_uint64(0),ctypes.byref(info),ctypes.sizeof(info))
        if size < 20 or info[3] != pid: return None
        try: exe = process_path(pid)
        except ValueError: return None
        if any(p.suffix == ".app" for p in exe.parents):
            return code_subject(exe)
        pid = info[4]
    return None


def resources_hash(binary):
    resources = binary.parents[1]/"Resources"
    inventory = {p.relative_to(resources).as_posix():digest(p.read_bytes()) for p in sorted(resources.rglob("*"))
                 if p.is_file() and p.name != ".DS_Store"}
    require(all(resources in p.resolve().parents for p in resources.rglob("*") if p.is_file()), "Unexpected resource link")
    return fingerprint(inventory)


def desktop_reader(binary):
    contents = binary.parents[1]
    helper = contents/"Helpers/NearpaneDesktopReader"
    expected = plistlib.loads((contents/"Info.plist").read_bytes()).get("NearpaneDesktopReaderSHA256")
    if expected is None and not helper.exists() and not helper.is_symlink():
        return None
    require(helper.resolve(strict=True) == helper and digest(helper.read_bytes()) == expected, "Desktop reader seal mismatch")
    return helper


def manifest(root,path,binary):
    subjects = dict(host=code_subject(binary),panelHelper=code_subject(path/"capture-panel"),
                    browserObserver=code_subject(path/"observe-draft"),systemScreenshot=code_subject("/usr/sbin/screencapture"),
                    launcher=code_subject(sys.executable),responsibleAncestor=observe_launcher())
    reader = desktop_reader(binary)
    if reader is not None:
        subjects["desktopReader"] = code_subject(reader)
    return dict(schema=3,session=path.name,appSHA256=subjects["host"]["sha256"],resourcesSHA256=resources_hash(binary),
                checkoutAtPreparation=subprocess.check_output(["git","rev-parse","HEAD"],cwd=root,text=True).strip(),
                infoPlistSHA256=digest((binary.parents[1]/"Info.plist").read_bytes()),
                domainLockSHA256=digest((root/"Dependencies/domains.lock.json").read_bytes()),scripts={s:digest((root/s).read_bytes()) for s in SEALED_SCRIPTS},
                subjects=subjects, observerLanguage="PID-addressed Apple Events + JavaScript", tcc="not queried; responsible process determined by macOS")


def verify_manifest(root,path,binary,seal):
    require(seal.get("schema") == 3 and seal.get("session") == path.name, "New frozen session required")
    require(digest(binary.read_bytes()) == seal["appSHA256"], "Test executable changed")
    require(digest((binary.parents[1]/"Info.plist").read_bytes()) == seal["infoPlistSHA256"], "Package metadata changed")
    reader = desktop_reader(binary)
    reader_sha = seal["subjects"].get("desktopReader", {}).get("sha256")
    require((digest(reader.read_bytes()) if reader else None) == reader_sha, "Sealed desktop reader changed")
    require(resources_hash(binary) == seal["resourcesSHA256"], "Test resources changed")
    require(digest((root/"Dependencies/domains.lock.json").read_bytes()) == seal["domainLockSHA256"], "Domain lock changed")
    require(set(seal["scripts"]) == set(SEALED_SCRIPTS), "Incomplete script inventory")
    for name in SEALED_SCRIPTS:
        require(digest((root/name).read_bytes()) == seal["scripts"][name], "Acceptance script changed: "+name)
    for name,key in (("capture-panel","panelHelper"),("observe-draft","browserObserver")):
        require(digest((path/name).read_bytes()) == seal["subjects"][key]["sha256"], "Acceptance helper changed: "+name)


def durable(path):
    library = path/"support/Riftlet"
    file = library/"queue.sqlite"
    require(file.resolve() == file, "Unexpected library path")
    with closing(sqlite3.connect(file.as_uri()+"?mode=ro",uri=True)) as db:
        db.execute("begin")
        assets = db.execute("select id,image_json,status,visibility,visibility_revision from assets order by sort_at,sequence").fetchall()
        ops = db.execute("select id,asset_id,attempt,target_key,phase,receipt_json from operations order by sequence").fetchall()
        starts = db.execute("select operation_id,receipt_json from upload_starts order by operation_id").fetchall()
        calls = db.execute("select key,value from checkpoints where key like 'transfer-dispatch-call-v1:%' order by key").fetchall()
    media = []
    for _,raw,*_rest in assets:
        img = json.loads(raw)
        f = library/"media"/img["fileName"]
        require(f.parent == library/"media" and f.resolve() == f, "Invalid fixture media")
        media.append(f.is_file() and digest(f.read_bytes()) == img["sha256"])
    voice_file = path/"support/Nearpane/Voice/Saytile.sqlite"
    voice = voice_evidence.snapshot(path) if voice_file.exists() else None
    claim = path/"input-claim.json"
    return dict(voiceSHA256=fingerprint(voice),voiceAvailable=voice is not None,
                voiceRecords=len(voice["records"]) if voice else 0, voiceRevisions=len(voice["revisions"]) if voice else 0,
                intactMedia=all(media),
                assetOrder=[r[0] for r in assets],assetSHA256=fingerprint([assets,media]),
                operationsSHA256=fingerprint(ops),unresolved=[r[0] for r in ops if r[4] not in ("failed","succeeded")],
                attempts=len(calls),dispatchSHA256=fingerprint(calls),starts=len(starts),startSHA256=fingerprint(starts),
                inputClaim=digest(claim.read_bytes()) if claim.is_file() else None)


def events(file):
    # Ignore an incomplete trailing record while its writer is running.
    raw = file.read_bytes() if file.exists() else b""
    return [json.loads(row) for row in raw.split(b"\n")[:-1] if row]


def current_point(path):
    start = time.time()
    deadline = time.monotonic()+10
    while time.monotonic() < deadline:
        file = max(path.glob("events-*.jsonl"),key=lambda p:p.stat().st_mtime,default=None)
        series = events(file) if file else []
        if series and series[-1]["time"] >= start and series[-1]["kind"] != "drained":
            return dict(session=path.name,run=file.stem,time=series[-1]["time"],state=series[-1]["state"])
        time.sleep(.1)
    raise ValueError("No fresh in-session heartbeat")


def focus_verdict(scene, bounds, stream, idle_seconds):
    if not bounds: return "PENDING"
    start,end = bounds
    if start["run"] != end["run"] or start["time"] >= end["time"]: return "INCONCLUSIVE"
    rows = [e for e in stream if start["time"] <= e["time"] <= end["time"]]
    if len(rows)<2 or rows[0]["time"] != start["time"] or rows[-1]["time"] != end["time"]: return "INCONCLUSIVE"
    first,last = rows[0]["state"],rows[-1]["state"]
    if first != start["state"] or last != end["state"] or not first["foreground"]: return "INCONCLUSIVE"
    if any(not 0 <= b["uptime"]-a["uptime"] <= 10 for a,b in zip(rows,rows[1:])): return "INCONCLUSIVE"
    if len({e["state"]["pid"] for e in rows}) != 1: return "INCONCLUSIVE"
    editing = acted = False
    for e in rows:
        s = e["state"]
        if e["kind"] == "editorClick": editing = True
        if scene == "edit":
            if s["foreground"] not in (first["foreground"],s["pid"]): return "FAIL"
            if (s["key"] or s["active"] or e["kind"] in ("panelBecameKey","appActivated")) and not editing: return "FAIL"
            acted |= editing and e["kind"] == "userEdit" and s["editorFocused"]
        else:
            if s["key"] or s["active"] or s["foreground"] != first["foreground"] or e["kind"] in ("appActivated","panelBecameKey"): return "FAIL"
            if scene == "button" and e["kind"] in ("trayButton","userStart","userPause"): acted = True
    if scene == "edit" and acted and (last["key"] or last["active"] or last["editorFocused"] or last["foreground"] != first["foreground"]):
        return "FAIL"
    if scene == "edit" or scene == "button": ok = first["visible"] and last["visible"] and acted
    elif scene == "hide": ok = first["visible"] and not last["visible"]
    elif scene == "restore": ok = not first["visible"] and last["visible"]
    else:
        ok = all(e["state"]["visible"] and e["state"]["layoutMatches"] and e["kind"] not in
                 ("panelClick","editorClick","userEdit","trayButton","userStart","userPause") for e in rows)
        ok = ok and rows[-1]["uptime"]-rows[0]["uptime"] >= idle_seconds
    return "PASS" if ok else "INCONCLUSIVE"


def supervise(path,command,cwd):
    import fcntl
    # The supervisor holds the admission lock through waitpid and post-exit data collection.
    with (path/"supervisor.lock").open("a") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        run = str(uuid.uuid4())
        before = durable(path)
        started = time.time()
        child = subprocess.Popen(command,cwd=cwd,env=dict(os.environ,NEARPANE_ACCEPTANCE_RUN=run))
        stamp = dict(session=path.name,run="events-"+run,pid=child.pid,started=started,prelaunch=before)
        evidence = path/("process-"+run+".json")
        log = path/("events-"+run+".jsonl")
        try:
            while child.poll() is None:
                series = events(log)
                if series and series[0]["kind"] == "opened" and series[0]["state"]["pid"] == child.pid:
                    stamp["openedAt"] = time.time()
                    stamp["startup"] = durable(path)
                    put(path/("startup-"+run+".json"),stamp)
                    break
                time.sleep(.1)
        finally:
            status = child.wait()
            stamp.update(exitCode=status,exited=time.time(),postExit=durable(path))
            put(evidence,stamp)
        require(status == 0, "Test app exited abnormally")


def restart_verdict(path, streams):
    runs = sorted((json.loads(p.read_text()) for p in path.glob("startup-*.json")),key=lambda v:v["started"])
    exits = [json.loads(p.read_text()) for p in path.glob("process-*.json")]
    if any(e["exitCode"] != 0 for e in exits): return "FAIL"
    if any(not e.get("startup") for e in exits): return "INCONCLUSIVE"
    if len(runs) < 2: return "PENDING"
    statuses = []
    for old,new in zip(runs,runs[1:]):
        exit_file = path/(old["run"].replace("events-","process-")+".json")
        end_file = path/("before-exit-"+old["run"]+".json")
        if not exit_file.is_file() or not end_file.is_file(): statuses.append("INCONCLUSIVE"); continue
        exit_info,checkpoint = json.loads(exit_file.read_text()),json.loads(end_file.read_text())
        a,b = streams.get(old["run"],[]),streams.get(new["run"],[])
        if not a or not b: statuses.append("INCONCLUSIVE"); continue
        initial = b[0]["state"]
        ok = (all(v["session"] == path.name for v in (old,new,exit_info,checkpoint)) and old["run"] == checkpoint["run"] == exit_info["run"]
              and old["pid"] == exit_info["pid"] == checkpoint["state"]["pid"] and all(e["state"]["pid"] == old["pid"] for e in a)
              and all(e["state"]["pid"] == new["pid"] for e in b) and old["run"] != new["run"]
              and a[0]["kind"]=="opened" and a[-1]["kind"]=="drained" and b[0]["kind"]=="opened" and exit_info["exitCode"]==0
              and old["started"] <= a[0]["time"] <= checkpoint["time"] <= a[-1]["time"] <= exit_info["exited"] <= new["started"] <= b[0]["time"] <= new["openedAt"]
              and checkpoint["durable"] == exit_info["postExit"] == new["prelaunch"] == new["startup"]
              and new["startup"]["intactMedia"] and initial["voice"]=="paused" and not initial["trayConnected"]
              and not initial["mayAttach"] and not initial["collecting"]
              and all(initial.get(k) is not None and initial[k] == checkpoint["state"].get(k) for k in ("micAuthorization","speechAuthorization")))
        statuses.append(restart_coverage(new["startup"]) if ok else "FAIL")
    return "FAIL" if "FAIL" in statuses else "INCONCLUSIVE" if "INCONCLUSIVE" in statuses else "PASS"


def restart_coverage(state):
    if state["attempts"] > 1 or state["starts"] > 1:
        return "FAIL"
    challenged = (state["voiceRecords"] > 0 and state["voiceRevisions"] > 0 and len(state["assetOrder"]) == 1
                  and state["attempts"] == state["starts"] == 1 and state["inputClaim"])
    return "PASS" if challenged else "INCONCLUSIVE"
