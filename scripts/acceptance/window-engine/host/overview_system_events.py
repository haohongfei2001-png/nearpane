"""Join a bounded physical overview to typed system events. No free-text log payload is retained."""
import argparse
import collections
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "native-spaces"))
from p0_system_events import LOG_FILTER, typed_row


SERVICES = {"Dock", "WindowManager", "WindowServer", "runningboardd", "launchservicesd", "lsd"}
OVERVIEW = "com.apple.exposelauncher"
QUIT = "QUITTING: pid=%d asn=0x-0x%llx foreground=%d wasFront=%d"


def time_window(report):
    measurement = report.get("measurement", {})
    if measurement.get("presentations") != 1:
        return None
    if "presentationRequest" in measurement:
        anchor = report["clockEnd"]
        request = measurement["presentationRequest"]["startUptime"]
        start = anchor["unix"] + request - anchor["uptime"] - 2
        end = anchor["unix"] + 1
    else:
        start = datetime.fromisoformat(report["startedUTC"].replace("Z", "+00:00")).timestamp() - 1
        end = datetime.fromisoformat(report["endedUTC"].replace("Z", "+00:00")).timestamp() + 1
    if not 0 < end-start <= 30:
        raise ValueError("unboundedPhysicalObservation")
    return start, end


def join_clock(row, report):
    # log show emits mach timestamps. Require agreement with BOTH physical wall/uptime anchors.
    anchors = [report.get("clockStart"), report.get("clockEnd")]
    if not all(anchors):
        return {"clockStatus": "historicalMachOnly"}
    projected = [a["uptime"] + row["unix"] - a["unix"] for a in anchors]
    if abs(projected[0]-projected[1]) > 0.08:
        return {"clockStatus": "wallUptimeDiscontinuity"}
    for key in ("machAbsolute", "machContinuous"):
        if not all(key in a for a in anchors):
            continue
        measured = [a["uptime"] + (row["mach"] - a[key])*a["numer"]/a["denom"]/1e9 for a in anchors]
        if max(abs(x-y) for x,y in zip(measured, projected)) <= 0.08:
            return {"clockStatus": key, "uptime": measured[0]}
    return {"clockStatus": "clockDomainUnverified"}


def decode(raw, tracked):
    name = Path(raw.get("processImagePath", "")).name
    parsed = typed_row(raw)
    if parsed:
        # The original log receipt remains private. Keep numeric event identity only.
        return {k:v for k,v in parsed.items() if k in
                ("kind", "pid", "targetPID", "previousPID", "window", "space", "returnID", "systemOSAScript")}
    if name not in SERVICES:
        return None
    fmt, msg = raw.get("formatString", ""), raw.get("eventMessage", "")
    if name == "launchservicesd" and fmt == QUIT:
        m = re.fullmatch(r"QUITTING: pid=(\d+) asn=0x-0x[\da-f]+ foreground=([01]) wasFront=([01])", msg, re.I)
        if m:
            return {"kind":"processQuit","subjectPID":int(m[1]),"foreground":m[2]=="1","wasFront":m[3]=="1"}
    if name == "WindowManager" and fmt in ("%x[%s]: space %d add window %x", "%x[%s]: space %d remove window %x"):
        m = re.search(r": space (\d+) (add|remove) window ([\da-f]+)$", msg, re.I)
        if m and int(m[3],16) in tracked:
            return {"kind":"trackedWindow"+m[2].title(),"space":int(m[1]),"window":int(m[3],16)}
    if name == "WindowManager" and fmt == "%x[%s]: space %d changed front connection to %x":
        m = re.search(r": space (\d+) changed front connection to ([\da-f]+)$",msg,re.I)
        if m:
            return {"kind":"spaceFrontConnection","space":int(m[1]),"connection":int(m[2],16)}
    if OVERVIEW in msg.lower() and name in ("runningboardd","launchservicesd","lsd"):
        return {"kind":"overviewLauncherReferenced"}
    return None


def activation_chain(rows, original):
    transitions = [r for r in rows if r["kind"] == "setFront" and r["previousPID"] == original
                   and r["targetPID"] != original]
    candidates = []
    for front in transitions:
        for receive in rows:
            if (receive["kind"] != "activationReceived" or receive["pid"] != front["targetPID"] or
                    not (0 <= front["unix"] - receive["unix"] <= .25) or receive["mach"] >= front["mach"]):
                continue
            matches = [r for r in rows if r["kind"] == "activationSent" and r["returnID"] == receive["returnID"] and
                       r["pid"] != receive["pid"] and r["mach"] < receive["mach"] and 0 <= receive["unix"]-r["unix"] <= .25]
            if len(matches) == 1:
                candidates.append((matches[0], receive, front))
    if len(transitions) == 1 and len(candidates) == 1:
        sent, received, front = candidates[0]
        # The audit log can redact the send's target address. A short return ID
        # and temporal order alone cannot prove which client requested focus.
        return dict(status="UNKNOWN",reason="requestAddressNotIndependentlyBound",
                    confirmedForegroundTransitions=1, matchedRequestChains=1, candidateSenderPID=sent["pid"],
                    targetPID=received["pid"],requestID=sent["returnID"],eventMach=[sent["mach"],received["mach"],front["mach"]])
    return dict(status="UNKNOWN",confirmedForegroundTransitions=len(transitions),matchedRequestChains=len(candidates))


