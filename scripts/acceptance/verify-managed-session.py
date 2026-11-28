#!/usr/bin/env python3
"""Read the real product controller/Host receipts. Does not start apps or request AX access."""
import argparse
import hashlib
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_bytes())


def check(value, reason):
    if not value:
        raise ValueError(reason)


def audit(session, evidence, app):
    binary = app / "Contents/MacOS/NearpaneHost"
    marker = read(session / "session.json")
    check(marker["session"].lower() == session.name and marker["executableSHA256"] == hashlib.sha256(binary.read_bytes()).hexdigest(),
          "session executable differs from the installation")
    root = session / "support/WorkRect"
    cohort = root / read(root / "management.json")["session"]
    origin = read(evidence / "baseline.json")
    check(origin["session"].lower() == cohort.name and len(origin["members"]) == 1, "initial owner missing")
    cases = {}
    for name in ("one", "two", "pair", "adopted", "three", "resumed", "floating", "docked", "recovered", "revoked", "quit"):
        result = read(evidence / (name + ".json"))
        journal = result["journal"]
        check(result["session"].lower() == cohort.name and journal["owner"] == origin["owner"] and
              journal["session"] == result["session"] and result["snapshotRevision"] == journal["revision"], name + " identity")
        for row in result["observations"]:
            identity = row["member"]["id"]
            check(identity["pid"] == origin["owner"]["pid"] and identity["launch"] == origin["owner"]["start"] and
                  row["onScreen"] and row["ax"] == row["cg"], name + " live readback")
        check(len(result["steps"]) == result["setters"] and all(s["requested"] == s["after"]["cg"] == s["after"]["ax"]
              for s in result["steps"]), name + " primitive readback")
        cases[name] = result
    def geometry(case):
        return [(o["member"]["id"], o["cg"]) for o in cases[case]["observations"]]
    check(geometry("revoked") == geometry("quit"), "revocation and explicit quit disagree")
    check(len(geometry("one")) == 1 and len(geometry("three")) == 3 and cases["one"]["creationUnavailableFor"],
          "admission / unavailable Native creation")
    check(cases["floating"]["workRect"] == read(cohort / "run.json")["screens"]["usable"] and
          cases["docked"]["workRect"]["width"] < cases["floating"]["workRect"]["width"], "reserve")
    before = read(cohort / "kill-witness.json")
    recovered = cases["recovered"]["journal"]
    check(before["journal"]["status"] == "prepared" and any(c.get("inFlight") for c in before["journal"]["changes"]) and
          before["journal"]["transaction"] == recovered["transaction"] and recovered["status"] == "restored" and
          recovered["owner"] == before["journal"]["owner"], "crash WAL relationship")
    check(all(c["confirmed"] == c["original"] and not c.get("inFlight") for c in recovered["changes"]), "incomplete rollback")
    exits = sorted((read(p) for p in session.glob("process-*.json")), key=lambda x: x["started"])
    check([e["exitCode"] for e in exits] == [-9, 0] and exits[0]["exited"] <= exits[1]["started"] and
          exits[0]["pid"] != exits[1]["pid"], "missing distinct killed/relaunched Host")
    for e in exits:
        lines = [json.loads(line) for line in (session / (e["run"] + ".jsonl")).read_bytes().splitlines()]
        check(e["session"] == session.name and lines[0]["kind"] == "opened" and
              all(row["state"]["pid"] == e["pid"] and not row["state"]["active"] and not row["state"]["key"] for row in lines) and
              len({row["state"]["foreground"] for row in lines}) == 1, "Host identity or focus")
        check(e["prelaunch"] == e["postExit"] and e["postExit"]["attempts"] == 0, "input domains changed")
        if e["exitCode"] == 0:
            check(lines[-1]["kind"] == "drained", "normal exit did not drain")
    return dict(session=session.name, cohort=cohort.name, executable=marker["executableSHA256"],
                cases={name: {"members": len(r["observations"]), "setters": r["setters"], "errorPoints": r.get("maxModelError")}
                       for name, r in cases.items()}, recoveryTransaction=recovered["transaction"], exits=[e["exitCode"] for e in exits])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("session", "evidence", "app"):
        parser.add_argument(arg, type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.session, args.evidence, args.app), indent=2))
