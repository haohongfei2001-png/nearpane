#!/usr/bin/env python3
"""Offline P4.2.1 first-window failure and sampled focus audit. No macOS calls."""
import argparse
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_bytes())


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def verify_focus(samples, baseline):
    require(len(samples) >= 2, "insufficient focus observations")
    last = None
    responders = {}
    max_gap = 0.
    for row in samples:
        require(row["event"] == "sample", "focus notification or discontinuity")
        require(row["frontPID"] == row["baselinePID"] == baseline and row["axWindowReadable"]
                and row["sameAXFocusedWindow"] and not row["active"], "foreground identity or AX focus changed")
        now = row["uptime"]
        if last is not None:
            require(0 < now-last < .35, "missing or reordered focus samples")
            max_gap = max(max_gap, now-last)
        last = now
        for w in row["windows"]:
            require(not w["key"] and not w["main"], "owned window received focus")
            require(responders.setdefault(w["number"], w["responder"]) == w["responder"], "first responder changed")
    return max_gap


def audit(directory):
    run = read(directory/"run.json")
    require(run["parkingStudy"], "not a frozen parking study")
    before = read(directory/"mini-baseline.json")
    owner = before[0]["member"]["id"]["pid"]
    samples = [json.loads(line) for line in (directory/f"focus-{owner}.jsonl").read_text().splitlines()]
    gap = verify_focus(samples, samples[0]["baselinePID"])
    events = [json.loads(line) for line in (directory/"events.jsonl").read_text().splitlines()]
    times = {r["uptime"]:r for r in samples}
    start = None
    for i, e in enumerate(events):
        if e["name"] == "before":
            require(start is None and e["focus"] in times, "missing start checkpoint")
            start = e
        if e["name"] == "after":
            require(start and start["command"] == e["command"] and start["focus"] < e["focus"] and e["focus"] in times,
                    "missing end checkpoint")
            receipt = events[i-1]
            require(receipt["name"] == e["command"] and "rc" in receipt and
                    start["monotonic"] <= receipt["monotonic"] <= e["focus"], "focus checkpoint did not bracket command")
            start = None
    require(start is None, "unclosed focus interval")
    attempts = [read(p) for p in directory.glob("mini-attempt-*.json")]
    require(len(attempts) == 1, "unexpected visibility write count")
    attempt = attempts[0]
    require(len(before) == 2 and all(w["onscreen"] and not w["minimized"] for w in before)
            and before[0]["settable"] and attempt["member"] == before[0]["member"]
            and attempt["minimize"] and attempt["result"] == 0, "wrong window or AX receipt")
    window_ids = {w["member"]["id"]["number"] for w in before}
    post = [r for r in samples if r["uptime"] >= attempt["uptime"]]
    require(len(post) >= 2 and all({w["number"] for w in r["windows"] if not w["mini"]} >= window_ids for r in post),
            "missing owner-side minimization evidence")
    journal = read(directory/"visibility.json")
    require(journal["run"].lower() == run["session"].lower() and journal["original"] == before and not journal["settled"]
            and journal["pendingIndex"] == 0 and journal["pendingValue"], "unrelated or settled WAL")
    require(not read(directory/"result.json")["completed"] and any(e["name"]=="mini-recover" and e["rc"] != 0 for e in events)
            and any(e["name"]=="CG-cleanup" and e["confirmedGone"] == 2 for e in events), "missing refusal or cleanup")
    killed = [e for e in events if e["name"] == "SIGKILL"]
    witness = read(directory/"kill-witness.json")
    record = witness["journal"]
    require(len(killed) == 1 and killed[0]["transaction"] == record["transaction"] and record["status"] == "prepared",
            "missing on-screen crash boundary")
    change = record["changes"][0]
    require(change["confirmed"] == change["original"] != change["inFlight"] and
            change["inFlight"] == witness["observations"][0]["ax"] == witness["observations"][0]["cg"], "wrong pre-ack state")
    recoveries = [read(p) for p in sorted(directory.glob("*-recover.stdout")) if p.stat().st_size]
    recovered = [r for r in recoveries if r["journal"]["transaction"] == record["transaction"]]
    require([r["setters"] for r in recovered] == [1, 0] and all(
        r["observations"][0]["member"] == change["member"] and r["observations"][0]["onScreen"]
        and r["observations"][0]["ax"] == r["observations"][0]["cg"] == change["original"] for r in recovered), "unconfirmed crash recovery")
    return dict(samples=len(samples), maximumGapSeconds=gap, afterSetterSamples=len(post), minimization="FAILED",
                visibleCrashRestored=any(e["name"]=="sigkill-restored" and e["onscreen"] for e in events),
                virtualSwitch="NOT_RUN")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    print(json.dumps(audit(parser.parse_args().session), sort_keys=True))
