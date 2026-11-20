#!/usr/bin/env python3
"""Build the two mock ABI fixtures and run the move readback tests. Never opens a window."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[3]
ADAPTER = Path("Sources/CNativeSpaceActions/NativeSpaceActions.m")
FIXTURE = Path("scripts/acceptance/native-spaces/bridge-abi-fixture.m")


def run(args, **options):
    return subprocess.run(args, cwd=ROOT, text=True, check=True, **options)


def qualify(directory):
    common = ["xcrun", "clang", "-Werror", "-DNP_MOVE_ABI_FIXTURE=1",
              "-ISources/CNativeSpaceActions", "-ISources/CNativeSpaceActions/include"]
    fixture = directory / "fixture.o"
    run([*common, "-fobjc-arc", "-c", FIXTURE, "-o", fixture])
    variants = {}
    for flag in ["-fobjc-arc", "-fno-objc-arc"]:
        binary = directory / flag[1:]
        run([*common, flag, ADAPTER, fixture, "-framework", "Foundation", "-framework", "ApplicationServices", "-o", binary])
        variants[flag] = json.loads(run([binary], stdout=subprocess.PIPE).stdout)
    xml = directory / "swift.xml"
    run([str(ROOT/"scripts/test.sh"), "--jobs", "4", "--filter", "MoveReadbackTests|WindowWitnessTests|ActionInventoryTests",
         "--xunit-output", xml], env={**os.environ, "NEARPANE_FOUNDATION_ONLY": "1"}, stdout=sys.stderr)
    suites = {}
    for case in ET.parse(xml).findall(".//testcase"):
        if any(case.find(kind) is not None for kind in ("failure", "error", "skipped")):
            raise ValueError("Unverified move case: " + case.get("name"))
        suites.setdefault(case.get("classname"), []).append(case.get("name"))
    if len(suites.get("NearpaneSpaceActionTests.MoveReadbackTests", [])) < 5:
        raise ValueError("Missing production move readback or closed request test")
    inputs = [ADAPTER, ADAPTER.with_name("PreparedWindowMove.h"), ADAPTER.parent / "include/NativeSpaceActions.h",
              FIXTURE, Path("Sources/NearpaneSpaceAction/main.swift"), Path("Sources/NearpaneSpaceAction/WindowWitness.swift"),
              Path("Sources/NearpaneSpaceAction/Inventory.swift"), Path("Tests/NearpaneSpaceActionTests/MoveReadbackTests.swift")]
    return {"status": "OFFLINE_PASS", "osBuild": run(["sysctl", "-n", "kern.osversion"], stdout=subprocess.PIPE).stdout.strip(),
            "architecture": platform.machine(), "systemMoveDispatch": "DISABLED", "installedRoundTrip": "NOT_RUN",
            "abiMocks": variants, "swiftTests": {name: sorted(tests) for name, tests in suites.items()},
            "sourceSHA256": {str(path): hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in inputs}}


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nearpane-closed-move-") as scratch:
        print(json.dumps(qualify(Path(scratch)), indent=2, sort_keys=True))
