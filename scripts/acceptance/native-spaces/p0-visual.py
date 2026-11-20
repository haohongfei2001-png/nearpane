"""Observe a single real card press with display-based fixture video and an optional isolated physical crop.

The installed P0 runner calls enroll during both initial round-trip starts, then start and finish
for each ten-stage press. No screen capture is requested when permission is absent. All control
paths are under a private attempt directory; the native Recorder owns a 25-second maximum.
"""
import argparse
import collections
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import uuid


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CHILDREN = {}
ERRORS = (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError)
POLICY = "Observed absence of a user-visible whole-display blackout during this interval; changes below measured sampling resolution are outside the evidence."
SOURCES = ["https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:including:)",
           "https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/displaytime"]


def require(ok, message):
    if not ok:
        raise ValueError(message)


def write(path, value):
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as temp:
        json.dump(value, temp, ensure_ascii=False, sort_keys=True, indent=2)
        temp.write("\n")
        temp.flush()
        os.fsync(temp.fileno())
    os.replace(temp.name, path)


def private(path, directory=False):
    path = Path(path).absolute()
    bits = path.lstat()
    require(path == path.resolve() and bits.st_uid == os.getuid(), "noncanonical or unowned path")
    require((stat.S_ISDIR(bits.st_mode) if directory else stat.S_ISREG(bits.st_mode) and bits.st_nlink == 1)
            and bits.st_mode & 0o022 == 0, "uncontrolled path")
    return path


def read(path):
    with private(path).open("rb") as f:
        data = f.read(6_000_001)
        require(len(data) <= 6_000_000, "oversize device receipt")
        return json.loads(data)


def kit_paths(kit):
    kit = private(kit, directory=True)
    require(kit.parent == Path("/private/tmp") and kit.name.startswith("nearpane-d01."), "fixture kit path mismatch")
    return kit, private(kit / "p0-card")


def binary(kit):
    source = HERE / "p0-visual.swift"
    header = HERE / "contract_members.h"
    objects = [private(kit / name) for name in ("reader.o", "members.o")]
    h = hashlib.sha256()
    for path in [source, header, *objects]:
        h.update(path.read_bytes())
    exe = kit / ("p0-visual-" + h.hexdigest()[:20])
    if not exe.exists():
        with tempfile.TemporaryDirectory(dir=kit) as tmp:
            fresh = Path(tmp)/"recorder"
            result = subprocess.run(["/usr/bin/xcrun","swiftc","-O","-parse-as-library","-Xcc","-I","-Xcc",
                str(ROOT/"Sources/CReadOnlySpaces/include"), "-import-objc-header",str(header),str(source),
                *map(str, objects),"-framework","ColorSync","-o",str(fresh)], capture_output=True, timeout=85)
            require(result.returncode == 0, "native display observer did not compile")
            fresh.chmod(0o700)
            fresh.replace(exe)
    return private(exe)


def ask(reader, mode, args=None, body=None):
    answer = subprocess.run([str(reader), mode, *map(str, args or [])],
                            input=json.dumps(body) if body is not None else None, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=4)
    require(answer.returncode == 0, "independent P0 reader refused " + mode)
    return json.loads(answer.stdout)


def witness(kit, p, at):
    _, reader = kit_paths(kit)
    topology = p["topology"]
    ids = [s["id"] for s in topology["records"]]
    require(topology["current"] != p["target"] and abs(ids.index(topology["current"]) - ids.index(p["target"])) == 1,
            "endpoints are not adjacent")
    uuid.UUID(topology["display"])
    windows = [p["sourceWindow"], p["targetWindow"]]
    known = {"org.nearpane.acceptance.LifecycleWindow": ("Lifecycle Window.app", "Lifecycle"),
             "net.example.spaces-route-witness": ("Route Notes.app", "FieldNotes"),
             "net.example.spaces-document": ("Field Notes.app", "FieldNotes")}
    require(windows[0]["number"] != windows[1]["number"], "duplicate fixture window number")
    for w in windows:
        app, file = known[w["identifier"]]
        require(w["executable"] == str(kit/app/"Contents/MacOS"/file), "fixture executable is outside this kit")
    lived = ask(reader, "windows", body=windows)["windows"]
    require(len(lived) == 2, "exact pair was not verified")
    records = []
    for w, proof, sid in zip(windows, lived, [topology["current"], p["target"]]):
        require(all(proof.get(k) == w[k] for k in ("pid", "birth", "number"))
                and proof["forward"] is True and proof["standard"] is True and proof["reverse"] == [sid],
                "fixture generation, exact AX window, or two-way Space membership changed")
        records.append({k: w[k] for k in ("pid", "birth", "number", "identifier", "hash")})
    state = ask(reader, "state")
    require(state["topology"] == dict(topology, current=at) and state["hid"] == p["hid"],
            "physical display, Space UUID order, current ID or real input changed")
    return {"current": at, "uptime": state["uptime"], "display": topology["display"], "windows": records}


