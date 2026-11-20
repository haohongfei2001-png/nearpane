#!/usr/bin/env python3
"""Run the deterministic P5 suites. The only live kernel sample belongs to this test process."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
HIDDEN = Path("engineering/verification/native-spaces/5.22-90-active-display-previews/installed-hidden-minute/result.json")
LIFECYCLE = Path("engineering/verification/native-spaces/5.22-90-installed-contract/runs/final-lifecycle/results.json")


def archive(path):
    raw = (ROOT/path).read_bytes()
    return json.loads(raw), {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest()}


def main():
    suite_names = ["WorkspaceLayoutTests", "ActiveSpaceLayoutTests", "NativeDesktopProviderTests", "HostLifecycleTests"]
    with tempfile.TemporaryDirectory(prefix="nearpane-p5-readback-") as temp:
        xml = Path(temp)/"swift.xml"
        subprocess.run([str(ROOT/"scripts/test.sh"),"--jobs","4","--filter","|".join(suite_names),"--xunit-output",xml],
                       cwd=ROOT,env={**os.environ,"NEARPANE_FOUNDATION_ONLY":"1"},stdout=sys.stderr,check=True)
        swift = {}
        for case in ET.parse(xml).findall(".//testcase"):
            if any(case.find(kind) is not None for kind in ("failure", "error", "skipped")):
                raise ValueError("Incomplete Swift test: " + case.get("name"))
            swift.setdefault(case.get("classname").split(".")[-1],[]).append(case.get("name"))
    if set(swift) != set(suite_names):
        raise ValueError("Missing P5 suite")
    bench = unittest.defaultTestLoader.loadTestsFromName("test_performance.ArrivalDistributionTests")
    names = [test.id() for test in bench]
    tests = unittest.TextTestRunner(verbosity=2).run(bench)
    if not tests.wasSuccessful() or tests.skipped or len(names) < 6:
        raise ValueError("Unverified benchmark qualification")
    hidden, hidden_file = archive(HIDDEN)
    life, life_file = archive(LIFECYCLE)
    inputs = ["Sources/NearpaneCore/ManagedWindowTiler.swift", "Sources/NearpaneCore/HostSession.swift",
              "Sources/NearpaneCore/DesktopPreview.swift", "Sources/NearpaneUI/NativeDesktopProvider.swift",
              "Tests/NearpaneCoreTests/WorkspaceLayoutTests.swift", "Tests/NearpaneCoreTests/HostLifecycleTests.swift",
              "Tests/NearpaneCoreTests/ActiveSpaceLayoutTests.swift", "Tests/NearpaneUITests/NativeDesktopProviderTests.swift",
              *("scripts/acceptance/native-spaces/" + name for name in
                ("performance.py", "footprint.c", "core_contract.py", "test_performance.py"))]
    return {"status":"OFFLINE_PASS", "sourceSHA256":{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in inputs},
            "swiftTests":{k:sorted(v) for k,v in swift.items()},
            "benchmarkTests":names, "osBuild":subprocess.check_output(["sysctl","-n","kern.osversion"],text=True).strip(),
            "measuredGeometryOnDesktop":"NOT_RUN", "newPhysicalOperations":0,
            "plannedWindowCounts":[1,2,3,4,8], "warmedProductBatches":0, "nativeReferenceOperations":0,
            "productArrivalPercentilesMs":None, "physicalFrameDrops":None, "physicalWakeRecoveryMs":None,
            "previousInstalledEvidence":{
                "hiddenMinute":{**hidden_file,"source":hidden["installed"]["source"],"status":hidden["status"],
                                "noNewDeliveredFramesAcrossMinute":hidden["contract"]["noNewDeliveredFramesAcrossMinute"],
                                "newStreamsDuringHidden":hidden["contract"]["newStreamsDuringHidden"]},
                "lifecycle":{**life_file,**{k:life[k] for k in ("F01","M01","R02","splitView")}}}}


if __name__ == "__main__":
    print(json.dumps(main(), indent=2, sort_keys=True))
