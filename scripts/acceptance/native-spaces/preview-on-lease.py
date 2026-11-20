#!/usr/bin/env python3
"""Measure installed two-window previews on an already enrolled ordinary Space."""
import argparse
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from installed_profile import PROFILE, owns_profile
from space_scope import require

driver = importlib.import_module("preview-workspace")


def empty_system_desktop(workspace, target):
    observations = []
    for _ in range(2):
        inventory = workspace.read()
        state = workspace.check(inventory)
        census = inventory["scopedMembers"][str(target)]
        require(state["current"] == target and census["ordinary"] == [] and census["unresolved"] == 0,
                "leased desktop has an ordinary or unidentified member")
        others = census["otherDetails"]
        require(len(others) == census["otherMembers"] and all(
            member["installedHost"] == 1 or
            (member["code"]["apple"] and member["code"]["identifier"] in
             ("com.apple.dock", "com.apple.WindowServer", "com.apple.WindowManager"))
            for member in others), "extra surface does not belong to the enrolled Host or system compositor")
        observations.append(dict(uptime=inventory["uptime"], ordinary=0, unresolved=0,
                                 extraOwners=[m["code"]["identifier"] for m in others]))
        time.sleep(.16)
    return observations


def run(args):
    os.umask(0o077)
    kit, output = args.kit.resolve(strict=True), args.output.resolve()
    require(kit.parent == Path("/private/tmp") and kit.name.startswith("nearpane-d01.") and
            kit.stat().st_uid == os.getuid() and not kit.stat().st_mode & 0o077, "unqualified fixture kit")
    preview = driver.validate_script(args.preview, "paired-preview.py")
    media = driver.validate_script(args.media, "live-preview-media.py")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    result = {"status": "BLOCKED", "newDesktops": 0, "preview": {"status": "NOT_RUN"},
              "stageRestore": {"status": "NOT_NEEDED"}, "media": {"status": "NOT_RUN"}}

    def save():
        temporary = output / "result.next"
        temporary.write_text(json.dumps(result, indent=2) + "\n")
        temporary.replace(output / "result.json")

    def record(event, **fields):
        with (output / "lease-events.jsonl").open("a") as f:
            f.write(json.dumps(dict(event=event, **fields)) + "\n")

    stage = None
    original_stage = None
    save()
    try:
        workspace = driver.PreviewWorkspace(kit, args.workspace.resolve(strict=True), record, resume=True)
        workspace.bind_quiet_cleanup()
        home = Path(os.environ["NEARPANE_TEST_HOME"])
        require(owns_profile(workspace.host["pid"], home / PROFILE), "installed Host does not hold the isolated profile")
        _, space_uuid = driver.lease_for(workspace, args.expected_space)
        result["lease"] = dict(space=args.expected_space, uuid=space_uuid, original=workspace.cleanup_current)
        result["admission"] = empty_system_desktop(workspace, args.expected_space)
        original_stage = driver.states(kit)[-1]["state"]
        stage = driver.PreferenceStage(kit, output, workspace, args.expected_space)
        require(stage.runtime(original_stage)["status"] == "PASS", "initial installed state not independently confirmed")
        if original_stage:
            result["stageSetup"] = stage.toggle("stage-off", True, False)
        result["offZeroBefore"] = driver.surface_checkpoint(kit, workspace.host, args.expected_space, False, 0)
        require(result["offZeroBefore"]["status"] == "PASS", "initial Host window area not empty")
        save()
        child = subprocess.run([sys.executable, preview, kit, output / "preview", "--expected-space",
                                str(args.expected_space), "--witness", "--preview-sampler", "streams"], timeout=160)
        proof = driver.readable_result(output / "preview/result.json")
        result["preview"] = dict(status=proof["status"], reason=proof.get("reason"), exit=child.returncode)
        result["afterFixture"] = empty_system_desktop(workspace, args.expected_space)
        result["offZeroAfter"] = driver.surface_checkpoint(kit, workspace.host, args.expected_space, False, 0)
        result["status"] = proof["status"] if result["offZeroAfter"]["status"] == "PASS" else "BLOCKED"
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        result["reason"] = str(error)[:260] or "interrupted"
    finally:
        if stage is not None and original_stage is not None:
            try:
                result["stageRestore"] = stage.restore(original_stage)
            except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                result["stageRestore"] = dict(status="BLOCKED", reason=str(error)[:260])
            if result["stageRestore"]["status"] != "PASS":
                result["status"] = "BLOCKED"
        save()
        if (output / "preview/result.json").is_file():
            try:
                proc = subprocess.run([sys.executable, media, output / "preview"], timeout=30)
                result["media"] = dict(status=driver.readable_result(output / "preview/media/receipt.json")["status"],
                                       exit=proc.returncode)
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                result["media"] = dict(status="BLOCKED", reason=str(error)[:160])
        save()
    return 0 if result["status"] == "PASS" else 2


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kit", type=Path)
    parser.add_argument("workspace", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--expected-space", required=True, type=int)
    src = Path(__file__).resolve().parent
    parser.add_argument("--preview", type=Path, default=src / "paired-preview.py")
    parser.add_argument("--media", type=Path, default=src / "live-preview-media.py")
    raise SystemExit(run(parser.parse_args()))