def pair_id(p):
    windows = [(sid, w["pid"], w["birth"], w["number"], w["identifier"], w["hash"])
               for sid, w in [(p["topology"]["current"], p["sourceWindow"]), (p["target"], p["targetWindow"])]]
    data = {"display": p["topology"]["display"], "records": p["topology"]["records"], "windows": sorted(windows)}
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


def binding(kit, p, folder, guardian, endpoints=None):
    born = ask(kit/"p0-card", "process", [guardian])["birth"]
    b = dict(nonce=str(uuid.uuid4()).upper(), guardian=guardian, guardianBirth=born, request=p, endpoints=endpoints)
    write(folder/"binding.json", b)
    return b


def enroll(kit, attempt, request):
    try:
        kit, _ = kit_paths(kit)
        attempt = private(attempt, directory=True)
        pre = witness(kit, request, request["topology"]["current"])
        root = attempt.parent / ".p0-visual-endpoints"
        root.mkdir(mode=0o700, exist_ok=True)
        private(root, directory=True)
        with tempfile.TemporaryDirectory(dir=root) as tmp:
            folder = Path(tmp)
            b = binding(kit, request, folder, os.getpid())
            result = subprocess.run([str(binary(kit)), str(folder), "enroll"], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=9)
            if result.returncode:
                raise ValueError((read(folder/"error.json") if (folder/"error.json").exists() else {}).get("error", "endpoint calibration unavailable"))
            witness(kit, request, pre["current"])
            observed = read(folder/"endpoint.json")
            require(observed["space"] == pre["current"] and observed["display"].upper() == pre["display"].upper(), "unexpected enrollment identity")
            name = f'{pair_id(request)}-{pre["current"]}.json'
            write(root/name, observed)
            return {"status": "READY", "display": pre["display"], "space": pre["current"], "nonce": b["nonce"]}
    except ERRORS as error:
        return {"status": "UNKNOWN", "reason": str(error)}


def unknown(reason):
    return dict(status="UNKNOWN", ready=False, reason=reason, scope=POLICY, screenshotTaken=False, sources=SOURCES)


