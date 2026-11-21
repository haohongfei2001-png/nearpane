"""Verify the pinned Corner sources and preserve the earlier real marker failure separately."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[4]
PIN = "69a73665488243bf78982c6d523ac4e0850c1ddb"
HERE = Path(__file__).resolve().parent
CRATE = ROOT / "Engine/nearpane-window-engine"


def run(origin, upstream):
    tree = json.loads((upstream.parent / "upstream-tree.json").read_bytes())
    if tree.get("truncated") is not False:
        raise ValueError("incomplete upstream tree")
    known = {row["path"]: row["sha"] for row in tree["tree"] if row["type"] == "blob"}
    for row in origin:
        if not (CRATE / row["local"]).is_file():
            raise ValueError(row["local"])
        data = (upstream / row["upstream"]).read_bytes()
        commit_blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if known.get(row["upstream"]) != commit_blob or row["blob"] != commit_blob:
            raise ValueError("upstream blob does not match " + row["upstream"])
    history = ROOT / "engineering/verification/stage-groups/5.22-90/isolation/qualification/corner.json"
    prior = json.loads(history.read_bytes())
    if not (prior["status"] == "FAIL" and prior["reason"] == "parkedWindowReceivedRealMouseDown" and
            prior["realClickWindowIDs"] and prior["restoredOriginals"] and prior["maskCoversRealStrip"]):
        raise ValueError("unrecognized archived installed-window witness")
    tests = subprocess.run([HERE/"run-offline.sh"], text=True, stdout=subprocess.PIPE, check=True)
    passed = re.search(r"test result: ok\. (\d+) passed; 0 failed", tests.stdout)
    if not passed:
        raise ValueError("no complete Corner test result")
    hosted=ROOT/"engineering/verification/window-engine/runs/44881106930/corner"
    previous=json.loads((hosted/"result.json").read_bytes()) if (hosted/"result.json").is_file() else {}
    evidence=(hosted/"events.jsonl")
    archived=dict(status=previous.get("status","NOT_RUN"),reason=previous.get("reason"),completeCircles=previous.get("single"),
                  specificMissingField="UNKNOWN",archivedEventBytes=evidence.stat().st_size if evidence.is_file() else None)
    return dict(upstreamCommit=PIN, checkedBlobs=len(origin), sourceTree=tree["sha"], offlineTests=int(passed[1]),
                historicalComparison=dict(file=str(history.relative_to(ROOT)),sha256=hashlib.sha256(history.read_bytes()).hexdigest(),
                                          status=prior["status"],reason=prior["reason"],realClickWindowIDs=prior["realClickWindowIDs"]),
                completedNativeAssertions=["threeGroupOrderedStages", "guardianAuthorizationAndJournalCorrelation", "singleMainActualDisplayScope"],
                hostedRun44881106930=archived,
                macos27PhysicalRun="NOT_RUN", receiverMarkers="NOT_RUN", guardianCrash="NOT_RUN",
                optionalWallpaperPatch="NOT_RUN", qualification="UNQUALIFIED")


if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--upstream",type=Path,default=ROOT/"build/window-engine/upstream")
    parser.add_argument("--output",type=Path)
    args=parser.parse_args()
    result=run(json.loads((CRATE/"origins/corner.json").read_bytes()),args.upstream)
    text=json.dumps(result,indent=2)+"\n"
    if args.output:
        with args.output.open("x") as f:f.write(text)
    print(text,end="")
