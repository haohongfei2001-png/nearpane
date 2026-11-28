#!/usr/bin/env python3
"""Reconcile run 18's immutable Host records, independent focus reads and typed system events."""
import argparse
import importlib
import json
from pathlib import Path
import re
import subprocess

from p0_system_events import correlate, read_system

ROOT=Path(__file__).resolve().parents[3]
P0=ROOT/"engineering/verification/native-spaces/5.22-p0"
REFERENCE_DATE=978307200


def replay(rows=None, process=None):
    verifier=importlib.import_module("verify-p0-receipts")
    folder=P0/"18-late-space-change"
    verified=verifier.verify(folder)
    checksum,_,archive=verifier.read_archive(folder)
    trial=json.loads(archive["ten-01/result.json"])
    journal=json.loads(archive["ten-01/"+trial["hostJournalFile"]])
    intent, reply=journal["intent"],journal["result"]
    samples=[json.loads(line) for line in archive["ten-01/windowserver.jsonl"].splitlines()]
    target=intent["window"]["pid"]
    first=next(i for i,s in enumerate(samples) if s["frontPID"]==target)
    handoff=next(s for s in samples[first+1:] if s["frontPID"]!=target)
    stop=json.loads((folder/"daily-focus.json").read_bytes())["beforeStoppingIsolatedHost"]
    foreign=handoff["frontPID"]
    focus=stop["systemFocus"]
    if not (verified["verification"]=="VERIFIED" and focus["pid"]==foreign==stop["frontPID"] and
            focus["number"]==stop["focusedNumber"] and not json.loads(archive["ten-02/result.json"])["axIssued"]):
        raise ValueError("Missing independent foreground, document or no-second-press evidence")
    offsets=[]
    for name,raw in archive.items():
        if re.fullmatch(r"(?:roundTrip|ten)-\d+/[A-Fa-f0-9-]{36}\.json",name):
            j=json.loads(raw)
            offsets.append(REFERENCE_DATE+j["finishedAt"]-j["result"]["confirmedAtUptime"])
    # The wall date is taken when the Host persists a reply. Three such anchors
    # check clock consistency; causal matching also requires independent IDs.
    offset=REFERENCE_DATE+journal["finishedAt"]-reply["confirmedAtUptime"]
    ax=json.loads(archive["ten-01/ax-dispatch.json"])["uptime"]
    if len(offsets)!=3 or max(offsets)-min(offsets)>.1:raise ValueError("Inconsistent Host clocks")
    if rows is None: rows=read_system(ax+offset-.1,stop["uptime"]+offset)
    result=correlate(rows,target_pid=target,foreign_pid=foreign,target_space=int(intent["target"]),
                     later_space=stop["topology"]["current"],display=intent["display"],
                     later_focus=focus["number"],press_wall=ax+offset)
    receiver=None
    if process and result["status"]=="CONFIRMED":
        identity=json.loads(subprocess.check_output([str(process),"process",str(foreign)],timeout=4))
        current_boot=subprocess.check_output(["/usr/sbin/sysctl","-n","kern.bootsessionuuid"],text=True).strip().upper()
        if (identity["pid"]==foreign and 0<identity["birth"]/1e6<ax+offset and result["events"][0]["boot"]==current_boot
                and re.fullmatch(r"[a-f0-9]{40}",identity["hash"])):
            receiver={k:identity[k] for k in ("pid","birth","identifier","hash")}
    return dict(historicalOperation=intent["id"],archiveSHA256=checksum,archiveObjects=verified["hashedMembers"],
                bootBoundSurvivingReceiver=receiver,clockAnchorCount=len(offsets),clockAnchorSpreadMs=round((max(offsets)-min(offsets))*1000,3),
                clockNote="Approximate wall mapping from Host journal persistence. The two operating-system causes are matched by identifiers.",
                firstIndependentExternalSecondsAfterPress=round(handoff["uptime"]-ax,6),
                targetAtFirstExternalRead=int(handoff["topology"]["current"]),
                lastTargetSecondsAfterPress=round(samples[-1]["uptime"]-ax,6),lateIndependentFocus=focus,
                externalPID=foreign,secondPressIssued=False,rootMechanisms=result,
                upstreamAutomationOwner="UNKNOWN",physicalHumanInput="No change in the eight archived HID counters; other input is unobserved.",
                fixtureContribution="No second fixture AXPress. Parent of the automation sender was not established.",
                qualification="Historical attribution only. No new operation, stable round trip, ten or fifty-action gate is established.")


if __name__=="__main__":
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--replay",type=Path,help="read the retained six typed events, without querying the OS log")
    cli.add_argument("--process-reader",type=Path,help="optional existing signed acceptance p0-card process reader")
    cli.add_argument("--output",type=Path)
    args=cli.parse_args()
    saved=json.loads(args.replay.read_bytes())["rootMechanisms"]["events"] if args.replay else None
    result=replay(saved,args.process_reader)
    body=json.dumps(result,indent=2,ensure_ascii=False)+"\n"
    if args.output:
        with args.output.open("x") as file:file.write(body)
    else:print(body,end="")
