#!/usr/bin/env python3
"""Exercise the installed sidebar on an already enrolled ordinary Space."""
import argparse
import importlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

from installed_profile import APP, PROFILE, owns_profile
from acceptance import Receipt
from contract_document import run as run_documents
from space_scope import require

driver = importlib.import_module("preview-workspace")


def empty_system_desktop(workspace, target):
    observations = []
    prior_surfaces = None
    for _ in range(2):
        inventory = workspace.read()
        state = workspace.check(inventory)
        census = inventory["scopedMembers"][str(target)]
        require(state["current"] == target and census["unresolved"] == 0, "leased desktop has an unidentified member")
        surfaces = []
        for member in census["ordinary"]:
            query = dict(display=workspace.display, space=target, pid=member["pid"], number=member["number"])
            proof = json.loads(subprocess.check_output(
                [workspace.kit / "split-view-read", "compare-roster", "inactive-stage-surface"],
                input=json.dumps(query), text=True, timeout=4))
            require(proof.get("admitted") is True, "leased desktop has an ordinary application window")
            surfaces.append(proof)
        surfaces.sort(key=lambda entry: entry["number"])
        require(prior_surfaces is None or prior_surfaces == surfaces, "inactive Stage Manager surfaces changed")
        prior_surfaces = surfaces
        others = census["otherDetails"]
        require(len(others) == census["otherMembers"] and all(
            member["installedHost"] == 1 or
            (member["code"]["apple"] and member["code"]["identifier"] in
             ("com.apple.dock", "com.apple.WindowServer", "com.apple.WindowManager"))
            for member in others), "extra surface does not belong to the enrolled Host or system compositor")
        observations.append(dict(uptime=inventory["uptime"], ordinary=0, unresolved=0,
                                 inactiveStageSurfaces=surfaces, extraOwners=[m["code"]["identifier"] for m in others]))
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
        ledgers = None
        if args.original_checkout:
            ledgers = args.original_checkout / "build/verification/secondary-route-followup"
            require(ledgers.resolve(strict=True) == ledgers and ledgers.is_dir(), "unrecognized original lease directory")
        workspace = driver.PreviewWorkspace(kit, args.workspace.resolve(strict=True), record, resume=True,
                                            previous_archive=args.previous_archive, install_receipt=args.install_receipt,
                                            original_ledgers=ledgers)
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
        if args.scenario == "same-space-documents":
            require(subprocess.run(["/usr/bin/pgrep", "-x", "TextEdit"], capture_output=True).returncode == 1,
                    "a TextEdit process is already running")
            document_receipt = Receipt(output / "documents")
            try:
                proof = run_documents(workspace, document_receipt, args.expected_space)
                document_receipt.scenarios["W01"] = proof
                result["documents"] = {k: proof[k] for k in ("status", "operationStatus", "reason", "issued", "passes", "cleanup")}
            finally:
                document_receipt.finish()
        elif args.scenario == "five-windows":
            five_script = driver.validate_script(Path(__file__).resolve().with_name("five-preview.py"), "five-preview.py")
            require(args.five_window_kit is not None, "the five-window fixture kit is required")
            installed = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
            require(installed.get("NearpaneSourceState") == "clean", "five-window trial requires a frozen candidate")
            child = subprocess.run([sys.executable, five_script, args.five_window_kit, output / "five-windows",
                                    "--expected-space", str(args.expected_space), "--expected-display", workspace.display,
                                    "--expected-space-uuid", space_uuid, "--expected-source", installed["NearpaneSourceRevision"]],
                                   timeout=150)
            proof = driver.readable_result(output / "five-windows/result.json")
            result["fiveWindows"] = dict(status=proof["status"], reason=proof.get("reason"), exit=child.returncode)
        else:
            child = subprocess.run([sys.executable, preview, kit, output / "preview", "--expected-space",
                                    str(args.expected_space), "--witness", "--preview-sampler", "streams"], timeout=160)
            proof = driver.readable_result(output / "preview/result.json")
            result["preview"] = dict(status=proof["status"], reason=proof.get("reason"), exit=child.returncode)
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
            elif result["preview"]["status"] != "NOT_RUN" or "documents" in result or "fiveWindows" in result:
                try:
                    result["afterFixture"] = empty_system_desktop(workspace, args.expected_space)
                except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                    result["cleanupReason"] = str(error)[:260]
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
    parser.add_argument("--scenario", choices=("paired-preview", "same-space-documents", "five-windows"), default="paired-preview")
    parser.add_argument("--five-window-kit", type=Path, help="signed five-application kit for the five-windows scenario")
    parser.add_argument("--previous-archive", type=Path)
    parser.add_argument("--install-receipt", type=Path)
    parser.add_argument("--original-checkout", type=Path)
    src = Path(__file__).resolve().parent
    parser.add_argument("--preview", type=Path, default=src / "paired-preview.py")
    parser.add_argument("--media", type=Path, default=src / "live-preview-media.py")
    raise SystemExit(run(parser.parse_args()))
