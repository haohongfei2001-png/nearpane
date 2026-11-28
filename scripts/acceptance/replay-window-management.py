#!/usr/bin/env python3
"""Independently check P4.2 receipts without starting an app or querying the desktop."""
import argparse
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_bytes())


def check(condition, message):
    if not condition:
        raise ValueError(message)


def events(directory):
    return [json.loads(line) for line in (directory / "events.jsonl").read_text().splitlines()]


def results(directory):
    for path in sorted(directory.glob("*.stdout")):
        if path.stat().st_size:
            yield read(path)


def measured(row):
    check(row.get("ax") == row["cg"], "missing matching AX and CG geometry")
    return tuple(row["cg"][k] for k in ("x", "y", "width", "height"))


def check_workrect(directory):
    result = read(directory / "result.json")
    check(result["completed"] and result["suite"] == "workrect", "incomplete WorkRect series")
    # Fractional boundaries are independent of the Swift partition tree.
    layouts = {
        1: [(0, 0, 1, 1)],
        2: [(0, 0, .5, 1), (.5, 0, .5, 1)],
        3: [(.5, 0, .5, .5), (.5, .5, .5, .5), (0, 0, .5, 1)],
        4: [(.5, 0, .5, .5), (.5, .5, .5, .5), (0, 0, .5, .5), (0, .5, .5, .5)],
        5: [(.5, 0, .25, .5), (.75, 0, .25, .5), (0, 0, .5, .5), (0, .5, .5, .5), (.5, .5, .5, .5)],
    }
    maximum, counts, custom, restored, previous = 0., set(), None, False, 0
    for receipt in results(directory):
        if not isinstance(receipt, dict) or "maxModelError" not in receipt:
            continue
        windows = sorted(receipt["observations"], key=lambda w: w["member"]["index"])
        n = len(windows)
        boxes = [measured(w) for w in windows]
        ids = [w["member"]["id"] for w in windows]
        a = receipt["workRect"]
        boxspec = layouts[n]
        if receipt["action"] == "custom-pair":
            custom = (ids, boxes)
            boxspec = [(.62, 0, .38, 1), (0, 0, .62, 1)]
        if previous == 3 and n == 2:
            check(custom == (ids, boxes), "pair geometry or identity changed across W3 removal")
            restored = True
            boxspec = [(.62, 0, .38, 1), (0, 0, .62, 1)]
        for (x, y, w, h), actual in zip(boxspec, boxes):
            expected = (a["x"] + a["width"] * x, a["y"] + a["height"] * y, a["width"] * w, a["height"] * h)
            maximum = max(maximum, *(abs(v - t) for v, t in zip(actual, expected)))
        for step in receipt["steps"]:
            check(step["member"] == step["after"]["member"] and step["requested"] == step["after"]["cg"] == step["after"]["ax"],
                  "unconfirmed or misdirected primitive")
        counts.add(n)
        previous = n
    check(counts == set(layouts) and restored and maximum <= 1, "incomplete or inaccurate geometry")
    return maximum


def check_controls(directory):
    check(read(directory / "result.json")["completed"], "incomplete accessible recovery / panel series")
    log = events(directory)
    witness = read(directory / "kill-witness.json")
    change, after = witness["journal"]["changes"][0], witness["observations"][0]
    check(witness["journal"]["status"] == "prepared" and change["confirmed"] == change["original"] != after["cg"]
          and change["member"] == after["member"] and change["inFlight"] == after["cg"] == after["ax"], "wrong kill boundary")
    killed = [x for x in log if x["name"] == "SIGKILL"]
    check(len(killed) == 1 and killed[0]["transaction"] == witness["journal"]["transaction"], "unrelated SIGKILL")
    restored = [r for r in results(directory) if isinstance(r, dict) and r.get("journal", {}).get("transaction") == killed[0]["transaction"]]
    check([(r["action"], r["setters"]) for r in restored] == [("restored", 1), ("already-restored", 0)], "unproven or repeated recovery")
    for r in restored:
        w = r["observations"][0]
        check(w["member"] == change["member"] and w["onScreen"] and w["cg"] == w["ax"] == change["original"], "lost or substituted window")
    panels = [e["action"] for e in log if e["name"] == "panel-checkpoint"]
    check(panels == ["panel-show", "panel-hide", "panel-show", "panel-expand", "panel-collapse", "panel-tools-off", "panel-hide"],
          "incomplete real panel series")
    # Pair the foreground panel evidence with the immediately following ordinary-window observation.
    samples = list(results(directory))
    pairs = [samples[i+1] for i, r in enumerate(samples[:-1]) if isinstance(r, dict) and r.get("action") in panels and "visible" in r]
    check(len(pairs) == len(panels) and all(len(p) == 2 for p in pairs), "missing ordinary-window checkpoints")
    expected = [(w["member"], measured(w)) for w in pairs[0]]
    check(all([(w["member"], measured(w)) for w in pair] == expected for pair in pairs), "panel changed an ordinary window")
    required = ("lease", "Accessibility denied", "unrecognized frame", "stale enrollment")
    check(all(any(e.get("rc") != 0 and e.get("attempts") == 0 and token in e.get("detail", "") for e in log)
              for token in required), "missing zero-write refusal")
    check(any(e["name"] == "old-process-and-window-rejected" for e in log) and sum(e["name"] == "CG-cleanup" for e in log) == 2,
          "missing process replacement / cleanup")


def check_failed_parking(directory):
    j = read(directory / "journal.json")
    check(not read(directory / "result.json")["completed"] and j["parked"] and j["status"] == "recovering", "unexpected parking verdict")
    c = j["changes"][0]
    seen = read(directory / "unconfirmed-readback.json")
    check(seen["member"] == c["member"] and seen["ax"] == seen["cg"] and seen["onScreen"]
          and seen["cg"] not in (c["original"], c["inFlight"]) and c["inFlight"] == c["target"], "missing unconfirmed parking witness")
    log = events(directory)
    check(sum(e.get("attempts", 0) for e in log if e.get("phase") == "virtual-canary") == 1
          and not any(e["name"] == "SIGKILL" for e in log)
          and any(e["name"] == "recovery-unresolved" for e in log) and log[-1]["name"] == "owned-fixture-exit" and log[-1]["rc"] == 0,
          "missing first-window stop or owner exit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("workrect", "controls", "failed-parking"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    error = check_workrect(args.workrect)
    check_controls(args.controls)
    check_failed_parking(args.failed_parking)
    print(f"1–5 windows, independent maximum error {error:g} pt; real panel and on-screen SIGKILL receipts verified.")
    print("Off-screen parking and first restoration FAILED; verified refusal and stop, no off-screen crash pass.")


if __name__ == "__main__":
    main()
