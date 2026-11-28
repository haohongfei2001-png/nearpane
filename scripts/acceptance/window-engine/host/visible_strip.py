"""Independently replay two grids of actual public AX calls. No GUI access and no inferred tile pixels."""
import argparse
import json
import math
from pathlib import Path


def contains(frame, point):
    x, y, w, h = frame
    return w > 0 and h > 0 and x <= point[0] < x + w and y <= point[1] < y + h


def read_grid(grid):
    nodes, hits = grid["objects"], grid["hits"]
    if (grid["completeGrid"] is not True or grid["inputInterrupted"] is not False or grid["rootDisagreement"] is not False or
            grid["rootTimeoutErrors"] != {"dock":0,"systemWide":0} or
            not 1 <= len(hits) == grid["targetPoints"] == grid["pointsRead"] <= 200):
        raise ValueError("incompleteCoordinateGrid")
    strips = grid["stripAttributes"]
    if len(strips) != 1:
        raise ValueError("ambiguousSpacesList")
    strip = strips[0]
    node = nodes[strip["list"]]
    if node["identifier"] != "mc.spaces.list" or node["role"] != "AXList":
        raise ValueError("unboundSpacesList")
    arrays = {r["attribute"]:r["objects"] for r in strip["attributes"] if r["axError"] == 0}
    children = arrays["AXChildren"]
    if children != arrays["AXVisibleChildren"] or not children or len(set(children)) != len(children):
        raise ValueError("visibleAndEnumeratedChildrenDisagree")
    parent = {r["object"]:r["parent"] for r in grid["parentReads"] if r["axError"] == 0}
    ordered = []
    occupied = {}
    coords = set()
    for child in children:
        item = nodes[child]
        if (parent.get(child) != strip["list"] or item["pid"] != node["pid"] or item["role"] != "AXButton" or
                item["identifier"] in ("mc.spaces.add","mc.spaces.remove") or
                any(item["errors"][k] != 0 for k in ("pid", "role", "position", "size")) or
                not all(math.isfinite(v) for v in item["frame"]) or min(item["frame"][2:]) <= 0):
            raise ValueError("unconfirmedChildIdentityOrFrame")
        ordered.append(item["frame"])
        occupied[child] = {}
    for row in hits:
        point = tuple(row["point"])
        if point in coords or not contains(grid["displayFrame"],point):
            raise ValueError("duplicateOrOffDisplayCoordinate")
        coords.add(point)
        for root in ("dock","systemWide"):
            hit = row[root]
            if type(hit["axError"]) is not int or (hit["axError"] == 0 and not 0 <= hit["object"] < len(nodes)):
                raise ValueError("unusableAXRead")
        hit = row["systemWide"]
        child = hit.get("object")
        if hit["axError"] == 0 and child in occupied and contains(node["frame"],point) and contains(nodes[child]["frame"],point):
            occupied[child].setdefault(point[1],[]).append(point[0])
    for y in sorted(set.intersection(*(set(occupied[c]) for c in children))):
        spans = [[min(occupied[c][y]),max(occupied[c][y])] for c in children]
        if all(a[1]<b[0] for a,b in zip(spans,spans[1:])) and all(a[0]+a[2]/2 < b[0]+b[2]/2 for a,b in zip(ordered,ordered[1:])):
            return dict(count=len(children),ownerPID=node["pid"],stripFrame=node["frame"],
                        frames=ordered,sampledY=y,topmostXSpans=spans,pointsPerRoot=len(hits))
    raise ValueError("noCommonOrderedTopmostScanline")


def replay(measurement):
    try:
        grids = measurement["hitTestSamples"]
        if len(grids) != 2 or grids[0]["endUptime"] >= grids[1]["startUptime"]:
            raise ValueError("twoDistinctSamplingIntervalsRequired")
        actual = [read_grid(g) for g in grids]
        if actual[0] != actual[1] or actual[0]["count"] != measurement["expectedCount"]:
            raise ValueError("distinctLayoutsOrIndependentInventoryCountDiffers")
        if measurement["hidBefore"] != measurement["hidAfter"] or measurement["inputUninterrupted"] is not True:
            raise ValueError("inputContinuityUnconfirmed")
        return dict(status="PASS", stage="visibleStripOnly", samples=actual)
    except (KeyError,TypeError,ValueError,IndexError) as err:
        return dict(status="UNKNOWN",stage="visibleStripOnly",reason=str(err))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("receipt",type=Path)
    args=p.parse_args()
    result=replay(json.loads(args.receipt.read_bytes()).get("measurement",{}))
    print(json.dumps(result,indent=2))
    raise SystemExit(0 if result["status"] == "PASS" else 2)
