"""Measure only the marked native Host and its dedicated focus reference, without reading window contents."""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import uuid
import time

import session_evidence as evidence


class Usage(C.Structure):
    # Darwin sys/resource.h, RUSAGE_INFO_V0.
    _fields_ = [("uuid", C.c_ubyte * 16)] + [(k, C.c_uint64) for k in (
        "user", "system", "package_wakes", "interrupt_wakes", "pageins", "wired", "resident",
        "footprint", "start", "exit")]


def console_open():
    graphics = C.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    graphics.CGSessionCopyCurrentDictionary.restype = C.c_void_p
    cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]
    cf.CFStringCreateWithCString.restype = C.c_void_p
    cf.CFDictionaryGetValue.argtypes = [C.c_void_p, C.c_void_p]
    cf.CFDictionaryGetValue.restype = C.c_void_p
    cf.CFRelease.argtypes = [C.c_void_p]
    cf.CFBooleanGetValue.argtypes = [C.c_void_p]
    session = graphics.CGSessionCopyCurrentDictionary()
    if not session:
        return False
    try:
        def flag(name):
            key = cf.CFStringCreateWithCString(None, name, 0x08000100)
            try:
                value = cf.CFDictionaryGetValue(session, key)
                return bool(value and cf.CFBooleanGetValue(value))
            finally:
                cf.CFRelease(key)
        return flag(b"kCGSSessionOnConsoleKey") and flag(b"kCGSessionLoginDoneKey") and not flag(b"CGSSessionScreenIsLocked")
    finally:
        cf.CFRelease(session)


def seconds_per_tick():
    timebase = (C.c_uint32 * 2)()
    result = C.CDLL(None).mach_timebase_info(C.byref(timebase))
    evidence.require(result == 0 and timebase[1] != 0, "Darwin timebase unavailable")
    return timebase[0] / timebase[1] / 1e9


def latest_event(stream, previous):
    for line in stream:
        if not line.endswith(b"\n"):
            stream.seek(-len(line), os.SEEK_CUR)
            break
        previous = json.loads(line)
    return previous


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("session", type=Path)
    p.add_argument("executable", type=Path)
    p.add_argument("reference_pid", type=int)
    p.add_argument("reference_executable", type=Path)
    a = p.parse_args()
    folder = a.session.resolve()
    start = json.loads((folder/"focus-idle-start.json").read_text())
    run = start["run"]
    pid = start["state"]["pid"]
    evidence.require(start["session"] == folder.name, "Session mismatch")
    evidence.require(evidence.process_path(pid).resolve() == a.executable.resolve(), "Host mismatch")
    evidence.require(evidence.process_path(a.reference_pid).resolve() == a.reference_executable.resolve(), "Reference mismatch")
    evidence.require(start["state"]["foreground"] == a.reference_pid, "Reference did not own focus")
    summary = dict(session=folder.name, run=run, targetSeconds=3600, referencePID=a.reference_pid)
    stream = folder/(run+".jsonl")
    start_event = next(e for e in evidence.events(stream) if e["time"] == start["time"])
    lib = C.CDLL("/usr/lib/libproc.dylib")
    samples = []
    last = start_event
    reason = "time limit"
    tick = seconds_per_tick()
    raw = "residence-"+run+"-"+str(uuid.uuid4())+".jsonl"
    summary["raw"] = raw
    with (folder/raw).open("x") as out, stream.open("rb") as events:
        until = time.monotonic()+3625
        while time.monotonic() < until:
            if not console_open():
                reason = "console locked or unavailable"
                break
            usage = Usage()
            try:
                host = evidence.process_path(pid).resolve()
                reference = evidence.process_path(a.reference_pid).resolve()
            except ValueError:
                reason = "observed process exited"
                break
            if lib.proc_pid_rusage(pid, 0, C.byref(usage)) or host != a.executable.resolve() or reference != a.reference_executable.resolve():
                reason = "observed identity or usage unavailable"
                break
            last = latest_event(events, last)
            row = dict(t=time.monotonic(), cpuSeconds=(usage.user + usage.system) * tick, rss=usage.resident,
                       footprint=usage.footprint, packageWakes=usage.package_wakes, interruptWakes=usage.interrupt_wakes,
                       visible=last["state"]["visible"], key=last["state"]["key"], active=last["state"]["active"],
                       referenceFront=last["state"]["foreground"] == a.reference_pid, processStart=usage.start)
            evidence.require(not samples or samples[0]["processStart"] == usage.start, "Host identity changed")
            samples.append(row)
            out.write(json.dumps(row)+"\n")
            out.flush()
            if last["kind"] == "drained" or time.time()-last["time"] > 12:
                reason = "heartbeat ended"
                break
            if row["t"]-samples[0]["t"] >= 3600 and last["uptime"]-start_event["uptime"] >= 3600:
                reason = "completed window"
                break
            time.sleep(5)
    end = dict(session=folder.name, run=run, time=last["time"], state=last["state"])
    evidence.put(folder/"focus-idle-end.json", end)
    series = evidence.events(stream)
    checks = evidence.focus_verdict("idle", [start,end], series, 3600)
    summary.update(stop=reason, uptimeSeconds=last["uptime"]-start_event["uptime"], focus=checks, samples=len(samples),
                   rawSHA256=evidence.digest((folder/raw).read_bytes()))
    if len(samples)>1:
        first, final = samples[0], samples[-1]
        dt = final["t"]-first["t"]
        values = [s["rss"] for s in samples]
        summary.update(sampleSeconds=dt, cpuPercent=100*(final["cpuSeconds"]-first["cpuSeconds"])/dt,
                       rssFirst=values[0], rssLast=values[-1], rssMin=min(values), rssMax=max(values),
                       rssQuarterEnds=[values[(len(values)-1)*q//4] for q in range(1,5)],
                       interruptWakesPerSecond=(final["interruptWakes"]-first["interruptWakes"])/dt,
                       packageIdleWakesPerSecond=(final["packageWakes"]-first["packageWakes"])/dt)
    evidence.put(folder/("residence-"+run+".json"),summary)


if __name__ == "__main__":
    main()