def start(kit, attempt, request, guardian=None):
    folder = None
    try:
        kit, _ = kit_paths(kit)
        attempt = private(attempt, directory=True)
        path = attempt/"visual"
        path.mkdir(mode=0o700)
        folder = path
        pre = witness(kit, request, request["topology"]["current"])
        write(folder/"before.json", pre)
        endpoints = {}
        for sid in [pre["current"], request["target"]]:
            f = attempt.parent/".p0-visual-endpoints"/f'{pair_id(request)}-{sid}.json'
            if f.is_file():
                endpoints[str(sid)] = read(f)
        b = binding(kit, request, folder, guardian or os.getpid(), endpoints)
        proc = subprocess.Popen([str(binary(kit)), str(folder)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)
        CHILDREN[str(folder)] = proc
        limit = time.monotonic() + 8
        while time.monotonic() < limit and proc.poll() is None and not (folder/"ready.json").is_file():
            time.sleep(.025)
        if (folder/"ready.json").is_file():
            ready = read(folder/"ready.json")
            require(ready["nonce"] == b["nonce"] and ready["pid"] == proc.pid and ready["ready"], "recorder handshake mismatch")
            return dict(status="READY", **ready)
        write(folder/"end.json", dict(nonce=b["nonce"], allowMovie=False, pressed=0.0, ended=0.0))
        detail = read(folder/"error.json").get("error") if (folder/"error.json").is_file() else "no genuine source frame before dispatch"
        raise ValueError(detail)
    except ERRORS as error:
        result = unknown(str(error))
        if folder is not None:
            write(folder/"receipt.json", result)
        return result


def score(data, request, pressed, ended, pre, post):
    result = unknown("The allowlisted fixture stream does not establish the visible desktop")
    result["captureFilter"] = "ScreenCaptureKit physical display, including only two exact fixture windows"
    result["wallpaperIncludedInMovie"] = False
    frames = data.get("frames", [])
    counts = collections.Counter(r.get("status", "unknown") for r in frames)
    result["allowlistedFrameCounts"] = dict(counts)
    result["filteredDarkFrames"] = sum(r.get("opaque", 0) >= 4 and r.get("dark") == r["opaque"] for r in frames)
    result["filteredEmptyFrames"] = sum(r.get("transparent", -1) == data.get("width", 0) * data.get("height", 0) for r in frames)
    result["movieSource"] = "real fixture pixels; excluded transparent areas matted gray"
    result["physicallyQualified"] = False
    if not (math.isfinite(pressed) and math.isfinite(ended) and 0 < pressed < ended and pre and post
            and pre["current"] == request["topology"]["current"] and post["current"] == request["target"]
            and data.get("postSpace") == request["target"] and pre["windows"] == post["windows"]
            and pre["uptime"] <= pressed < ended <= post["uptime"] and data.get("ready")
            and not data.get("changed") and not data.get("stoppedEarly")):
        result["reason"] = "Issued interval or independently revalidated endpoints unavailable"
        return result
    probe = data.get("physical", {})
    result["displayProbe"] = {"armed": probe.get("armed",False), "censusAfter": probe.get("censusAfter",False),
                              "cropPoints": probe.get("crop"), "privatePixelOutput": False}
    if not (probe.get("armed") and probe.get("censusAfter") and not probe.get("error")
            and probe.get("filter") == "display-excluding-other-apps"):
        result["reason"] = "Two enrolled ordinary desktops, trusted wallpaper, distinct visible source/target markers and a clean physical crop were not confirmed"
        return result
    rows = probe["frames"]
    usable = sorted((r for r in rows if isinstance(r.get("displayTime"), (float,int)) and r["displayTime"] > 0),
                    key=lambda r: r["displayTime"])
    if any(pressed <= r.get("callback", -1) <= ended and (r.get("displayTime") or 0) <= 0 for r in rows):
        result["reason"] = "A received physical frame could not be timed"
        return result
    before = [i for i,r in enumerate(usable) if r.get("to", r["displayTime"]) <= pressed and r.get("safe") and r.get("matchesSource")
              and r.get("lit") and r.get("visible") == "source" and r.get("space") == pre["current"]]
    after = [i for i,r in enumerate(usable) if r.get("from",r["displayTime"]) >= ended]
    if not before or not after:
        result["reason"] = "Missing source frame before press or displayed frame after independent observation"
        return result
    # Static marker does not need to change every refresh. Apple idle events carry the last visible frame.
    # 50 ms bounds a user-visible gap; low refresh displays get two presentation intervals.
    hz = data.get("displayModeHz",0) or data.get("refreshLimitHz",0)
    if not isinstance(hz, (float,int)) or not 24 <= hz <= 240:
        result["reason"] = "Display refresh cadence unavailable"
        return result
    window = usable[before[-1]:after[0]+1]
    limit = max(.050, 2 / hz)
    gaps = [b.get("to", b["displayTime"]) - a.get("from", a["displayTime"]) for a,b in zip(window,window[1:])]
    result["displayProbe"]["currentCropReads"] = sum(r.get("origin") == "guarded-current-display-crop" for r in window)
    result["coverage"] = {"from": window[0]["displayTime"], "to": window[-1]["displayTime"],
                          "samples": len(window), "maxGapMS": max(gaps,default=0)*1000, "permittedGapMS": limit*1000}
    if any(r.get("safe") is not True or r.get("space") not in [pre["current"],post["current"]]
           or not 0 <= r["callback"]-r["displayTime"] <= .075 for r in window):
        result["reason"] = "Foreground layer, wallpaper, process identity or frame-time binding unavailable during transition"
        return result
    result["physicallyQualified"] = True
    if any(r["status"] == 2 and pressed <= r["displayTime"] <= ended for r in window):
        result.update(status="FAIL", reason="Independently scoped physical display path reported SCFrameStatus.blank during the issued press")
        return result
    if len(gaps) < 2 or any(not 0 <= gap <= limit for gap in gaps):
        result["reason"] = "The physical stream has an unsampled interval exceeding the visible-blackout observation bound"
        return result
    lit = target = False
    for r in window:
        if r["status"] in (0,4):
            lit = r.get("lit") is True
            target = r.get("matchesTarget") is True and r["space"] == post["current"] and r.get("visible") == "target"
        elif r["status"] == 1:
            target = target and r.get("visible") == "target" and r["space"] == post["current"]
        else:
            result["reason"] = "Missing, blank or suspended physical frame status"
            return result
        if not lit:
            result["reason"] = "Dark or empty local marker; the whole display cannot be classified from this frame"
            return result
    if target:
        result.update(status="PASS",reason="Independent display crop stayed visibly lit and reached the enrolled target color throughout measured coverage")
    else:
        result["reason"] = "Target frame/color was not independently visible at the final Space"
    return result


def finish(kit, attempt, pressed, ended):
    folder = None
    try:
        kit, _ = kit_paths(kit)
        folder = private(private(attempt, directory=True)/"visual", directory=True)
        receipt = folder/"receipt.json"
        if receipt.exists():
            return read(receipt)
        b = read(folder/"binding.json")
        p = b["request"]
        post = None
        if 0 < pressed < ended and math.isfinite(ended):
            try:
                post = witness(kit, p, p["target"])
            except ERRORS:
                pass
        write(folder/"end.json", dict(nonce=b["nonce"], pressed=pressed, ended=ended, allowMovie=bool(post)))
        limit = time.monotonic() + 11
        while time.monotonic() < limit and not (folder/"frames.json").exists() and not (folder/"error.json").exists():
            time.sleep(.04)
        observed = read(folder/"frames.json")
        require(observed["nonce"] == b["nonce"], "recorder generation changed")
        pre = read(folder/"before.json")
        if post:
            post = witness(kit, p, p["target"])
            write(folder/"after.json", post)
        result = score(observed, p, float(pressed), float(ended), pre, post)
        movie = folder/"verified-pair.mp4"
        if movie.is_file() and observed.get("movie") and post:
            result["silentMovie"] = {"file":movie.name, "sha256":hashlib.sha256(private(movie).read_bytes()).hexdigest()}
        result.update(frameLog="frames.json", nonce=b["nonce"], source=p["topology"]["current"], target=p["target"], pressed=pressed, ended=ended)
    except ERRORS as error:
        result = unknown(str(error))
        if folder:
            (folder/"verified-pair.mp4").unlink(missing_ok=True)
    finally:
        proc = CHILDREN.pop(str(folder), None)
        if proc:
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try: proc.wait(timeout=2)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait()
    if folder:
        write(folder/"receipt.json", result)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["enroll","start","finish"])
    parser.add_argument("kit", type=Path)
    parser.add_argument("attempt", type=Path)
    parser.add_argument("values", nargs="+")
    args = parser.parse_args()
    os.umask(0o077)
    if args.mode == "finish":
        answer = finish(args.kit, args.attempt, *map(float,args.values))
    elif args.mode == "enroll":
        answer = enroll(args.kit, args.attempt, read(Path(args.values[0])))
    else:
        answer = start(args.kit, args.attempt, read(Path(args.values[0])), guardian=os.getppid())
    print(json.dumps(answer))
    raise SystemExit(0 if answer["status"] in ("READY","PASS") else 2)