def system_rows(start, end, predicate):
    def stamp(t):
        return datetime.fromtimestamp(t,timezone.utc).strftime("%Y-%m-%d %H:%M:%S+0000")
    run = subprocess.run(["/usr/bin/log","show","--style","ndjson","--info","--debug","--timezone","UTC",
                          "--start",stamp(start),"--end",stamp(end+1),"--predicate",predicate],
                         capture_output=True,text=True,timeout=45,check=True)
    for line in run.stdout.splitlines():
        if line.startswith("{"):
            raw = json.loads(line)
            if isinstance(raw.get("machTimestamp"),int) and raw.get("timestamp"):
                unix = datetime.fromisoformat(raw["timestamp"]).timestamp()
                if start <= unix <= end:
                    yield raw, unix


def clock_check(report):
    first, last = report["clockStart"], report["clockEnd"]
    if report["stage"] != "passiveReadOnly" or not 0 < last["unix"] - first["unix"] <= 5:
        return {"status":"BLOCKED","reason":"boundedPassiveAnchorsRequired"}
    predicate = " OR ".join('process == "'+s+'"' for s in sorted(SERVICES))
    results, boots = [], set()
    # A real log clock can be tested using only public timestamp fields.
    for raw, unix in system_rows(first["unix"], last["unix"], predicate):
        row = dict(mach=raw["machTimestamp"],unix=unix)
        row.update(join_clock(row,report))
        results.append(row)
        boots.add(raw.get("bootUUID"))
        if len(results) == 32:
            break
    domains = {r["clockStatus"] for r in results}
    passed = (len({r["mach"] for r in results}) >= 2 and len(boots)==1 and None not in boots and
              len(domains)==1 and domains <= {"machAbsolute","machContinuous"})
    return dict(status="PASS" if passed else "UNKNOWN", scope="physicalSystemTimestampCorrelationOnly",
                anchors=[first,last],samples=results,sameBoot=len(boots)==1 and None not in boots)


def collect(report):
    interval = time_window(report)
    if interval is None:
        return dict(status="NOT_RUN", reason="noPhysicalPresentation")
    start,end = interval
    tracked = {report["measurement"]["originalFocus"]["window"]}
    for snapshot in report.get("workspaceTimeline",{}).get("events",[]):
        for subject in snapshot.get("subjects",[]):
            tracked.update(w["id"] for w in subject.get("windows",[]))
    service_filter = " OR ".join('process == "'+s+'"' for s in sorted(SERVICES))
    fields = ("front connection", "QUITTING:", "add window", "remove window", OVERVIEW, "focus", "activat")
    selected = " OR ".join('eventMessage CONTAINS[c] "'+field+'"' for field in fields)
    filter_text = "("+LOG_FILTER+") OR (("+service_filter+") AND ("+selected+"))"
    rows, boots, emitters = [], set(), collections.Counter()
    for raw, unix in system_rows(start,end,filter_text):
        name = Path(raw.get("processImagePath","")).name
        if name in SERVICES:
            emitters[name] += 1
        row = decode(raw,tracked)
        if row is None:
            continue
        boots.add(raw.get("bootUUID"))
        row.update(unix=unix,mach=raw["machTimestamp"],emitter=name if name in SERVICES else "appleEventEndpoint",
                   emitterPID=raw.get("processID"))
        row.update(join_clock(row,report))
        rows.append(row)
    rows.sort(key=lambda r:r["mach"])
    causal = activation_chain(rows,report["measurement"]["originalFocus"]["pid"]) if len(boots)==1 and None not in boots else {"status":"UNKNOWN","reason":"bootNotUnique"}
    return dict(status="OBSERVED",startUnix=start,endUnix=end,queriedServices=sorted(SERVICES),
                matchedServiceCounts=dict(emitters),events=rows,activationRequestAttribution=causal)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("receipt",type=Path)
    cli.add_argument("output",type=Path)
    cli.add_argument("--check-passive-clock",action="store_true")
    args = cli.parse_args()
    try:
        report = json.loads(args.receipt.read_bytes())
        evidence = clock_check(report) if args.check_passive_clock else collect(report)
    except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
        evidence = dict(status="UNKNOWN",reason=type(error).__name__)
    with args.output.open("x") as stream:
        json.dump(evidence,stream,indent=2)
        stream.write("\n")
