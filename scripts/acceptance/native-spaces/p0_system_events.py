"""Read only typed activation, ordering and current-Space records from the macOS unified log."""
from datetime import datetime, timezone
import hashlib
import json
import re
import subprocess
from uuid import UUID


SET_FRONT = "SETFRONT: pid=%d asn=0x-0x%x foreground=%d oldFrontPid=%d oldFrontASN=0x-0x%u"
FOLLOW = "switching to space %llu for window(%x) app(%x %x) ordered on non-visible space"
CURRENT = "%x[%s]: display %{public}@ changed current space to %d"
SEND = "AESendMessage(%{public}s,%{public}s %{public}s..."
RECEIVE = "RECEIVED:(%{public}s,%{public}s) %{public}s..."
LOG_FILTER = ('(subsystem == "com.apple.appleevents" AND (eventMessage BEGINSWITH "AESendMessage(misc,actv" '
              'OR eventMessage BEGINSWITH "RECEIVED:(misc,actv")) OR '
              '(process == "launchservicesd" AND subsystem == "com.apple.processmanager" AND eventMessage BEGINSWITH "SETFRONT:") OR '
              '(process == "Dock" AND subsystem == "com.apple.dock.spaces" AND eventMessage BEGINSWITH "switching to space") OR '
              '(process == "WindowManager" AND subsystem == "com.apple.SkyLight" AND eventMessage CONTAINS "changed current space")')


def typed_row(raw):
    """No application payload, user text, window title or command line is returned."""
    fmt, message = raw.get("formatString"), raw.get("eventMessage", "")
    path, subsystem = raw.get("processImagePath", ""), raw.get("subsystem")
    if fmt in (SEND, RECEIVE) and subsystem == "com.apple.appleevents":
        prefix = "AESendMessage(misc,actv " if fmt == SEND else "RECEIVED:(misc,actv) "
        request = re.search(r"\breturnID=(-?\d+)\}", message)
        if not message.startswith(prefix) or not request:
            return None
        row = dict(kind="activationSent" if fmt == SEND else "activationReceived", returnID=int(request[1]),
                   systemOSAScript=path == "/usr/bin/osascript")
    elif fmt == SET_FRONT and path.endswith("/launchservicesd") and subsystem == "com.apple.processmanager":
        m = re.fullmatch(r"SETFRONT: pid=(\d+) asn=0x-0x([\da-f]+) foreground=1 oldFrontPid=(\d+) oldFrontASN=0x-0x(\d+)", message, re.I)
        if not m:
            return None
        row = dict(kind="setFront", targetPID=int(m[1]), targetASN=int(m[2],16), previousPID=int(m[3]))
    elif fmt == FOLLOW and path == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" and subsystem == "com.apple.dock.spaces":
        m = re.fullmatch(r"switching to space (\d+) for window\(([\da-f]+)\) app\(([\da-f]+) ([\da-f]+)\) ordered on non-visible space", message, re.I)
        if not m:
            return None
        row = dict(kind="dockFollowOrderedWindow", space=int(m[1]), window=int(m[2],16),
                   asnHigh=int(m[3],16), asnLow=int(m[4],16))
    elif fmt == CURRENT and path == "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager" and subsystem == "com.apple.SkyLight":
        m = re.search(r": display ([\da-f-]{36}) changed current space to (\d+)$", message, re.I)
        if not m:
            return None
        row = dict(kind="currentSpace", display=str(UUID(m[1])).upper(), space=int(m[2]))
    else:
        return None
    row.update(pid=raw["processID"], boot=str(UUID(raw["bootUUID"])).upper(),
               time=datetime.fromisoformat(raw["timestamp"]).timestamp(), mach=raw["machTimestamp"],
               messageSHA256=hashlib.sha256(message.encode()).hexdigest())
    return row


def read_system(start, end):
    if not 0 < end-start <= 30:
        raise ValueError("A bounded interval of at most 30 seconds is required")
    def stamp(t):
        return datetime.fromtimestamp(t,timezone.utc).strftime("%Y-%m-%d %H:%M:%S+0000")
    run = subprocess.run(["/usr/bin/log","show","--style","ndjson","--info","--debug","--timezone","UTC",
                          "--start",stamp(start),"--end",stamp(end+1),"--predicate",LOG_FILTER],
                         text=True,capture_output=True,check=True,timeout=40)
    rows = []
    for line in run.stdout.splitlines():
        if not line.startswith("{"):
            continue
        row = typed_row(json.loads(line))
        if row and start <= row["time"] <= end:
            rows.append(row)
    return rows


def correlate(rows, *, target_pid, foreign_pid, target_space, later_space, display, later_focus, press_wall):
    def after(earlier, later, bound):
        return earlier["boot"] == later["boot"] and earlier["mach"] < later["mach"] and 0 <= later["time"]-earlier["time"] <= bound
    def candidates(kind, **fields):
        return [row for row in rows if row["kind"]==kind and all(row.get(k)==v for k,v in fields.items())]
    # Require one unambiguous complete chain. Nearby events from other apps cannot supply missing links.
    chains=[]
    for land in candidates("currentSpace",display=display,space=target_space):
        if not 0 <= land["time"]-press_wall <= 1: continue
        for receive in candidates("activationReceived",pid=foreign_pid):
            if not after(land,receive,10): continue
            sends=[s for s in candidates("activationSent",returnID=receive["returnID"]) if after(s,receive,.25)]
            if len(sends)!=1 or sends[0]["pid"] in (foreign_pid,target_pid) or not after(land,sends[0],10): continue
            for front in candidates("setFront",targetPID=foreign_pid,previousPID=target_pid):
                if not after(receive,front,.25): continue
                for follow in candidates("dockFollowOrderedWindow",space=later_space,window=later_focus,asnHigh=0,asnLow=front["targetASN"]):
                    if not after(front,follow,10): continue
                    for current in candidates("currentSpace",display=display,space=later_space):
                        if after(follow,current,2): chains.append([land,sends[0],receive,front,follow,current])
    if len(chains)!=1:
        return dict(status="UNKNOWN",matchingChains=len(chains),events=[])
    return dict(status="CONFIRMED",matchingChains=1,events=chains[0],
                foregroundTrigger="Apple Event misc/actv addressed to the subsequently frontmost process",
                spaceTrigger="Dock explicitly followed that process's ordered off-Space window")
