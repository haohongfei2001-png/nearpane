#!/usr/bin/env python3
"""Compare saved scope-only Reader samples. This command reads files and emits no system input."""
import argparse
import json
import math
from pathlib import Path
import runpy
import sys
import uuid


checkpoint = runpy.run_path(str(Path(__file__).with_name("space-checkpoint.py")))
require, load = checkpoint["require"], checkpoint["load"]


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def rect(value):
    coords = tuple(value[k] for k in ("x", "y", "width", "height"))
    require(all(map(number, coords)) and min(coords[2:]) > 0, "invalid display rectangle")
    return coords


def scope_state(sample, primary, secondary):
    native = sample["native"]
    require(sample["source"] == "macos-window-server" and sample["freshness"] == "fresh"
            and sample["topologyConsistent"] is True and sample["separateSpaces"] is True
            and native["population"] == "markedFixture" and native["spaces"] == "observed"
            and sample["windows"] == [] and native["rows"] == [] and native["windowLimitReached"] is False,
            "expected a stable scope-only Reader sample")
    require(primary != secondary and len(sample["displays"]) == len(sample["scopes"]) == 2
            and set(sample["ordinaryRecordsByDisplay"]) == {primary, secondary}, "two designated displays required")
    geometry = {}
    for d in sample["displays"]:
        frame = rect(d["frame"])
        require((d["id"] == primary) == (frame[:2] == (0, 0)), "primary display does not match Quartz origin")
        require(number(d["backingScale"]) and d["backingScale"] > 0 and number(d["rotationDegrees"]),
                "invalid display scale or rotation")
        geometry[d["id"]] = (frame, rect(d["usable"]), d["rotationDegrees"], d["backingScale"])
    scopes, all_ids = {}, set()
    for scope in sample["scopes"]:
        display = scope["displayID"]
        records = scope["records"]
        require(scope["id"] == "scope-" + display and all(type(row["isCurrent"]) is bool for row in records),
                "ambiguous scope or current")
        order = tuple(row["id"] for row in records)
        require(all(isinstance(i, str) and i.isascii() and i.isdecimal() and 0 < int(i) < 2**64
                    and str(int(i)) == i for i in order), "invalid Space record ID")
        require(len(set(order)) == len(order) and all_ids.isdisjoint(order), "duplicate Space record")
        all_ids.update(order)
        active = [row["id"] for row in records if row["isCurrent"]]
        ordinary_ids = sample["ordinaryRecordsByDisplay"][display]
        require(isinstance(ordinary_ids, list), "missing ordinary record list")
        ordinary = tuple(ordinary_ids)
        require(len(active) == 1 and tuple(i for i in order if i in ordinary) == ordinary,
                "inconsistent current or ordinary record order")
        scopes[display] = (order, ordinary, active[0])
    require(geometry.keys() == scopes.keys() == {primary, secondary}, "display-to-scope mapping changed")
    require(sample["sourceBuild"] and sample["topologyFingerprint"], "missing build or topology evidence")
    return (sample["sourceBuild"], sample["topologyFingerprint"], geometry, scopes[primary]), scopes[secondary]


def verify(primary, secondary, before, after, restored=None):
    """Require temporally distinct stable pairs and an exact one-record insertion next to A."""
    last_times = None
    revisions = {}
    states = []
    for pair in (before, after) if restored is None else (before, after, restored):
        require(len(pair) == 2, "two samples required at each checkpoint")
        checkpoint_state = []
        for sample in pair:
            session = uuid.UUID(sample["sessionID"])
            revision = sample["revision"]
            require(type(revision) is int and revision > revisions.get(session, 0), "replayed Reader revision")
            revisions[session] = revision
            starts = (sample["sampledFrom"], sample["native"]["beganUptime"])
            ends = (sample["sampledTo"], sample["native"]["endedUptime"])
            require(all(number(a) and number(b) and 0 <= b - a <= 3 for a, b in zip(starts, ends)),
                    "invalid sample interval")
            require(last_times is None or all(a > b for a, b in zip(starts, last_times)),
                    "samples overlap or are out of order")
            last_times = ends
            checkpoint_state.append(scope_state(sample, primary, secondary))
        require(checkpoint_state[0] == checkpoint_state[1], "unstable checkpoint")
        states.append(checkpoint_state[0])

    base, (old_order, old_ordinary, source) = states[0]
    current, (new_order, new_ordinary, active) = states[1]
    require(base == current, "protected display, build or geometry changed")
    require(source == active and source in old_ordinary, "secondary did not remain at its ordinary source")
    added = set(new_order) - set(old_order)
    require(len(added) == 1, "expected exactly one new Space record")
    target = added.pop()
    require(target in new_ordinary and tuple(i for i in new_order if i != target) == old_order
            and tuple(i for i in new_ordinary if i != target) == old_ordinary,
            "existing order/types changed or new record is not ordinary")
    offset = new_order.index(target) - new_order.index(source)
    require(abs(offset) == 1, "new record is not adjacent in complete secondary order")
    if restored is not None:
        require(states[0] == states[2], "original topology and currents were not restored")
    return dict(observation="oneAdjacentOrdinaryRecordAdded", secondary=secondary, primary=primary,
                source=source, target=target, direction="right" if offset == 1 else "left",
                primaryCurrent=base[3][2], originalScopesRestored=True if restored is not None else None,
                creatorProven=False, emptyDesktopProven=False, deletionAuthorized=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--primary", required=True, help="independently identified primary display UUID")
    parser.add_argument("--secondary", required=True, help="independently identified secondary display UUID")
    for key in ("before", "after", "restored"):
        parser.add_argument("--" + key, nargs=2, required=key != "restored", type=Path,
                            metavar=("FIRST_JSON", "SECOND_JSON"))
    args = parser.parse_args()
    pairs = [[load(path) for path in paths] if paths else None for paths in (args.before, args.after, args.restored)]
    print(json.dumps(verify(args.primary, args.secondary, *pairs), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, KeyError, OSError, AttributeError) as error:
        sys.exit(f"REFUSED: {error}")
