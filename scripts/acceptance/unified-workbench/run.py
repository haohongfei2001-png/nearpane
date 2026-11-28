#!/usr/bin/env python3
"""Drive the packaged app's existing disposable native acceptance entry point.

This is run on an ephemeral macOS CI desktop. The original candidate is untouched;
an ad-hoc signed copy uses the existing alpha fixture identity. Captured UI is real
AppKit/SwiftUI, while library entries and playback state are explicitly fixtures.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid


def main() -> int:
    repo = Path(__file__).resolve().parents[3]
    candidate = Path(sys.argv[1]).resolve()
    output = repo / "build/unified-workbench-evidence"
    output.mkdir(parents=True, exist_ok=True)
    session_id = str(uuid.uuid4())
    staging = repo / "build" / ("unified-workbench." + session_id)
    app = staging / "Nearpane.app"
    session = repo / "build/native-acceptance" / session_id
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    receipt = {
        "schema": 1,
        "sourceCommit": commit,
        "status": "RUNNING",
        "scope": "Packaged native UI / isolated fixture data / no real Spaces qualification",
        "fixtureSession": session_id,
        "candidateSHA256": hashlib.sha256((candidate / "Contents/MacOS/NearpaneHost").read_bytes()).hexdigest(),
    }
    try:
        staging.mkdir(parents=True)
        subprocess.run(["/usr/bin/ditto", str(candidate), str(app)], check=True)
        info = app / "Contents/Info.plist"
        with info.open("rb") as stream:
            values = plistlib.load(stream)
        values["CFBundleIdentifier"] = "com.holdsnow.nearpane.alpha"
        values["NearpaneUnifiedWorkbenchCommit"] = commit
        with info.open("wb") as stream:
            plistlib.dump(values, stream)
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, capture_output=True)
        binary = app / "Contents/MacOS/NearpaneHost"
        receipt["fixtureExecutableSHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        receipt["fixtureBundleID"] = "com.holdsnow.nearpane.alpha"
        env = dict(os.environ, NEARPANE_ACCEPTANCE_CHECKOUT=str(repo))
        for mode, name, timeout in [
            ("--native-acceptance-prepare", "native-prepare.log", 45),
            ("--native-settings-readback", "native-workbench.log", 180),
        ]:
            with (output / name).open("w") as log:
                process = subprocess.run([str(binary), "--verify-bundled-resources", mode, session_id],
                                         cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
            if process.returncode:
                raise RuntimeError(f"{mode} exited {process.returncode}; see {name}")
        native = json.loads((session / "workbench/native-workbench-receipt.json").read_text())
        if native["status"] != "PASS":
            raise RuntimeError("Native workbench receipt did not pass")
        receipt["status"] = "PASS"
    except Exception as error:
        receipt["status"] = "FAIL"
        receipt["error"] = str(error)
    finally:
        # Persist only the generated acceptance evidence, never a reusable fixture
        # library or an unknown system window/screen capture.
        if (session / "workbench").is_dir():
            shutil.copytree(session / "workbench", output / "native", dirs_exist_ok=True)
        if (session / "status-menu.json").is_file():
            shutil.copy2(session / "status-menu.json", output / "status-menu.json")
        (output / "runner-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt, indent=2))
    return 0 if receipt["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
